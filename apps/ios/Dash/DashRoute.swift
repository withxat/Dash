import Foundation

enum DashRouteAccountResolution: Equatable, Sendable {
  case open(DashRoute)
  case confirmSwitch(accountID: String, route: DashRoute)
  case rejectMissingAccount
  case rejectUnavailable(accountID: String)
}

/// A destination expressible as a `dash://` deep link. Deliberately a small,
/// stable surface — deep links, App Intents, and the widget all speak this
/// vocabulary, mapping onto the richer `Destination` enum at consumption time.
///
/// Grammar:
///   dash://settings
///   dash://watchtower?account=<account-id>
///   dash://action/<HomeActionID.rawValue>?account=<account-id>
///   dash://zone/<id>[/dns|cache|settings|analytics|waf]?account=<account-id>
///   dash://feature/<FeatureID.rawValue>?account=<account-id>
///   dash://worker/<name>?account=<account-id>
///   dash://pages/<name>[/domains|/deployments/<id>]?account=<account-id>
///   dash://r2/<name>?account=<account-id>
///   dash://kv/<id>?account=<account-id>
///   dash://registrar/<domain>?account=<account-id>
///
/// Settings is global. Every other route must be bound to a Cloudflare account
/// with `?account=<account-id>` so the app can confirm a switch instead of
/// opening the same resource name under whichever account happens to be active.
enum DashRoute: Hashable, Sendable {
  case settings
  case watchtower
  /// Opens Home and runs the matching quick action tray.
  case action(HomeActionID)
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
  /// One Cloudflare Registrar domain, keyed on the FQDN.
  case registrarDomain(String)
  indirect case scoped(accountID: String, route: DashRoute)

  static func parse(_ url: URL) -> DashRoute? {
    guard url.scheme == "dash" else { return nil }
    // URLComponents keeps the host lowercased and percent-decodes path parts.
    guard let host = url.host?.lowercased() else { return nil }
    let segments = url.pathComponents.filter { $0 != "/" }
    guard let route = parseUnscoped(host: host, segments: segments) else { return nil }

    let accountItems =
      URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
      .filter { $0.name == "account" } ?? []
    guard accountItems.count <= 1 else { return nil }
    if case .settings = route {
      return accountItems.isEmpty ? route : nil
    }
    guard let accountItem = accountItems.first else { return nil }
    guard
      let accountID = accountItem.value?.trimmingCharacters(in: .whitespacesAndNewlines),
      !accountID.isEmpty
    else {
      return nil
    }
    return route.scoped(to: accountID)
  }

  private static func parseUnscoped(host: String, segments: [String]) -> DashRoute? {
    switch host {
    case "oauth":
      // Owned by ASWebAuthenticationSession during sign-in; a stray callback
      // outside an auth flow is intentionally ignored.
      return nil
    case "settings":
      return segments.isEmpty ? .settings : nil
    case "watchtower":
      return .watchtower
    case "action":
      guard segments.count == 1, let action = HomeActionID(rawValue: segments[0]) else {
        return nil
      }
      return .action(action)
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
    case "registrar":
      guard let domain = segments.first, domain.contains(".") else { return nil }
      return .registrarDomain(domain.lowercased())
    default:
      return nil
    }
  }

  /// Account explicitly carried by the external route, if any.
  var accountID: String? {
    switch self {
    case .scoped(let accountID, _): accountID
    default: nil
    }
  }

  /// Removes account metadata while preserving the navigation destination.
  /// Consumption only uses this after the target account has been verified.
  var unscoped: DashRoute {
    switch self {
    case .scoped(_, let route): route.unscoped
    default: self
    }
  }

  /// Returns one canonical account wrapper, replacing any existing scope.
  /// Global Settings and empty account identifiers cannot be scoped.
  func scoped(to accountID: String) -> DashRoute? {
    let accountID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
    let route = unscoped
    guard !accountID.isEmpty else { return nil }
    guard case .settings = route else {
      return .scoped(accountID: accountID, route: route)
    }
    return nil
  }

  /// Pure account-safety policy used before a parsed external route reaches
  /// navigation. A scoped route only opens directly when its account is
  /// already active.
  func accountResolution(
    activeAccountID: String?,
    availableAccountIDs: Set<String>
  ) -> DashRouteAccountResolution {
    let route = unscoped
    if case .settings = route { return .open(.settings) }
    guard
      let accountID = accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
      !accountID.isEmpty
    else {
      return .rejectMissingAccount
    }
    if accountID == activeAccountID { return .open(route) }
    if availableAccountIDs.contains(accountID) {
      return .confirmSwitch(accountID: accountID, route: route)
    }
    return .rejectUnavailable(accountID: accountID)
  }

  /// The pushable screen, or nil when the route is a bare tab switch.
  var destination: Destination? {
    switch self {
    case .settings: .settings
    case .watchtower: nil
    case .action: nil
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
    case .registrarDomain(let domain): .registrarDomain(domain)
    case .scoped(_, let route): route.destination
    }
  }
}
