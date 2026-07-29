import CloudflareAPI
import FileProvider
import Foundation

/// File Provider returns immutable domain descriptors from an Objective-C
/// completion handler, but the SDK type does not declare `Sendable`. Keep the
/// ownership assertion at that callback boundary so the rest of the domain
/// lifecycle continues to work with the system objects themselves.
private struct FileProviderDomainList: @unchecked Sendable {
  let values: [NSFileProviderDomain]
}

/// App-side ownership of Dash's replicated File Provider domains.
///
/// A domain identifier is the immutable Cloudflare account id. Its display
/// name stays the account name verbatim so Files and Dash describe the same
/// account without localizing or otherwise transforming user data.
enum FileProviderDomains {
  static let mirrorKey = "dash.file_provider_domains"
  private static let operationGate = FileProviderDomainOperationGate()

  private static var sharedDefaults: UserDefaults? {
    UserDefaults(suiteName: R2ShareDestination.appGroupID)
  }

  /// Reads live system state. The App Group value is only an extension-facing
  /// mirror; it is never accepted as UI truth.
  @discardableResult
  static func mountedAccountIDs() async throws -> Set<String> {
    try await operationGate.withLock {
      try await mountedAccountIDsUnlocked()
    }
  }

  private static func mountedAccountIDsUnlocked() async throws -> Set<String> {
    let domains = try await fetchDomains()
    let accountIDs = identifiers(in: domains)
    updateMirror(accountIDs)
    return accountIDs
  }

  /// Adds or refreshes an account's Files domain.
  ///
  /// File Provider can report `NSFileWriteFileExistsError` when the replica
  /// directory already exists. That error is idempotent only when a fresh
  /// domain read proves that this identifier is mounted.
  @discardableResult
  static func addDomain(for account: CloudflareAccount) async throws -> Set<String> {
    try await operationGate.withLock {
      try await addDomainUnlocked(for: account)
    }
  }

  private static func addDomainUnlocked(
    for account: CloudflareAccount
  ) async throws -> Set<String> {
    let domain = NSFileProviderDomain(
      identifier: NSFileProviderDomainIdentifier(account.id),
      displayName: account.name
    )

    do {
      try await add(domain)
    } catch {
      guard isFileExists(error) else { throw error }
      let domains = try await fetchDomains()
      let accountIDs = identifiers(in: domains)
      guard accountIDs.contains(account.id) else { throw error }
      updateMirror(accountIDs)
      return accountIDs
    }

    let domains = try await fetchDomains()
    let accountIDs = identifiers(in: domains)
    guard accountIDs.contains(account.id) else {
      throw FileProviderDomainsError.inconsistentState
    }
    updateMirror(accountIDs)
    return accountIDs
  }

  /// Destructively removes one account's replica and all downloaded data.
  ///
  /// A missing domain is already the requested result. A racing second remove
  /// is also accepted only after a live re-read proves the domain is gone.
  @discardableResult
  static func removeDomain(accountID: String) async throws -> Set<String> {
    try await operationGate.withLock {
      try await removeDomainUnlocked(accountID: accountID)
    }
  }

  private static func removeDomainUnlocked(accountID: String) async throws -> Set<String> {
    let domains = try await fetchDomains()
    guard let domain = domains.first(where: { identifier(of: $0) == accountID }) else {
      let accountIDs = identifiers(in: domains)
      updateMirror(accountIDs)
      return accountIDs
    }

    do {
      try await remove(domain)
    } catch {
      let refreshedDomains = try await fetchDomains()
      let accountIDs = identifiers(in: refreshedDomains)
      guard !accountIDs.contains(accountID) else { throw error }
      updateMirror(accountIDs)
      return accountIDs
    }

    let refreshedDomains = try await fetchDomains()
    let accountIDs = identifiers(in: refreshedDomains)
    guard !accountIDs.contains(accountID) else {
      throw FileProviderDomainsError.inconsistentState
    }
    updateMirror(accountIDs)
    return accountIDs
  }

  /// Removes mounted domains whose credentials can no longer exist.
  ///
  /// This is intentionally a subtraction, not a top-up: mounting is an
  /// explicit user choice, while orphan removal is required to prevent a
  /// permanently unauthenticated location in Files.
  @discardableResult
  static func reconcile(
    accounts: [CloudflareAccount],
    preservingAccountIDs: Set<String> = []
  ) async throws -> Set<String> {
    try await operationGate.withLock {
      try await reconcileUnlocked(
        accounts: accounts,
        preservingAccountIDs: preservingAccountIDs)
    }
  }

