import Foundation

extension CloudflareClient {
  /// Account overview totals + per-bucket HTTP / Workers series for charts.
  ///
  /// Window totals keep a single-bucket Overview / Workers row so CPU P90
  /// matches the official dashboard. Series add the same ratio / quantile
  /// fields on a time dimension so every Watchtower metric can chart.
  public func accountAnalytics(
    accountID: String,
    hours: Int = 24,
    granularity: AccountAnalyticsGranularity = .hour
  ) async throws -> AccountAnalyticsSnapshot {
    try await accountAnalytics(
      accountID: accountID,
      hours: hours,
      granularity: granularity,
      includesPrevious: true)
  }

  private func accountAnalytics(
    accountID: String,
    hours: Int,
    granularity: AccountAnalyticsGranularity,
    includesPrevious: Bool
  ) async throws -> AccountAnalyticsSnapshot {
    let window = max(hours, 1)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(identifier: "UTC")
    let until = Date()
    let since = until.addingTimeInterval(-TimeInterval(window) * 3600)
    let previousSince = since.addingTimeInterval(-TimeInterval(window) * 3600)
    let previousSinceStamp = formatter.string(from: previousSince)
    let sinceStamp = formatter.string(from: since)
    let untilStamp = formatter.string(from: until)
    let seriesLimit = granularity.seriesLimit(hours: window)
    let orderBy: String
    let httpDimension: String
    let workerDimension: String
    switch granularity {
    case .hour:
      orderBy = "datetimeHour_ASC"
      httpDimension = "datetimeHour"
      workerDimension = "datetimeHour"
    case .day:
      orderBy = "date_ASC"
      httpDimension = "date"
      workerDimension = "date"
    }
    let previousHTTPQuery =
      includesPrevious
      ? """
      previousOverview: httpRequestsOverviewAdaptiveGroups(limit: 1, filter: { \
      datetimeMinute_geq: "\(previousSinceStamp)", \
      datetimeMinute_lt: "\(sinceStamp)" \
      }) { sum { requests bytes } ratio { \
      cachedRequests encryptedRequests encryptedBytes status4xx \
      } }
      """
      : ""
    let previousWorkersQuery =
      includesPrevious
      ? """
      previousWorkers: workersInvocationsAdaptive(limit: 1, filter: { \
      datetime_geq: "\(previousSinceStamp)", \
      datetime_lt: "\(sinceStamp)" \
      }) { sum { requests errors } quantiles { cpuTimeP90 } }
      """
      : ""
    let query = """
      { viewer { accounts(filter: {accountTag: "\(accountID)"}) { \
      overview: httpRequestsOverviewAdaptiveGroups(limit: 1, filter: { \
      datetimeMinute_geq: "\(sinceStamp)", \
      datetimeMinute_lt: "\(untilStamp)" \
      }) { sum { requests bytes } ratio { \
      cachedRequests encryptedRequests encryptedBytes status4xx \
      } } \
      \(previousHTTPQuery) \
      httpSeries: httpRequestsOverviewAdaptiveGroups( \
      limit: \(seriesLimit), orderBy: [\(orderBy)], filter: { \
      datetimeMinute_geq: "\(sinceStamp)", \
      datetimeMinute_lt: "\(untilStamp)" \
      }) { sum { requests bytes } ratio { \
      cachedRequests encryptedRequests encryptedBytes status4xx \
      } dimensions { \(httpDimension) } } \
      workers: workersInvocationsAdaptive(limit: 1, filter: { \
      datetime_geq: "\(sinceStamp)", \
      datetime_lt: "\(untilStamp)" \
      }) { sum { requests errors } quantiles { cpuTimeP90 } } \
      \(previousWorkersQuery) \
      workerSeries: workersInvocationsAdaptive( \
      limit: \(seriesLimit), orderBy: [\(orderBy)], filter: { \
      datetime_geq: "\(sinceStamp)", \
      datetime_lt: "\(untilStamp)" \
      }) { sum { requests errors } quantiles { cpuTimeP90 } \
      dimensions { \(workerDimension) } } \
      } } }
      """
    let payload = try JSONEncoder().encode(["query": query])
    let response: Data
    do {
      response = try await graphQLRaw(payload)
    } catch let error as CloudflareAPIError {
      guard
        includesPrevious,
        case .request(let status, _) = error,
        status == 400
      else { throw error }
      return try await accountAnalytics(
        accountID: accountID,
        hours: hours,
        granularity: granularity,
        includesPrevious: false)
    }
    let envelope = try JSONDecoder().decode(
      GraphQLEnvelope<AccountAnalyticsData>.self, from: response)
    if let error = envelope.errors?.first {
      if includesPrevious, error.semanticStatusCode == 400 {
        return try await accountAnalytics(
          accountID: accountID,
          hours: hours,
          granularity: granularity,
          includesPrevious: false)
      }
      throw CloudflareAPIError.request(
        status: error.semanticStatusCode,
        errors: [APIErrorItem(code: 0, message: error.message)])
    }
    let account = envelope.data?.viewer.accounts.first
    let http = account?.overview.first
    let workers = account?.workers.first
    func makeOverview(
      http: AccountAnalyticsData.HTTPTotals?,
      workers: AccountAnalyticsData.WorkerTotals?
    ) -> AccountAnalyticsOverview {
      let requests = http?.sum.requests ?? 0
      let bytes = http?.sum.bytes ?? 0
      let encryptedRate = http?.ratio?.encryptedBytes ?? 0
      return AccountAnalyticsOverview(
        webRequests: requests,
        bytes: bytes,
        cacheRate: http?.ratio?.cachedRequests ?? 0,
        clientErrorRate: http?.ratio?.status4xx ?? 0,
        encryptedRequestRate: http?.ratio?.encryptedRequests ?? 0,
        encryptedBytes: Int64((Double(bytes) * encryptedRate).rounded()),
        workerInvocations: workers?.sum.requests ?? 0,
        workerErrors: workers?.sum.errors ?? 0,
        cpuTimeP90Us: workers?.quantiles?.cpuTimeP90 ?? 0,
        hours: window
      )
    }
    let overview = makeOverview(http: http, workers: workers)
    let previousOverview: AccountAnalyticsOverview?
    if let previousHTTPRows = account?.previousOverview,
      let previousWorkerRows = account?.previousWorkers
    {
      previousOverview = makeOverview(
        http: previousHTTPRows.first,
        workers: previousWorkerRows.first)
    } else {
      previousOverview = nil
    }
    let httpPoints = (account?.httpSeries ?? []).compactMap { row -> AccountAnalyticsPoint? in
      guard let stamp = row.dimensions.datetimeHour ?? row.dimensions.date else { return nil }
      let pointBytes = row.sum.bytes
      let encrypted = row.ratio?.encryptedBytes ?? 0
      return AccountAnalyticsPoint(
        datetime: stamp,
        requests: row.sum.requests,
        bytes: pointBytes,
        errors: 0,
        cacheRate: row.ratio?.cachedRequests ?? 0,
        clientErrorRate: row.ratio?.status4xx ?? 0,
        encryptedRequestRate: row.ratio?.encryptedRequests ?? 0,
        encryptedBytes: Int64((Double(pointBytes) * encrypted).rounded()),
        cpuTimeP90Us: 0)
    }
    let workerPoints = (account?.workerSeries ?? []).compactMap { row -> AccountAnalyticsPoint? in
      guard let stamp = row.dimensions.datetimeHour ?? row.dimensions.date else { return nil }
      return AccountAnalyticsPoint(
        datetime: stamp,
        requests: row.sum.requests,
        bytes: 0,
        errors: row.sum.errors,
        cpuTimeP90Us: row.quantiles?.cpuTimeP90 ?? 0)
    }
    return AccountAnalyticsSnapshot(
      overview: overview,
      previousOverview: previousOverview,
      httpPoints: httpPoints,
      workerPoints: workerPoints,
      fetchedAt: .now)
  }

