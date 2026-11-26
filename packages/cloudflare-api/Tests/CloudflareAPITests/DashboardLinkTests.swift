import Foundation
import Testing

@testable import CloudflareAPI

private let account = "0123456789abcdef0123456789ABCDEF"
private let deployment = "4fcdd3b4-e0a7-42df-b2d9-4a89a1981d9d"

private func link(_ string: String) -> CloudflareDashboardLink? {
  URL(string: string).flatMap(CloudflareDashboardLink.init(url:))
}

@Test func dashboardLinkReadsPagesDeploymentFromAnAccountPath() {
  let parsed = link("https://dash.cloudflare.com/\(account)/pages/view/portal/\(deployment)")
  // The account tag is normalised; the project and deployment are not swapped.
  #expect(parsed?.accountID == "0123456789abcdef0123456789abcdef")
  #expect(parsed?.resource == .pagesDeployment(project: "portal", deploymentID: deployment))
}

@Test func dashboardLinkReadsTheGitHubCheckRedirectForm() {
  // What the Pages GitHub check's "View logs" links to.
  let parsed = link(
    "https://dash.cloudflare.com/?to=/:account/pages/view/portal/\(deployment)")
  #expect(parsed?.accountID == nil)
  #expect(parsed?.resource == .pagesDeployment(project: "portal", deploymentID: deployment))

  // The same form without the slash before the query, and percent-encoded.
  #expect(
    link("https://dash.cloudflare.com?to=%2F%3Aaccount%2Fpages%2Fview%2Fportal%2F\(deployment)")
      == parsed)

  // `?to=` may also carry a concrete account.
  #expect(
    link("https://dash.cloudflare.com/?to=/\(account)/pages/view/portal")?.accountID
      == account.lowercased())
}

@Test func dashboardLinkTellsProjectTabsFromDeployments() {
  func resource(_ tail: String) -> CloudflareDashboardLink.Resource? {
    link("https://dash.cloudflare.com/\(account)/pages/view/portal\(tail)")?.resource
  }
  #expect(resource("") == .pagesProject(name: "portal"))
  #expect(resource("/") == .pagesProject(name: "portal"))
  #expect(resource("/deployments") == .pagesProject(name: "portal"))
  #expect(resource("/deployments/new") == .pagesProject(name: "portal"))
  #expect(resource("/settings/builds-deployments") == .pagesProject(name: "portal"))
  #expect(resource("/domains") == .pagesDomains(project: "portal"))
  // A short id is still a deployment; a tab made of hex letters under eight
  // characters is not mistaken for one.
  #expect(resource("/4fcdd3b4") == .pagesDeployment(project: "portal", deploymentID: "4fcdd3b4"))
  #expect(resource("/feed") == .pagesProject(name: "portal"))
}

@Test func dashboardLinkReadsWorkersAndBuilds() {
  let build = "a398d794-7322-4c97-96d9-40b5140a8d9b"
  func resource(_ tail: String) -> CloudflareDashboardLink.Resource? {
    link("https://dash.cloudflare.com/\(account)/workers/services/view/api\(tail)")?.resource
  }
  #expect(resource("") == .worker(name: "api"))
  #expect(resource("/production") == .worker(name: "api"))
  #expect(resource("/production/deployments") == .worker(name: "api"))
  #expect(resource("/production/builds") == .worker(name: "api"))
  #expect(resource("/production/builds/\(build)") == .workerBuild(worker: "api", buildID: build))
}

@Test func dashboardLinkReadsR2KVAndAuditLogs() {
  let nsID = "0f2ac74b498b48028cb6838f7c0137e4"
  #expect(
    link("https://dash.cloudflare.com/\(account)/workers/kv/namespaces/\(nsID)")?.resource
      == .kvNamespace(id: nsID))
  #expect(link("https://dash.cloudflare.com/\(account)/workers/kv/namespaces") == nil)
  #expect(link("https://dash.cloudflare.com/\(account)/workers/kv/namespaces/new") == nil)

  #expect(
    link("https://dash.cloudflare.com/\(account)/r2/default/buckets/assets")?.resource
      == .r2Bucket(name: "assets"))
  #expect(
    link("https://dash.cloudflare.com/\(account)/r2/default/buckets/assets/objects")?.resource
      == .r2Bucket(name: "assets"))
  #expect(
    link("https://dash.cloudflare.com/\(account)/r2/default/buckets/assets/settings")?.resource
      == .r2BucketSettings(name: "assets"))
  // Jurisdictional buckets stay in Safari so Dash never sends requests to the wrong jurisdiction.
  #expect(link("https://dash.cloudflare.com/\(account)/r2/eu/buckets/assets") == nil)
  #expect(link("https://dash.cloudflare.com/\(account)/r2/default/buckets") == nil)

  #expect(link("https://dash.cloudflare.com/\(account)/audit-log")?.resource == .auditLogs)
  #expect(link("https://dash.cloudflare.com/\(account)/audit-log/export") == nil)
}

