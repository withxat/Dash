import Foundation
import Testing

@testable import CloudflareAPI

/// Zone rulesets: read a phase, toggle one rule.
///
/// The network tests live in `extension NetworkTests` so they inherit that
/// suite's `.serialized` trait. Every function is prefixed `ruleset…` so
/// `--filter ruleset` selects the whole set.
extension NetworkTests {

  @Test func rulesetEntrypointDecodesRedirectAndCustomRules() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(
        request.url?.path
          == "/zones/z1/rulesets/phases/http_request_dynamic_redirect/entrypoint")
      #expect(request.httpMethod == "GET")
      return (
        200,
        Data(
          #"""
          {"success":true,"result":{
            "id":"rs1","name":"default","kind":"zone","version":"7",
            "phase":"http_request_dynamic_redirect","last_updated":"2026-07-01T00:00:00Z",
            "rules":[
              {"id":"r1","version":"3","action":"redirect","description":" Maintenance page ",
               "expression":"(http.host eq \"example.com\")","enabled":false,
               "last_updated":"2026-06-30T10:00:00Z","ref":"r1",
               "action_parameters":{"from_value":{"status_code":302,
                 "target_url":{"value":"https://status.example.com/"},
                 "preserve_query_string":true}}},
              {"id":"r2","action":"redirect","expression":"true",
               "action_parameters":{"from_value":{"status_code":301,
                 "target_url":{"expression":"concat(\"https://www.\", http.host)"}}}}
            ]}}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let ruleset = try #require(
      try await client.getZoneEntrypointRuleset(zoneID: "z1", phase: .dynamicRedirect))

    #expect(ruleset.id == "rs1")
    #expect(ruleset.phase == "http_request_dynamic_redirect")
    #expect(ruleset.rules.map(\.id) == ["r1", "r2"])
    let first = ruleset.rules[0]
    #expect(first.name == "Maintenance page")
    #expect(!first.isEnabled)
    #expect(first.action == "redirect")
    #expect(first.expression == #"(http.host eq "example.com")"#)
    #expect(first.redirectStatusCode == 302)
    #expect(first.redirectTarget?.value == "https://status.example.com/")
    #expect(first.redirectTarget?.isExpression == false)
    #expect(first.lastUpdated == "2026-06-30T10:00:00Z")
    // No description, and no `enabled`: Cloudflare omits it for a rule that is on.
    let second = ruleset.rules[1]
    #expect(second.name == nil)
    #expect(second.isEnabled)
    #expect(second.redirectTarget?.isExpression == true)
    #expect(second.redirectStatusCode == 301)

    // The feature cache persists what it is handed: unknown fields included.
    let restored = try JSONDecoder().decode(ZoneRuleset.self, from: JSONEncoder().encode(ruleset))
    #expect(restored == ruleset)
  }

  @Test func rulesetMissingEntrypointIsAnEmptyAnswerButOtherFailuresThrow() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let status = RequestRecorder()
    let session = mockSession { request in
      let phase = request.url?.lastPathComponent == "entrypoint"
      #expect(phase)
      // The first call asks for custom rules, the second for redirects.
      let isCustom = request.url?.path.contains("http_request_firewall_custom") == true
      status.record(isCustom ? "custom" : "redirect")
      return (
        isCustom ? 404 : 403,
        Data(
          #"{"success":false,"errors":[{"code":10003,"message":"could not find entrypoint"}],"result":null}"#
            .utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    // A zone that never had a custom rule has no entry point at all.
    #expect(try await client.getZoneEntrypointRuleset(zoneID: "z1", phase: .customFirewall) == nil)
    // A missing permission is not "no rules".
    await #expect(throws: CloudflareAPIError.self) {
      try await client.getZoneEntrypointRuleset(zoneID: "z1", phase: .dynamicRedirect)
    }
    #expect(status.paths == ["custom", "redirect"])
  }

  @Test func rulesetTogglePatchesOneRuleAndSendsEveryFieldBack() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.url?.path == "/zones/z1/rulesets/rs1/rules/r1")
      #expect(request.httpMethod == "PATCH")
      let body = try #require(requestBodyObject(request))
      // The PATCH replaces the rule, so everything it had must come back…
      #expect(body["id"] as? String == "r1")
      #expect(body["action"] as? String == "block")
      #expect(body["expression"] as? String == "(cf.threat_score gt 40)")
      #expect(body["description"] as? String == "Block risky")
      #expect(body["ref"] as? String == "stable-ref")
      #expect((body["logging"] as? [String: Any])?["enabled"] as? Bool == true)
      let ratelimit = body["ratelimit"] as? [String: Any]
      #expect(ratelimit?["period"] as? Int == 60)
      #expect(ratelimit?["characteristics"] as? [String] == ["ip.src", "cf.colo.id"])
      // …including a field this client has never modelled…
      #expect(body["some_future_field"] as? [String: String] == ["keep": "me"])
      // …except what Cloudflare computes itself…
      #expect(body["version"] == nil)
      #expect(body["last_updated"] == nil)
      // …with the one value that changed.
      #expect(body["enabled"] as? Bool == false)
      return (
        200,
        Data(
          #"""
          {"success":true,"result":{"id":"rs1","phase":"http_request_firewall_custom","version":"8",
            "rules":[{"id":"r1","action":"block","expression":"(cf.threat_score gt 40)",
                      "description":"Block risky","enabled":false,"version":"4"}]}}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let rule = try JSONDecoder().decode(
      RulesetRule.self,
      from: Data(
        #"""
        {"id":"r1","version":"3","last_updated":"2026-06-30T10:00:00Z","action":"block",
         "expression":"(cf.threat_score gt 40)","description":"Block risky","ref":"stable-ref",
         "enabled":true,"logging":{"enabled":true},
         "ratelimit":{"period":60,"requests_per_period":100,
                      "characteristics":["ip.src","cf.colo.id"]},
         "some_future_field":{"keep":"me"}}
        """#.utf8))

    let updated = try await client.setZoneRulesetRuleEnabled(
      zoneID: "z1", rulesetID: "rs1", rule: rule, enabled: false)

    #expect(updated.version == "8")
    #expect(updated.rules.first?.isEnabled == false)
  }
}

@Test func rulesetRuleOptimisticCopyChangesOnlyEnabled() throws {
  let rule = RulesetRule(fields: [
    "id": .string("r1"), "action": .string("block"), "expression": .string("true"),
    "version": .string("3"),
  ])
  #expect(rule.isEnabled)
  let off = rule.settingEnabled(false)
  #expect(!off.isEnabled)
  #expect(off.id == "r1")
  #expect(off.fields.count == rule.fields.count + 1)
  #expect(off.settingEnabled(true).isEnabled)
  // Turning a rule on is stated, not left to the omitted-means-on default.
  #expect(rule.updateBody(enabled: true)["enabled"] == .bool(true))
  #expect(RulesetRule.serverOwnedFields == ["version", "last_updated"])

  // A rule with no id cannot be addressed by the PATCH, so it must not decode.
  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode(RulesetRule.self, from: Data(#"{"action":"block"}"#.utf8))
  }
  // A block rule has no redirect to describe.
  #expect(rule.redirectTarget == nil)
  #expect(rule.redirectStatusCode == nil)
}