  private static func reconcileUnlocked(
    accounts: [CloudflareAccount],
    preservingAccountIDs: Set<String>
  ) async throws -> Set<String> {
    let validAccountIDs = Set(accounts.map(\.id))
    let domains = try await fetchDomains()
    try Task.checkCancellation()
    let orphanedIDs = orphanedAccountIDs(
      installed: identifiers(in: domains),
      validAccountIDs: validAccountIDs,
      preservingAccountIDs: preservingAccountIDs
    )
    let orphanedDomains = domains.filter {
      orphanedIDs.contains(identifier(of: $0))
    }

    try await removeDomains(orphanedDomains)
    try Task.checkCancellation()
    return try await mountedAccountIDsUnlocked()
  }

  /// Destructively removes every mounted replica. Call this before token
  /// revocation during sign-out or Demo exit.
  @discardableResult
  static func removeAllDomains() async throws -> Set<String> {
    try await operationGate.withLock {
      try await removeAllDomainsUnlocked()
    }
  }

  private static func removeAllDomainsUnlocked() async throws -> Set<String> {
    let domains = try await fetchDomains()
    try await removeDomains(domains)
    return try await mountedAccountIDsUnlocked()
  }

  static func clearMirror() {
    sharedDefaults?.removeObject(forKey: mirrorKey)
  }

  static func mirroredAccountIDs(
    in defaults: UserDefaults? = sharedDefaults
  ) -> Set<String> {
    Set(defaults?.stringArray(forKey: mirrorKey) ?? [])
  }

  /// Pure set-diff seam for reconciliation tests.
  static func orphanedAccountIDs(
    installed: Set<String>,
    validAccountIDs: Set<String>,
    preservingAccountIDs: Set<String> = []
  ) -> Set<String> {
    installed.subtracting(validAccountIDs.union(preservingAccountIDs))
  }

  private static func removeDomains(_ domains: [NSFileProviderDomain]) async throws {
    var firstError: Error?

    for domain in domains {
      try Task.checkCancellation()
      do {
        try await remove(domain)
      } catch let removalError {
        // File Provider operations can overlap lifecycle reconciliation. Only
        // suppress a racing remove when the live domain list confirms success.
        do {
          let refreshedDomains = try await fetchDomains()
          if refreshedDomains.contains(where: { identifier(of: $0) == identifier(of: domain) }) {
            firstError = firstError ?? removalError
          }
        } catch {
          firstError = firstError ?? removalError
        }
      }
    }

    if let firstError {
      // Keep the mirror authoritative even when one domain could not be
      // removed; the caller still receives the first actionable failure.
      if let refreshedDomains = try? await fetchDomains() {
        updateMirror(identifiers(in: refreshedDomains))
      }
      throw firstError
    }
  }

  private static func updateMirror(_ accountIDs: Set<String>) {
    sharedDefaults?.set(accountIDs.sorted(), forKey: mirrorKey)
  }

  private static func identifiers(in domains: [NSFileProviderDomain]) -> Set<String> {
    Set(domains.map(identifier(of:)))
  }

  private static func identifier(of domain: NSFileProviderDomain) -> String {
    domain.identifier.rawValue
  }

  private static func isFileExists(_ error: Error) -> Bool {
    let cocoaError = error as NSError
    return cocoaError.domain == NSCocoaErrorDomain
      && cocoaError.code == NSFileWriteFileExistsError
  }

  private static func fetchDomains() async throws -> [NSFileProviderDomain] {
    let list: FileProviderDomainList = try await withCheckedThrowingContinuation {
      continuation in
      NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: FileProviderDomainList(values: domains))
        }
      }
    }
    return list.values
  }

  private static func add(_ domain: NSFileProviderDomain) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      NSFileProviderManager.add(domain) { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  private static func remove(_ domain: NSFileProviderDomain) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      NSFileProviderManager.remove(domain, mode: .removeAll) { _, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }
}

private enum FileProviderDomainsError: LocalizedError {
  case inconsistentState

  var errorDescription: String? {
    "Couldn't update the Files mount."
  }
}

/// File Provider's completion-handler APIs are process-global. App lifecycle
/// reconciliation, a settings toggle, and sign-out can otherwise interleave
/// their read-modify-remove sequences and leave a just-added domain behind.
private actor FileProviderDomainOperationGate {
  private var isHeld = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func withLock<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
  ) async rethrows -> Value {
    await acquire()
    defer { release() }
    return try await operation()
  }

  private func acquire() async {
    guard isHeld else {
      isHeld = true
      return
    }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  private func release() {
    if waiters.isEmpty {
      isHeld = false
    } else {
      waiters.removeFirst().resume()
    }
  }
}
