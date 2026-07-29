import Foundation

enum FeatureID: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
  case zones, workers, pages, r2, kv

  var id: String { rawValue }
  var title: String {
    DashL10n.ui(FeatureCatalog.descriptor(for: self).title)
  }
  var subtitle: String {
    DashL10n.ui(FeatureCatalog.descriptor(for: self).subtitle)
  }
  var symbol: String { FeatureCatalog.descriptor(for: self).symbol }
  var solarFillAssetName: String { FeatureCatalog.descriptor(for: self).solarFillAssetName }
  var solarOutlineAssetName: String { FeatureCatalog.descriptor(for: self).solarOutlineAssetName }
  var category: String {
    DashL10n.ui(FeatureCatalog.descriptor(for: self).category)
  }
  var capability: FeatureCapability { FeatureCatalog.descriptor(for: self).capability }
}

struct FeatureCapability: Hashable, Sendable {
  let read: Set<String>
  let write: Set<String>

  var all: Set<String> { read.union(write) }

  func accessLevel(grantedScopes: Set<String>?) -> FeatureAccessLevel {
    guard let grantedScopes else { return .locked }
    guard read.isSubset(of: grantedScopes) else { return .locked }
    guard write.isEmpty || write.isSubset(of: grantedScopes) else { return .readOnly }
    return .full
  }
}

enum FeatureAccessLevel: Hashable, Sendable {
  case locked
  case readOnly
  case full
}

struct FeatureDescriptor: Hashable, Sendable {
  let id: FeatureID
  let title: String
  let subtitle: String
  let symbol: String
  let solarFillAssetName: String
  let solarOutlineAssetName: String
  let category: String
  let capability: FeatureCapability
}

enum Destination: Hashable {
  case profile
  case settings
  case settingsAccounts
  case about
  /// Settings → Open source: third-party libraries and icon sets Dash ships.
  case openSource
  #if DEBUG
    /// DEBUG-only playground (toasts, haptics, hold-to-confirm).
    case debug
  #endif
  case feature(FeatureID)
  case zone(String)
  case dns(String)
  case cache(String)
  case zoneAnalytics(String)
  /// Beacon-reported Web Analytics (RUM) — a different measurement from
  /// `zoneAnalytics`, which is what the edge saw.
  case zoneWebAnalytics(String)
  case zoneWAF(String)
  case zoneSettings(String)
  case auditLogs
  case pushAlerts
  /// Watchtower notification inbox (Cloudflare history + Dash detections).
  case watchtowerInbox
  case worker(String)
  case pagesProject(String)
  case pagesDeployment(project: String, deploymentID: String)
  case pagesDomains(String)
  /// `prefix` is the S3-style folder key (trailing `/`), or `""` at the bucket root.
  case r2Bucket(String, prefix: String)
  case r2BucketSettings(String)
  case kvNamespace(String)
  /// KV key value — full-screen JSON editor (not a tray).
  case kvKey(namespaceID: String, key: String)
}

enum FeatureCatalog {
  static let descriptors: [FeatureDescriptor] = [
    // Domains & DNS
    feature(
      .zones, "Domains", "Domains, DNS, cache, and domain settings", "globe",
      "SolarGlobalFill", "SolarGlobalOutline", "Domains & DNS",
      read: ["zone.read"], write: ["zone.write"]),
    // Compute
    feature(
      .workers, "Workers", "Deployments, domains, and analytics",
      "bolt.horizontal.circle", "SolarCodeSquareFill", "SolarCodeSquareOutline", "Compute",
      read: ["workers-scripts.read"],
      write: ["workers-scripts.write"]),
    feature(
      .pages, "Pages", "Deployments, rollback, and custom domains",
      "doc.text", "SolarCodeCircleFill", "SolarCodeOutline", "Compute",
      read: ["page.read"], write: ["page.write"]),
    // Storage & Data
    feature(
      .r2, "R2", "R2 object storage buckets", "externaldrive",
      "SolarCloudStorageFill", "SolarCloudStorageOutline", "Storage & Data",
      read: ["workers-r2.read", "workers-r2-bucket-item.read"],
      write: ["workers-r2.write", "workers-r2-bucket-item.write"]),
    feature(
      .kv, "KV", "Namespaces, keys, and values", "list.bullet.rectangle",
      "SolarKeyMinimalisticFill", "SolarKeyMinimalisticOutline", "Storage & Data",
      read: ["workers-kv-storage.read"], write: ["workers-kv-storage.write"]),
  ]

  private static let byID = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0) })

  static var all: [FeatureID] { descriptors.map(\.id) }

  static func descriptor(for id: FeatureID) -> FeatureDescriptor {
    guard let descriptor = byID[id] else {
      preconditionFailure("Feature \(id.rawValue) is missing from FeatureCatalog.descriptors")
    }
    return descriptor
  }

  static func sections(for features: [FeatureID]) -> [(String, [FeatureID])] {
    let order = catalogOrder
    return Dictionary(grouping: features, by: \.category)
      .map { category, items in
        (
          category,
          items.sorted { (order[$0] ?? .max) < (order[$1] ?? .max) }
        )
      }
      .sorted { (order[$0.1.first!] ?? .max) < (order[$1.1.first!] ?? .max) }
  }

  static var grouped: [(String, [FeatureID])] {
    sections(for: all)
  }

  static var catalogOrder: [FeatureID: Int] {
    Dictionary(uniqueKeysWithValues: all.enumerated().map { ($1, $0) })
  }

  static func sorted(_ features: [FeatureID]) -> [FeatureID] {
    let order = catalogOrder
    return features.sorted { (order[$0] ?? .max) < (order[$1] ?? .max) }
  }

  private static func feature(
    _ id: FeatureID,
    _ title: String,
    _ subtitle: String,
    _ symbol: String,
    _ solarFillAssetName: String,
    _ solarOutlineAssetName: String,
    _ category: String,
    read: [String],
    write: [String] = []
  ) -> FeatureDescriptor {
    FeatureDescriptor(
      id: id,
      title: title,
      subtitle: subtitle,
      symbol: symbol,
      solarFillAssetName: solarFillAssetName,
      solarOutlineAssetName: solarOutlineAssetName,
      category: category,
      capability: FeatureCapability(read: Set(read), write: Set(write))
    )
  }
}
