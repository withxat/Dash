import Foundation

enum FeatureID: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
  case zones, registrar, emailRouting, workers, pages, r2, kv, tunnels

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

  /// Whether `FeatureRouterContent` should hang the shared read-only banner
  /// over this feature's index. Registrar and Email Routing indexes are
  /// browse-only — mutations live on nested destinations that already show
  /// their own notice. Tunnels has no write scopes at all (Dash never mutates
  /// tunnels), so a Grant-access banner would request nothing.
  var showsCatalogReadOnlyBanner: Bool {
    switch self {
    case .registrar, .emailRouting, .tunnels: false
    case .zones, .workers, .pages, .r2, .kv: true
    }
  }
}

struct FeatureCapability: Hashable, Sendable {
  let read: Set<String>
  let write: Set<String>

  var all: Set<String> { read.union(write) }

  func accessLevel(grantedScopes: Set<String>?) -> FeatureAccessLevel {
    guard let grantedScopes else { return .locked }
    guard read.isSubset(of: grantedScopes) else { return .locked }
    // Empty write means Dash never mutates this feature — permanently
    // Read-only once unlocked, not "full" just because there is nothing to grant.
    guard !write.isEmpty, write.isSubset(of: grantedScopes) else { return .readOnly }
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
    /// DEBUG-only playground (toasts, haptics).
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
  /// Email Routing for one zone: routes, catch-all, and plus addressing.
  case zoneEmailRouting(String)
  case auditLogs
  case pushAlerts
  /// Watchtower notification inbox (Cloudflare history + Dash detections).
  case watchtowerInbox
  /// Account-level Email Routing destination addresses.
  case emailAddresses
  /// One Cloudflare Registrar domain, keyed on its FQDN. The account's index is
  /// `feature(.registrar)` in Resources — there is no separate list destination.
  case registrarDomain(String)
  /// Render-ready snapshot of the chart the user tapped; never refetches.
  case chartDetail(DashChartDetail)
  case worker(String)
  /// One Cloudflare Tunnel, keyed on its immutable id.
  case tunnel(String)
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

extension DashExperimentalFeatures {
  /// Whether a catalog feature should appear in Resources / Home shortcuts.
  /// Experimental features stay hidden until their Settings toggle is on.
  static func isCatalogVisible(_ feature: FeatureID, tunnelsEnabled: Bool) -> Bool {
    if DashAuthorizationScopes.experimentalFeatures.contains(feature) {
      return feature == .tunnels && tunnelsEnabled
    }
    return true
  }
}

enum FeatureCatalog {
  static let descriptors: [FeatureDescriptor] = [
    // Domains & DNS
    feature(
      .zones, "Domains", "Domains, DNS, cache, and domain settings", "globe",
      "SolarGlobalFill", "SolarGlobalOutline", "Domains & DNS",
      read: ["zone.read"], write: ["zone.write"]),
    // A zone and a registration are different objects — a zone Cloudflare
    // serves DNS for versus a name the account owns — so Registrar browses
    // beside Domains. `write` carries `registrar-domains.admin` so Resources
    // can badge Demo / partial grants as Read-only; the index itself is
    // browse-only and suppresses `FeatureReadOnlyBanner` (see
    // `FeatureID.showsCatalogReadOnlyBanner`).
    feature(
      .registrar, "Registrations", "Domains you bought on Cloudflare",
      "checkmark.seal", "SolarGlobusFill", "SolarGlobusOutline", "Domains & DNS",
      read: ["registrar-domains.read"], write: ["registrar-domains.admin"]),
    // Email Routing browses beside Domains: pick a zone, then manage routes.
    // Write scopes live on the capability for the Resources Read-only badge;
    // the domains index suppresses the catalog banner (mutations sit on
    // per-zone / destination-address screens with their own notices).
    feature(
      // Sentence case, and the same catalog key the zone row and the per-zone
      // screen already use: "Email Routing" was a second key differing only in
      // case, and the one nobody translated — so Resources showed English on a
      // Chinese screen while the row one tap away read 邮件路由.
      .emailRouting, "Email routing", "Forward domain mail to inboxes you already use",
      "tray", "SolarMailboxFill", "SolarMailboxOutline", "Domains & DNS",
      read: ["zone.read", "email-routing-rule.read"],
      write: ["email-routing-rule.write", "email-routing-address.write"]),
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
    // Networks — experimental. Hidden from Resources until Settings →
    // Experimental opts it in; scopes stay out of `core` and are requested
    // when the locked row's Grant access runs. `write` stays empty on purpose:
    // Dash never mutates tunnels, so an unlocked row is always Read-only.
    feature(
      .tunnels, "Tunnels", "Connectors, hostnames, and private routes",
      "point.3.connected.trianglepath.dotted", "SolarRoutingFill", "SolarRoutingOutline",
      "Networks", read: ["argotunnel.read"], write: []),
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
