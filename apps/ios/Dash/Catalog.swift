import Foundation

enum FeatureID: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
  case zones, workers, r2, kv, d1, queues, vectorize, secrets
  case turnstile, accessApps, emailAddresses, registrar, tunnels, loadBalancerPools
  case images, stream, analytics, account

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
    case .turnstile: "Turnstile"
    case .accessApps: "Access apps"
    case .emailAddresses: "Email addresses"
    case .registrar: "Registrar"
    case .tunnels: "Tunnels"
    case .loadBalancerPools: "LB Pools"
    case .images: "Images"
    case .stream: "Stream"
    case .analytics: "Analytics"
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
    case .turnstile: "CAPTCHA-free widgets and secret rotation"
    case .accessApps: "Zero Trust application inventory"
    case .emailAddresses: "Email Routing destination addresses"
    case .registrar: "Registered domains and renewals"
    case .tunnels: "Cloudflare Tunnel health and connections"
    case .loadBalancerPools: "Load balancer origin pools"
    case .images: "Cloudflare Images library"
    case .stream: "Stream video library"
    case .analytics: "Account and zone traffic charts"
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
    case .turnstile: "checkmark.shield"
    case .accessApps: "lock.app.dashed"
    case .emailAddresses: "envelope"
    case .registrar: "network"
    case .tunnels: "arrow.left.arrow.right"
    case .loadBalancerPools: "scale.3d"
    case .images: "photo.on.rectangle"
    case .stream: "play.rectangle"
    case .analytics: "chart.xyaxis.line"
    case .account: "person.2"
    }
  }
  var category: String {
    switch self {
    case .zones: "Infrastructure"
    case .workers: "Compute"
    case .r2, .kv, .d1, .queues, .vectorize, .secrets: "Storage & Data"
    case .turnstile, .accessApps: "Security"
    case .emailAddresses, .registrar: "Email & Domains"
    case .tunnels, .loadBalancerPools: "Network"
    case .images, .stream: "Media"
    case .analytics: "Insights"
    case .account: "Account"
    }
  }
}

enum Destination: Hashable {
  case feature(FeatureID)
  case zone(String)
  case dns(String)
  case cache(String)
  case zoneSettings(String)
  case zoneTool(zoneID: String, title: String, path: String)
  case worker(String)
  case r2Bucket(String)
  case kvNamespace(String)
  case d1Database(String, String)
}

enum FeatureCatalog {
  static let defaults: [FeatureID] = [.zones, .workers, .r2, .kv]
  static var grouped: [(String, [FeatureID])] {
    Dictionary(grouping: FeatureID.allCases, by: \.category)
      .sorted {
        FeatureID.allCases.firstIndex(of: $0.value[0])! < FeatureID.allCases.firstIndex(
          of: $1.value[0])!
      }
  }
}
