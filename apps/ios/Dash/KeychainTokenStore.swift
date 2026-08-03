import CloudflareAPI
import Darwin
import Foundation
import Security

/// The exact fields Dash persists for one Cloudflare credential.
///
/// Expiry remains an absolute, raw timestamp here. Converting it back through
/// `TokenSet.expiresIn` during rollback would silently extend or shorten the
/// old credential, so recovery writes these values back byte-for-byte.
struct KeychainStoredCredentialSnapshot: Equatable, Sendable {
  let accessToken: String?
  let refreshToken: String?
  let rawExpirationTimestamp: String?
  let rawGrantedScopes: String?

  var grantedScopes: Set<String>? {
    rawGrantedScopes.map { Set($0.split(separator: " ").map(String.init)) }
  }

  /// Suitable for a short-lived client that only needs to finish cleanup with
  /// a credential already removed from the shared Keychain. Exact restoration
  /// must use the raw snapshot instead.
  var tokenSet: TokenSet? {
    guard let accessToken else { return nil }
    return TokenSet(
      accessToken: accessToken,
      refreshToken: refreshToken,
      scope: rawGrantedScopes)
  }

  static let empty = KeychainStoredCredentialSnapshot(
    accessToken: nil,
    refreshToken: nil,
    rawExpirationTimestamp: nil,
    rawGrantedScopes: nil)
}

/// Receipt for an OAuth credential replacement that actually committed.
/// Keeping the installed snapshot beside the removed one turns rollback into
/// a full compare-and-swap rather than permission to overwrite a credential a
/// sibling process may have rotated or a later OAuth flow may have installed.
struct KeychainCredentialReplacement: Equatable, Sendable {
  let previousCredential: KeychainStoredCredentialSnapshot
  let installedCredential: KeychainStoredCredentialSnapshot

