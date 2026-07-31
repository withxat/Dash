import CloudflareAPI
import Foundation
import OSLog
import UIKit

enum FeatureCacheKey {
  static func zones(_ accountID: String) -> String { "zones:\(accountID)" }
  static func zone(_ zoneID: String) -> String { "zone:\(zoneID)" }
  static func dnsRecords(_ zoneID: String) -> String { "dns:\(zoneID)" }
  static func emailRouting(_ zoneID: String) -> String { "emailRouting:\(zoneID)" }
  static func emailRoutingDNS(_ zoneID: String) -> String { "emailRoutingDNS:\(zoneID)" }
  static func emailAddresses(_ accountID: String) -> String { "emailAddresses:\(accountID)" }
  static func workers(_ accountID: String) -> String { "workers:\(accountID)" }
  static func workersAccountSubdomain(_ accountID: String) -> String {
    "workersAccountSubdomain:\(accountID)"
  }
  static func workerSubdomain(accountID: String, name: String) -> String {
    "workerSubdomain:\(accountID):\(name)"
  }
  static func workerAnalytics(accountID: String, name: String) -> String {
    "workerAnalytics:\(accountID):\(name)"
  }
  static func accountAnalytics(_ accountID: String, hours: Int) -> String {
    "accountAnalytics:\(accountID):\(hours)"
  }
  static func workerDeployments(accountID: String, name: String) -> String {
    "workerDeployments:\(accountID):\(name)"
  }
  static func workerDomains(accountID: String, name: String) -> String {
    "workerDomains:\(accountID):\(name)"
  }
  /// Account-wide: routes for every zone in one entry, filtered per worker at
  /// read time, so the per-zone fan-out happens once per session, not once per
  /// worker screen.
  static func workerRoutes(_ accountID: String) -> String { "workerRoutes:\(accountID)" }
  static func pagesProjects(_ accountID: String) -> String { "pages:\(accountID)" }
  static func pagesProject(accountID: String, name: String) -> String {
    "pagesProject:\(accountID):\(name)"
  }
  static func pagesDeployments(accountID: String, name: String) -> String {
    "pagesDeployments:\(accountID):\(name)"
  }
  static func pagesDomains(accountID: String, name: String) -> String {
    "pagesDomains:\(accountID):\(name)"
  }
  static func zoneSettings(_ zoneID: String) -> String { "zoneSettings:\(zoneID)" }
  static func zoneAnalytics(_ zoneID: String, days: Int) -> String {
    "zoneAnalytics:\(zoneID):\(days)"
  }
  static func zoneAnalyticsHourly(_ zoneID: String) -> String { "zoneAnalyticsHourly:\(zoneID)" }
  static func zoneRequestsHourly(_ zoneID: String) -> String { "zoneRequestsHourly:\(zoneID)" }
  static func zoneWAF(_ zoneID: String) -> String { "zoneWAF:\(zoneID)" }
  static func emailRoutingAnalytics(_ zoneID: String) -> String {
    "emailRoutingAnalytics:\(zoneID)"
  }
  static func webAnalyticsSites(_ accountID: String) -> String { "rumSites:\(accountID)" }
  static func webAnalyticsPageviews(_ siteTag: String, days: Int) -> String {
    "rumPageviews:\(siteTag):\(days)"
  }
  static func webAnalyticsMetrics(_ siteTag: String, days: Int) -> String {
    "rumMetrics:\(siteTag):\(days)"
  }
  static func zoneRdap(_ zoneID: String) -> String { "zoneRdap:\(zoneID)" }
  static func auditLogs(_ accountID: String) -> String { "auditLogs:\(accountID)" }
  static func registrarDomains(_ accountID: String) -> String {
    "registrarDomains:\(accountID)"
  }
  static func registrarDomain(accountID: String, domain: String) -> String {
    "registrarDomain:\(accountID):\(domain)"
  }
  static func tunnels(_ accountID: String) -> String { "tunnels:\(accountID)" }
  static func tunnel(accountID: String, tunnelID: String) -> String {
    "tunnel:\(accountID):\(tunnelID)"
  }
  static func tunnelConnectors(accountID: String, tunnelID: String) -> String {
    "tunnelConnectors:\(accountID):\(tunnelID)"
  }
  static func tunnelConfiguration(accountID: String, tunnelID: String) -> String {
    "tunnelConfiguration:\(accountID):\(tunnelID)"
  }
  static func tunnelRoutes(accountID: String, tunnelID: String) -> String {
    "tunnelRoutes:\(accountID):\(tunnelID)"
  }
  static func tunnelVirtualNetworks(_ accountID: String) -> String {
    "tunnelVirtualNetworks:\(accountID)"
  }
  static func accessApplications(_ accountID: String) -> String {
    "accessApplications:\(accountID)"
  }
  static func r2Buckets(_ accountID: String) -> String { "r2:\(accountID)" }
  static func r2Objects(accountID: String, bucket: String, prefix: String) -> String {
    "r2:\(accountID):\(bucket):\(prefix)"
  }
  /// Prefix under which every object listing of one bucket lives. Object
  /// mutations invalidate all of them at once because the affected key may
  /// appear in more than one cached prefix listing.
  static func r2ObjectsPrefix(accountID: String, bucket: String) -> String {
    "r2:\(accountID):\(bucket):"
  }
  static func r2Domains(accountID: String, bucket: String) -> String {
    "r2Domains:\(accountID):\(bucket)"
  }
  static func kvNamespaces(_ accountID: String) -> String { "kv:\(accountID)" }
  static func kvKeys(accountID: String, namespaceID: String, prefix: String) -> String {
    "kvKeys:\(accountID):\(namespaceID):\(prefix)"
  }
  static func watchtower(_ accountID: String) -> String { "watchtower:\(accountID)" }
}

