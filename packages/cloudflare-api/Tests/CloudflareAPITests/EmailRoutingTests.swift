import Foundation
import Testing

@testable import CloudflareAPI

// Every function is prefixed `emailRouting…` so `--filter emailRouting` matches
// by name; `--filter` never matches a file. They live in `extension NetworkTests`
// so they inherit its `.serialized` trait — `MockURLProtocol` keeps
// `nonisolated(unsafe) static` state that a parallel suite would race on.
extension NetworkTests {

  // MARK: - Settings

  @Test func emailRoutingUnknownStatusResolvesToNilNeverReady() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.url?.path == "/zones/zone-1/email/routing")
      return (
        200,
        Data(
          #"""
          {"success":true,"result":{
            "id":"er-1","name":"example.com","enabled":true,
            "status":"a_status_dash_has_never_seen",
            "created":"2024-01-01T00:00:00Z","modified":"2024-02-01T00:00:00Z",
            "skip_wizard":false,"support_subaddress":true,"tag":"tag-1"
          }}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let settings = try await client.getEmailRoutingSettings(zoneID: "zone-1")

    #expect(settings.enabled)
    #expect(settings.supportSubaddress == true)
    #expect(settings.skipWizard == false)
    #expect(settings.status == "a_status_dash_has_never_seen")
    // The whole point: an unrecognised status is unknown, never `.ready`.
    #expect(settings.routingStatus == nil)

    let locked = try JSONDecoder().decode(
      EmailRoutingSettings.self,
      from: Data(
        #"{"id":"er-1","name":"example.com","enabled":true,"status":"misconfigured/locked"}"#.utf8))
    #expect(locked.routingStatus == .misconfiguredLocked)
  }

  @Test func emailRoutingSettingsNotFoundThrowsRatherThanReadingAsTurnedOff() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { _ in
      (
        404,
        Data(
          #"{"success":false,"errors":[{"code":1000,"message":"Not found"}],"result":null}"#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    // A 404 must reach the caller. Painting it as "email routing is off" hands
    // the user an empty state whose only action rewrites the zone's apex MX.
    await #expect(throws: CloudflareAPIError.self) {
      try await client.getEmailRoutingSettings(zoneID: "zone-1")
    }
    do {
      _ = try await client.getEmailRoutingSettings(zoneID: "zone-1")
      Issue.record("expected a 404 to throw")
    } catch let error as CloudflareAPIError {
      #expect(error.isNotFound)
    }
  }

  @Test func emailRoutingSubaddressingPatchSendsOnlySupportSubaddress() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.httpMethod == "PATCH")
      #expect(request.url?.path == "/zones/zone-1/email/routing")
      let body =
        requestBodyObject(request)
      // Cloudflare documents `enabled` on this PATCH as a no-op. Sending it
      // alongside a real flag is how a screen ends up believing it turned
      // routing off.
      #expect(body?.count == 1)
      #expect(body?["support_subaddress"] as? Bool == true)
      #expect(body?["enabled"] == nil)
      return (
        200,
        Data(
          #"""
          {"success":true,"result":{"id":"er-1","name":"example.com","enabled":true,
            "status":"ready","support_subaddress":true}}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let settings = try await client.updateEmailRoutingSubaddressing(zoneID: "zone-1", enabled: true)

    #expect(settings.supportSubaddress == true)
    #expect(settings.routingStatus == .ready)
  }

  // MARK: - DNS plan (a `oneOf` with two documented shapes)

  @Test func emailRoutingDNSPlanDecodesBareRecordArray() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.url?.path == "/zones/zone-1/email/routing/dns")
      return (
        200,
        Data(
          #"""
          {"success":true,"result":[
            {"type":"MX","name":"example.com","content":"route1.mx.cloudflare.net","ttl":1,
             "priority":51},
            {"type":"TXT","name":"example.com","content":"v=spf1 include:_spf.mx.cloudflare.net ~all",
             "ttl":1}
          ]}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let plan = try await client.getEmailRoutingDNSPlan(zoneID: "zone-1")

    #expect(plan.records.count == 2)
    #expect(plan.missing.isEmpty)
    #expect(!plan.isEmpty)
    #expect(plan.records.first?.type == "MX")
    #expect(plan.records.first?.priority == 51)
    #expect(plan.records.first?.ttl == 1)
    #expect(plan.records.last?.content?.hasPrefix("v=spf1") == true)
  }

  @Test func emailRoutingDNSPlanDecodesErrorObjectShapeWithMissingRecords() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { _ in
      (
        200,
        Data(
          #"""
          {"success":true,"result":{
            "errors":[
              {"code":"missing_dns_record","missing":{"type":"MX","name":"example.com",
                "content":"route2.mx.cloudflare.net","ttl":1,"priority":72}},
              {"code":2001,"missing":{"type":"TXT","name":"example.com",
                "content":"v=spf1 include:_spf.mx.cloudflare.net ~all","ttl":1}}
            ],
            "record":[{"type":"MX","name":"example.com","content":"route1.mx.cloudflare.net",
              "ttl":1,"priority":51}]
          }}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let plan = try await client.getEmailRoutingDNSPlan(zoneID: "zone-1")

    #expect(plan.records.map(\.content) == ["route1.mx.cloudflare.net"])
    #expect(
      plan.missing.map(\.content) == [
        "route2.mx.cloudflare.net",
        "v=spf1 include:_spf.mx.cloudflare.net ~all",
      ])
    #expect(plan.missing.first?.priority == 72)
  }

  @Test func emailRoutingDNSPlanThrowsOnUnrecognisedShapeRatherThanEmptying() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { _ in
      (200, Data(#"{"success":true,"result":{"unexpected":1}}"#.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    // Degrading to empty arrays would render "Records Cloudflare will add:
    // (nothing)" beside an armed confirm that replaces the apex MX set,
    // and would collapse the client-side conflict check. Empty != failed.
    await #expect(throws: DecodingError.self) {
      try await client.getEmailRoutingDNSPlan(zoneID: "zone-1")
    }
  }

  // MARK: - Rules

  @Test func emailRoutingRulesPageDropsARuleWithNoIdentifier() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.url?.path == "/zones/zone-1/email/routing/rules")
      let query = Dictionary(
        uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
          .queryItems ?? []).map { ($0.name, $0.value ?? "") })
      #expect(query["page"] == "1")
      #expect(query["per_page"] == "50")
      return (
        200,
        Data(
          #"""
          {"success":true,"result":[
            {"id":"rule-1","tag":"tag-1","name":"hi@example.com","enabled":true,"priority":12,
             "matchers":[{"type":"literal","field":"to","value":"hi@example.com"}],
             "actions":[{"type":"forward","value":["inbox@example.net"]}]},
            {"id":"rule-2","source":"wrangler","name":"worker route",
             "matchers":[{"type":"literal","field":"to","value":"bot@example.com"}],
             "actions":[{"type":"worker","value":["mailer"]}]},
            {"tag":"orphan","matchers":[],"actions":[]}
          ],"result_info":{"page":1,"per_page":50,"total_count":3}}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let page = try await client.listEmailRoutingRules(zoneID: "zone-1")

    // The id-less row is dropped by LossyElement, not thrown over.
    #expect(page.items.map(\.id) == ["rule-1", "rule-2"])
    #expect(page.items.first?.matchedAddress == "hi@example.com")
    #expect(page.items.first?.actions.first?.forwardTarget == "inbox@example.net")
    #expect(page.items.first?.priority == 12)
    #expect(page.items.first?.isWranglerManaged == false)
    #expect(page.items.last?.isWranglerManaged == true)
    // A worker action is not a forward target — the row must not claim one.
    #expect(page.items.last?.actions.first?.forwardTarget == nil)
  }

  @Test func emailRoutingCreateRuleBodyCarriesNoSourceOrOwnerWorkerTag() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.httpMethod == "POST")
      #expect(request.url?.path == "/zones/zone-1/email/routing/rules")
      let body =
        requestBodyObject(request)
      // Dash must never claim a rule as wrangler-managed, and must never
      // re-parent one to a Worker on a round-trip.
      #expect(body?["source"] == nil)
      #expect(body?["owner_worker_tag"] == nil)
      #expect(Set((body ?? [:]).keys) == ["matchers", "actions", "enabled", "name"])
      let matchers = body?["matchers"] as? [[String: Any]]
      #expect(matchers?.first?["type"] as? String == "literal")
      #expect(matchers?.first?["value"] as? String == "hi@example.com")
      return (
        200,
        Data(
          #"""
          {"success":true,"result":{"id":"rule-9","enabled":true,"priority":30,
            "matchers":[{"type":"literal","field":"to","value":"hi@example.com"}],
            "actions":[{"type":"forward","value":["inbox@example.net"]}]}}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let rule = try await client.createEmailRoutingRule(
      zoneID: "zone-1",
      input: EmailRoutingRuleInput(
        matchers: [EmailRoutingRuleMatcher(type: "literal", field: "to", value: "hi@example.com")],
        actions: [EmailRoutingRuleAction(type: "forward", value: ["inbox@example.net"])],
        enabled: true, name: "hi@example.com"))

    #expect(rule.id == "rule-9")
    #expect(rule.priority == 30)
  }

  @Test func emailRoutingRuleUpdateRoundTripsTheFetchedPriorityUntouched() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.httpMethod == "PUT")
      #expect(request.url?.path == "/zones/zone-1/email/routing/rules/rule-1")
      let body =
        requestBodyObject(request)
      // Priority is hidden in the UI but must survive every save, or an edit
      // silently reorders rules the user never touched.
      #expect(body?["priority"] as? Int == 12)
      #expect(body?["source"] == nil)
      return (
        200,
        Data(
          #"""
          {"success":true,"result":{"id":"rule-1","enabled":false,"priority":12,
            "matchers":[{"type":"literal","field":"to","value":"hi@example.com"}],
            "actions":[{"type":"drop"}]}}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let rule = try await client.updateEmailRoutingRule(
      zoneID: "zone-1", ruleID: "rule-1",
      input: EmailRoutingRuleInput(
        matchers: [EmailRoutingRuleMatcher(type: "literal", field: "to", value: "hi@example.com")],
        actions: [EmailRoutingRuleAction(type: "drop")],
        enabled: false, name: nil, priority: 12))

    #expect(rule.enabled == false)
    // A drop action has no forward target and no `value` on the wire.
    #expect(rule.actions.first?.type == "drop")
    #expect(rule.actions.first?.value == nil)
  }

  @Test func emailRoutingCatchAllDecodesAndUpdatesWithoutAPriority() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.url?.path == "/zones/zone-1/email/routing/rules/catch_all")
      if request.httpMethod == "PUT" {
        let body =
          requestBodyObject(request)
        // The separate input type exists so a phantom priority can never be
        // written back onto the catch-all.
        #expect(body?["priority"] == nil)
        #expect((body?["matchers"] as? [[String: Any]])?.first?["type"] as? String == "all")
      }
      return (
        200,
        Data(
          #"""
          {"success":true,"result":{"id":"catch-all","tag":"ca","name":"Catch-all",
            "enabled":true,"matchers":[{"type":"all"}],
            "actions":[{"type":"forward","value":["inbox@example.net"]}]}}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let fetched = try await client.getEmailRoutingCatchAll(zoneID: "zone-1")
    #expect(fetched.enabled == true)
    #expect(fetched.matchers.first?.type == "all")
    #expect(fetched.actions.first?.forwardTarget == "inbox@example.net")

    let updated = try await client.updateEmailRoutingCatchAll(
      zoneID: "zone-1",
      input: EmailRoutingCatchAllInput(
        actions: [EmailRoutingRuleAction(type: "drop")], enabled: true))
    #expect(updated.id == "catch-all")
  }

  // MARK: - Destination addresses

  @Test func emailRoutingAddressesIssueBothVerifiedSweepsAndUnionThem() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let recorder = RequestRecorder()
    let session = mockSession { request in
      #expect(request.url?.path == "/accounts/acct/email/routing/addresses")
      let query = Dictionary(
        uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
          .queryItems ?? []).map { ($0.name, $0.value ?? "") })
      // 50 is this endpoint's documented maximum, not the usual 100.
      #expect(query["per_page"] == "50")
      #expect(query["page"] == "1")
      let verified = query["verified"] ?? "<absent>"
      recorder.record(verified)
      if verified == "true" {
        return (
          200,
          Data(
            #"""
            {"success":true,"result":[
              {"id":"addr-a","tag":"ta","email":"a@example.net",
               "verified":"2024-03-01T00:00:00Z","created":"2024-02-01T00:00:00Z"}
            ],"result_info":{"page":1,"per_page":50,"total_count":1}}
            """#.utf8)
        )
      }
      #expect(verified == "false")
      return (
        200,
        Data(
          #"""
          {"success":true,"result":[
            {"id":"addr-a","tag":"ta","email":"a@example.net",
             "verified":"2024-03-01T00:00:00Z"},
            {"id":"addr-b","tag":"tb","email":"b@example.net","verified":null}
          ],"result_info":{"page":1,"per_page":50,"total_count":2}}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let addresses = try await client.listEmailDestinationAddresses(accountID: "acct")

    // `verified` documents `default: true`, so one naive GET would hide exactly
    // the addresses the screen has to warn about.
    #expect(Set(recorder.paths) == ["true", "false"])
    #expect(recorder.paths.count == 2)
    #expect(addresses.map(\.id) == ["addr-a", "addr-b"])
    #expect(addresses.first?.isVerified == true)
    #expect(addresses.last?.isVerified == false)
  }

  @Test func emailRoutingAddressWithNullVerifiedIsNotVerifiedAndCreatePostsTheEmail() async throws {
    let unverified = try JSONDecoder().decode(
      EmailDestinationAddress.self,
      from: Data(#"{"id":"addr-b","email":"b@example.net","verified":null}"#.utf8))
    // `verified` is a nullable timestamp, not a Bool.
    #expect(unverified.verified == nil)
    #expect(!unverified.isVerified)

    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.httpMethod == "POST")
      #expect(request.url?.path == "/accounts/acct/email/routing/addresses")
      let body =
        requestBodyObject(request)
      #expect(body?.count == 1)
      #expect(body?["email"] as? String == "new@example.net")
      return (
        200,
        Data(
          #"""
          {"success":true,"result":{"id":"addr-c","tag":"tc","email":"new@example.net",
            "verified":null,"created":"2024-04-01T00:00:00Z"}}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let created = try await client.createEmailDestinationAddress(
      accountID: "acct", email: "new@example.net")

    #expect(created.id == "addr-c")
    #expect(!created.isVerified)
  }

  // MARK: - Enable / disable

  @Test func emailRoutingEnableAndDisableUseTheDNSEndpointNotTheDeprecatedTriplet() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let recorder = RequestRecorder()
    let session = mockSession { request in
      recorder.record("\(request.httpMethod ?? "?") \(request.url?.path ?? "")")
      if request.httpMethod == "DELETE" {
        return (200, Data(#"{"success":true,"result":null}"#.utf8))
      }
      return (
        200,
        Data(
          #"""
          {"success":true,"result":{"id":"er-1","name":"example.com","enabled":true,
            "status":"ready"}}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let enabled = try await client.enableEmailRouting(zoneID: "zone-1")
    #expect(enabled.enabled)
    #expect(enabled.routingStatus == .ready)

    // `result: null` on the disable path must not throw.
    try await client.disableEmailRouting(zoneID: "zone-1")

    #expect(
      recorder.paths == [
        "POST /zones/zone-1/email/routing/dns",
        "DELETE /zones/zone-1/email/routing/dns",
      ])
  }
}
