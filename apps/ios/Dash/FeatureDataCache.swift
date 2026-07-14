import CloudflareAPI
import Foundation

enum FeatureCacheKey {
  static func zones(_ accountID: String) -> String { "zones:\(accountID)" }
  static func zone(_ zoneID: String) -> String { "zone:\(zoneID)" }
  static func dnsRecords(_ zoneID: String) -> String { "dns:\(zoneID)" }
  static func workers(_ accountID: String) -> String { "workers:\(accountID)" }
  static func pages(_ accountID: String) -> String { "pages:\(accountID)" }
  static func workerSource(accountID: String, name: String) -> String {
    "workerSource:\(accountID):\(name)"
  }
  static func workerSubdomain(accountID: String, name: String) -> String {
    "workerSubdomain:\(accountID):\(name)"
  }
  static func zoneSettings(_ zoneID: String) -> String { "zoneSettings:\(zoneID)" }
  static func zoneAnalytics(_ zoneID: String, days: Int) -> String {
    "zoneAnalytics:\(zoneID):\(days)"
  }
  static func zoneAnalyticsHourly(_ zoneID: String) -> String { "zoneAnalyticsHourly:\(zoneID)" }
  static func generic(path: String) -> String { "generic:\(path)" }
  static func images(_ accountID: String) -> String { "images:\(accountID)" }
  static func stream(_ accountID: String) -> String { "stream:\(accountID)" }
  static func rumSites(_ accountID: String) -> String { "rumSites:\(accountID)" }
  static func accountSnapshot(_ accountID: String) -> String { "account:\(accountID)" }
  static func r2Buckets(_ accountID: String) -> String { "r2:\(accountID)" }
  static func r2Objects(accountID: String, bucket: String, prefix: String) -> String {
    "r2:\(accountID):\(bucket):\(prefix)"
  }
  static func kvNamespaces(_ accountID: String) -> String { "kv:\(accountID)" }
  static func kvKeys(accountID: String, namespaceID: String, prefix: String) -> String {
    "kvKeys:\(accountID):\(namespaceID):\(prefix)"
  }
  static func d1Databases(_ accountID: String) -> String { "d1:\(accountID)" }
  static func watchtower(_ accountID: String) -> String { "watchtower:\(accountID)" }
}

struct AccountFeatureSnapshot: Sendable {
  var members: [AccountMember]
  var policies: [NotificationPolicy]
  var history: [NotificationHistoryEntry]
  var auditLogs: [AuditLogEntry]
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

struct WorkerDetailSnapshot: Sendable {
  var source: WorkerSource
  var subdomainEnabled: Bool
  var tag: String?
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
  private var storage: [String: Any] = [:]

  func get<T>(_ key: String) -> T? {
    storage[key] as? T
  }

  func set<T>(_ key: String, _ value: T) {
    storage[key] = value
  }

  func remove(_ key: String) {
    storage.removeValue(forKey: key)
  }

  func clear() {
    storage.removeAll()
  }
}