struct WatchtowerSnapshot: Sendable {
  var alerts: [NotificationHistoryEntry]
  var alertsStatus: WatchtowerAlertsStatus
  var fetchedAt: Date

  func isStale(now: Date = .now, ttl: TimeInterval) -> Bool {
    now.timeIntervalSince(fetchedAt) > ttl
  }

  /// Projects the snapshot into the slim Codable form the widget reads. Only
  /// deliveries this iPhone has not read yet — the widget answers "did
  /// Cloudflare tell me anything I haven't seen", not "is my account healthy".
  func widgetSnapshot(
    accountID: String,
    accountName: String?,
    defaults: UserDefaults = .standard
  ) -> WatchtowerWidgetSnapshot {
    let unread = WatchtowerInboxStore.contents(
      accountID: accountID,
      alerts: alertsStatus == .ok ? alerts : [],
      defaults: defaults
    ).unreadNotifications
    return WatchtowerWidgetSnapshot(
      unreadCount: unread.count,
      alerts: unread.map {
        WatchtowerWidgetSnapshot.Alert(id: $0.id, title: $0.title, detail: $0.detail)
      },
      alertsUnavailable: alertsStatus != .ok,
      accountID: accountID,
      accountName: accountName,
      fetchedAt: fetchedAt)
  }
}

/// Accumulated cursor-paginated rows plus the cursor to continue from, so a
/// revisited screen keeps both its rows and its Load more button.
struct CursorPageSnapshot<Item: Sendable>: Sendable {
  var items: [Item]
  var cursor: String?
}

@MainActor
@Observable
final class FeatureDataCache {
  private protocol InFlightTaskBox: AnyObject {
    var id: UUID { get }
    func cancel()
  }

  private final class TypedInFlightTaskBox<Value: Sendable>: InFlightTaskBox {
    let id = UUID()
    var task: Task<Void, Never>?
    var waiters: [UUID: CheckedContinuation<Value, any Error>] = [:]

    func cancel() {
      task?.cancel()
      task = nil
      let continuations = Array(waiters.values)
      waiters.removeAll()
      for continuation in continuations {
        continuation.resume(throwing: CancellationError())
      }
    }
  }

