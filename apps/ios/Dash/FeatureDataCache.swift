import CloudflareAPI
import Foundation
import UIKit

enum FeatureCacheKey {
  static func zones(_ accountID: String) -> String { "zones:\(accountID)" }
  static func zone(_ zoneID: String) -> String { "zone:\(zoneID)" }
  static func dnsRecords(_ zoneID: String) -> String { "dns:\(zoneID)" }
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
  static func webAnalyticsSites(_ accountID: String) -> String { "rumSites:\(accountID)" }
  static func webAnalyticsPageviews(_ siteTag: String, days: Int) -> String {
    "rumPageviews:\(siteTag):\(days)"
  }
  static func zoneRdap(_ zoneID: String) -> String { "zoneRdap:\(zoneID)" }
  static func auditLogs(_ accountID: String) -> String { "auditLogs:\(accountID)" }
  static func r2Buckets(_ accountID: String) -> String { "r2:\(accountID)" }
  static func r2Objects(accountID: String, bucket: String, prefix: String) -> String {
    "r2:\(accountID):\(bucket):\(prefix)"
  }
  /// Prefix under which every object listing of one bucket lives — rename and
  /// move invalidate all of them at once, since the destination folder's
  /// snapshot goes stale along with the source's.
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
  var signals: [WatchtowerSignal]
  var alerts: [NotificationHistoryEntry]
  var alertsStatus: WatchtowerAlertsStatus
  var missingScopeChecks: [String]
  var failedChecks: [String]
  var fetchedAt: Date

  var issueCount: Int { signals.count { $0.status != .ok } }

  func isStale(now: Date = .now, ttl: TimeInterval) -> Bool {
    now.timeIntervalSince(fetchedAt) > ttl
  }

  /// Projects the full snapshot into the slim Codable form the widget reads.
  /// Non-ok signals only, critical before warning.
  func widgetSnapshot(accountName: String?) -> WatchtowerWidgetSnapshot {
    let issues = signals.filter { $0.status != .ok }
    let ordered = issues.sorted { lhs, rhs in
      (lhs.status == .critical ? 0 : 1) < (rhs.status == .critical ? 0 : 1)
    }
    return WatchtowerWidgetSnapshot(
      issueCount: issues.count,
      criticalCount: signals.count { $0.status == .critical },
      warningCount: signals.count { $0.status == .warning },
      signals: ordered.map {
        WatchtowerWidgetSnapshot.Signal(
          title: $0.title, detail: $0.detail, status: $0.status.widgetRawValue)
      },
      accountName: accountName,
      fetchedAt: fetchedAt)
  }
}

extension WatchtowerStatus {
  var widgetRawValue: String {
    switch self {
    case .ok: "ok"
    case .warning: "warning"
    case .critical: "critical"
    }
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

  func get<T>(_ key: String, maxAge: TimeInterval? = nil) -> T? {
    guard let entry = storage[key] else { return nil }
    let limit = maxAge ?? entry.ttl
    if let limit, Date().timeIntervalSince(entry.fetchedAt) > limit {
      storage.removeValue(forKey: key)
      return nil
    }
    return entry.value as? T
  }

  func set<T>(_ key: String, _ value: T, ttl: TimeInterval? = defaultTTL) {
    storage[key] = Entry(value: value, fetchedAt: .now, ttl: ttl)
    trimIfNeeded()
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
  }

  /// Drops every entry under a key prefix (e.g. all cached listings of one
  /// bucket after a rename touched two folders).
  func remove(prefix: String) {
    storage = storage.filter { !$0.key.hasPrefix(prefix) }
  }

  func clear() {
    storage.removeAll()
  }

  /// Drops everything except Watchtower snapshots when memory is tight.
  func purgeForMemoryPressure(keepingPrefix prefix: String = "watchtower:") {
    storage = storage.filter { $0.key.hasPrefix(prefix) }
  }

  private func trimIfNeeded() {
    guard storage.count > Self.maxEntries else { return }
    let sorted = storage.sorted { $0.value.fetchedAt < $1.value.fetchedAt }
    let dropCount = storage.count - Self.maxEntries
    for entry in sorted.prefix(dropCount) {
      storage.removeValue(forKey: entry.key)
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
