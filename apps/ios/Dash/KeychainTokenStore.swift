import CloudflareAPI
import Darwin
import Foundation
import Security

actor KeychainTokenStore: TokenStore {
  private enum Key {
    static let access = "dash.access_token"
    static let refresh = "dash.refresh_token"
    static let expiry = "dash.expires_at"
    static let scopes = "dash.granted_scopes"
  }

  /// Cross-process refresh coordination.
  ///
  /// This credential is shared through the keychain access group with every
  /// bundle that talks to Cloudflare — DashShare today, a File Provider next —
  /// and Cloudflare rotates the refresh token on use. Two processes that 401 at
  /// the same instant would otherwise both POST the same refresh token: the
  /// first rotates it, the second is told `invalid_grant`, and the loser can
  /// wipe a keychain the winner has not written back to yet. Both end up signed
  /// out and only a full re-OAuth recovers.
  ///
  /// The lock is `flock` on a file in the App Group container rather than a
  /// keychain item, for the reason that outranks every other consideration
  /// here: the kernel drops a `flock` when the open file description goes away,
  /// including on `SIGKILL`. A File Provider extension is killed routinely, and
  /// a lock that outlived its holder would wedge the app until reboot.
  /// `SecItemAdd` returning `errSecDuplicateItem` is also an atomic
  /// test-and-set, but nothing releases it when the holder dies.
  private enum RefreshLock {
    static let appGroupID = "group.sh.xat.dash.app"
    static let fileName = "dash.token-refresh.lock"
    /// A token POST is a few hundred milliseconds. Still waiting seconds later
    /// means the holder is stalled on a dying network, not about to finish.
    static let timeout: TimeInterval = 5
    static let retryDelay: Duration = .milliseconds(25)
  }

  private let service = "sh.xat.dash.app"
  private var refreshTurnHeld = false
  private var refreshTurnWaiters: [CheckedContinuation<Void, Never>] = []

  private var accessGroup: String? {
    guard
      let group = Bundle.main.object(forInfoDictionaryKey: "DashKeychainAccessGroup") as? String,
      !group.isEmpty, !group.contains("$(")
    else { return nil }
    return group
  }

  func clear() async throws {
    try delete(Key.access)
    try delete(Key.refresh)
    try delete(Key.expiry)
    try delete(Key.scopes)
  }

  func getAccessToken() async throws -> String? { try read(Key.access) }
  func getRefreshToken() async throws -> String? { try read(Key.refresh) }
  func getGrantedScopes() async throws -> Set<String>? {
    guard let value = try read(Key.scopes) else { return nil }
    return Set(value.split(separator: " ").map(String.init))
  }

  func setGrantedScopes(_ scopes: Set<String>) async throws {
    try write(scopes.sorted().joined(separator: " "), key: Key.scopes)
  }

  func setTokens(_ tokens: TokenSet) async throws {
    try store(tokens)
  }

  func replaceTokens(
    _ tokens: TokenSet,
    ifCurrentAccessToken expectedAccessToken: String?,
    refreshToken expectedRefreshToken: String?
  ) async throws -> Bool {
    guard
      try read(Key.access) == expectedAccessToken,
      try read(Key.refresh) == expectedRefreshToken
    else {
      return false
    }
    try store(tokens)
    return true
  }

  func clearTokens(
    ifCurrentAccessToken expectedAccessToken: String?,
    refreshToken expectedRefreshToken: String?
  ) async throws -> Bool {
    guard
      try read(Key.access) == expectedAccessToken,
      try read(Key.refresh) == expectedRefreshToken
    else {
      return false
    }
    try clearStoredCredential()
    return true
  }

  func withExclusiveRefreshAccess<T: Sendable>(
    _ body: @Sendable (_ isExclusive: Bool) async throws -> T
  ) async throws -> T {
    // `flock` is held per open file description, so a second descriptor opened
    // by *this* process contends with the first: both callers would spin to the
    // timeout and then proceed unlocked, which is the opposite of the point.
    // Same-process overlap is real — `AppModel` builds a fresh `CloudflareClient`
    // on sign-in while the previous one may still have a request in flight, and
    // each instance carries its own single-flight. Serialise here first, then
    // reach for the file lock exactly once.
    await beginRefreshTurn()
    defer { endRefreshTurn() }

    guard let descriptor = Self.openLockFile() else {
      // Failure to open the shared lock cannot prove no sibling process is
      // refreshing. Fail closed instead of spending a rotating token without
      // mutual exclusion.
      return try await body(false)
    }
    // `close` releases the lock too; the explicit unlock is for readers.
    defer { _ = close(descriptor) }
    let isExclusive = await Self.lockExclusively(descriptor)
    defer { if isExclusive { _ = flock(descriptor, LOCK_UN) } }
    return try await body(isExclusive)
  }

  /// In-process turn-taking for the file lock. The `while` re-check plus a
  /// wake-all release means a caller that barges in between a resume and its
  /// waiter running simply sends that waiter back to sleep — no FIFO
  /// bookkeeping, no lost wakeup.
  private func beginRefreshTurn() async {
    while refreshTurnHeld {
      await withCheckedContinuation { continuation in
        refreshTurnWaiters.append(continuation)
      }
    }
    refreshTurnHeld = true
  }

  private func endRefreshTurn() {
    refreshTurnHeld = false
    let waiters = refreshTurnWaiters
    refreshTurnWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }

  private static func openLockFile() -> Int32? {
    guard
      let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: RefreshLock.appGroupID)
    else { return nil }
    let path = container.appendingPathComponent(RefreshLock.fileName, isDirectory: false).path
    if !FileManager.default.fileExists(atPath: path) {
      // Match the credential's own accessibility. A File Provider extension can
      // be woken with the device locked, and the default protection class would
      // make the lock file unopenable exactly then.
      FileManager.default.createFile(
        atPath: path, contents: nil,
        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    }
    let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    return descriptor < 0 ? nil : descriptor
  }

  /// Never a blocking `LOCK_EX`: this actor runs on a Swift-concurrency
  /// cooperative thread, the pool is sized to the core count, and parking one
  /// of them for the length of another process's token POST is a stall the
  /// pool cannot absorb. `Task.sleep` gives the thread back between attempts.
  private static func lockExclusively(_ descriptor: Int32) async -> Bool {
    let deadline = Date().addingTimeInterval(RefreshLock.timeout)
    while true {
      if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return true }
      // Only "somebody else holds it" is worth waiting on; a bad descriptor or
      // an unsupported filesystem will not clear.
      guard errno == EWOULDBLOCK, Date() < deadline else { return false }
      do { try await Task.sleep(for: RefreshLock.retryDelay) } catch { return false }
    }
  }

  private func store(_ tokens: TokenSet) throws {
    try write(tokens.accessToken, key: Key.access)
    if let refresh = tokens.refreshToken { try write(refresh, key: Key.refresh) }
    if let scope = tokens.scope {
      try write(
        scope.split(separator: " ").map(String.init).sorted().joined(separator: " "),
        key: Key.scopes
      )
    }
    if let expiresIn = tokens.expiresIn {
      try write(
        String(Date().addingTimeInterval(TimeInterval(expiresIn)).timeIntervalSince1970),
        key: Key.expiry)
    }
  }

  private func clearStoredCredential() throws {
    try delete(Key.access)
    try delete(Key.refresh)
    try delete(Key.expiry)
    try delete(Key.scopes)
  }

  private func query(_ key: String) -> [String: Any] {
    var item: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrAccount as String: key,
      kSecAttrService as String: service,
    ]
    if let accessGroup {
      item[kSecAttrAccessGroup as String] = accessGroup
    }
    return item
  }

  private func read(_ key: String) throws -> String? {
    var query = query(key)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status) }
    return String(data: data, encoding: .utf8)
  }

  private func write(_ value: String, key: String) throws {
    let data = Data(value.utf8)
    let status = SecItemUpdate(
      query(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      var item = query(key)
      item[kSecValueData as String] = data
      item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      let addStatus = SecItemAdd(item as CFDictionary, nil)
      guard addStatus == errSecSuccess else { throw KeychainError(addStatus) }
    } else if status != errSecSuccess {
      throw KeychainError(status)
    }
  }

  private func delete(_ key: String) throws {
    let status = SecItemDelete(query(key) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainError(status)
    }
  }
}

private struct KeychainError: Error, LocalizedError {
  let status: OSStatus
  init(_ status: OSStatus) { self.status = status }
  var errorDescription: String? {
    SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
  }
}