  private struct Entry {
    var value: Any
    var fetchedAt: Date
    var ttl: TimeInterval?
  }

  /// Default freshness for general feature lists. Watchtower uses its own TTL
  /// via `WatchtowerSnapshot.isStale` and is stored with `ttl: nil`.
  static let defaultTTL: TimeInterval = 15 * 60
  static let maxEntries = 200

  private var storage: [String: Entry] = [:]
  private var inFlight: [String: any InFlightTaskBox] = [:]

  func get<T>(_ key: String, maxAge: TimeInterval? = nil) -> T? {
    getWithFetchedAt(key, maxAge: maxAge)?.value
  }

  func getWithFetchedAt<T>(
    _ key: String,
    maxAge: TimeInterval? = nil
  ) -> (value: T, fetchedAt: Date)? {
    guard let entry = storage[key] else { return nil }
    let limit = maxAge ?? entry.ttl
    if let limit, Date().timeIntervalSince(entry.fetchedAt) > limit {
      storage.removeValue(forKey: key)
      return nil
    }
    guard let value = entry.value as? T else { return nil }
    return (value, entry.fetchedAt)
  }

  func set<T>(
    _ key: String,
    _ value: T,
    fetchedAt: Date = .now,
    ttl: TimeInterval? = defaultTTL
  ) {
    storage[key] = Entry(value: value, fetchedAt: fetchedAt, ttl: ttl)
    trimIfNeeded()
  }

  /// Joins concurrent work for one logical cache key. The operation deliberately
  /// does not write `storage`: callers decide whether a result is complete and
  /// still belongs to the active account before committing it atomically.
  func coalescedLoad<Value: Sendable>(
    _ key: String,
    operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    let waiterID = UUID()
    let cancellation = FeatureLoadWaiterCancellationState()
    let value = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Value, any Error>) in
        let box: TypedInFlightTaskBox<Value>
        let created: Bool
        if let existing = inFlight[key] {
          guard let typed = existing as? TypedInFlightTaskBox<Value> else {
            continuation.resume(throwing: FeatureDataCacheLoadError.typeMismatch(key))
            return
          }
          box = typed
          created = false
        } else {
          box = TypedInFlightTaskBox<Value>()
          inFlight[key] = box
          created = true
        }

        guard cancellation.bind(loadID: box.id) else {
          if created, box.waiters.isEmpty, inFlight[key]?.id == box.id {
            inFlight.removeValue(forKey: key)
          }
          continuation.resume(throwing: CancellationError())
          return
        }