  /// Totals-only convenience used by tests and callers that do not need series.
  public func accountAnalyticsOverview(accountID: String, hours: Int = 6)
    async throws -> AccountAnalyticsOverview
  {
    try await accountAnalytics(
      accountID: accountID, hours: hours,
      granularity: hours > 48 ? .day : .hour
    ).overview
  }
}

public enum AccountAnalyticsGranularity: Hashable, Sendable {
  case hour
  case day

  func seriesLimit(hours: Int) -> Int {
    switch self {
    case .hour: min(max(hours + 2, 24), 200)
    case .day: min(max((hours / 24) + 2, 8), 40)
    }
  }
}

/// Account-scoped overview tiles for a rolling window (Watchtower).
/// HTTP fields come from `httpRequestsOverviewAdaptiveGroups`; Workers fields
/// from a single-bucket `workersInvocationsAdaptive` (P90 over the whole window).
public struct AccountAnalyticsOverview: Hashable, Sendable {
  public var webRequests: Int
  public var bytes: Int64
  public var cacheRate: Double
  public var clientErrorRate: Double
  public var encryptedRequestRate: Double
  public var encryptedBytes: Int64
  public var workerInvocations: Int
  public var workerErrors: Int
  public var cpuTimeP90Us: Double
  public var hours: Int

