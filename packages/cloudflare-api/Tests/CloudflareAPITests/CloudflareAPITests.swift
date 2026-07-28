import CryptoKit
import Foundation
import Testing

@testable import CloudflareAPI

@Test func pkceUsesURLSafeSHA256Challenge() {
  let pair = PKCEPair.generate()
  #expect(pair.verifier.count >= 43)
  #expect(!pair.challenge.contains("+"))
  #expect(!pair.challenge.contains("/"))
  #expect(!pair.challenge.contains("="))
  let expected = Data(SHA256.hash(data: Data(pair.verifier.utf8))).base64EncodedString()
    .replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_")
    .replacingOccurrences(of: "=", with: "")
  #expect(pair.challenge == expected)
}

@Test func authorizationURLContainsRequiredOAuthParameters() throws {
  let url = OAuth.authorizationURL(
    clientID: "client", redirectURI: "https://relay.example/oauth/callback", callbackState: "state",
    pkce: PKCEPair(verifier: "verifier", challenge: "challenge"), scopes: ["zone.read"]
  )
  let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
  let values = Dictionary(
    uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
  #expect(values["client_id"] == "client")
  #expect(values["state"] == "state")
  #expect(values["code_challenge_method"] == "S256")
  #expect(values["scope"] == "zone.read")
}

@Test func authorizationURLDropsMisspelledAndOAuthUnsupportedScopes() throws {
  let misspelled = "ai-search.meatadata_read"
  let url = OAuth.authorizationURL(
    clientID: "client",
    redirectURI: "https://relay.example/oauth/callback",
    callbackState: "state",
    pkce: PKCEPair(verifier: "verifier", challenge: "challenge"),
    scopes: ["ai-search.read", misspelled, "d1.metadata_read", "d1.read"]
  )
  let values = Dictionary(
    uniqueKeysWithValues:
      URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map {
        ($0.name, $0.value ?? "")
      }
  )
  #expect(values["scope"] == "ai-search.read d1.read")
  #expect(CloudflareScopes.invalid(in: [misspelled]) == [misspelled])
  #expect(CloudflareScopes.invalid(in: CloudflareScopes.all).isEmpty)
}

@Test func generatedCatalogCoversOfficialOAuthScopes() {
  #expect(OAuthScopeCatalog.all.count == 368)
  #expect(Set(OAuthScopeCatalog.allIDs).count == OAuthScopeCatalog.all.count)
  #expect(OAuthScopeCatalog.byID["query-cache.read"]?.name == "Hyperdrive Read")
  #expect(CloudflareScopes.invalid(in: CloudflareScopes.published).isEmpty)
  #expect(Set(CloudflareScopes.required).isSubset(of: Set(CloudflareScopes.published)))
  #expect(!CloudflareScopes.published.contains("ai-search.metadata_read"))
  #expect(CloudflareScopes.published.count == 359)
  #expect(CloudflareScopes.unsupportedByOAuthClient.count == 10)
  #expect(
    CloudflareScopes.unsupported(in: CloudflareScopes.all)
      == CloudflareScopes.unsupportedByOAuthClient
  )
}

@Test func authenticationAndAuthorizationErrorsAreDistinct() {
  let unauthorized = CloudflareAPIError.request(status: 401, errors: [])
  let forbidden = CloudflareAPIError.request(status: 403, errors: [])
  #expect(unauthorized.isUnauthorized)
  #expect(!unauthorized.isPermissionDenied)
  #expect(forbidden.isForbidden)
  #expect(forbidden.isPermissionDenied)
}

@Test func transportAndRateLimitErrorsAreDistinguishable() {
  let offline = CloudflareAPIError.transport("offline")
  let rateLimited = CloudflareAPIError.request(status: 429, errors: [])
  let unauthorized = CloudflareAPIError.request(status: 401, errors: [])
  #expect(offline.isTransport)
  #expect(!offline.isRateLimited)
  #expect(rateLimited.isRateLimited)
  #expect(!rateLimited.isTransport)
  #expect(!unauthorized.isTransport)
  #expect(!unauthorized.isRateLimited)
}

@Test func retryDelayHonorsRetryAfterHeader() {
  #expect(CloudflareClient.retryDelay(retryAfter: nil) == 1)
  #expect(CloudflareClient.retryDelay(retryAfter: "not-a-number") == 1)
  #expect(CloudflareClient.retryDelay(retryAfter: "0") == 0)
  #expect(CloudflareClient.retryDelay(retryAfter: "3") == 3)
  #expect(CloudflareClient.retryDelay(retryAfter: "5") == 5)
  #expect(CloudflareClient.retryDelay(retryAfter: "6") == nil)
  #expect(CloudflareClient.retryDelay(retryAfter: "120") == nil)
  #expect(CloudflareClient.retryDelay(retryAfter: "-2") == 0)
}

@Test func decodesPaginatedZoneEnvelope() throws {
  let data = Data(
    #"{"success":true,"result":[{"id":"zone","name":"example.com","status":"active"}],"result_info":{"page":1,"per_page":50,"total_count":1}}"#
      .utf8)
  let envelope = try JSONDecoder().decode(APIEnvelope<[CloudflareZone]>.self, from: data)
  #expect(envelope.result.first?.name == "example.com")
  #expect(envelope.resultInfo?.totalCount == 1)
}

@Test func decodesZonePlan() throws {
  let data = Data(
    #"{"id":"zone","name":"example.com","status":"active","plan":{"id":"p","name":"Free Website","legacy_id":"free"}}"#
      .utf8)
  let zone = try JSONDecoder().decode(CloudflareZone.self, from: data)
  #expect(zone.plan?.legacyId == "free")
  #expect(zone.plan?.name == "Free Website")
}

