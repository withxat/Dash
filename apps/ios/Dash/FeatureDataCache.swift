import CloudflareAPI
import Foundation
import UIKit

enum FeatureCacheKey {
  static func zones(_ accountID: String) -> String { "zones:\(accountID)" }
  static func zone(_ zoneID: String) -> String { "zone:\(zoneID)" }
  static func dnsRecords(_ zoneID: String) -> String { "dns:\(zoneID)" }
  static func workers(_ accountID: String) -> String { "workers:\(accountID)" }
  static func workerSubdomain(accountID: String, name: String) -> String {
    "workerSubdomain:\(accountID):\(name)"
  }
  static func workerAnalytics(accountID: String, name: String) -> String {
    "workerAnalytics:\(accountID):\(name)"
  }
  static func zoneSettings(_ zoneID: String) -> String { "zoneSettings:\(zoneID)" }
  static func zoneAnalytics(_ zoneID: String, days: Int) -> String {
    "zoneAnalytics:\(zoneID):\(days)"
  }
  static func zoneAnalyticsHourly(_ zoneID: String) -> String { "zoneAnalyticsHourly:\(zoneID)" }
  static func r2Buckets(_ accountID: String) -> String { "r2:\(accountID)" }
  static func r2Objects(accountID: String, bucket: String, prefix: String) -> String {
    "r2:\(accountID):\(bucket):\(prefix)"
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

  func remove(_ key: String) {
    storage.removeValue(forKey: key)
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