  func permitsRestoration(over current: KeychainStoredCredentialSnapshot) -> Bool {
    current == installedCredential
  }
}

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
    _ = try await removeCredential()
  }

  /// Removes and returns the credential that was actually present while the
  /// cross-process lock was held. A missing access token still clears orphaned
  /// refresh, expiry, and scope fields, but returns `nil` because there is no
  /// usable credential for post-sign-out cleanup.
  func removeCredential() async throws -> KeychainStoredCredentialSnapshot? {
    try await withExclusiveRefreshAccess { [self] isExclusive in
      guard isExclusive else {
        throw KeychainCredentialCoordinationError.exclusiveAccessUnavailable
      }
      return try await removeCredentialWhileLocked()
    }
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
    try await withExclusiveRefreshAccess { [self] isExclusive in
      guard isExclusive else {
        throw KeychainCredentialCoordinationError.exclusiveAccessUnavailable
      }
      try await storeWhileLocked(tokens)
    }
  }

  /// Installs a browser-authorized identity as one cross-process transaction.
  /// A Widget refresh that started with the prior rotating token either
  /// finishes before this critical section or loses its later CAS; it can
  /// never interleave individual Keychain writes from two identities.
  @discardableResult
  func replaceCredential(with tokens: TokenSet) async throws -> KeychainCredentialReplacement {
    try await replaceCredential(with: tokens, overridingGrantedScopes: nil)
  }

  /// The OAuth caller already knows the effective grant when the response
  /// omits `scope`. Installing it in this transaction keeps the receipt's full
  /// snapshot stable for a later compare-and-swap restoration.
  @discardableResult
  func replaceCredential(
    with tokens: TokenSet,
    grantedScopes: Set<String>
  ) async throws -> KeychainCredentialReplacement {
    try await replaceCredential(with: tokens, overridingGrantedScopes: grantedScopes)
  }

  /// Restores the exact credential removed by `replaceCredential`, but only if
  /// no field of the installed credential has changed since. In particular, a
  /// Widget token rotation or a later OAuth replacement makes this return
  /// `false` instead of overwriting that newer credential.
  func restoreCredential(from replacement: KeychainCredentialReplacement) async throws -> Bool {
    try await withExclusiveRefreshAccess { [self] isExclusive in
      guard isExclusive else {
        throw KeychainCredentialCoordinationError.exclusiveAccessUnavailable
      }
      return try await restoreCredentialWhileLocked(from: replacement)
    }
  }

  private func replaceCredential(
    with tokens: TokenSet,
    overridingGrantedScopes grantedScopes: Set<String>?
  ) async throws -> KeychainCredentialReplacement {
    try await withExclusiveRefreshAccess { [self] isExclusive in
      guard isExclusive else {
        throw KeychainCredentialCoordinationError.exclusiveAccessUnavailable
      }
      return try await replaceCredentialWhileLocked(
        with: tokens,
        overridingGrantedScopes: grantedScopes)
    }
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
    // Cloudflare rotates the refresh token as soon as the token endpoint
    // succeeds. Persist it before publishing the matching access token so a
    // process termination between keychain writes leaves the old access token
    // paired with the new, still-spendable refresh token. The next 401 can then
    // recover normally instead of retrying a refresh token Cloudflare retired.
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
    // Treat the access token as the commit marker for the credential set.
    try write(tokens.accessToken, key: Key.access)
  }

  private func clearStoredCredential() throws {
    // A refresh token can mint a replacement access token. Remove that
    // capability first and delete access last as the credential's invalidation
    // commit marker; interruption can leave a short-lived access token, but
    // never a refresh-only credential that an extension silently resurrects.
    try delete(Key.refresh)
    try delete(Key.scopes)
    try delete(Key.expiry)
    try delete(Key.access)
  }

  private func storeWhileLocked(_ tokens: TokenSet) throws {
    try store(tokens)
  }

  private func removeCredentialWhileLocked() throws -> KeychainStoredCredentialSnapshot? {
    let removed = try readStoredCredential()
    guard removed != .empty else { return nil }
    try transitionStoredCredential(to: .empty, rollingBackTo: removed)
    return removed.accessToken == nil ? nil : removed
  }

  private func replaceCredentialWhileLocked(
    with tokens: TokenSet,
    overridingGrantedScopes grantedScopes: Set<String>?
  ) throws -> KeychainCredentialReplacement {
    let previous = try readStoredCredential()
    let installed = replacementSnapshot(
      for: tokens,
      overridingGrantedScopes: grantedScopes)
    try transitionStoredCredential(to: installed, rollingBackTo: previous)
    return KeychainCredentialReplacement(
      previousCredential: previous,
      installedCredential: installed)
  }

  private func restoreCredentialWhileLocked(
    from replacement: KeychainCredentialReplacement
  ) throws -> Bool {
    let current = try readStoredCredential()
    guard replacement.permitsRestoration(over: current) else { return false }
    try transitionStoredCredential(
      to: replacement.previousCredential,
      rollingBackTo: current)
    return true
  }

  private func replacementSnapshot(
    for tokens: TokenSet,
    overridingGrantedScopes grantedScopes: Set<String>?
  ) -> KeychainStoredCredentialSnapshot {
    let rawGrantedScopes =
      grantedScopes.map(Self.encodeScopes)
      ?? tokens.scope.map(Self.normalizeScopes)
    let rawExpirationTimestamp = tokens.expiresIn.map {
      String(Date().addingTimeInterval(TimeInterval($0)).timeIntervalSince1970)
    }
    return KeychainStoredCredentialSnapshot(
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken,
      rawExpirationTimestamp: rawExpirationTimestamp,
      rawGrantedScopes: rawGrantedScopes)
  }

  private func readStoredCredential() throws -> KeychainStoredCredentialSnapshot {
    try KeychainStoredCredentialSnapshot(
      accessToken: read(Key.access),
      refreshToken: read(Key.refresh),
      rawExpirationTimestamp: read(Key.expiry),
      rawGrantedScopes: read(Key.scopes))
  }

  private func store(_ snapshot: KeychainStoredCredentialSnapshot) throws {
    if let refreshToken = snapshot.refreshToken {
      try write(refreshToken, key: Key.refresh)
    }
    if let rawGrantedScopes = snapshot.rawGrantedScopes {
      try write(rawGrantedScopes, key: Key.scopes)
    }
    if let rawExpirationTimestamp = snapshot.rawExpirationTimestamp {
      try write(rawExpirationTimestamp, key: Key.expiry)
    }
    if let accessToken = snapshot.accessToken {
      try write(accessToken, key: Key.access)
    }
  }

  /// Keychain has no multi-item transaction. If a delete or write fails, put
  /// the exact pre-mutation snapshot back before releasing the flock. A second
  /// failure means the credential cannot be proven and is surfaced distinctly
  /// so callers fail closed instead of binding work to a guessed identity.
  private func transitionStoredCredential(
    to desired: KeychainStoredCredentialSnapshot,
    rollingBackTo previous: KeychainStoredCredentialSnapshot
  ) throws {
    do {
      try clearStoredCredential()
      try store(desired)
    } catch let mutationError {
      do {
        try clearStoredCredential()
        try store(previous)
      } catch {
        throw KeychainCredentialCoordinationError.credentialStateUncertain
      }
      throw mutationError
    }
  }

  private static func normalizeScopes(_ value: String) -> String {
    encodeScopes(Set(value.split(separator: " ").map(String.init)))
  }

  private static func encodeScopes(_ scopes: Set<String>) -> String {
    scopes.sorted().joined(separator: " ")
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

enum KeychainCredentialCoordinationError: Error, LocalizedError, Sendable {
  case exclusiveAccessUnavailable
  case credentialStateUncertain

  var errorDescription: String? {
    DashL10n.string("Cloudflare couldn’t complete this request. Try again.")
  }
}

private struct KeychainError: Error, LocalizedError {
  let status: OSStatus
  init(_ status: OSStatus) { self.status = status }
  var errorDescription: String? {
    SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
  }
}