        box.waiters[waiterID] = continuation
        guard box.task == nil else { return }
        let loadID = box.id
        let priority = Task.currentPriority
        box.task = Task.detached(priority: priority) { [weak self] in
          let result: Result<Value, any Error>
          do {
            let interval = DashPerformance.signposter.beginInterval("FeatureDataCache.Load")
            defer {
              DashPerformance.signposter.endInterval("FeatureDataCache.Load", interval)
            }
            try Task.checkCancellation()
            let value = try await operation()
            try Task.checkCancellation()
            result = .success(value)
          } catch {
            result = .failure(error)
          }
          await self?.completeLoad(key, loadID: loadID, result: result)
        }
      }
    } onCancel: { [weak self] in
      guard let loadID = cancellation.cancel() else { return }
      Task { @MainActor [weak self] in
        self?.cancelWaiter(
          key, loadID: loadID, waiterID: waiterID, as: Value.self)
      }
    }
    try Task.checkCancellation()
    return value
  }

  /// Account zone list plus per-id entries so zone detail can paint the
  /// header from Home / Domains cache without waiting on `getZone`.
  func storeZones(_ zones: [CloudflareZone], accountID: String) {
    set(FeatureCacheKey.zones(accountID), zones)
    for zone in zones {
      set(FeatureCacheKey.zone(zone.id), zone)
    }
  }

  /// Prefer the dedicated zone entry, then the account list snapshot.
  func cachedZone(id: String, accountID: String?) -> CloudflareZone? {
    if let zone: CloudflareZone = get(FeatureCacheKey.zone(id)) { return zone }
    guard let accountID else { return nil }
    let zones: [CloudflareZone]? = get(FeatureCacheKey.zones(accountID))
    return zones?.first { $0.id == id }
  }

  func remove(_ key: String) {
    storage.removeValue(forKey: key)
    inFlight.removeValue(forKey: key)?.cancel()
  }

  /// Drops every entry under a key prefix (e.g. every cached listing of one
  /// bucket after an object mutation).
  func remove(prefix: String) {
    storage = storage.filter { !$0.key.hasPrefix(prefix) }
    let matchingLoads = inFlight.keys.filter { $0.hasPrefix(prefix) }
    for key in matchingLoads {
      inFlight.removeValue(forKey: key)?.cancel()
    }
  }

  func clear() {
    storage.removeAll()
    cancelAllLoads()
  }

  /// Drops everything except Watchtower snapshots when memory is tight.
  func purgeForMemoryPressure(keepingPrefix prefix: String = "watchtower:") {
    storage = storage.filter { $0.key.hasPrefix(prefix) }
    let discardedLoads = inFlight.keys.filter { !$0.hasPrefix(prefix) }
    for key in discardedLoads {
      inFlight.removeValue(forKey: key)?.cancel()
    }
  }

  private func trimIfNeeded() {
    guard storage.count > Self.maxEntries else { return }
    let sorted = storage.sorted { $0.value.fetchedAt < $1.value.fetchedAt }
    let dropCount = storage.count - Self.maxEntries
    for entry in sorted.prefix(dropCount) {
      storage.removeValue(forKey: entry.key)
    }
  }

  private func cancelAllLoads() {
    let loads = Array(inFlight.values)
    inFlight.removeAll()
    for load in loads {
      load.cancel()
    }
  }

  private func cancelWaiter<Value: Sendable>(
    _ key: String,
    loadID: UUID,
    waiterID: UUID,
    as _: Value.Type = Value.self
  ) {
    guard let box = inFlight[key] as? TypedInFlightTaskBox<Value>, box.id == loadID,
      let continuation = box.waiters.removeValue(forKey: waiterID)
    else { return }
    continuation.resume(throwing: CancellationError())
    if box.waiters.isEmpty {
      inFlight.removeValue(forKey: key)
      box.task?.cancel()
      box.task = nil
    }
  }

  private func completeLoad<Value: Sendable>(
    _ key: String,
    loadID: UUID,
    result: Result<Value, any Error>
  ) {
    guard let box = inFlight[key] as? TypedInFlightTaskBox<Value>, box.id == loadID else {
      return
    }
    inFlight.removeValue(forKey: key)
    box.task = nil
    let continuations = Array(box.waiters.values)
    box.waiters.removeAll()
    for continuation in continuations {
      continuation.resume(with: result)
    }
  }
}

private enum FeatureDataCacheLoadError: Error {
  case typeMismatch(String)
}

/// `onCancel` may run before the continuation has registered on the main
/// actor. This tiny lock-protected token binds that early cancellation to the
/// exact load generation, so it can never cancel a later request for the key.
private final class FeatureLoadWaiterCancellationState: @unchecked Sendable {
  private let lock = NSLock()
  private var loadID: UUID?
  private var isCancelled = false

  func bind(loadID: UUID) -> Bool {
    lock.withLock {
      self.loadID = loadID
      return !isCancelled
    }
  }

  func cancel() -> UUID? {
    lock.withLock {
      guard !isCancelled else { return nil }
      isCancelled = true
      return loadID
    }
  }
}

extension AppModel {
  func installMemoryWarningObserver() {
    NotificationCenter.default.addObserver(
      forName: UIApplication.didReceiveMemoryWarningNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.featureCache.purgeForMemoryPressure()
      }
    }
  }
}
