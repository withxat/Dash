import Foundation

enum FeatureID: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
  case zones, workers, r2, kv

  var id: String { rawValue }
  var title: String { FeatureCatalog.descriptor(for: self).title }
  var subtitle: String { FeatureCatalog.descriptor(for: self).subtitle }
  var symbol: String { FeatureCatalog.descriptor(for: self).symbol }
  var solarAssetName: String { FeatureCatalog.descriptor(for: self).solarAssetName }
  var solarOutlineAssetName: String { FeatureCatalog.descriptor(for: self).solarOutlineAssetName }
  var category: String { FeatureCatalog.descriptor(for: self).category }
  var capability: FeatureCapability { FeatureCatalog.descriptor(for: self).capability }
}

struct FeatureCapability: Hashable, Sendable {
  let read: Set<String>
  let write: Set<String>

  var all: Set<String> { read.union(write) }

  func accessLevel(grantedScopes: Set<String>?) -> FeatureAccessLevel {
    guard let grantedScopes else { return .full }
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
  let solarAssetName: String
  let solarOutlineAssetName: String
  let category: String
  let capability: FeatureCapability
}

enum Destination: Hashable {
  case profile
  case settings
  case feature(FeatureID)
  case zone(String)
  case dns(String)
  case cache(String)
  case zoneAnalytics(String)
  case zoneSettings(String)
  case worker(String)
  case workerTail(String)
  case r2Bucket(String)
  case kvNamespace(String)
}

enum FeatureCatalog {
  static let descriptors: [FeatureDescriptor] = [
    // Domains & DNS
    feature(
      .zones, "Zones", "Domains, DNS, cache, and zone settings", "globe",
      "SolarGlobal", "SolarGlobalOutline", "Domains & DNS",
      read: ["zone.read"], write: ["zone.write"]),
    // Compute
    feature(
      .workers, "Workers", "Scripts, metrics, and live tail",
      "bolt.horizontal.circle", "SolarCodeSquare", "SolarCodeSquareOutline", "Compute",
      // page.read outlives the Pages tab: Watchtower's pagesSignal still fans
      // out to Pages projects. See DashAuthorizationScopes.
      read: ["workers-scripts.read", "page.read"],
      write: ["workers-scripts.write"]),
    // Storage & Data
    feature(
      .r2, "R2", "R2 object storage buckets", "externaldrive",
      "SolarCloudStorage", "SolarCloudStorageOutline", "Storage & Data",
      read: ["workers-r2.read", "workers-r2-bucket-item.read"],
      write: ["workers-r2.write", "workers-r2-bucket-item.write"]),
    feature(
      .kv, "KV", "Workers KV namespaces", "list.bullet.rectangle",
      "SolarKeyMinimalistic", "SolarKeyMinimalisticOutline", "Storage & Data",
      read: ["workers-kv-storage.read"], write: ["workers-kv-storage.write"]),
  ]

  private static let byID = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0) })

  static let defaults: [FeatureID] = [.zones, .workers, .r2, .kv]

  /// `defaults` in the form `@AppStorage` persists it. Home and the shortcut
  /// editor bind the same key, so the default has to resolve to one value.
  static let defaultShortcutData = defaults.map(\.rawValue).joined(separator: ",")

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

  static func matchesSearch(_ feature: FeatureID, query: String) -> Bool {
    let needle = query.localizedLowercase
    let fields = [
      feature.title,
      feature.subtitle,
      feature.rawValue,
    ].map { $0.localizedLowercase }
    return fields.contains { $0.contains(needle) }
  }

  private static func feature(
    _ id: FeatureID,
    _ title: String,
    _ subtitle: String,
    _ symbol: String,
    _ solarAssetName: String,
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
      solarAssetName: solarAssetName,
      solarOutlineAssetName: solarOutlineAssetName,
      category: category,
      capability: FeatureCapability(read: Set(read), write: Set(write))
    )
  }
}