@Test func dashboardLinkReadsZoneSectionsAndLeavesUnsupportedPagesInSafari() {
  func resource(_ tail: String) -> CloudflareDashboardLink.Resource? {
    link("https://dash.cloudflare.com/\(account)/Example.COM\(tail)")?.resource
  }
  #expect(resource("") == .zone(name: "example.com", section: .overview))
  #expect(resource("/overview") == .zone(name: "example.com", section: .overview))
  #expect(resource("/dns") == .zone(name: "example.com", section: .dns))
  #expect(resource("/dns/records") == .zone(name: "example.com", section: .dns))
  #expect(resource("/caching/configuration") == .zone(name: "example.com", section: .cache))
  #expect(resource("/security") == .zone(name: "example.com", section: .waf))
  #expect(resource("/security/events") == .zone(name: "example.com", section: .waf))
  #expect(resource("/security/waf/custom-rules") == .zone(name: "example.com", section: .waf))
  #expect(resource("/security/settings") == .zone(name: "example.com", section: .settings))
  #expect(resource("/ssl-tls/edge-certificates") == .zone(name: "example.com", section: .settings))
  #expect(resource("/network") == .zone(name: "example.com", section: .settings))
  #expect(resource("/analytics") == .zone(name: "example.com", section: .analytics))
  #expect(resource("/analytics/traffic") == .zone(name: "example.com", section: .analytics))
  #expect(resource("/email/routing/routes") == .zone(name: "example.com", section: .emailRouting))

  // Unsupported zone subpages stay in Safari.
  #expect(resource("/zaraz") == nil)
  #expect(resource("/rules/redirect-rules") == nil)
  #expect(resource("/security/bots") == nil)
  #expect(resource("/analytics/logs") == nil)
  #expect(resource("/email/dmarc-management") == nil)
  #expect(resource("/overview/extra") == nil)
}

@Test func dashboardLinkRejectsWhatItCannotName() {
  // Another host that merely contains the dashboard's name.
  #expect(link("https://dash.cloudflare.com.evil.test/\(account)/pages/view/portal") == nil)
  #expect(link("https://developers.cloudflare.com/\(account)/pages/view/portal") == nil)
  #expect(link("dash://\(account)/pages/view/portal") == nil)
  // Dashboard pages that are not account-scoped.
  #expect(link("https://dash.cloudflare.com/login") == nil)
  #expect(link("https://dash.cloudflare.com/") == nil)
  #expect(link("https://dash.cloudflare.com/profile/pages/view/portal") == nil)
  // An account with nothing recognisable under it.
  #expect(link("https://dash.cloudflare.com/\(account)") == nil)
  #expect(link("https://dash.cloudflare.com/\(account)/example.com/zaraz") == nil)
  #expect(link("https://dash.cloudflare.com/\(account)/pages") == nil)
  // Cloudflare's "pick a project" placeholder names no project.
  #expect(
    link("https://dash.cloudflare.com/?to=/:account/pages/view/:pages-project/domains") == nil)
  // Two targets is not a link Dash should guess between.
  #expect(
    link(
      "https://dash.cloudflare.com/?to=/:account/pages/view/a&to=/:account/pages/view/b") == nil)
}

/// The same list `apps/ios/scripts/safari-handoff.test.mjs` runs the Safari
/// extension's matcher against. Safari hands a page to Dash exactly when the
/// fixture says `opens`; this is the half that proves Dash can then place it.
@Test func dashboardLinkAgreesWithTheSafariExtensionFixtures() throws {
  struct Fixture: Decodable {
    let url: String
    let opens: Bool
  }
  let file = try #require(
    Bundle.module.url(
      forResource: "dashboard-links", withExtension: "json", subdirectory: "Fixtures"))
  let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: file))
  #expect(fixtures.contains { $0.opens })
  #expect(fixtures.contains { !$0.opens })

  for fixture in fixtures {
    let url = try #require(URL(string: fixture.url), "unparseable fixture \(fixture.url)")
    #expect(
      (CloudflareDashboardLink(url: url) != nil) == fixture.opens,
      "\(fixture.url) should \(fixture.opens ? "open in Dash" : "stay in Safari")")
  }
}

@Test func dashboardLinkRejectsFullwidthLookalikes() {
  // `Character.isHexDigit` is true for these; an account tag is ASCII.
  let fullwidth = String(repeating: "０", count: 32)
  #expect(link("https://dash.cloudflare.com/\(fullwidth)/pages/view/portal") == nil)
}

@Test func dashboardLinkReadsTunnelsAndTunnelDetails() {
  let tunnelID = "7a8b132e-a702-38d4-9f0e-6a1b2c3d4e5f"
  #expect(
    link("https://dash.cloudflare.com/\(account)/zero-trust/networks/tunnels")?.resource
      == .tunnels)
  #expect(
    link(
      "https://dash.cloudflare.com/\(account)/zero-trust/networks/connectors/cloudflare-tunnels"
    )?.resource == .tunnels)
  #expect(
    link(
      "https://dash.cloudflare.com/\(account)/zero-trust/networks/tunnels/cfd_tunnel/\(tunnelID)/edit"
    )?.resource == .tunnel(id: tunnelID))
  #expect(
    link(
      "https://dash.cloudflare.com/\(account)/zero-trust/networks/connectors/cloudflare-tunnels/cfd_tunnel/\(tunnelID)"
    )?.resource == .tunnel(id: tunnelID))
  #expect(
    link("https://dash.cloudflare.com/\(account)/zero-trust/networks/tunnels/\(tunnelID)")?.resource
      == .tunnel(id: tunnelID))
  #expect(
    link("https://dash.cloudflare.com/\(account)/zero-trust/networks/tunnels/create") == nil)
  #expect(
    link("https://dash.cloudflare.com/\(account)/zero-trust/networks/tunnels/cfd_tunnel") == nil)
}
