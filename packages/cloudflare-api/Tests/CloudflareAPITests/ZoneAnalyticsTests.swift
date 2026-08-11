import Foundation
import Testing

@testable import CloudflareAPI

extension NetworkTests {
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

  @Test func zoneAnalyticsComparisonMapsBothAliasedWindows() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      let body = try #require(requestBodyData(request))
      let object = try #require(
        JSONSerialization.jsonObject(with: body) as? [String: Any])
      let query = try #require(object["query"] as? String)
      #expect(query.contains("current: httpRequests1dGroups"))
      #expect(query.contains("previous: httpRequests1dGroups"))
      #expect(query.contains("date_lt:"))
      #expect(!query.contains("date_leq:"))
      let response = #"""
        {"data":{"viewer":{"zones":[{
        "current":[{
          "dimensions":{"date":"2026-07-28"},
          "sum":{"requests":220,"pageViews":90,"threats":3,"bytes":22000,"cachedRequests":180,"cachedBytes":17000},
          "uniq":{"uniques":44}
        }],
        "previous":[{
          "dimensions":{"date":"2026-07-21"},
          "sum":{"requests":180,"pageViews":72,"threats":5,"bytes":18000,"cachedRequests":130,"cachedBytes":12000},
          "uniq":{"uniques":36}
        }]
        }]}},"errors":null}
        """#
      return (200, Data(response.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let comparison = try await client.zoneAnalyticsComparison(zoneID: "zone", days: 7)

    #expect(comparison.current.map(\.requests) == [220])
    #expect(comparison.previous?.map(\.requests) == [180])
    #expect(comparison.current.first?.cachedRequests == 180)
    #expect(comparison.previous?.first?.uniques == 36)
  }

  @Test func zoneAnalyticsDailyWindowsUseAdjacentCompleteUTCDays() throws {
    let parser = ISO8601DateFormatter()
    let now = try #require(parser.date(from: "2026-07-29T12:34:56Z"))

    let bounds = CloudflareClient.zoneAnalyticsDailyBounds(days: 7, now: now)

    #expect(bounds.previousStart == "2026-07-15")
    #expect(bounds.currentStart == "2026-07-22")
    #expect(bounds.end == "2026-07-29")
  }

  @Test func zoneAnalyticsComparisonKeepsCurrentDataWhenOlderWindowIsUnavailable()
    async throws
  {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let recorder = RequestRecorder()
    let session = mockSession { request in
      let body = try #require(requestBodyData(request))
      let object = try #require(
        JSONSerialization.jsonObject(with: body) as? [String: Any])
      let query = try #require(object["query"] as? String)
      recorder.record(query)
      if query.contains("previous: httpRequests1dGroups") {
        return (
          200,
          Data(
            #"""
            {"data":null,"errors":[{"message":"requested data is older than this plan allows"}]}
            """#.utf8)
        )
      }
      #expect(query.contains("httpRequests1dGroups"))
      #expect(!query.contains("previous:"))
      return (
        200,
        Data(
          #"""
          {"data":{"viewer":{"zones":[{"httpRequests1dGroups":[{
            "dimensions":{"date":"2026-07-28"},
            "sum":{"requests":220,"pageViews":90,"threats":3,"bytes":22000},
            "uniq":{"uniques":44}
          }]}]}},"errors":null}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client",
      tokenStore: store,
      apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let comparison = try await client.zoneAnalyticsComparison(zoneID: "zone", days: 30)

    #expect(comparison.current.map(\.requests) == [220])
    #expect(comparison.previous == nil)
    #expect(recorder.paths.count == 2)
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

  @Test func webAnalyticsSitesDoNotSilentlyTruncateAfterOneHundredPages() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let recorder = RequestRecorder()
    let session = mockSession { request in
      let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
      let page =
        components?.queryItems?.first(where: { $0.name == "page" })?.value.flatMap(Int.init) ?? 1
      recorder.record(request.url?.absoluteString ?? "")
      let body = #"""
        {"result":[{"site_tag":"site-\#(page)","auto_install":false}],
         "success":true,"errors":[],"messages":[],
         "result_info":{"page":\#(page),"per_page":1,"total_count":101,"total_pages":101}}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let sites = try await client.webAnalyticsSites(accountID: "acct")

    #expect(sites.count == 101)
    #expect(sites.last?.siteTag == "site-101")
    #expect(recorder.paths.count == 101)
    #expect(recorder.paths.last?.contains("page=101") == true)
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

  @Test func webAnalyticsMetricsDecodePageloadDaysAscending() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let recorder = RequestRecorder()
    let session = mockSession { request in
      recorder.record(request.url?.absoluteString ?? "")
      let body = #"""
        {"data":{"viewer":{"accounts":[{
        "pageload":[
        {"count":46,"sum":{"visits":20},"dimensions":{"date":"2026-07-22"}},
        {"count":51,"sum":{"visits":25},"dimensions":{"date":"2026-07-23"}}
        ]}]}},"errors":null}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let result = try await client.webAnalyticsMetrics(
      accountID: "acct", siteTag: "site-1", days: 7)

    #expect(result.days.map(\.date) == ["2026-07-22", "2026-07-23"])
    #expect(result.days.map(\.pageviews) == [46, 51])
    #expect(result.days.map(\.visits) == [20, 25])
    #expect(recorder.paths.first?.contains("/graphql") == true)
  }

  @Test func webAnalyticsMetricsQueriesOnlyPageloadOverCompleteUTCDays() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let recorder = RequestRecorder()
    let session = mockSession { request in
      if let body = requestBodyData(request) {
        recorder.record(String(decoding: body, as: UTF8.self))
      }
      let body = #"""
        {"data":{"viewer":{"accounts":[{"pageload":[]}]}},"errors":null}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let result = try await client.webAnalyticsMetrics(
      accountID: "acct", siteTag: "site-1", days: 7)

    #expect(result.days.isEmpty)
    let body = try #require(recorder.paths.first)
    let request = try JSONDecoder().decode([String: String].self, from: Data(body.utf8))
    let query = try #require(request["query"])
    // The performance dataset carried only page-load time and the web-vitals
    // dataset only LCP / INP / CLS. Both metrics left the screen — querying
    // either again would pay for numbers nothing reads.
    #expect(!query.contains("rumPerformanceEventsAdaptiveGroups"))
    #expect(!query.contains("rumWebVitalsEventsAdaptiveGroups"))
    #expect(query.contains("pageload: rumPageloadEventsAdaptiveGroups"))

    let regex = try NSRegularExpression(
      pattern: #"datetime_(?:geq|lt): "([^"]+)""#)
    let range = NSRange(query.startIndex..<query.endIndex, in: query)
    let timestamps = regex.matches(in: query, range: range).compactMap { match -> Date? in
      guard let valueRange = Range(match.range(at: 1), in: query) else { return nil }
      return ISO8601DateFormatter().date(from: String(query[valueRange]))
    }
    // One filter, spanning both windows: the caller splits current from
    // comparison by date rather than paying for a second aliased query.
    #expect(timestamps.count == 2)
    let start = try #require(timestamps.first)
    let end = try #require(timestamps.last)
    #expect(end.timeIntervalSince(start) == 14 * 86400)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    #expect(
      timestamps.allSatisfy {
        let parts = calendar.dateComponents([.hour, .minute, .second], from: $0)
        return parts.hour == 0 && parts.minute == 0 && parts.second == 0
      })
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
        {"data":{"viewer":{"zones":[{"current":[
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

  @Test func hourlyZoneAnalyticsComparisonMapsBothAliasedWindows() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      let body = try #require(requestBodyData(request))
      let object = try #require(
        JSONSerialization.jsonObject(with: body) as? [String: Any])
      let query = try #require(object["query"] as? String)
      #expect(query.contains("current: httpRequests1hGroups"))
      #expect(query.contains("previous: httpRequests1hGroups"))
      #expect(query.contains("datetime_lt:"))
      #expect(!query.contains("datetime_leq:"))
      let response = #"""
        {"data":{"viewer":{"zones":[{
        "current":[{
          "dimensions":{"datetime":"2026-07-28T10:00:00Z"},
          "sum":{"requests":40,"pageViews":16,"threats":1,"bytes":4096}
        }],
        "previous":[{
          "dimensions":{"datetime":"2026-07-27T10:00:00Z"},
          "sum":{"requests":30,"pageViews":12,"threats":0,"bytes":3072}
        }]
        }]}},"errors":null}
        """#
      return (200, Data(response.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let comparison = try await client.zoneAnalyticsHourlyComparison(zoneID: "zone", hours: 24)

    #expect(comparison.current.map(\.requests) == [40])
    #expect(comparison.previous?.map(\.requests) == [30])
    #expect(comparison.current.first?.datetime == "2026-07-28T10:00:00Z")
    #expect(comparison.previous?.first?.datetime == "2026-07-27T10:00:00Z")
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

  @Test func firewallEventsSummaryUsesByTimeGroupsAndAdaptiveTops() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.url?.path.hasSuffix("/graphql") == true)
      let body = try #require(requestBodyData(request))
      let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
      let query = try #require(object["query"] as? String)
      #expect(query.contains("firewallEventsAdaptiveByTimeGroups"))
      #expect(query.contains("samples: firewallEventsAdaptive("))
      #expect(!query.contains("firewallEventsAdaptiveGroups"))
      #expect(query.contains("action: \"block\""))
      return (
        200,
        Data(
          #"""
          {"data":{"viewer":{"zones":[{
            "byTime":[
              {"count":10,"dimensions":{"datetimeHour":"2026-07-30T10:00:00Z"}},
              {"count":5,"dimensions":{"datetimeHour":"2026-07-30T11:00:00Z"}}
            ],
            "samples":[
              {"clientCountryName":"US","ruleId":"bot_fight_mode"},
              {"clientCountryName":"US","ruleId":"bot_fight_mode"},
              {"clientCountryName":"CN","ruleId":"rule-1"}
            ]
          }]}},"errors":null}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let summary = try await client.firewallEventsSummary(zoneID: "zone", hours: 24)
    #expect(summary.blocked == 15)
    #expect(summary.series.map(\.count) == [10, 5])
    #expect(summary.countries.map(\.label) == ["US", "CN"])
    #expect(summary.countries.map(\.count) == [2, 1])
    #expect(summary.rules.map(\.label) == ["bot_fight_mode", "rule-1"])
  }

  @Test func firewallAdaptiveTopBucketsRankStableTies() {
    let tops = CloudflareClient.firewallAdaptiveTopBuckets(
      [
        FirewallAdaptiveEvent(clientCountryName: "DE", ruleId: "b"),
        FirewallAdaptiveEvent(clientCountryName: "FR", ruleId: "a"),
        FirewallAdaptiveEvent(clientCountryName: "DE", ruleId: "a"),
        FirewallAdaptiveEvent(clientCountryName: "  ", ruleId: nil),
        FirewallAdaptiveEvent(clientCountryName: nil, ruleId: "  "),
      ],
      countryLimit: 8,
      ruleLimit: 8)
    #expect(tops.countries.map(\.label) == ["DE", "FR"])
    #expect(tops.countries.map(\.count) == [2, 1])
    #expect(tops.rules.map(\.label) == ["a", "b"])
    #expect(tops.rules.map(\.count) == [2, 1])
  }
}
