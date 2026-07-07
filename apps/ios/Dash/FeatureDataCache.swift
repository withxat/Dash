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
  var unavailableCount: Int
}

struct WorkerDetailSnapshot: Sendable {
  var source: String
  var subdomainEnabled: Bool
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
