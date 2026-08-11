import Foundation
import Testing

@testable import CloudflareAPI

@Test func workerAnalyticsBucketInitDefaultsCPUToZero() {
  let bucket = WorkerAnalyticsBucket(datetime: "2026-07-22T10:00:00Z", requests: 12, errors: 1)
  #expect(bucket.cpuTimeP50Us == 0)
}

extension NetworkTests {
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
    #expect(snapshot.previousOverview == nil)
  }

  @Test func accountAnalyticsMapsPreviousOverviewFromSameQuery() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      let body = try #require(requestBodyData(request))
      let object = try #require(
        JSONSerialization.jsonObject(with: body) as? [String: Any])
      let query = try #require(object["query"] as? String)
      #expect(query.contains("previousOverview: httpRequestsOverviewAdaptiveGroups"))
      #expect(query.contains("previousWorkers: workersInvocationsAdaptive"))
      #expect(query.contains("datetimeMinute_lt:"))
      #expect(query.contains("datetime_lt:"))
      #expect(!query.contains("datetimeMinute_leq:"))
      #expect(!query.contains("datetime_leq:"))
      let response = #"""
        {"data":{"viewer":{"accounts":[{
        "overview":[{
          "sum":{"requests":500,"bytes":10000},
          "ratio":{"cachedRequests":0.5,"encryptedRequests":0.9,"encryptedBytes":0.8,"status4xx":0.02}
        }],
        "previousOverview":[{
          "sum":{"requests":400,"bytes":8000},
          "ratio":{"cachedRequests":0.4,"encryptedRequests":0.85,"encryptedBytes":0.75,"status4xx":0.03}
        }],
        "httpSeries":[],
        "workers":[{"sum":{"requests":100,"errors":2},"quantiles":{"cpuTimeP90":1200.0}}],
        "previousWorkers":[{"sum":{"requests":80,"errors":4},"quantiles":{"cpuTimeP90":1500.0}}],
        "workerSeries":[]
        }]}},"errors":null}
        """#
      return (200, Data(response.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let snapshot = try await client.accountAnalytics(accountID: "acct", hours: 24)
    let previous = try #require(snapshot.previousOverview)

    #expect(snapshot.overview.webRequests == 500)
    #expect(previous.webRequests == 400)
    #expect(previous.bytes == 8000)
    #expect(previous.encryptedBytes == 6000)
    #expect(previous.workerInvocations == 80)
    #expect(previous.workerErrors == 4)
    #expect(previous.cpuTimeP90Us == 1500)
    #expect(previous.hours == 24)
  }

  @Test func accountAnalyticsKeepsCurrentSnapshotWhenPreviousWindowExceedsRetention()
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
      if query.contains("previousOverview:") {
        return (
          200,
          Data(
            #"""
            {"data":null,"errors":[{"message":"cannot request data older than 2592000s"}]}
            """#.utf8)
        )
      }
      #expect(!query.contains("previousWorkers:"))
      return (
        200,
        Data(
          #"""
          {"data":{"viewer":{"accounts":[{
            "overview":[{
              "sum":{"requests":500,"bytes":10000},
              "ratio":{"cachedRequests":0.5,"encryptedRequests":0.9,"encryptedBytes":0.8,"status4xx":0.02}
            }],
            "httpSeries":[],
            "workers":[{"sum":{"requests":100,"errors":2},"quantiles":{"cpuTimeP90":1200.0}}],
            "workerSeries":[]
          }]}},"errors":null}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client",
      tokenStore: store,
      apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let snapshot = try await client.accountAnalytics(
      accountID: "acct",
      hours: 720,
      granularity: .day)

    #expect(snapshot.overview.webRequests == 500)
    #expect(snapshot.overview.workerInvocations == 100)
    #expect(snapshot.previousOverview == nil)
    #expect(recorder.paths.count == 2)
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

  @Test func workerAnalyticsUsesWindowTotalsAndPreviousFullWindowMedian() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      let body = try #require(requestBodyData(request))
      let object = try #require(
        JSONSerialization.jsonObject(with: body) as? [String: Any])
      let query = try #require(object["query"] as? String)
      #expect(query.contains("currentTotals: workersInvocationsAdaptive"))
      #expect(query.contains("previousTotals: workersInvocationsAdaptive"))
      #expect(query.contains("workersInvocationsAdaptive(limit: 2500"))
      #expect(query.contains("datetime_lt:"))
      #expect(!query.contains("datetime_leq:"))
      let response = #"""
        {"data":{"viewer":{"accounts":[{
        "currentTotals":[{
          "sum":{"requests":999,"errors":7},
          "quantiles":{"cpuTimeP50":1234.0}
        }],
        "previousTotals":[{
          "sum":{"requests":800,"errors":9},
          "quantiles":{"cpuTimeP50":987.0}
        }],
        "workersInvocationsAdaptive":[
          {"sum":{"requests":90,"errors":0},"quantiles":{"cpuTimeP50":800.0},"dimensions":{"datetimeFiveMinutes":"2026-07-22T10:00:00Z","status":"success"}},
          {"sum":{"requests":10,"errors":2},"quantiles":{"cpuTimeP50":2000.0},"dimensions":{"datetimeFiveMinutes":"2026-07-22T10:00:00Z","status":"error"}}
        ]
        }]}},"errors":null}
        """#
      return (200, Data(response.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let payload = try await client.workerAnalytics(
      accountID: "acct", scriptName: "worker", hours: 24)

    #expect(payload.requests == 999)
    #expect(payload.errors == 7)
    #expect(payload.cpuTimeP50Us == 1234)
    #expect(payload.previousRequests == 800)
    #expect(payload.previousErrors == 9)
    #expect(payload.previousCPUTimeP50Us == 987)
    #expect(payload.points.first?.requests == 100)
    #expect(payload.points.first?.errors == 2)
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
    #expect(payload.previousRequests == nil)
    #expect(payload.previousErrors == nil)
    #expect(payload.previousCPUTimeP50Us == nil)
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
}
