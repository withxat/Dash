import Foundation

/// A Cloudflare dashboard URL (`dash.cloudflare.com`) reduced to the resource
/// it names, so a link copied from the dashboard, a GitHub check, or an email
/// can open the matching native screen.
///
/// Two shapes carry the same path:
///
///   https://dash.cloudflare.com/<account-id>/pages/view/<project>/<deployment-id>
///   https://dash.cloudflare.com/?to=/:account/pages/view/<project>/<deployment-id>
///
/// The second is Cloudflare's own deep-link form — the Pages GitHub check's
/// "View logs" uses it — where `:account` means "whichever account the reader
/// picks". `accountID` is nil for it; the caller decides what that resolves to.
///
/// Only verified dashboard paths are recognised. Anything else is nil rather
/// than a guess: an unparsed link stays in the browser, a wrongly parsed one
/// opens the wrong resource.
///
/// The Safari extension (`apps/ios/DashSafari/Resources/content.js`) decides
/// which pages to hand to Dash with a JavaScript mirror of these rules. Change
/// one and change the other; `Tests/CloudflareAPITests/Fixtures/dashboard-links.json`
/// is read by both test suites and fails whichever side drifted.
public struct CloudflareDashboardLink: Hashable, Sendable {
  /// The screen a zone-scoped dashboard link lands on.
  public enum ZoneSection: String, Hashable, Sendable {
    case overview
    case dns
    case cache
    case waf
    case settings
    case analytics
    case emailRouting
  }

  public enum Resource: Hashable, Sendable {
    case pagesProject(name: String)
    case pagesDeployment(project: String, deploymentID: String)
    case pagesDomains(project: String)
    case worker(name: String)
    /// One Workers Builds run. `buildID` is the build UUID from the URL.
    case workerBuild(worker: String, buildID: String)
    /// A default-jurisdiction R2 bucket. Jurisdictional buckets stay in Safari
    /// because Dash does not send `cf-r2-jurisdiction`.
    case r2Bucket(name: String)
    case r2BucketSettings(name: String)
    case kvNamespace(id: String)
    case d1Databases
    case d1Database(id: String)
    case tunnels
    case tunnel(id: String)
    case auditLogs
    /// A zone addressed by its domain name — dashboard URLs carry the FQDN
    /// rather than the zone tag, so the app resolves it against the account.
    case zone(name: String, section: ZoneSection)
  }

  /// The 32-hex account tag from the path, lowercased, or nil when the link
  /// used the `:account` placeholder.
  public let accountID: String?
  public let resource: Resource

  public init(accountID: String?, resource: Resource) {
    self.accountID = accountID
    self.resource = resource
  }

  public init?(url: URL) {
    guard
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
      components.host?.lowercased() == "dash.cloudflare.com"
    else { return nil }

    // `?to=` wins when present: the dashboard treats it as the real target and
    // the URL's own path is just the root it bounces from.
    let redirectTargets = components.queryItems?.filter { $0.name == "to" } ?? []
    guard redirectTargets.count <= 1 else { return nil }
    let path = redirectTargets.first?.value ?? components.path
    var segments = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard !segments.isEmpty else { return nil }

    let account = segments.removeFirst()
    let accountID: String?
    if account == ":account" {
      accountID = nil
    } else if account.count == 32, account.allSatisfy(Self.isHex) {
      accountID = account.lowercased()
    } else {
      // `/login`, `/profile`, `/sign-up`, … are dashboard pages, not accounts.
      return nil
    }

    guard let resource = Self.resource(segments) else { return nil }
    self.init(accountID: accountID, resource: resource)
  }

  private static func resource(_ segments: [String]) -> Resource? {
    guard !segments.isEmpty else { return nil }
    // pages/view/<project>[/<deployment-id> | /domains | /<any other tab>]
    if segments.count >= 3, segments[0] == "pages", segments[1] == "view" {
      let project = segments[2]
      guard isResourceName(project) else { return nil }
      guard segments.count >= 4 else { return .pagesProject(name: project) }
      let tail = segments[3]
      if tail == "domains" { return .pagesDomains(project: project) }
      if isIdentifier(tail) { return .pagesDeployment(project: project, deploymentID: tail) }
      // deployments, settings, analytics, … are tabs of the project screen.
      return .pagesProject(name: project)
    }

    // workers/services/view/<worker>[/<environment>[/builds/<build-id> | /<tab>]]
    if segments.count >= 4, segments[0] == "workers", segments[1] == "services",
      segments[2] == "view"
    {
      let worker = segments[3]
      guard isResourceName(worker) else { return nil }
      if segments.count >= 7, segments[5] == "builds", isIdentifier(segments[6]) {
        return .workerBuild(worker: worker, buildID: segments[6])
      }
      return .worker(name: worker)
    }

    // workers/kv/namespaces/<namespace-id>[/...]
    if segments.count >= 4, segments[0] == "workers", segments[1] == "kv",
      segments[2] == "namespaces", isIdentifier(segments[3])
    {
      return .kvNamespace(id: segments[3])
    }

    // workers/d1[/databases/<database-id>[/...]]
    if segments.count >= 2, segments[0] == "workers", segments[1] == "d1" {
      if segments.count == 2 { return .d1Databases }
      guard segments.count >= 4, segments[2] == "databases", isIdentifier(segments[3])
      else { return nil }
      return .d1Database(id: segments[3])
    }

    // r2/default/buckets/<bucket>[/settings | /<tab>]
    // Jurisdictional buckets (eu, fedramp, …) intentionally stay in Safari:
    // Dash does not send the `cf-r2-jurisdiction` header.
    if segments.count >= 4, segments[0] == "r2", segments[1] == "default",
      segments[2] == "buckets", isResourceName(segments[3])
    {
      let bucket = segments[3]
      if segments.count >= 5, segments[4] == "settings" {
        return .r2BucketSettings(name: bucket)
      }
      return .r2Bucket(name: bucket)
    }

    // zero-trust/networks/tunnels[/cfd_tunnel/<tunnel-id>[/...] | /<tunnel-id>[/...]]
    // zero-trust/networks/connectors/cloudflare-tunnels[/cfd_tunnel/<tunnel-id>[/...] | /<tunnel-id>[/...]]
    if let tunnelResource = tunnelResource(segments) {
      return tunnelResource
    }

    // audit-log
    if segments.count == 1, segments[0] == "audit-log" {
      return .auditLogs
    }

    // <domain>[/overview | /dns/… | /caching/… | /security[/events | /waf/… | /settings]
    //         | /ssl-tls/… | /network/… | /analytics[/traffic/…] | /email/routing/…]
    // Unsupported zone subpages (zaraz, rules, spectrum, …) stay in Safari
    // rather than dumping the reader onto zone overview.
    if isDomainName(segments[0]) {
      let domain = segments[0].lowercased()
      guard let section = zoneSection(Array(segments.dropFirst())) else { return nil }
      return .zone(name: domain, section: section)
    }

    return nil
  }