@Test func decodesNotificationPolicyWithMechanisms() throws {
  let data = Data(
    #"""
    {"id":"pol1","name":"Origin down","alert_type":"http_alert_origin_error",
     "enabled":true,"alert_interval":"30m","description":"Ping me",
     "filters":{"zones":["zone1"]},
     "mechanisms":{"webhooks":[{"id":"wh1"}],"email":[{"id":"a@b.c"}]}}
    """#.utf8)
  let policy = try JSONDecoder().decode(NotificationPolicy.self, from: data)
  #expect(policy.id == "pol1")
  #expect(policy.mechanisms?.webhooks?.first?.id == "wh1")
  #expect(policy.mechanisms?.email?.first?.id == "a@b.c")
  #expect(policy.filters?["zones"] == ["zone1"])
  #expect(policy.alertInterval == "30m")

  let input = policy.input(enabled: false)
  #expect(input.enabled == false)
  #expect(input.mechanisms?.webhooks?.first?.id == "wh1")
  #expect(input.filters?["zones"] == ["zone1"])
  #expect(input.alertType == "http_alert_origin_error")

  let encoded = try JSONEncoder().encode(input)
  let roundTrip = try JSONDecoder().decode(NotificationPolicyInput.self, from: encoded)
  #expect(roundTrip.name == "Origin down")
  #expect(roundTrip.enabled == false)
  #expect(roundTrip.mechanisms?.webhooks?.first?.id == "wh1")
  #expect(roundTrip.description == "Ping me")
}

@Test func workerAnalyticsBucketInitDefaultsCPUToZero() {
  let bucket = WorkerAnalyticsBucket(datetime: "2026-07-22T10:00:00Z", requests: 12, errors: 1)
  #expect(bucket.cpuTimeP50Us == 0)
}

@Suite(.serialized)
struct NetworkTests {
  @Test func flattensAvailableAlertsFromCategoryMap() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { _ in
      let body = #"""
        {"success":true,"result":{"Origin Monitoring":[
          {"type":"http_alert_origin_error","display_name":"Origin Error Rate Alert",
           "description":"5xx at origin"}
        ]}}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let alerts = try await client.listAvailableAlerts(accountID: "acct")
    #expect(alerts.count == 1)
    #expect(alerts.first?.type == "http_alert_origin_error")
    #expect(alerts.first?.displayName == "Origin Error Rate Alert")
  }

  @Test func treatsNullNotificationHistoryAsEmpty() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.url?.path == "/accounts/acct/alerting/v3/history")
      #expect(
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
          .queryItems?.first { $0.name == "per_page" }?.value == "10")
      return (200, Data(#"{"success":true,"result":null}"#.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let history = try await client.listNotificationHistory(accountID: "acct")

    #expect(history.isEmpty)
  }

  @Test func notificationHistoryPrefersAPIIdentifier() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { _ in
      let body = #"""
        {"success":true,"result":[{
          "id":"f174e90afafe4643bbbc4a0ed4fc8415",
          "policy_id":"pol-1",
          "name":"SSL",
          "alert_type":"universal_ssl_event_type",
          "alert_body":"expired",
          "sent":"2021-10-08T17:52:17.571336Z"
        }]}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let history = try await client.listNotificationHistory(accountID: "acct")
    #expect(history.count == 1)
    #expect(history.first?.historyID == "f174e90afafe4643bbbc4a0ed4fc8415")
    #expect(history.first?.id == "f174e90afafe4643bbbc4a0ed4fc8415")
  }

  @Test func registrarDomainsAcceptNameOrIDAsIdentity() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.url?.path == "/accounts/acct/registrar/domains")
      let body = #"""
        {"success":true,"result":[
          {"name":"live.example","expires_at":"2027-01-01T00:00:00Z"},
          {"id":"documented.example","expires_at":"2027-02-01T00:00:00Z"}
        ]}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let domains = try await client.listRegistrarDomains(accountID: "acct")

    #expect(domains.map(\.id) == ["live.example", "documented.example"])
    #expect(domains.map(\.name) == ["live.example", "documented.example"])
  }

  @Test func createZonePostsNameAndAccountAndDecodesNameServers() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.httpMethod == "POST")
      #expect(request.url?.path == "/zones")
      let stream = request.httpBodyStream.map { stream -> Data in
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
          let read = stream.read(buffer, maxLength: size)
          if read <= 0 { break }
          data.append(buffer, count: read)
        }
        return data
      }
      if let stream,
        let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: stream)
      {
        #expect(decoded["name"] == .string("new.example"))
        #expect(decoded["account"] == .object(["id": .string("acct")]))
      }
      let body = #"""
        {"success":true,"result":{"id":"z-new","name":"new.example","status":"pending",
        "name_servers":["ada.ns.cloudflare.com","bob.ns.cloudflare.com"]}}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let zone = try await client.createZone(name: "new.example", accountID: "acct")

    #expect(zone.id == "z-new")
    #expect(zone.status == "pending")
    #expect(zone.nameServers == ["ada.ns.cloudflare.com", "bob.ns.cloudflare.com"])
  }

  @Test func activationCheckPutsToActivationCheckPath() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.httpMethod == "PUT")
      #expect(request.url?.path == "/zones/z1/activation_check")
      return (200, Data(#"{"success":true,"result":{"id":"z1"}}"#.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    try await client.triggerZoneActivationCheck(zoneID: "z1")
  }

  @Test func activationCheckSurfacesRateLimitMessage() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { _ in
      let body = #"""
        {"success":false,"result":null,
        "errors":[{"code":1224,"message":"You may only perform this action once per hour"}]}
        """#
      return (400, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    do {
      try await client.triggerZoneActivationCheck(zoneID: "z1")
      Issue.record("activation check should throw on a failed envelope")
    } catch let error as CloudflareAPIError {
      guard case .request(let status, let errors) = error else {
        Issue.record("expected .request, got \(error)")
        return
      }
      #expect(status == 400)
      #expect(errors.first?.code == 1224)
    }
  }

  @Test func createZoneSurfacesEnvelopeFailureAsRequestError() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { _ in
      let body = #"""
        {"success":false,"result":null,
        "errors":[{"code":1061,"message":"taken.example already exists."}]}
        """#
      return (400, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    do {
      _ = try await client.createZone(name: "taken.example", accountID: "acct")
      Issue.record("createZone should throw on a failed envelope")
    } catch let error as CloudflareAPIError {
      guard case .request(let status, let errors) = error else {
        Issue.record("expected .request, got \(error)")
        return
      }
      #expect(status == 400)
      #expect(errors.first?.code == 1061)
    }
  }

  @Test func decodesCanonicalRegistrarRegistration() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.url?.path == "/accounts/acct/registrar/registrations/example.com")
      let body = #"""
        {"success":true,"result":{
          "domain_name":"example.com",
          "status":"active",
          "created_at":"2025-01-15T10:00:00Z",
          "expires_at":"2027-01-15T10:00:00Z",
          "auto_renew":true,
          "privacy_mode":"redaction",
          "locked":true
        }}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let registration = try await client.getRegistrarRegistration(
      accountID: "acct", domainName: "example.com")

    #expect(registration.id == "example.com")
    #expect(registration.status == "active")
    #expect(registration.createdAt == "2025-01-15T10:00:00Z")
    #expect(registration.expiresAt == "2027-01-15T10:00:00Z")
    #expect(registration.autoRenew)
    #expect(registration.privacyMode == "redaction")
    #expect(registration.locked)
  }

  @Test func decodesZoneAnalyticsGraphQL() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { _ in
      let body = #"""
        {"data":{"viewer":{"zones":[{"httpRequests1dGroups":[
        {"dimensions":{"date":"2026-07-06"},"sum":{"requests":120,"pageViews":40,"threats":2,"bytes":98304,"cachedRequests":90,"cachedBytes":65536},"uniq":{"uniques":33}}
        ]}]}},"errors":null}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let days = try await client.zoneAnalytics(zoneID: "zone")
    #expect(days.count == 1)
    #expect(days.first?.requests == 120)
    #expect(days.first?.bytes == 98304)
    #expect(days.first?.uniques == 33)
    #expect(days.first?.cachedRequests == 90)
    #expect(days.first?.cachedBytes == 65536)
  }

  @Test func webAnalyticsSitesMapToZonesThroughTheirRuleset() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { _ in
      let body = #"""
        {"result":[
        {"site_tag":"site-1","site_token":"token-1","auto_install":true,
         "ruleset":{"id":"rule-1","zone_tag":"zone-1","zone_name":"example.com","enabled":true}},
        {"site_tag":"site-2","auto_install":false,
         "ruleset":{"id":"rule-2","zone_tag":"zone-2","zone_name":"paused.example","enabled":false}},
        {"site_tag":"site-hostonly","auto_install":false,
         "rules":[{"host":"manual.example.net","inclusive":true,"is_paused":false}]}
        ],"success":true,"errors":[],"messages":[]}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let sites = try await client.webAnalyticsSites(accountID: "acct")

    #expect(sites.map(\.zoneTag) == ["zone-1", "zone-2", nil])
    #expect(sites.first?.isCollecting == true)
    // auto_install with a disabled ruleset means the beacon is not injected;
    // a manual-snippet site is assumed live because we cannot see its HTML.
    #expect(sites[1].isCollecting == true)
    #expect(sites.last?.analyticsName == "manual.example.net")
  }

  @Test func webAnalyticsSitesFollowServerPagination() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let recorder = RequestRecorder()
    let session = mockSession { request in
      let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
      let page =
        components?.queryItems?.first(where: { $0.name == "page" })?.value.flatMap(Int.init) ?? 1
      recorder.record(request.url?.absoluteString ?? "")
      let range = page == 1 ? 1...10 : 11...12
      let sites = range.map {
        #"{"site_tag":"site-\#($0)","auto_install":false}"#
      }.joined(separator: ",")
      let body = #"""
        {"result":[\#(sites)],"success":true,"errors":[],"messages":[],
         "result_info":{"page":\#(page),"per_page":10,"total_count":12}}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let sites = try await client.webAnalyticsSites(accountID: "acct")

    #expect(sites.count == 12)
    #expect(sites.first?.siteTag == "site-1")
    #expect(sites.last?.siteTag == "site-12")
    #expect(recorder.paths.count == 2)
    #expect(recorder.paths.last?.contains("page=2") == true)
  }

  @Test func webAnalyticsPageviewsDecodeDailyCounts() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let recorder = RequestRecorder()
    let session = mockSession { request in
      recorder.record(request.url?.absoluteString ?? "")
      let body = #"""
        {"data":{"viewer":{"accounts":[{"rumPageloadEventsAdaptiveGroups":[
        {"count":46,"dimensions":{"date":"2026-07-22"}},
        {"count":51,"dimensions":{"date":"2026-07-23"}}
        ]}]}},"errors":null}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let days = try await client.webAnalyticsPageviews(siteTag: "site-1", days: 7)

    #expect(days.map(\.pageviews) == [46, 51])
    #expect(days.first?.date == "2026-07-22")
    #expect(recorder.paths.first?.contains("/graphql") == true)
  }

  @Test func webAnalyticsMetricsJoinPageloadAndPerformanceByDate() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let recorder = RequestRecorder()
    let session = mockSession { request in
      recorder.record(request.url?.absoluteString ?? "")
      // The performance dataset is missing 2026-07-23 on purpose: a day with no
      // timing samples must join to a nil median, not drop the pageview row.
      let body = #"""
        {"data":{"viewer":{"accounts":[{
        "pageload":[
        {"count":46,"sum":{"visits":20},"dimensions":{"date":"2026-07-22"}},
        {"count":51,"sum":{"visits":25},"dimensions":{"date":"2026-07-23"}}
        ],
        "performance":[
        {"quantiles":{"pageLoadTimeP50":812.4},"dimensions":{"date":"2026-07-22"}}
        ]}]}},"errors":null}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let days = try await client.webAnalyticsMetrics(accountID: "acct", siteTag: "site-1", days: 7)

    #expect(days.map(\.pageviews) == [46, 51])
    #expect(days.map(\.visits) == [20, 25])
    #expect(days.first?.pageLoadTimeP50Ms == 812)  // 812.4 rounded to nearest ms
    #expect(days.last?.pageLoadTimeP50Ms == nil)  // no performance row for 07-23
    #expect(recorder.paths.first?.contains("/graphql") == true)
  }

  @Test func zoneAnalyticsToleratesMissingUniquesAndCacheFields() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { _ in
      // A response without the uniq / cached blocks must still decode — the
      // chart hides itself rather than the whole screen erroring.
      let body = #"""
        {"data":{"viewer":{"zones":[{"httpRequests1dGroups":[
        {"dimensions":{"date":"2026-07-06"},"sum":{"requests":120,"pageViews":40,"threats":2,"bytes":98304}}
        ]}]}},"errors":null}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let days = try await client.zoneAnalytics(zoneID: "zone")
    #expect(days.first?.uniques == 0)
    #expect(days.first?.cachedRequests == 0)
    #expect(days.first?.cachedBytes == 0)
  }
  @Test func decodesHourlyZoneAnalyticsAscending() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let recorder = RequestRecorder()
    let session = mockSession { request in
      recorder.record(request.url?.absoluteString ?? "")
      let body = #"""
        {"data":{"viewer":{"zones":[{"httpRequests1hGroups":[
        {"dimensions":{"datetime":"2026-07-14T08:00:00Z"},"sum":{"requests":10,"pageViews":4,"threats":1,"bytes":2048},"uniq":{"uniques":3}},
        {"dimensions":{"datetime":"2026-07-14T09:00:00Z"},"sum":{"requests":20,"pageViews":8,"threats":0,"bytes":4096},"uniq":{"uniques":7}}
        ]}]}},"errors":null}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let points = try await client.zoneAnalyticsHourly(zoneID: "zone", hours: 24)
    #expect(points.map(\.datetime) == ["2026-07-14T08:00:00Z", "2026-07-14T09:00:00Z"])
    #expect(points.first?.requests == 10)
    #expect(points.last?.bytes == 4096)
    #expect(points.map(\.uniques) == [3, 7])
    #expect(recorder.paths.first?.contains("/graphql") == true)
  }

  @Test func decodesFreePlanHourlyZoneRequests() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { _ in
      let body = #"""
        {"data":{"viewer":{"zones":[{"httpRequestsAdaptiveGroups":[
        {"count":10,"dimensions":{"datetimeHour":"2026-07-14T08:00:00Z"}},
        {"count":20,"dimensions":{"datetimeHour":"2026-07-14T09:00:00Z"}}
        ]}]}},"errors":null}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let points = try await client.zoneRequestsHourly(zoneID: "zone", hours: 24)

    #expect(points.map(\.requests) == [10, 20])
    #expect(points.allSatisfy { $0.pageViews == 0 })
  }

  @Test func surfacesHourlyAnalyticsGraphQLErrors() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { _ in
      (200, Data(#"{"data":null,"errors":[{"message":"zones [zone] are not authorized"}]}"#.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    do {
      _ = try await client.zoneAnalyticsHourly(zoneID: "zone")
      Issue.record("Expected a GraphQL authorization error")
    } catch let error as CloudflareAPIError {
      #expect(error.isForbidden)
    }
  }

  @Test func accountAnalyticsMapsOverviewSeriesAndWorkerP90() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { _ in
      let body = #"""
        {"data":{"viewer":{"accounts":[{
        "overview":[{
          "sum":{"requests":3431,"bytes":10276045},
          "ratio":{"cachedRequests":0.412,"encryptedRequests":0.981,"encryptedBytes":0.973,"status4xx":0.5511}
        }],
        "httpSeries":[
          {"sum":{"requests":100,"bytes":1000},"ratio":{"cachedRequests":0.4,"encryptedRequests":0.9,"encryptedBytes":0.8,"status4xx":0.1},"dimensions":{"datetimeHour":"2026-07-22T10:00:00Z"}},
          {"sum":{"requests":200,"bytes":2000},"ratio":{"cachedRequests":0.5,"encryptedRequests":0.95,"encryptedBytes":0.9,"status4xx":0.05},"dimensions":{"datetimeHour":"2026-07-22T11:00:00Z"}}
        ],
        "workers":[{
          "sum":{"requests":1280,"errors":17},
          "quantiles":{"cpuTimeP90":1840.0}
        }],
        "workerSeries":[
          {"sum":{"requests":40,"errors":1},"quantiles":{"cpuTimeP90":1200.0},"dimensions":{"datetimeHour":"2026-07-22T10:00:00Z"}},
          {"sum":{"requests":60,"errors":2},"quantiles":{"cpuTimeP90":1600.0},"dimensions":{"datetimeHour":"2026-07-22T11:00:00Z"}}
        ]
        }]}},"errors":null}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let snapshot = try await client.accountAnalytics(accountID: "acct", hours: 24)
    let overview = snapshot.overview

    #expect(overview.webRequests == 3431)
    #expect(overview.bytes == 10_276_045)
    #expect(abs(overview.cacheRate - 0.412) < 0.0001)
    #expect(abs(overview.clientErrorRate - 0.5511) < 0.0001)
    #expect(abs(overview.encryptedRequestRate - 0.981) < 0.0001)
    #expect(overview.encryptedBytes == Int64((10_276_045.0 * 0.973).rounded()))
    #expect(overview.workerInvocations == 1280)
    #expect(overview.workerErrors == 17)
    #expect(abs(overview.cpuTimeP90Us - 1840) < 0.0001)
    #expect(overview.hours == 24)
    #expect(snapshot.httpPoints.map(\.requests) == [100, 200])
    #expect(snapshot.httpPoints.map(\.cacheRate) == [0.4, 0.5])
    #expect(snapshot.httpPoints.first?.encryptedBytes == 800)
    #expect(snapshot.workerPoints.map(\.errors) == [1, 2])
    #expect(snapshot.workerPoints.map(\.cpuTimeP90Us) == [1200, 1600])
  }

  @Test func accountAnalyticsSurfacesGraphQLAuthorizationErrors() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { _ in
      (200, Data(#"{"data":null,"errors":[{"message":"authz error: not authorized"}]}"#.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    do {
      _ = try await client.accountAnalytics(accountID: "acct")
      Issue.record("Expected a GraphQL authorization error")
    } catch let error as CloudflareAPIError {
      #expect(error.isForbidden)
    }
  }

  @Test func workerAnalyticsWeightsBucketCPUByRowRequests() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { _ in
      let body = #"""
        {"data":{"viewer":{"accounts":[{"workersInvocationsAdaptive":[
        {"sum":{"requests":90,"errors":0},"quantiles":{"cpuTimeP50":800.0},"dimensions":{"datetimeFiveMinutes":"2026-07-22T10:00:00Z","status":"success"}},
        {"sum":{"requests":10,"errors":10},"quantiles":{"cpuTimeP50":2000.0},"dimensions":{"datetimeFiveMinutes":"2026-07-22T10:00:00Z","status":"error"}},
        {"sum":{"requests":50,"errors":0},"quantiles":{"cpuTimeP50":600.0},"dimensions":{"datetimeFiveMinutes":"2026-07-22T10:05:00Z","status":"success"}}
        ]}]}},"errors":null}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let payload = try await client.workerAnalytics(accountID: "acct", scriptName: "worker")

    #expect(payload.points.map(\.datetime) == ["2026-07-22T10:00:00Z", "2026-07-22T10:05:00Z"])
    let first = try #require(payload.points.first)
    #expect(first.requests == 100)
    #expect(first.errors == 10)
    // Request-weighted: (800*90 + 2000*10) / 100 = 920.
    #expect(abs(first.cpuTimeP50Us - 920) < 0.0001)
    let last = try #require(payload.points.last)
    #expect(abs(last.cpuTimeP50Us - 600) < 0.0001)
    // Payload-level CPU keeps the plain mean of all samples.
    #expect(abs(payload.cpuTimeP50Us - (800.0 + 2000.0 + 600.0) / 3) < 0.0001)
    #expect(payload.requests == 150)
    #expect(payload.errors == 10)
  }

  @Test func workerAnalyticsBucketCPUSurvivesMissingQuantilesAndZeroWeight() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { _ in
      let body = #"""
        {"data":{"viewer":{"accounts":[{"workersInvocationsAdaptive":[
        {"sum":{"requests":0,"errors":0},"quantiles":{"cpuTimeP50":750.0},"dimensions":{"datetimeFiveMinutes":"2026-07-22T10:00:00Z","status":"success"}},
        {"sum":{"requests":40,"errors":0},"quantiles":null,"dimensions":{"datetimeFiveMinutes":"2026-07-22T10:00:00Z","status":"success"}},
        {"sum":{"requests":25,"errors":0},"quantiles":null,"dimensions":{"datetimeFiveMinutes":"2026-07-22T10:05:00Z","status":"success"}}
        ]}]}},"errors":null}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let payload = try await client.workerAnalytics(accountID: "acct", scriptName: "worker")

    let first = try #require(payload.points.first)
    // All sampled weight is 0, so the bucket falls back to the plain mean of
    // present samples; the nil-quantiles row contributes nothing.
    #expect(abs(first.cpuTimeP50Us - 750) < 0.0001)
    #expect(first.requests == 40)
    let last = try #require(payload.points.last)
    // No CPU samples at all in this bucket.
    #expect(last.cpuTimeP50Us == 0)
  }

  @Test func refreshesExpiredTokenFromGraphQLUnauthorizedEnvelope() async throws {
    let recorder = RequestRecorder()
    let store = MemoryTokenStore(access: "old", refresh: "refresh")
    let session = mockSession { request in
      if request.url?.path == "/token" {
        recorder.recordRefresh()
        return (200, Data(#"{"access_token":"new","refresh_token":"refresh"}"#.utf8))
      }
      if request.value(forHTTPHeaderField: "Authorization") == "Bearer new" {
        let body = #"""
          {"data":{"viewer":{"zones":[{"httpRequests1hGroups":[
          {"dimensions":{"datetime":"2026-07-14T08:00:00Z"},"sum":{"requests":10,"pageViews":4,"threats":1,"bytes":2048}}
          ]}]}},"errors":null}
          """#
        return (200, Data(body.utf8))
      }
      return (200, Data(#"{"data":null,"errors":[{"message":"Unauthorized"}]}"#.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session, tokenURL: URL(string: "https://auth.example.test/token")!)

    let points = try await client.zoneAnalyticsHourly(zoneID: "zone")

    #expect(points.first?.pageViews == 4)
    #expect(recorder.refreshCount == 1)
  }

  @Test func genericResourceExtractsQueueAndRouteIdentity() throws {
    let decoder = JSONDecoder()
    let queue = try decoder.decode(
      GenericResource.self,
      from: Data(#"{"queue_id":"q1","queue_name":"jobs","producers":[]}"#.utf8))
    #expect(queue.id == "q1")
    #expect(queue.name == "jobs")

    let route = try decoder.decode(
      GenericResource.self,
      from: Data(#"{"id":"r1","pattern":"example.com/*","script":"worker"}"#.utf8))
    #expect(route.id == "r1")
    #expect(route.name == "example.com/*")
  }

  @Test func decodesImagesListEnvelope() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { _ in
      let body =
        #"{"success":true,"result":{"images":[{"id":"img","filename":"hero.png","requireSignedURLs":false}]}}"#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let images = try await client.listImages(accountID: "account")
    #expect(images.first?.filename == "hero.png")
  }

  @Test func decodesR2ResponseWrappers() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { _ in
      let body =
        #"{"success":true,"result":{"buckets":[{"name":"assets","creation_date":"2026-07-06"}]}}"#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let buckets = try await client.listR2Buckets(accountID: "account")
    #expect(buckets.map(\.name) == ["assets"])
  }

  @Test func listsR2ObjectsAndVirtualFolders() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      let query = Dictionary(
        uniqueKeysWithValues:
          URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map {
            ($0.name, $0.value ?? "")
          })
      #expect(query["prefix"] == "photos/")
      #expect(query["delimiter"] == "/")
      #expect(query["per_page"] == "100")
      let body = #"""
        {"success":true,"result":[
          {"key":"photos/cover.jpg","size":1048576,"etag":"abc123",
           "last_modified":"2026-07-15T08:00:00Z","storage_class":"Standard"}
        ],"result_info":{
          "cursor":"next-page","delimited":["photos/2025/","photos/raw/"],
          "is_truncated":true,"per_page":100
        }}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let page = try await client.listR2Objects(
      accountID: "account", bucket: "assets", prefix: "photos/", delimiter: "/")

    #expect(page.objects.map(\.key) == ["photos/cover.jpg"])
    #expect(page.objects.first?.size == 1_048_576)
    #expect(page.objects.first?.etag == "abc123")
    #expect(page.objects.first?.uploaded == "2026-07-15T08:00:00Z")
    #expect(page.commonPrefixes == ["photos/2025/", "photos/raw/"])
    #expect(page.cursor == "next-page")
    #expect(page.isTruncated)
  }

  @Test func paginatesR2ObjectsWithCursor() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      let query = Dictionary(
        uniqueKeysWithValues:
          URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map {
            ($0.name, $0.value ?? "")
          })
      #expect(query["prefix"] == "logs/")
      #expect(query["delimiter"] == "/")
      if let cursor = query["cursor"] {
        #expect(cursor == "opaque-cursor")
        let body = #"""
          {"success":true,"result":[
            {"key":"logs/latest.txt","size":12,"etag":"second",
             "last_modified":"2026-07-15T09:00:00Z"}
          ],"result_info":{"is_truncated":false,"per_page":100}}
          """#
        return (200, Data(body.utf8))
      }
      let body = #"""
        {"success":true,"result":[],
         "result_info":{"cursor":"opaque-cursor","delimited":["logs/2025/"],
                        "is_truncated":true,"per_page":100}}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let first = try await client.listR2Objects(
      accountID: "account", bucket: "archive", prefix: "logs/", delimiter: "/")
    let second = try await client.listR2Objects(
      accountID: "account", bucket: "archive", cursor: first.cursor, prefix: "logs/",
      delimiter: "/")

    #expect(first.commonPrefixes == ["logs/2025/"])
    #expect(first.cursor == "opaque-cursor")
    #expect(second.objects.map(\.key) == ["logs/latest.txt"])
    #expect(second.cursor == nil)
    #expect(!second.isTruncated)
  }

  @Test func returnsRawR2ObjectBody() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let payload = Data([0x50, 0x4B, 0x03, 0x04, 0x00])
    let session = mockSession { request in
      #expect(request.url?.path.hasSuffix("/r2/buckets/assets/objects/archive.zip") == true)
      return (200, payload)
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let data = try await client.getR2Object(
      accountID: "account", bucket: "assets", key: "archive.zip")
    #expect(data == payload)
  }

  @Test func uploadsR2ObjectFromFile() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let payload = Data("file-backed upload".utf8)
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "cloudflare-api-upload-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appending(path: "object.txt")
    try payload.write(to: source)

    let session = mockSession { request in
      #expect(request.httpMethod == "PUT")
      #expect(request.url?.path.hasSuffix("/r2/buckets/assets/objects/folder/object.txt") == true)
      #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
      #expect(request.value(forHTTPHeaderField: "Content-Type") == "text/plain")
      #expect(requestBodyData(request) == payload)
      return (200, Data())
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    try await client.putR2Object(
      accountID: "account", bucket: "assets", key: "folder/object.txt", fileURL: source,
      contentType: "text/plain")
  }

  @Test func downloadsR2ObjectDirectlyToFile() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let payload = Data([0x50, 0x4B, 0x03, 0x04, 0x00])
    let session = mockSession { request in
      #expect(request.httpMethod == "GET")
      #expect(request.url?.path.hasSuffix("/r2/buckets/assets/objects/archive.zip") == true)
      return (200, payload)
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "cloudflare-api-download-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appending(path: "archive.zip")

    let downloaded = try await client.downloadR2Object(
      accountID: "account", bucket: "assets", key: "archive.zip", to: destination,
      maximumBytes: 1024)

    #expect(downloaded == destination)
    #expect(try Data(contentsOf: destination) == payload)
  }

  @Test func fileBackedR2DownloadUsesTheInjectedSessionDelegate() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let metrics = SessionMetricsRecorder()
    let session = mockSession(delegate: metrics) { _ in
      (200, Data("same session".utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "cloudflare-api-download-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }

    _ = try await client.downloadR2Object(
      accountID: "account", bucket: "assets", key: "delegate.txt",
      to: directory.appending(path: "delegate.txt"), maximumBytes: 1024)
    for _ in 0..<50 {
      if metrics.count > 0 { break }
      try await Task.sleep(for: .milliseconds(10))
    }

    #expect(metrics.count == 1)
  }

  @Test func rejectsUnknownLengthOversizedFileBackedR2DownloadAndCleansDestination() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let payload = Data(repeating: 0xAB, count: 16)
    let session = mockSession { _ in (200, payload) }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "cloudflare-api-download-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appending(path: "large.bin")

    do {
      _ = try await client.downloadR2Object(
        accountID: "account", bucket: "assets", key: "large.bin", to: destination,
        maximumBytes: 8)
      Issue.record("expected the transfer limit to reject the file")
    } catch let error as CloudflareTransferError {
      guard case .exceedsLimit(let limit, let actual) = error else {
        Issue.record("expected an exceeds-limit error")
        return
      }
      #expect(limit == 8)
      // MockURLProtocol delivers this response as one unknown-length chunk.
      #expect(actual == Int64(payload.count))
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    let leftovers =
      (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)) ?? []
    #expect(leftovers.isEmpty)
  }

  @Test func cancelsUnknownLengthR2DownloadBeforeTheWholeBodyArrives() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let payload = Data(repeating: 0xCD, count: 2 * 1024 * 1024)
    let delivered = ByteRecorder()
    MockURLProtocol.chunkSize = 64 * 1024
    MockURLProtocol.chunkDelay = 0.01
    MockURLProtocol.onChunk = { delivered.record($0) }
    defer {
      MockURLProtocol.chunkSize = nil
      MockURLProtocol.chunkDelay = 0
      MockURLProtocol.onChunk = nil
    }
    let session = mockSession { _ in (200, payload) }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "cloudflare-api-download-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appending(path: "large.bin")

    do {
      _ = try await client.downloadR2Object(
        accountID: "account", bucket: "assets", key: "large.bin", to: destination,
        maximumBytes: 100 * 1024)
      Issue.record("expected the transfer limit to cancel the download")
    } catch let error as CloudflareTransferError {
      guard case .exceedsLimit(let limit, let actual) = error else {
        Issue.record("expected an exceeds-limit error")
        return
      }
      #expect(limit == 100 * 1024)
      #expect((actual ?? 0) > limit)
    }

    #expect(delivered.bytes < payload.count)
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    let leftovers =
      (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)) ?? []
    #expect(leftovers.isEmpty)
  }

  @Test func cancellingFileBackedR2DownloadRemovesPartialFile() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let payload = Data(repeating: 0xAC, count: 2 * 1024 * 1024)
    let delivered = ByteRecorder()
    MockURLProtocol.chunkSize = 64 * 1024
    MockURLProtocol.chunkDelay = 0.01
    MockURLProtocol.onChunk = { delivered.record($0) }
    defer {
      MockURLProtocol.chunkSize = nil
      MockURLProtocol.chunkDelay = 0
      MockURLProtocol.onChunk = nil
    }
    let session = mockSession { _ in (200, payload) }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "cloudflare-api-download-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appending(path: "cancelled.bin")

    let download = Task {
      try await client.downloadR2Object(
        accountID: "account", bucket: "assets", key: "cancelled.bin", to: destination)
    }
    try await Task.sleep(for: .milliseconds(30))
    download.cancel()
    do {
      _ = try await download.value
      Issue.record("expected cancellation")
    } catch is CancellationError {
      // Expected.
    } catch {
      Issue.record("expected CancellationError, got \(error)")
    }

    #expect(delivered.bytes < payload.count)
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    let leftovers =
      (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)) ?? []
    #expect(leftovers.isEmpty)
  }

  @Test func fileBackedR2DownloadRetriesAfterRefreshingUnauthorizedToken() async throws {
    let store = MemoryTokenStore(access: "old", refresh: "refresh")
    let recorder = RequestRecorder()
    let payload = Data("refreshed download".utf8)
    let session = mockSession { request in
      recorder.record(request.url?.path ?? "")
      if request.url?.path == "/token" {
        return (200, Data(#"{"access_token":"new","refresh_token":"refresh"}"#.utf8))
      }
      if request.value(forHTTPHeaderField: "Authorization") == "Bearer new" {
        return (200, payload)
      }
      return (401, Data(#"{"success":false,"errors":[{"code":1000,"message":"expired"}]}"#.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session, tokenURL: URL(string: "https://auth.example.test/token")!)
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "cloudflare-api-download-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appending(path: "object.txt")

    try await client.downloadR2Object(
      accountID: "account", bucket: "assets", key: "object.txt", to: destination,
      maximumBytes: 1024)

    #expect(try Data(contentsOf: destination) == payload)
    #expect(
      recorder.paths == [
        "/accounts/account/r2/buckets/assets/objects/object.txt",
        "/token",
        "/accounts/account/r2/buckets/assets/objects/object.txt",
      ])
  }

  @Test func fileBackedR2DownloadRetriesAfterRateLimit() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let recorder = RequestRecorder()
    let payload = Data("retried download".utf8)
    MockURLProtocol.responseHeaders = ["Retry-After": "0"]
    defer { MockURLProtocol.responseHeaders = nil }
    let session = mockSession { request in
      recorder.record(request.url?.path ?? "")
      if recorder.paths.count == 1 {
        return (
          429, Data(#"{"success":false,"errors":[{"code":971,"message":"rate limited"}]}"#.utf8)
        )
      }
      return (200, payload)
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "cloudflare-api-download-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appending(path: "object.txt")

    try await client.downloadR2Object(
      accountID: "account", bucket: "assets", key: "object.txt", to: destination,
      maximumBytes: 1024)

    #expect(try Data(contentsOf: destination) == payload)
    #expect(recorder.paths.count == 2)
  }

  @Test func fileBackedR2DownloadBoundsErrorBodyAndPreservesHTTPStatus() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let payload = Data(repeating: 0xEE, count: 2 * 1024 * 1024)
    let delivered = ByteRecorder()
    MockURLProtocol.chunkSize = 64 * 1024
    MockURLProtocol.chunkDelay = 0.01
    MockURLProtocol.onChunk = { delivered.record($0) }
    defer {
      MockURLProtocol.chunkSize = nil
      MockURLProtocol.chunkDelay = 0
      MockURLProtocol.onChunk = nil
    }
    let session = mockSession { _ in (503, payload) }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "cloudflare-api-download-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }

    do {
      _ = try await client.downloadR2Object(
        accountID: "account", bucket: "assets", key: "failure.bin",
        to: directory.appending(path: "failure.bin"), maximumBytes: 8)
      Issue.record("expected the HTTP error to be preserved")
    } catch let error as CloudflareAPIError {
      guard case .request(let status, _) = error else {
        Issue.record("expected a request error")
        return
      }
      #expect(status == 503)
    }

    #expect(delivered.bytes < payload.count)
  }

  @Test func fileBackedR2DownloadPreservesExistingDestinationAndCocoaError() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let recorder = RequestRecorder()
    let session = mockSession { request in
      recorder.record(request.url?.path ?? "")
      return (200, Data("replacement".utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "cloudflare-api-download-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appending(path: "object.txt")
    let original = Data("keep me".utf8)
    try original.write(to: destination)

    do {
      _ = try await client.downloadR2Object(
        accountID: "account", bucket: "assets", key: "object.txt", to: destination,
        maximumBytes: 1024)
      Issue.record("expected an existing-destination Cocoa error")
    } catch is CocoaError {
      // Expected: local filesystem failures must not be presented as transport errors.
    } catch {
      Issue.record("expected CocoaError, got \(error)")
    }

    #expect(try Data(contentsOf: destination) == original)
    #expect(recorder.paths.isEmpty)
  }

  @Test func decodesR2ObjectHTTPMetadataContentType() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { _ in
      let body = #"""
        {"success":true,"result":[
          {"key":"cover.jpg","size":9,"etag":"e","last_modified":"2026-07-15T08:00:00Z",
           "http_metadata":{"contentType":"image/jpeg","cacheControl":"max-age=3600"}},
          {"key":"notes.txt","size":3,"etag":"f","last_modified":"2026-07-15T08:00:00Z"}
        ],"result_info":{"is_truncated":false,"per_page":100}}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let page = try await client.listR2Objects(accountID: "account", bucket: "assets")

    #expect(page.objects.first?.contentType == "image/jpeg")
    #expect(page.objects.last?.contentType == nil)
  }

  @Test func managedR2DomainRoundTripsEnabledFlag() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.url?.path.hasSuffix("/r2/buckets/assets/domains/managed") == true)
      if request.httpMethod == "PUT" {
        let body =
          #"{"success":true,"result":{"bucketId":"b1","domain":"pub-b1.r2.dev","enabled":true}}"#
        return (200, Data(body.utf8))
      }
      let body =
        #"{"success":true,"result":{"bucketId":"b1","domain":"pub-b1.r2.dev","enabled":false}}"#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let current = try await client.getR2ManagedDomain(accountID: "account", bucket: "assets")
    let updated = try await client.setR2ManagedDomain(
      accountID: "account", bucket: "assets", enabled: true)

    #expect(current.domain == "pub-b1.r2.dev")
    #expect(!current.enabled)
    #expect(updated.enabled)
  }

  @Test func listsR2CustomDomainsWithOptionalStatusFields() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.url?.path.hasSuffix("/r2/buckets/assets/domains/custom") == true)
      let body = #"""
        {"success":true,"result":{"domains":[
          {"domain":"img.example.com","enabled":true,
           "status":{"ownership":"active","ssl":"active"},
           "minTLS":"1.2","zoneId":"z1","zoneName":"example.com"},
          {"domain":"cdn.example.net","enabled":false,
           "status":{"ownership":"pending","ssl":"initializing"}}
        ]}}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let domains = try await client.listR2CustomDomains(accountID: "account", bucket: "assets")

    #expect(domains.map(\.domain) == ["img.example.com", "cdn.example.net"])
    #expect(domains.first?.status?.ssl == "active")
    #expect(domains.first?.zoneName == "example.com")
    #expect(domains.last?.zoneName == nil)
    #expect(domains.last?.minTLS == nil)
  }

  @Test func addR2CustomDomainPostsZoneAndDecodesStatuslessResponse() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.httpMethod == "POST")
      #expect(request.url?.path.hasSuffix("/r2/buckets/assets/domains/custom") == true)
      let stream = request.httpBodyStream.map { stream -> Data in
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
          let read = stream.read(buffer, maxLength: size)
          if read <= 0 { break }
          data.append(buffer, count: read)
        }
        return data
      }
      if let stream,
        let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: stream)
      {
        #expect(decoded["domain"] == .string("img.example.com"))
        #expect(decoded["zoneId"] == .string("z1"))
        #expect(decoded["enabled"] == .bool(true))
      }
      // The create response carries no `status` — provisioning starts async.
      let body =
        #"{"success":true,"result":{"domain":"img.example.com","enabled":true,"zoneId":"z1"}}"#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let added = try await client.addR2CustomDomain(
      accountID: "account", bucket: "assets", domain: "img.example.com", zoneID: "z1")

    #expect(added.domain == "img.example.com")
    #expect(added.status == nil)
  }

  @Test func deleteR2CustomDomainTargetsDomainPath() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.httpMethod == "DELETE")
      #expect(
        request.url?.path.hasSuffix("/r2/buckets/assets/domains/custom/img.example.com") == true)
      return (200, Data(#"{"success":true,"result":{"domain":"img.example.com"}}"#.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    try await client.deleteR2CustomDomain(
      accountID: "account", bucket: "assets", domain: "img.example.com")
  }

  @Test func decodesRulesetListAndDetail() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      if request.url?.path == "/accounts/account/rulesets" {
        let body = #"""
          {"success":true,"result":[
          {"id":"rs1","name":"Custom rules","kind":"custom","phase":"http_request_firewall_custom"},
          {"id":"rs2","name":"Managed","kind":"managed","phase":"http_request_firewall_managed"}
          ]}
          """#
        return (200, Data(body.utf8))
      }
      let body = #"""
        {"success":true,"result":{"id":"rs1","name":"Custom rules","kind":"custom",
        "phase":"http_request_firewall_custom","rules":[
        {"id":"r1","action":"block","expression":"ip.src eq 1.2.3.4","enabled":true}
        ]}}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let rulesets = try await client.listRulesets(basePath: "/accounts/account")
    #expect(rulesets.map(\.kind) == ["custom", "managed"])
    let detail = try await client.getRuleset(basePath: "/accounts/account", id: "rs1")
    #expect(detail.rules?.first?.action == "block")
    #expect(detail.rules?.first?.enabled == true)
  }

  @Test func patchRulesetRuleTargetsRulePathWithBody() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.httpMethod == "PATCH")
      #expect(request.url?.path == "/zones/zone/rulesets/rs1/rules/r1")
      let stream = request.httpBodyStream.map { stream -> Data in
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
          let read = stream.read(buffer, maxLength: size)
          if read <= 0 { break }
          data.append(buffer, count: read)
        }
        return data
      }
      if let stream,
        let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: stream)
      {
        #expect(decoded["enabled"] == .bool(false))
      }
      let body = #"""
        {"success":true,"result":{"id":"rs1","name":"Custom rules","kind":"zone",
        "phase":"http_request_firewall_custom","rules":[
        {"id":"r1","action":"block","expression":"ip.src eq 1.2.3.4","enabled":false}
        ]}}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let detail = try await client.patchRulesetRule(
      basePath: "/zones/zone", rulesetID: "rs1", ruleID: "r1",
      body: ["enabled": .bool(false)])
    #expect(detail.rules?.first?.enabled == false)
  }

  @Test func createAccessPolicyTargetsReusableOrAppPath() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let recorder = RequestRecorder()
    let session = mockSession { request in
      recorder.record(request.url?.path ?? "")
      let body = #"""
        {"success":true,"result":{"id":"p1","name":"Allow team","decision":"allow",
        "include":[{"email_domain":{"domain":"xat.sh"}}]}}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let body: [String: JSONValue] = [
      "name": .string("Allow team"),
      "decision": .string("allow"),
      "include": .array([.object(["email_domain": .object(["domain": .string("xat.sh")])])]),
    ]
    let reusable = try await client.createAccessPolicy(accountID: "account", body: body)
    #expect(reusable.decision == "allow")
    _ = try await client.createAccessPolicy(accountID: "account", appID: "app1", body: body)
    #expect(
      recorder.paths == [
        "/accounts/account/access/policies",
        "/accounts/account/access/apps/app1/policies",
      ])
  }

  @Test func multipartFormEncodesGoldenBytes() {
    var form = MultipartForm(boundary: "b0")
    form.addField(name: "requireSignedURLs", value: "true")
    form.addFile(
      name: "file", filename: "photo.jpg", contentType: "image/jpeg",
      data: Data("JPEGDATA".utf8))
    let expected =
      "--b0\r\n"
      + "Content-Disposition: form-data; name=\"requireSignedURLs\"\r\n"
      + "\r\ntrue\r\n"
      + "--b0\r\n"
      + "Content-Disposition: form-data; name=\"file\"; filename=\"photo.jpg\"\r\n"
      + "Content-Type: image/jpeg\r\n"
      + "\r\nJPEGDATA\r\n"
      + "--b0--\r\n"
    #expect(form.contentType == "multipart/form-data; boundary=b0")
    #expect(form.encode() == Data(expected.utf8))
  }

  @Test func multipartDocumentParsesModuleDownload() {
    let body =
      "--sep\r\n"
      + "Content-Disposition: form-data; name=\"worker.js\"; filename=\"worker.js\"\r\n"
      + "Content-Type: application/javascript+module\r\n"
      + "\r\nexport default { fetch() {} }\r\n"
      + "--sep\r\n"
      + "Content-Disposition: form-data; name=\"lib.js\"; filename=\"lib.js\"\r\n"
      + "Content-Type: application/javascript+module\r\n"
      + "\r\nexport const x = 1\r\n"
      + "--sep--\r\n"
    let parts = MultipartDocument.parse(
      data: Data(body.utf8), contentType: "multipart/form-data; boundary=sep")
    #expect(parts.count == 2)
    #expect(parts.first?.filename == "worker.js")
    #expect(parts.first?.contentType == "application/javascript+module")
    #expect(
      String(decoding: parts.first?.body ?? Data(), as: UTF8.self)
        == "export default { fetch() {} }")
  }

  @Test func workerSourceBranchesOnResponseContentType() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.url?.path.hasSuffix("/workers/scripts/api/content/v2") == true)
      let body =
        "--sep\r\n"
        + "Content-Disposition: form-data; name=\"index.mjs\"; filename=\"index.mjs\"\r\n"
        + "Content-Type: application/javascript+module\r\n"
        + "\r\nexport default {}\r\n"
        + "--sep--\r\n"
      return (200, Data(body.utf8))
    }
    MockURLProtocol.responseHeaders = [
      "Content-Type": "multipart/form-data; boundary=sep"
    ]
    defer { MockURLProtocol.responseHeaders = nil }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let source = try await client.getWorkerSource(accountID: "account", name: "api")
    #expect(source.mainModule == "index.mjs")
    #expect(source.moduleCount == 1)
    #expect(source.content == "export default {}")
  }

  @Test func classicWorkerSourceDecodesAsPlainScript() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { _ in
      (200, Data("addEventListener('fetch', () => {})".utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let source = try await client.getWorkerSource(accountID: "account", name: "legacy")
    #expect(source.mainModule == nil)
    #expect(source.moduleCount == 0)
    #expect(source.content.hasPrefix("addEventListener"))
  }

  @Test func uploadWorkerScriptSendsMetadataAndModulePart() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.httpMethod == "PUT")
      #expect(request.url?.path.hasSuffix("/workers/scripts/api/content") == true)
      let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? ""
      #expect(contentType.hasPrefix("multipart/form-data; boundary="))
      return (200, Data(#"{"success":true,"result":{"id":"api"}}"#.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let source = WorkerSource(content: "old", mainModule: "index.mjs", moduleCount: 1)
    _ = try await client.uploadWorkerScript(
      accountID: "account", name: "api", source: source, content: "export default {}")
  }

  @Test func inviteAccountMemberSendsEmailAndRoleIDs() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.httpMethod == "POST")
      #expect(request.url?.path == "/accounts/account/members")
      let body = #"""
        {"success":true,"result":{"id":"m1","status":"pending",
        "user":{"email":"new@xat.sh"},"roles":[{"id":"r1","name":"Administrator Read Only"}]}}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let member = try await client.inviteAccountMember(
      accountID: "account", email: "new@xat.sh", roleIDs: ["r1"])
    #expect(member.id == "m1")
    #expect(member.roles?.first?.id == "r1")
  }

  @Test func mediaUploadsSendMultipartFilePart() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let recorder = RequestRecorder()
    let session = mockSession { request in
      recorder.record(request.url?.path ?? "")
      let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? ""
      #expect(contentType.hasPrefix("multipart/form-data; boundary="))
      if request.url?.path.hasSuffix("/images/v1") == true {
        return (200, Data(#"{"success":true,"result":{"id":"img1","filename":"a.jpg"}}"#.utf8))
      }
      return (200, Data(#"{"success":true,"result":{"uid":"vid1"}}"#.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let image = try await client.uploadImage(
      accountID: "account", filename: "a.jpg", data: Data("img".utf8))
    #expect(image.id == "img1")
    let video = try await client.uploadStreamVideo(
      accountID: "account", filename: "a.mp4", data: Data("vid".utf8))
    #expect(video.uid == "vid1")
    #expect(
      recorder.paths == ["/accounts/account/images/v1", "/accounts/account/stream"])
  }

  @Test func streamCopySendsURLAndOptionalName() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.url?.path.hasSuffix("/stream/copy") == true)
      return (200, Data(#"{"success":true,"result":{"uid":"vid2"}}"#.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let video = try await client.streamCopy(
      accountID: "account", url: "https://example.com/a.mp4", name: "A")
    #expect(video.uid == "vid2")
  }

  @Test func executeRawPassesBinaryBodiesThroughUntouched() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let payload = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])
    let session = mockSession { request in
      #expect(request.url?.path.hasSuffix("/browser-rendering/screenshot") == true)
      #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
      return (200, payload)
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let body = try JSONEncoder().encode(JSONValue.object(["url": .string("https://example.com")]))
    let data = try await client.executeRaw(
      path: "/accounts/account/browser-rendering/screenshot",
      method: "POST", data: body, contentType: "application/json")
    #expect(data == payload)
  }

  @Test func workerTagMatchesExactScriptName() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.url?.path == "/accounts/account/workers/scripts")
      let body = #"""
        {"success":true,"result":[
        {"id":"api-staging","tag":"e8f70fdbc8b1fb0b8ddb1af166186758"},
        {"id":"api","tag":"57eb1c68b8504f0baa4b5cc56cbc7d0f"}
        ]}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let tag = try await client.workerTag(accountID: "account", name: "api")
    #expect(tag == "57eb1c68b8504f0baa4b5cc56cbc7d0f")
  }

  @Test func genericResourceExtractsBuildIdentity() throws {
    let build = try JSONDecoder().decode(
      GenericResource.self,
      from: Data(
        #"{"build_uuid":"b-1","status":"stopped","branch":"main","created_at":"2026-07-09"}"#.utf8))
    #expect(build.id == "b-1")
    #expect(build.name == "main")
    #expect(build.detail == "stopped")
  }

  @Test func listResourcesUnwrapsWorkerDeployments() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { _ in
      let body = #"""
        {"success":true,"result":{"deployments":[
        {"id":"dep-1","created_on":"2026-07-09T00:00:00Z","source":"api"}
        ]}}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let page = try await client.listResources(
      path: "/accounts/account/workers/scripts/api/deployments")
    #expect(page.items.map(\.id) == ["dep-1"])
  }

  @Test func listWorkerDeploymentsDecodesOperationalFields() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(
        request.url?.path
          == "/accounts/account/workers/scripts/api/deployments")
      let body = #"""
        {"success":true,"result":{"deployments":[{
          "id":"182bd5e5-6e1a-4fe4-a799-aa6d9a6ab26e",
          "created_on":"2026-07-16T03:04:05.678Z",
          "source":"api",
          "strategy":"percentage",
          "versions":[{"version_id":"version-1","percentage":100}],
          "annotations":{"workers/message":"Fix cache key","workers/triggered_by":"upload"},
          "author_email":"dev@example.com"
        }]}}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let deployments = try await client.listWorkerDeployments(
      accountID: "account", scriptName: "api")

    #expect(deployments.count == 1)
    #expect(deployments[0].source == "api")
    #expect(deployments[0].versions.first?.percentage == 100)
    #expect(deployments[0].versions.first?.versionID == "version-1")
    #expect(deployments[0].annotations?.message == "Fix cache key")
    #expect(deployments[0].annotations?.triggeredBy == "upload")
    #expect(deployments[0].authorEmail == "dev@example.com")
  }

  @Test func listSkipsMalformedElementsInsteadOfFailingThePage() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.url?.path == "/zones/zone-1/healthchecks")
      let body = #"""
        {"success":true,"result":[
          {"id":"hc-1","name":"Primary","status":"healthy"},
          {"name":"missing id"},
          {"id":"hc-2","status":"unhealthy"}
        ]}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let checks = try await client.listHealthchecks(zoneID: "zone-1")

    #expect(checks.map(\.id) == ["hc-1", "hc-2"])
  }

  @Test func listWorkerDeploymentsSkipsMalformedEntries() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(
        request.url?.path == "/accounts/account/workers/scripts/api/deployments")
      let body = #"""
        {"success":true,"result":{"deployments":[
          {"created_on":"2026-07-16T03:04:05.678Z","source":"api"},
          {"id":"dep-2","created_on":"2026-07-16T04:00:00.000Z","source":"api"}
        ]}}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let deployments = try await client.listWorkerDeployments(
      accountID: "account", scriptName: "api")

    #expect(deployments.count == 1)
    #expect(deployments[0].id == "dep-2")
    #expect(deployments[0].versions.isEmpty)
  }

  @Test func createWorkerDeploymentPostsWholeTrafficSwitch() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.httpMethod == "POST")
      #expect(
        request.url?.path == "/accounts/account/workers/scripts/api/deployments")
      if let body = requestBodyData(request),
        let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
      {
        #expect(payload["strategy"] as? String == "percentage")
        let versions = payload["versions"] as? [[String: Any]]
        #expect(versions?.count == 1)
        #expect(versions?.first?["version_id"] as? String == "version-old")
        #expect((versions?.first?["percentage"] as? NSNumber)?.doubleValue == 100)
        let annotations = payload["annotations"] as? [String: Any]
        #expect(annotations?["workers/message"] as? String == "Rollback")
      }
      return (
        200,
        Data(
          #"""
          {"success":true,"result":{
            "id":"dep-new",
            "created_on":"2026-07-17T00:00:00Z",
            "source":"api",
            "strategy":"percentage",
            "versions":[{"version_id":"version-old","percentage":100}],
            "annotations":{"workers/message":"Rollback"}
          }}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let deployment = try await client.createWorkerDeployment(
      accountID: "account", scriptName: "api", versionID: "version-old", message: "Rollback")
    #expect(deployment.id == "dep-new")
    #expect(deployment.versions.first?.versionID == "version-old")
  }

  @Test func listDNSRecordsForwardsSearchAndType() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
      let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
      #expect(values["search"] == "mail")
      #expect(values["type"] == "MX")
      return (
        200,
        Data(
          #"""
          {"success":true,"result":[{
            "id":"rec-1","type":"MX","name":"example.com","content":"mail.example.com",
            "ttl":1,"priority":10
          }],"result_info":{"page":1,"per_page":100,"count":1,"total_count":1}}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let page = try await client.listDNSRecords(
      zoneID: "zone", search: "mail", type: "MX")
    #expect(page.items.count == 1)
    #expect(page.items[0].priority == 10)
  }

  @Test func dnsRecordInputEncodesSRVDataWithoutContent() throws {
    let input = DNSRecordInput(
      type: "SRV", name: "_xmpp._tcp.example.com",
      data: DNSRecordData(priority: 10, weight: 5, port: 5223, target: "server.example.com"))
    let data = try JSONEncoder().encode(input)
    let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(object["content"] == nil)
    let payload = object["data"] as! [String: Any]
    #expect(payload["priority"] as? Int == 10)
    #expect(payload["weight"] as? Int == 5)
    #expect(payload["port"] as? Int == 5223)
    #expect(payload["target"] as? String == "server.example.com")
  }

  @Test func dnsRecordInputEncodesCAADataWithoutContent() throws {
    let input = DNSRecordInput(
      type: "CAA", name: "example.com",
      data: DNSRecordData(flags: 0, tag: "issue", value: "letsencrypt.org"))
    let data = try JSONEncoder().encode(input)
    let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(object["content"] == nil)
    #expect(object["priority"] == nil)
    let payload = object["data"] as! [String: Any]
    #expect(payload["flags"] as? Int == 0)
    #expect(payload["tag"] as? String == "issue")
    #expect(payload["value"] as? String == "letsencrypt.org")
    #expect(payload["priority"] == nil)
    #expect(payload["target"] == nil)
  }

  @Test func getWorkersAccountSubdomainComposesScriptHostname() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.url?.path.hasSuffix("/workers/subdomain") == true)
      #expect(request.url?.path.contains("/scripts/") != true)
      return (
        200,
        Data(#"{"success":true,"result":{"subdomain":"my-team"},"errors":[],"messages":[]}"#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let account = try await client.getWorkersAccountSubdomain(accountID: "account")

    #expect(account.subdomain == "my-team")
    #expect(account.hostname(forScript: "api-worker") == "api-worker.my-team.workers.dev")
  }

  @Test func listPagesDeploymentsDecodesOperationalFields() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.url?.path.hasSuffix("/pages/projects/docs/deployments") == true)
      return (
        200,
        Data(
          #"""
          {"success":true,"result":[{
            "id":"dep-1","short_id":"dep1abcd","url":"https://dep1.docs.pages.dev",
            "environment":"production","created_on":"2026-07-17T00:00:00Z",
            "is_skipped":false,
            "latest_stage":{"name":"deploy","status":"success"},
            "stages":[{"name":"build","status":"success"}],
            "deployment_trigger":{"type":"github:push",
              "metadata":{"branch":"main","commit_message":"Ship it"}}
          }],"result_info":{"page":1,"per_page":25,"count":1,"total_count":1}}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let page = try await client.listPagesDeployments(accountID: "account", projectName: "docs")
    #expect(page.items.count == 1)
    #expect(page.items[0].branch == "main")
    #expect(page.items[0].commitMessage == "Ship it")
    #expect(page.items[0].latestStage?.status == "success")
  }

  @Test func pagesDeploymentLogsDecodeLines() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { _ in
      (
        200,
        Data(
          #"""
          {"success":true,"result":{"total":2,"includes_container_logs":false,
            "data":[{"line":"Cloning…","ts":"2026-07-17T00:00:00Z"},{"line":"Done","ts":"2026-07-17T00:00:01Z"}]}}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let logs = try await client.getPagesDeploymentLogs(
      accountID: "account", projectName: "docs", deploymentID: "dep-1")
    #expect(logs.total == 2)
    #expect(logs.data.map(\.line) == ["Cloning…", "Done"])
  }

  @Test func rdapParsesRegistrarAndExpiry() throws {
    let body = #"""
      {
        "ldhName": "example.com",
        "status": ["client transfer prohibited"],
        "events": [
          {"eventAction": "registration", "eventDate": "1995-08-14T04:00:00Z"},
          {"eventAction": "expiration", "eventDate": "2027-08-13T04:00:00Z"}
        ],
        "nameservers": [{"ldhName": "a.iana-servers.net"}],
        "entities": [{
          "roles": ["registrar"],
          "vcardArray": ["vcard", [["version", {}, "text", "4.0"], ["fn", {}, "text", "RESERVED"]]]
        }]
      }
      """#
    let registration = try #require(
      RdapClient.parse(Data(body.utf8), fallbackDomain: "example.com"))
    #expect(registration.registrar == "RESERVED")
    #expect(registration.expiresOn == "2027-08-13T04:00:00Z")
    #expect(registration.nameservers == ["a.iana-servers.net"])
  }

  @Test func rdapLookupDecodesRelaySnapshot() async throws {
    let session = mockSession { request in
      #expect(request.url?.path == "/api/registration/xat.sh")
      return (
        200,
        Data(
          #"""
          {"domain":"xat.sh","status":["clientTransferProhibited"],
           "registrar":"Cloudflare, Inc",
           "registeredOn":"2024-10-23T06:49:51Z",
           "expiresOn":"2027-10-23T06:49:51Z",
           "updatedOn":"2026-05-05T02:33:29Z",
           "nameservers":["jason.ns.cloudflare.com","nola.ns.cloudflare.com"]}
          """#.utf8)
      )
    }
    let registration = try #require(
      try await RdapClient.lookup(
        domain: "xat.sh",
        relayBaseURL: URL(string: "https://dash.example.test")!,
        session: session))
    #expect(registration.registrar == "Cloudflare, Inc")
    #expect(registration.expiresOn == "2027-10-23T06:49:51Z")
    #expect(registration.nameservers.count == 2)
  }

  @Test func firewallEventsSummaryDecodesAliasedGroups() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.url?.path.hasSuffix("/graphql") == true)
      return (
        200,
        Data(
          #"""
          {"data":{"viewer":{"zones":[{
            "blocked":[{"count":42}],
            "byCountry":[{"count":30,"dimensions":{"clientCountryName":"US"}},
                         {"count":12,"dimensions":{"clientCountryName":"CN"}}],
            "byRule":[{"count":40,"dimensions":{"ruleId":"rule-1"}}]
          }]}}}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let summary = try await client.firewallEventsSummary(zoneID: "zone", hours: 24)
    #expect(summary.blocked == 42)
    #expect(summary.countries.map(\.label) == ["US", "CN"])
    #expect(summary.rules.first?.label == "rule-1")
  }

  @Test func listAndAttachWorkerDomains() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let recorder = RequestRecorder()
    let session = mockSession { request in
      recorder.record("\(request.httpMethod ?? "?") \(request.url?.path ?? "")")
      if request.httpMethod == "GET" {
        let service = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
          .queryItems?.first { $0.name == "service" }?.value
        #expect(service == "api")
        return (
          200,
          Data(
            #"""
            {"success":true,"result":[{
              "id":"dom-1","hostname":"api.example.com","service":"api",
              "zone_id":"zone-1","zone_name":"example.com","cert_id":"cert-1",
              "environment":"production"
            }]}
            """#.utf8)
        )
      }
      if let body = requestBodyData(request),
        let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
      {
        #expect(payload["hostname"] as? String == "app.example.com")
        #expect(payload["service"] as? String == "api")
        #expect(payload["zone_id"] as? String == "zone-1")
      }
      return (
        200,
        Data(
          #"""
          {"success":true,"result":{
            "id":"dom-2","hostname":"app.example.com","service":"api",
            "zone_id":"zone-1","zone_name":"example.com"
          }}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let listed = try await client.listWorkerDomains(accountID: "account", service: "api")
    #expect(listed.map(\.hostname) == ["api.example.com"])
    let attached = try await client.attachWorkerDomain(
      accountID: "account", hostname: "app.example.com", service: "api",
      zoneID: "zone-1", zoneName: "example.com")
    #expect(attached.id == "dom-2")
    #expect(
      recorder.paths == [
        "GET /accounts/account/workers/domains",
        "PUT /accounts/account/workers/domains",
      ])
  }

  @Test func workerRoutesListDecodesDisabledRoutes() async throws {
    let recorder = RequestRecorder()
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      recorder.record("\(request.httpMethod ?? "?") \(request.url?.path ?? "")")
      return (
        200,
        Data(
          #"""
          {"success":true,"result":[
            {"id":"route-1","pattern":"example.com/*","script":"api"},
            {"id":"route-2","pattern":"disabled.example.com/*"}
          ]}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let routes = try await client.listWorkerRoutes(zoneID: "zone-1")
    #expect(routes.map(\.pattern) == ["example.com/*", "disabled.example.com/*"])
    #expect(routes.map(\.script) == ["api", nil])
    #expect(recorder.paths == ["GET /zones/zone-1/workers/routes"])
  }

  @Test func concurrent401ResponsesShareOneRefresh() async throws {
    let recorder = RequestRecorder()
    let store = MemoryTokenStore(access: "old", refresh: "refresh")
    let session = mockSession { request in
      if request.url?.path == "/token" {
        recorder.recordRefresh()
        return (200, Data(#"{"access_token":"new","refresh_token":"refresh"}"#.utf8))
      }
      if request.value(forHTTPHeaderField: "Authorization") == "Bearer new" {
        return (200, Data(#"{"success":true,"result":[{"id":"account","name":"Example"}]}"#.utf8))
      }
      return (401, Data(#"{"success":false,"errors":[{"code":1000,"message":"expired"}]}"#.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session, tokenURL: URL(string: "https://auth.example.test/token")!)

    async let first = client.listAccounts()
    async let second = client.listAccounts()
    let values = try await (first, second)
    #expect(values.0.first?.name == "Example")
    #expect(values.1.first?.name == "Example")
    #expect(recorder.refreshCount == 1)
  }

  @Test func revokedRefreshTokenSurfacesUnauthorizedAndClearsCredentials() async throws {
    let store = MemoryTokenStore(access: "old", refresh: "revoked")
    let session = mockSession { request in
      if request.url?.path == "/token" {
        return (400, Data(#"{"error":"invalid_grant"}"#.utf8))
      }
      return (401, Data(#"{"success":false,"errors":[{"code":1000,"message":"expired"}]}"#.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session, tokenURL: URL(string: "https://auth.example.test/token")!)

    do {
      _ = try await client.listAccounts()
      Issue.record("a revoked refresh token should surface as unauthorized")
    } catch let error as CloudflareAPIError {
      // invalid_grant must convert into a real 401 so AppModel's isUnauthorized
      // sign-out path fires — not an opaque .oauth error that strands the app.
      #expect(error.isUnauthorized)
    }

    let remainingRefresh = await store.getRefreshToken()
    #expect(remainingRefresh == nil)
  }

  @Test func rateLimitedRequestRetriesAfterShortWait() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let recorder = RequestRecorder()
    let session = mockSession { request in
      recorder.record(request.url?.path ?? "")
      if recorder.paths.count == 1 {
        return (
          429, Data(#"{"success":false,"errors":[{"code":971,"message":"rate limited"}]}"#.utf8)
        )
      }
      return (200, Data(#"{"success":true,"result":[{"id":"account","name":"Example"}]}"#.utf8))
    }
    MockURLProtocol.responseHeaders = ["Retry-After": "0"]
    defer { MockURLProtocol.responseHeaders = nil }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let accounts = try await client.listAccounts()
    #expect(accounts.first?.name == "Example")
    #expect(recorder.paths.count == 2)
  }

  @Test func rateLimitedRequestSurfacesLongWaitImmediately() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let recorder = RequestRecorder()
    let session = mockSession { request in
      recorder.record(request.url?.path ?? "")
      return (
        429, Data(#"{"success":false,"errors":[{"code":971,"message":"rate limited"}]}"#.utf8)
      )
    }
    MockURLProtocol.responseHeaders = ["Retry-After": "120"]
    defer { MockURLProtocol.responseHeaders = nil }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    await #expect(throws: CloudflareAPIError.self) { try await client.listAccounts() }
    #expect(recorder.paths.count == 1)
  }

  @Test func rateLimitedRetriesAreCapped() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let recorder = RequestRecorder()
    let session = mockSession { request in
      recorder.record(request.url?.path ?? "")
      return (
        429, Data(#"{"success":false,"errors":[{"code":971,"message":"rate limited"}]}"#.utf8)
      )
    }
    MockURLProtocol.responseHeaders = ["Retry-After": "0"]
    defer { MockURLProtocol.responseHeaders = nil }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    do {
      _ = try await client.listAccounts()
      Issue.record("expected a rate-limit error")
    } catch let error as CloudflareAPIError {
      #expect(error.isRateLimited)
    }
    #expect(recorder.paths.count == CloudflareClient.maxAttempts + 1)
  }

  // MARK: - Workers Builds

  @Test func listWorkerBuildsKeysOnTheScriptTagNotTheName() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      // The whole point of the tag: `/builds/workers/{external_script_id}/builds`
      // 404s if a Worker's *name* is sent here.
      #expect(request.url?.path == "/accounts/acc/builds/workers/tag-uuid/builds")
      #expect(request.url?.query?.contains("per_page=20") == true)
      return (
        200,
        Data(
          #"""
          {"success":true,"errors":[],"messages":[],"result":[
            {"build_uuid":"b-1","status":"running","created_on":"2026-07-27T10:00:00Z",
             "initializing_on":"2026-07-27T10:00:05Z","running_on":"2026-07-27T10:00:20Z",
             "build_trigger_metadata":{"branch":"main","commit_hash":"0123456789abcdef",
               "commit_message":"fix the thing","author":"xat","build_command":"npm run build"}},
            {"build_uuid":"b-0","status":"stopped","build_outcome":"success",
             "created_on":"2026-07-26T10:00:00Z","stopped_on":"2026-07-26T10:03:00Z"}
          ]}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let page = try await client.listWorkerBuilds(accountID: "acc", scriptTag: "tag-uuid")
    #expect(page.items.count == 2)
    #expect(page.items[0].isInProgress)
    #expect(page.items[0].phase == .running)
    #expect(page.items[0].buildTriggerMetadata?.branch == "main")
    #expect(page.items[0].buildTriggerMetadata?.shortCommit == "0123456")
    #expect(!page.items[1].isInProgress)
    #expect(!page.items[1].didFail)
  }

  @Test func latestWorkerBuildsBatchesTagsAndIsKeyedByTag() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.url?.path == "/accounts/acc/builds/builds/latest")
      #expect(request.url?.query?.contains("external_script_ids=tag-a,tag-b") == true)
      return (
        200,
        Data(
          #"""
          {"success":true,"errors":[],"messages":[],"result":{"builds":{
            "tag-a":{"build_uuid":"b-a","status":"queued","created_on":"2026-07-27T10:00:00Z"},
            "tag-b":{"build_uuid":"b-b","build_outcome":"failure","stopped_on":"2026-07-27T09:00:00Z"}
          }}}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let builds = try await client.latestWorkerBuilds(
      accountID: "acc", scriptTags: ["tag-a", "tag-b"])
    #expect(builds["tag-a"]?.phase == .queued)
    #expect(builds["tag-b"]?.phase == .finished)
    #expect(builds["tag-b"]?.didFail == true)
  }

  @Test func latestWorkerBuildsSkipsTheRequestWhenThereIsNothingToAsk() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { _ in
      Issue.record("no request should be sent for an empty tag list")
      return (200, Data("{}".utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    #expect(try await client.latestWorkerBuilds(accountID: "acc", scriptTags: []).isEmpty)
  }

  @Test func cancelWorkerBuildPutsAndIgnoresAnUndocumentedBody() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.httpMethod == "PUT")
      #expect(request.url?.path == "/accounts/acc/builds/builds/b-1/cancel")
      // Shape is undocumented; a cancel that worked must not read as a failure.
      return (200, Data(#"{"success":true,"errors":[],"messages":[],"result":{"weird":1}}"#.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    try await client.cancelWorkerBuild(accountID: "acc", buildUUID: "b-1")
  }

}

private actor MemoryTokenStore: TokenStore {
  var access: String?
  var refresh: String?
  init(access: String?, refresh: String?) {
    self.access = access
    self.refresh = refresh
  }
  func clear() {
    access = nil
    refresh = nil
  }
  func getAccessToken() -> String? { access }
  func getRefreshToken() -> String? { refresh }
  func setTokens(_ tokens: TokenSet) {
    access = tokens.accessToken
    refresh = tokens.refreshToken
  }
}

private func requestBodyData(_ request: URLRequest) -> Data? {
  if let body = request.httpBody { return body }
  guard let stream = request.httpBodyStream else { return nil }
  stream.open()
  defer { stream.close() }
  var data = Data()
  let size = 1024
  let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
  defer { buffer.deallocate() }
  while stream.hasBytesAvailable {
    let read = stream.read(buffer, maxLength: size)
    if read <= 0 { break }
    data.append(buffer, count: read)
  }
  return data
}

// MARK: - Workers Builds (pure decoding)

@Test func workerBuildPhaseReadsTimestampsNotTheUndocumentedStatusString() throws {
  // Cloudflare publishes no enum for `status`. A build carrying a status this
  // app has never seen must still resolve — and must resolve to finished, so an
  // unknown value can never pin a Live Activity to the Lock Screen forever.
  func build(_ json: String) throws -> WorkerBuild {
    try JSONDecoder().decode(WorkerBuild.self, from: Data(json.utf8))
  }

  #expect(try build(#"{"status":"some_future_state"}"#).phase == .finished)
  #expect(try build(#"{}"#).phase == .finished)
  // A terminal signal always wins, whatever the status says.
  #expect(
    try build(#"{"status":"running","running_on":"t","stopped_on":"t2"}"#).phase == .finished)
  #expect(try build(#"{"status":"running","build_outcome":"success"}"#).phase == .finished)
  // Live states.
  #expect(try build(#"{"status":"queued"}"#).phase == .queued)
  #expect(try build(#"{"status":"anything","initializing_on":"t"}"#).phase == .initializing)
  #expect(try build(#"{"status":"anything","running_on":"t"}"#).phase == .running)
}

@Test func workerBuildTreatsAMissingOutcomeAsUnknownRatherThanSuccess() throws {
  let stopped = try JSONDecoder().decode(
    WorkerBuild.self, from: Data(#"{"build_uuid":"b","stopped_on":"t"}"#.utf8))
  #expect(stopped.phase == .finished)
  // No outcome means Cloudflare did not say; claiming failure would be a lie
  // in the other direction.
  #expect(!stopped.didFail)

  let failed = try JSONDecoder().decode(
    WorkerBuild.self, from: Data(#"{"build_uuid":"b","build_outcome":"failure"}"#.utf8))
  #expect(failed.didFail)
}

private final class RequestRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  private var recorded: [String] = []
  var refreshCount: Int { lock.withLock { count } }
  var paths: [String] { lock.withLock { recorded } }
  func recordRefresh() { lock.withLock { count += 1 } }
  func record(_ path: String) { lock.withLock { recorded.append(path) } }
}

private final class ByteRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var bytes: Int { lock.withLock { count } }
  func record(_ bytes: Int) { lock.withLock { count += bytes } }
}

private final class SessionMetricsRecorder: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private var recordedCount = 0
  var count: Int { lock.withLock { recordedCount } }

  func urlSession(
    _: URLSession,
    task _: URLSessionTask,
    didFinishCollecting _: URLSessionTaskMetrics
  ) {
    lock.withLock { recordedCount += 1 }
  }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?
  /// Optional response headers for the next requests (e.g. Content-Type for
  /// module-worker multipart downloads). Reset it in tests that set it.
  nonisolated(unsafe) static var responseHeaders: [String: String]?
  /// Optional slow chunking for cancellation tests. NetworkTests is serialized,
  /// and every test that sets these restores the defaults in a defer.
  nonisolated(unsafe) static var chunkSize: Int?
  nonisolated(unsafe) static var chunkDelay: TimeInterval = 0
  nonisolated(unsafe) static var onChunk: (@Sendable (Int) -> Void)?

  private let stateLock = NSLock()
  private var stopped = false

  override class func canInit(with _: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let chunkSize = Self.chunkSize
    let chunkDelay = Self.chunkDelay
    if chunkSize != nil {
      DispatchQueue.global(qos: .userInitiated).async {
        self.performLoading(chunkSize: chunkSize, chunkDelay: chunkDelay)
      }
    } else {
      performLoading(chunkSize: nil, chunkDelay: 0)
    }
  }

  override func stopLoading() {
    stateLock.withLock { stopped = true }
  }

  private func performLoading(chunkSize: Int?, chunkDelay: TimeInterval) {
    do {
      let (status, data) = try Self.handler?(request) ?? (500, Data())
      guard !isStopped else { return }
      let response = HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: nil,
        headerFields: Self.responseHeaders)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      if let chunkSize, chunkSize > 0 {
        var offset = 0
        while offset < data.count {
          guard !isStopped else { return }
          let end = min(offset + chunkSize, data.count)
          let chunk = data.subdata(in: offset..<end)
          client?.urlProtocol(self, didLoad: chunk)
          Self.onChunk?(chunk.count)
          offset = end
          if chunkDelay > 0 {
            Thread.sleep(forTimeInterval: chunkDelay)
          }
        }
      } else {
        client?.urlProtocol(self, didLoad: data)
      }
      guard !isStopped else { return }
      client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }

  private var isStopped: Bool {
    stateLock.withLock { stopped }
  }
}

private func mockSession(
  handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)
) -> URLSession {
  MockURLProtocol.handler = handler
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [MockURLProtocol.self]
  return URLSession(configuration: configuration)
}

private func mockSession(
  delegate: any URLSessionDelegate,
  handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)
) -> URLSession {
  MockURLProtocol.handler = handler
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [MockURLProtocol.self]
  return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
}
