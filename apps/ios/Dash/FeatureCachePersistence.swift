import Foundation

/// One persisted cache entry. `data` is the JSON-encoded (Codable) value the
/// cache wrote at `set` time; `fetchedAt` / `ttl` mirror the in-memory entry so
/// a relaunch can still judge freshness without re-fetching.
struct FeatureCachePersistedEntry: Codable, Sendable {
  var data: Data
  var fetchedAt: Date
  var ttl: TimeInterval?
}

/// Disk-backed mirror of `FeatureDataCache`. The cache stays the single
/// `@MainActor` source of truth; this actor owns the file I/O and a debounced
/// flush so a burst of `set` calls collapses into one write per account.
///
/// Files are per-account (`feature-cache-<accountID>.json`) so switching
/// accounts never touches another account's on-disk data, and sign-out can
/// delete every file the user owned. Keys inside a file embed the account (or
/// an account-owned id), so no cross-account read can occur while a file is
/// loaded.
actor FeatureCachePersistence {
  static let schemaVersion = 1
  static let directoryName = "FeatureCache"

  private struct Store: Codable {
    var schemaVersion: Int
    var entries: [String: FeatureCachePersistedEntry]
  }

  private let directory: URL
  /// Authoritative per-account store, loaded lazily on first access.
  private var stores: [String: [String: FeatureCachePersistedEntry]] = [:]
  private var dirtyAccounts: Set<String> = []
  private var flushTask: Task<Void, Never>?

  init(directory: URL? = nil) {
    if let directory {
      self.directory = directory
    } else {
      let base =
        FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first ?? FileManager.default.temporaryDirectory
      self.directory = base.appendingPathComponent(Self.directoryName, isDirectory: true)
    }
    try? FileManager.default.createDirectory(
      at: self.directory, withIntermediateDirectories: true)
  }

  /// An isolated persistence for tests and previews — its own temp directory,
  /// so it never touches the app's Application Support cache.
  static func ephemeral() -> FeatureCachePersistence {
    FeatureCachePersistence(
      directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("FeatureCache-ephemeral-\(UUID().uuidString)", isDirectory: true))
  }

  func load(accountID: String) -> [String: FeatureCachePersistedEntry] {
    if let store = stores[accountID] { return store }
    var store: [String: FeatureCachePersistedEntry] = [:]
    if let data = try? Data(contentsOf: fileURL(accountID: accountID)),
      let decoded = try? JSONDecoder().decode(Store.self, from: data)
    {
      store = decoded.entries
    }
    stores[accountID] = store
    return store
  }

  func upsert(_ entry: FeatureCachePersistedEntry, key: String, accountID: String) {
    _ = load(accountID: accountID)
    stores[accountID, default: [:]][key] = entry
    dirtyAccounts.insert(accountID)
    scheduleFlush()
  }

  func remove(key: String, accountID: String) {
    _ = load(accountID: accountID)
    guard stores[accountID]?.removeValue(forKey: key) != nil else { return }
    dirtyAccounts.insert(accountID)
    scheduleFlush()
  }

  func remove(prefix: String, accountID: String) {
    _ = load(accountID: accountID)
    guard var store = stores[accountID] else { return }
    let before = store.count
    store = store.filter { !$0.key.hasPrefix(prefix) }
    guard store.count != before else { return }
    stores[accountID] = store
    dirtyAccounts.insert(accountID)
    scheduleFlush()
  }

  /// Drop a whole account's in-memory store and delete its file. `clearAll` is
  /// the sign-out path; this is what protects a discarded account's data.
  func clear(accountID: String) {
    stores[accountID] = nil
    dirtyAccounts.remove(accountID)
    try? FileManager.default.removeItem(at: fileURL(accountID: accountID))
  }

  func clearAll() {
    stores.removeAll()
    dirtyAccounts.removeAll()
    flushTask?.cancel()
    flushTask = nil
    try? FileManager.default.removeItem(at: directory)
    try? FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true)
  }

  /// Flush pending changes immediately (used by tests and sign-out). Returns
  /// after the write lands so callers can assert on disk state.
  func flushNow() async {
    flushTask?.cancel()
    flushTask = nil
    await flushAll()
  }

  private func scheduleFlush() {
    flushTask?.cancel()
    flushTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(500))
      guard !Task.isCancelled else { return }
      await self?.flushAll()
    }
  }

  private func flushAll() async {
    let accounts = dirtyAccounts
    dirtyAccounts.removeAll()
    for accountID in accounts {
      guard let store = stores[accountID] else { continue }
      let payload = Store(schemaVersion: Self.schemaVersion, entries: store)
      guard let data = try? JSONEncoder().encode(payload) else { continue }
      try? data.write(to: fileURL(accountID: accountID), options: .atomic)
    }
  }

  private func fileURL(accountID: String) -> URL {
    directory.appendingPathComponent("feature-cache-\(accountID).json")
  }
}