  private static func tunnelResource(_ segments: [String]) -> Resource? {
    let tail: ArraySlice<String>
    if segments.count >= 3, segments[0] == "zero-trust", segments[1] == "networks",
      segments[2] == "tunnels"
    {
      tail = segments.dropFirst(3)
    } else if segments.count >= 4, segments[0] == "zero-trust", segments[1] == "networks",
      segments[2] == "connectors", segments[3] == "cloudflare-tunnels"
    {
      tail = segments.dropFirst(4)
    } else {
      return nil
    }
    guard let first = tail.first else { return .tunnels }
    if first == "cfd_tunnel" {
      let rest = tail.dropFirst()
      guard let id = rest.first, isIdentifier(id) else { return nil }
      return .tunnel(id: id)
    }
    if isIdentifier(first) {
      return .tunnel(id: first)
    }
    return nil
  }

  private static func zoneSection(_ tail: [String]) -> ZoneSection? {
    guard let first = tail.first else { return .overview }
    switch first {
    case "overview":
      return tail.count == 1 ? .overview : nil
    case "dns":
      return .dns
    case "caching":
      return .cache
    case "security":
      guard tail.count > 1 else { return .waf }
      switch tail[1] {
      case "events", "waf":
        return .waf
      case "settings":
        return .settings
      default:
        return nil
      }
    case "ssl-tls", "network":
      return .settings
    case "analytics":
      guard tail.count == 1 || tail[1] == "traffic" else { return nil }
      return .analytics
    case "email":
      guard tail.count >= 2, tail[1] == "routing" else { return nil }
      return .emailRouting
    default:
      return nil
    }
  }

  /// `:pages-project` is the placeholder Cloudflare's own "magic links" use for
  /// a project the reader has to pick; it names nothing.
  private static func isResourceName(_ value: String) -> Bool {
    !value.isEmpty && !value.hasPrefix(":")
  }

  /// A zone's FQDN as it appears in the dashboard path. Account-level sections
  /// (`home`, `pages`, `workers`, `r2`, …) never contain a dot; requiring valid
  /// ASCII DNS labels and an alphabetic or punycode TLD keeps non-domain paths
  /// out without maintaining a denylist.
  private static func isDomainName(_ value: String) -> Bool {
    guard !value.isEmpty, value.count <= 253, !value.hasPrefix(":") else { return false }
    let lower = value.lowercased()
    let labels = lower.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count >= 2 else { return false }
    for label in labels {
      guard !label.isEmpty, label.count <= 63 else { return false }
      guard
        let first = label.first, let last = label.last,
        isLowerAlphanumeric(first), isLowerAlphanumeric(last),
        label.allSatisfy({ isLowerAlphanumeric($0) || $0 == "-" })
      else { return false }
    }
    guard let tld = labels.last else { return false }
    if tld.count >= 2, tld.allSatisfy(isLowerAlpha) { return true }
    if tld.hasPrefix("xn--"), tld.count >= 6 { return true }
    return false
  }

  /// Deployment and build ids are UUIDs. Matching on shape — hex and hyphens,
  /// at least a short id long — is what tells one from a tab name without
  /// keeping a list of every tab the dashboard has or will add.
  private static func isIdentifier(_ value: String) -> Bool {
    value.count >= 8 && value.allSatisfy { isHex($0) || $0 == "-" }
  }

  /// ASCII only. `Character.isHexDigit` also accepts the fullwidth forms, which
  /// no Cloudflare id contains and the Safari extension's matcher rejects.
  private static func isHex(_ character: Character) -> Bool {
    character.isASCII && character.isHexDigit
  }

  private static func isLowerAlpha(_ character: Character) -> Bool {
    character >= "a" && character <= "z"
  }

  private static func isLowerAlphanumeric(_ character: Character) -> Bool {
    isLowerAlpha(character) || (character >= "0" && character <= "9")
  }
}