  public init(
    webRequests: Int,
    bytes: Int64,
    cacheRate: Double,
    clientErrorRate: Double,
    encryptedRequestRate: Double,
    encryptedBytes: Int64,
    workerInvocations: Int,
    workerErrors: Int,
    cpuTimeP90Us: Double,
    hours: Int
  ) {
    self.webRequests = webRequests
    self.bytes = bytes
    self.cacheRate = cacheRate
    self.clientErrorRate = clientErrorRate
    self.encryptedRequestRate = encryptedRequestRate
    self.encryptedBytes = encryptedBytes
    self.workerInvocations = workerInvocations
    self.workerErrors = workerErrors
    self.cpuTimeP90Us = cpuTimeP90Us
    self.hours = hours
  }
}

/// One bucket in an account HTTP or Workers series.
///
/// HTTP rows fill traffic / bandwidth / ratio fields; Workers rows fill
/// invocations / errors / CPU. Unused fields stay zero.
public struct AccountAnalyticsPoint: Hashable, Sendable, Identifiable {
  public var id: String { datetime }
  public var datetime: String
  public var requests: Int
  public var bytes: Int64
  public var errors: Int
  public var cacheRate: Double
  public var clientErrorRate: Double
  public var encryptedRequestRate: Double
  public var encryptedBytes: Int64
  public var cpuTimeP90Us: Double

  public init(
    datetime: String,
    requests: Int,
    bytes: Int64 = 0,
    errors: Int = 0,
    cacheRate: Double = 0,
    clientErrorRate: Double = 0,
    encryptedRequestRate: Double = 0,
    encryptedBytes: Int64 = 0,
    cpuTimeP90Us: Double = 0
  ) {
    self.datetime = datetime
    self.requests = requests
    self.bytes = bytes
    self.errors = errors
    self.cacheRate = cacheRate
    self.clientErrorRate = clientErrorRate
    self.encryptedRequestRate = encryptedRequestRate
    self.encryptedBytes = encryptedBytes
    self.cpuTimeP90Us = cpuTimeP90Us
  }
}

/// Totals plus HTTP / Workers time series for one Watchtower range.
public struct AccountAnalyticsSnapshot: Hashable, Sendable {
  public var overview: AccountAnalyticsOverview
  public var previousOverview: AccountAnalyticsOverview?
  public var httpPoints: [AccountAnalyticsPoint]
  public var workerPoints: [AccountAnalyticsPoint]
  /// Wall-clock time the snapshot was fetched; used for “Updated …” chrome.
  public var fetchedAt: Date

  public init(
    overview: AccountAnalyticsOverview,
    previousOverview: AccountAnalyticsOverview? = nil,
    httpPoints: [AccountAnalyticsPoint],
    workerPoints: [AccountAnalyticsPoint],
    fetchedAt: Date = .now
  ) {
    self.overview = overview
    self.previousOverview = previousOverview
    self.httpPoints = httpPoints
    self.workerPoints = workerPoints
    self.fetchedAt = fetchedAt
  }
}
private struct AccountAnalyticsData: Decodable, Sendable {
  let viewer: Viewer

  struct Viewer: Decodable, Sendable { let accounts: [Account] }
  struct Account: Decodable, Sendable {
    let overview: [HTTPTotals]
    let previousOverview: [HTTPTotals]?
    let httpSeries: [HTTPSeries]
    let workers: [WorkerTotals]
    let previousWorkers: [WorkerTotals]?
    let workerSeries: [WorkerSeries]
  }

  struct HTTPTotals: Decodable, Sendable {
    let sum: Sum
    let ratio: Ratio?

    struct Sum: Decodable, Sendable {
      let requests: Int
      let bytes: Int64
    }
    struct Ratio: Decodable, Sendable {
      let cachedRequests: Double?
      let encryptedRequests: Double?
      let encryptedBytes: Double?
      let status4xx: Double?
    }
  }

  struct HTTPSeries: Decodable, Sendable {
    let sum: Sum
    let ratio: Ratio?
    let dimensions: Dimensions

    struct Sum: Decodable, Sendable {
      let requests: Int
      let bytes: Int64
    }
    struct Ratio: Decodable, Sendable {
      let cachedRequests: Double?
      let encryptedRequests: Double?
      let encryptedBytes: Double?
      let status4xx: Double?
    }
    struct Dimensions: Decodable, Sendable {
      let datetimeHour: String?
      let date: String?
    }
  }

  struct WorkerTotals: Decodable, Sendable {
    let sum: Sum
    let quantiles: Quantiles?

    struct Sum: Decodable, Sendable {
      let requests: Int
      let errors: Int
    }
    struct Quantiles: Decodable, Sendable {
      let cpuTimeP90: Double?
    }
  }

  struct WorkerSeries: Decodable, Sendable {
    let sum: Sum
    let quantiles: Quantiles?
    let dimensions: Dimensions

    struct Sum: Decodable, Sendable {
      let requests: Int
      let errors: Int
    }
    struct Quantiles: Decodable, Sendable {
      let cpuTimeP90: Double?
    }
    struct Dimensions: Decodable, Sendable {
      let datetimeHour: String?
      let date: String?
    }
  }
}
