import CloudflareAPI
import Foundation
import Testing

@testable import Dash

private struct CoverCase: Sendable {
  let ingress: String
  let accessHosts: Set<String>
  let expected: Bool
  let note: String
}

@Test(arguments: [
  CoverCase(
    ingress: "app.example.com",
    accessHosts: ["app.example.com"],
    expected: true,
    note: "literal match"),
  CoverCase(
    ingress: "api.example.com",
    accessHosts: ["*.example.com"],
    expected: true,
    note: "wildcard covers subdomain"),
  CoverCase(
    ingress: "foo.bar.example.com",
    accessHosts: ["*.example.com"],
    expected: true,
    note: "wildcard covers nested subdomain"),
  CoverCase(
    ingress: "example.com",
    accessHosts: ["*.example.com"],
    expected: false,
    note: "apex is not a subdomain of itself"),
  CoverCase(
    ingress: "https://API.Example.com:8443/v1",
    accessHosts: ["*.example.com"],
    expected: true,
    note: "scheme/path/port normalize before match"),
  CoverCase(
    ingress: "evil-example.com",
    accessHosts: ["*.example.com"],
    expected: false,
    note: "suffix must sit on a label boundary"),
  CoverCase(
    ingress: "",
    accessHosts: ["*.example.com", "app.example.com"],
    expected: false,
    note: "empty ingress never matches"),
  CoverCase(
    ingress: "   ",
    accessHosts: ["*.example.com"],
    expected: false,
    note: "whitespace-only ingress never matches"),
  CoverCase(
    ingress: "*.example.com",
    accessHosts: ["*.example.com"],
    expected: true,
    note: "ingress wildcard matches equal Access pattern only"),
  CoverCase(
    ingress: "*.example.com",
    accessHosts: ["*.other.com"],
    expected: false,
    note: "ingress wildcard does not expand against other patterns"),
  CoverCase(
    ingress: "api.example.com",
    accessHosts: ["*"],
    expected: false,
    note: "bare star is not a *.suffix pattern"),
  CoverCase(
    ingress: "api.example.com",
    accessHosts: ["*.*.example.com"],
    expected: false,
    note: "nested stars are refused"),
  CoverCase(
    ingress: "ssh.example.com",
    accessHosts: ["app.example.com"],
    expected: false,
    note: "unrelated literal does not cover sibling host"),
])
func tunnelHostMatchingCovers(cover: CoverCase) {
  #expect(
    TunnelHostMatching.covers(ingressHost: cover.ingress, accessHosts: cover.accessHosts)
      == cover.expected,
    "\(cover.note): \(cover.ingress) vs \(cover.accessHosts.sorted())")
}

@Test func tunnelHostnameRowUsesWildcardAccessCoverage() throws {
  let rule = try JSONDecoder().decode(
    TunnelIngressRule.self,
    from: Data(
      #"{"hostname":"api.example.com","path":"/v1/*","service":"http://localhost:8787"}"#.utf8))
  let protectedRow = TunnelHostnameRow(
    rule: rule,
    index: 0,
    tunnelRequiresAccess: false,
    accessHosts: ["*.example.com"])
  #expect(protectedRow.isProtected)

  let uncovered = TunnelHostnameRow(
    rule: rule,
    index: 0,
    tunnelRequiresAccess: false,
    accessHosts: ["app.example.com"])
  #expect(!uncovered.isProtected)
}
