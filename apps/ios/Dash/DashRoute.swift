import Foundation

/// A destination expressible as a `dash://` deep link. Deliberately a small,
/// stable surface — deep links, App Intents, and the widget all speak this
/// vocabulary, mapping onto the richer `Destination` enum at consumption time.
///
/// Grammar:
///   dash://watchtower
///   dash://zone/<id>[/dns|cache|settings|analytics|waf]
///   dash://feature/<FeatureID.rawValue>
///   dash://worker/<name>
///   dash://pages/<name>[/domains|/deployments/<id>]
///   dash://r2/<name>
///   dash://kv/<id>
enum DashRoute: Hashable, Sendable {
  case watchtower
  case zone(String)
  case zoneDNS(String)
  case zoneCache(String)
  case zoneSettings(String)
  case zoneAnalytics(String)
  case zoneWAF(String)
  case feature(FeatureID)
  case worker(String)
  case pagesProject(String)
  case pagesDeployment(project: String, deploymentID: String)
  case pagesDomains(String)
  case r2(String)
  case kv(String)

  static func parse(_ url: URL) -> DashRoute? {
    guard url.scheme == "dash" else { return nil }
    // URLComponents keeps the host lowercased and percent-decodes path parts.
    guard let host = url.host?.lowercased() else { return nil }
    let segments = url.pathComponents.filter { $0 != "/" }

    switch host {
    case "oauth":
      // Owned by ASWebAuthenticationSession during sign-in; a stray callback
      // outside an auth flow is intentionally ignored.
      return nil
    case "watchtower":
      return .watchtower
    case "zone":
      guard let id = segments.first else { return nil }
      switch segments.count >= 2 ? segments[1] : "" {
      case "dns": return .zoneDNS(id)
      case "cache": return .zoneCache(id)
      case "settings": return .zoneSettings(id)
      case "analytics": return .zoneAnalytics(id)
      case "waf": return .zoneWAF(id)
      default: return .zone(id)
      }
    case "feature":
      guard let raw = segments.first, let feature = FeatureID(rawValue: raw) else { return nil }
      return .feature(feature)
    case "worker":
      guard let name = segments.first else { return nil }
      return .worker(name)
    case "pages":
      guard let name = segments.first else { return nil }
      if segments.count >= 3, segments[1] == "deployments" {
        return .pagesDeployment(project: name, deploymentID: segments[2])
      }
      if segments.count >= 2, segments[1] == "domains" {
        return .pagesDomains(name)
      }
      return .pagesProject(name)
    case "r2":
      guard let name = segments.first else { return nil }
      return .r2(name)
    case "kv":
      guard let id = segments.first else { return nil }
      return .kv(id)
    default:
      return nil
    }
  }

  /// The pushable screen, or nil when the route is a bare tab switch.
  var destination: Destination? {
    switch self {
    case .watchtower: nil
    case .zone(let id): .zone(id)
    case .zoneDNS(let id): .dns(id)
    case .zoneCache(let id): .cache(id)
    case .zoneSettings(let id): .zoneSettings(id)
    case .zoneAnalytics(let id): .zoneAnalytics(id)
    case .zoneWAF(let id): .zoneWAF(id)
    case .feature(let feature): .feature(feature)
    case .worker(let name): .worker(name)
    case .pagesProject(let name): .pagesProject(name)
    case .pagesDeployment(let project, let id): .pagesDeployment(project: project, deploymentID: id)
    case .pagesDomains(let name): .pagesDomains(name)
    case .r2(let name): .r2Bucket(name, prefix: "")
    case .kv(let id): .kvNamespace(id)
    }
  }
}
