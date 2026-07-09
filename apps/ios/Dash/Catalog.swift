import Foundation

enum FeatureID: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
  case zones, workers, r2, kv, d1, queues, vectorize, secrets
  case hyperdrive, pipelines, aiGateway
  case turnstile, accessApps, accessGroups, serviceTokens, gatewayPolicies, ruleLists
  case emailAddresses, registrar, tunnels, loadBalancerPools, dnsFirewall
  case images, stream, analytics, logpush, account

  var id: String { rawValue }
  var title: String {
    switch self {
    case .zones: "Zones"
    case .workers: "Workers & Pages"
    case .r2: "R2"
    case .kv: "KV"
    case .d1: "D1"
    case .queues: "Queues"
    case .vectorize: "Vectorize"
    case .secrets: "Secrets Store"
    case .hyperdrive: "Hyperdrive"
    case .pipelines: "Pipelines"
    case .aiGateway: "AI Gateway"
    case .turnstile: "Turnstile"
    case .accessApps: "Access apps"
    case .accessGroups: "Access groups"
    case .serviceTokens: "Service tokens"
    case .gatewayPolicies: "Gateway policies"
    case .ruleLists: "Rule lists"
    case .emailAddresses: "Email addresses"
    case .registrar: "Registrar"
    case .tunnels: "Tunnels"
    case .loadBalancerPools: "LB Pools"
    case .dnsFirewall: "DNS Firewall"
    case .images: "Images"
    case .stream: "Stream"
    case .analytics: "Analytics"
    case .logpush: "Logpush"
    case .account: "Account"
    }
  }
  var subtitle: String {
    switch self {
    case .zones: "Domains, DNS, cache, and zone settings"
    case .workers: "Scripts, routes, deployments, and custom domains"
    case .r2: "R2 object storage buckets"
    case .kv: "Workers KV namespaces"
    case .d1: "Serverless SQL databases and console"
    case .queues: "Message queues, producers, and consumers"
    case .vectorize: "Vector indexes for AI search"
    case .secrets: "Account-level secrets, names only"
    case .hyperdrive: "Accelerated connections to external databases"
    case .pipelines: "Streaming ingestion into R2"
    case .aiGateway: "Gateways for observing and controlling AI traffic"
    case .turnstile: "CAPTCHA-free widgets and secret rotation"
    case .accessApps: "Zero Trust application inventory"
    case .accessGroups: "Reusable Zero Trust rule groups"
    case .serviceTokens: "Machine credentials for Access"
    case .gatewayPolicies: "Zero Trust Gateway filtering rules"
    case .ruleLists: "Reusable IP and redirect lists"
    case .emailAddresses: "Email Routing destination addresses"
    case .registrar: "Registered domains and renewals"
    case .tunnels: "Cloudflare Tunnel health and connections"
    case .loadBalancerPools: "Load balancer origin pools"
    case .dnsFirewall: "Upstream DNS caching and protection"
    case .images: "Cloudflare Images library"
    case .stream: "Stream video library"
    case .analytics: "Account and zone traffic charts"
    case .logpush: "Log delivery jobs to external storage"
    case .account: "Members, notifications, and audit logs"
    }
  }
  var symbol: String {
    switch self {
    case .zones: "globe"
    case .workers: "bolt.horizontal.circle"
    case .r2: "externaldrive"
    case .kv: "list.bullet.rectangle"
    case .d1: "cylinder"
    case .queues: "tray.2"
    case .vectorize: "point.3.connected.trianglepath.dotted"
    case .secrets: "key.horizontal"
    case .hyperdrive: "bolt.horizontal"
    case .pipelines: "arrow.triangle.merge"
    case .aiGateway: "brain"
    case .turnstile: "checkmark.shield"
    case .accessApps: "lock.app.dashed"
    case .accessGroups: "person.3"
    case .serviceTokens: "key.viewfinder"
    case .gatewayPolicies: "shield.lefthalf.filled"
    case .ruleLists: "list.bullet.rectangle.portrait"
    case .emailAddresses: "envelope"
    case .registrar: "network"
    case .tunnels: "arrow.left.arrow.right"
    case .loadBalancerPools: "scale.3d"
    case .dnsFirewall: "shield.slash"
    case .images: "photo.on.rectangle"
    case .stream: "play.rectangle"
    case .analytics: "chart.xyaxis.line"
    case .logpush: "square.and.arrow.up.on.square"
    case .account: "person.2"
    }
  }
  var solarAssetName: String {
    switch self {
    case .zones: "SolarGlobal"
    case .workers: "SolarCodeSquare"
    case .r2: "SolarBoxMinimalistic"
    case .kv: "SolarKeyMinimalistic"
    case .d1: "SolarDatabase"
    case .queues: "SolarInbox"
    case .vectorize: "SolarStructure"
    case .secrets: "SolarLockKeyhole"
    case .hyperdrive: "SolarDatabase"
    case .pipelines: "SolarRouting"
    case .aiGateway: "SolarStructure"
    case .turnstile: "SolarShieldCheck"
    case .accessApps: "SolarShieldUser"
    case .accessGroups: "SolarShieldUser"
    case .serviceTokens: "SolarKeyMinimalistic"
    case .gatewayPolicies: "SolarShieldCheck"
    case .ruleLists: "SolarInbox"
    case .emailAddresses: "SolarLetter"
    case .registrar: "SolarGlobus"
    case .tunnels: "SolarRouting"
    case .loadBalancerPools: "SolarBranchingPathsUp"
    case .dnsFirewall: "SolarShieldCheck"
    case .images: "SolarGallery"
    case .stream: "SolarVideoLibrary"
    case .analytics: "SolarChart2"
    case .logpush: "SolarChart2"
    case .account: "SolarSettingsMinimalistic"
    }
  }
  var solarOutlineAssetName: String {
    switch self {
    case .zones: SolarAsset.globe
    case .workers: SolarAsset.code
    case .r2: SolarAsset.box
    case .kv: "SolarKeyMinimalisticOutline"
    case .d1: SolarAsset.database
    case .queues: SolarAsset.inbox
    case .vectorize: "SolarStructureOutline"
    case .secrets: SolarAsset.lock
    case .hyperdrive: SolarAsset.database
    case .pipelines: SolarAsset.routing
    case .aiGateway: "SolarStructureOutline"
    case .turnstile: SolarAsset.shieldCheck
    case .accessApps: "SolarShieldUserOutline"
    case .accessGroups: "SolarShieldUserOutline"
    case .serviceTokens: SolarAsset.key
    case .gatewayPolicies: SolarAsset.shieldCheck
    case .ruleLists: SolarAsset.inbox
    case .emailAddresses: SolarAsset.letter
    case .registrar: SolarAsset.globus
    case .tunnels: SolarAsset.routing
    case .loadBalancerPools: SolarAsset.branching
    case .dnsFirewall: SolarAsset.shieldCheck
    case .images: SolarAsset.gallery
    case .stream: SolarAsset.video
    case .analytics: SolarAsset.chart
    case .logpush: SolarAsset.chart
    case .account: SolarAsset.settings
    }
  }
  var category: String {
    switch self {
    case .zones: "Infrastructure"
    case .workers: "Compute"
    case .r2, .kv, .d1, .queues, .vectorize, .secrets, .hyperdrive, .pipelines, .aiGateway:
      "Storage & Data"
    case .turnstile, .accessApps, .accessGroups, .serviceTokens, .gatewayPolicies, .ruleLists:
      "Security"
    case .emailAddresses, .registrar: "Email & Domains"
    case .tunnels, .loadBalancerPools, .dnsFirewall: "Network"
    case .images, .stream: "Media"
    case .analytics, .logpush: "Insights"
    case .account: "Account"
    }
  }
}

enum Destination: Hashable {
  case feature(FeatureID)
  case zone(String)
  case dns(String)
  case cache(String)
  case zoneAnalytics(String)
  case zoneSettings(String)
  case zoneTool(zoneID: String, title: String, path: String)
  case worker(String)
  case r2Bucket(String)
  case kvNamespace(String)
  case d1Database(String, String)
}

enum FeatureCatalog {
  static let defaults: [FeatureID] = [.zones, .workers, .r2, .kv]

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
    sections(for: FeatureID.allCases)
  }

  static var catalogOrder: [FeatureID: Int] {
    Dictionary(uniqueKeysWithValues: FeatureID.allCases.enumerated().map { ($1, $0) })
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
}
