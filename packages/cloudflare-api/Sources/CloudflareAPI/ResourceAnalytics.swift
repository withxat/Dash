import Foundation

// MARK: - DNS

/// One DNS query-volume bucket (hourly ISO timestamp or `yyyy-MM-dd`).
public struct DNSAnalyticsPoint: Codable, Hashable, Sendable {
  public let datetime: String
  public let queries: Int

  public init(datetime: String, queries: Int) {
    self.datetime = datetime
    self.queries = queries
  }
}

public struct DNSAnalyticsBucket: Codable, Hashable, Identifiable, Sendable {
  public var id: String { label }
  public let label: String
  public let count: Int

  public init(label: String, count: Int) {
    self.label = label
    self.count = count
  }
}

/// Zone DNS query analytics from `dnsAnalyticsAdaptiveGroups`.
public struct DNSAnalyticsSummary: Codable, Hashable, Sendable {
  public let points: [DNSAnalyticsPoint]
  public let totalQueries: Int
  public let previousTotalQueries: Int?
  public let queryTypes: [DNSAnalyticsBucket]

  public init(
    points: [DNSAnalyticsPoint],
    totalQueries: Int,
    previousTotalQueries: Int? = nil,
    queryTypes: [DNSAnalyticsBucket] = []
  ) {
    self.points = points
    self.totalQueries = totalQueries
    self.previousTotalQueries = previousTotalQueries
    self.queryTypes = queryTypes
  }
}

// MARK: - Email Routing

public struct EmailRoutingAnalyticsPoint: Codable, Hashable, Sendable {
  public let datetime: String
  public let count: Int

  public init(datetime: String, count: Int) {
    self.datetime = datetime
    self.count = count
  }
}

/// Forwarded / dropped volume for one zone from `emailRoutingAdaptiveGroups`.
public struct EmailRoutingAnalyticsSummary: Codable, Hashable, Sendable {
  public let hours: Int
  public let total: Int
  public let series: [EmailRoutingAnalyticsPoint]

  public init(hours: Int, total: Int, series: [EmailRoutingAnalyticsPoint] = []) {
    self.hours = hours
    self.total = total
    self.series = series
  }

  public var isEmpty: Bool { total == 0 && series.isEmpty }
}

// MARK: - R2 / KV

public struct StorageAnalyticsPoint: Codable, Hashable, Sendable {
  public let date: String
  public let requests: Int

  public init(date: String, requests: Int) {
    self.date = date
    self.requests = requests
  }
}

public struct StorageAnalyticsSummary: Codable, Hashable, Sendable {
  public let days: Int
  public let totalRequests: Int
  public let previousTotalRequests: Int?
  public let points: [StorageAnalyticsPoint]

  public init(
    days: Int,
    totalRequests: Int,
    previousTotalRequests: Int? = nil,
    points: [StorageAnalyticsPoint] = []
  ) {
    self.days = days
    self.totalRequests = totalRequests
    self.previousTotalRequests = previousTotalRequests
    self.points = points
  }

  public var isEmpty: Bool { points.isEmpty && totalRequests == 0 }
}

// MARK: - Client

extension CloudflareClient {
  /// Hourly DNS query volume for adjacent equal windows, plus top query types
  /// for the current window. Requires `analytics.read`.
  public func dnsAnalyticsHourlyComparison(zoneID: String, hours: Int = 24) async throws
    -> DNSAnalyticsSummary
  {
    let window = max(hours, 1)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(identifier: "UTC")
    let end = Date()
    let currentStart = end.addingTimeInterval(-TimeInterval(window) * 3600)
    let previousStart = currentStart.addingTimeInterval(-TimeInterval(window) * 3600)
    let endStamp = formatter.string(from: end)
    let currentStartStamp = formatter.string(from: currentStart)
    let previousStartStamp = formatter.string(from: previousStart)
    let query = """
      { viewer { zones(filter: {zoneTag: "\(zoneID)"}) { \
      current: dnsAnalyticsAdaptiveGroups(limit: \(window + 1), \
      filter: {datetime_geq: "\(currentStartStamp)", datetime_lt: "\(endStamp)"}, \
      orderBy: [datetimeHour_ASC]) { count dimensions { datetimeHour } } \
      previous: dnsAnalyticsAdaptiveGroups(limit: \(window + 1), \
      filter: {datetime_geq: "\(previousStartStamp)", datetime_lt: "\(currentStartStamp)"}, \
      orderBy: [datetimeHour_ASC]) { count dimensions { datetimeHour } } \
      queryTypes: dnsAnalyticsAdaptiveGroups(limit: 8, \
      filter: {datetime_geq: "\(currentStartStamp)", datetime_lt: "\(endStamp)"}, \
      orderBy: [count_DESC]) { count dimensions { queryType } } } } }
      """
    return try await decodeDNSAnalytics(
      query: query,
      mapPoint: {
        DNSAnalyticsPoint(datetime: $0.dimensions.datetimeHour ?? "", queries: $0.count)
      },
      mapQueryType: true)
  }

  /// Daily DNS query volume for adjacent equal windows. Requires `analytics.read`.
  public func dnsAnalyticsDailyComparison(zoneID: String, days: Int = 7) async throws
    -> DNSAnalyticsSummary
  {
    let window = max(days, 1)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
    let end = calendar.startOfDay(for: Date())
    let currentStart = calendar.date(byAdding: .day, value: -window, to: end) ?? end
    let previousStart =
      calendar.date(byAdding: .day, value: -window, to: currentStart) ?? currentStart
    let dayFormatter = DateFormatter()
    dayFormatter.dateFormat = "yyyy-MM-dd"
    dayFormatter.locale = Locale(identifier: "en_US_POSIX")
    dayFormatter.timeZone = TimeZone(identifier: "UTC")
    let endDay = dayFormatter.string(from: calendar.date(byAdding: .day, value: -1, to: end) ?? end)
    let currentStartDay = dayFormatter.string(from: currentStart)
    let previousEndDay =
      dayFormatter.string(
        from: calendar.date(byAdding: .day, value: -1, to: currentStart) ?? currentStart)
    let previousStartDay = dayFormatter.string(from: previousStart)
    let query = """
      { viewer { zones(filter: {zoneTag: "\(zoneID)"}) { \
      current: dnsAnalyticsAdaptiveGroups(limit: \(window + 1), \
      filter: {date_geq: "\(currentStartDay)", date_leq: "\(endDay)"}, \
      orderBy: [date_ASC]) { count dimensions { date } } \
      previous: dnsAnalyticsAdaptiveGroups(limit: \(window + 1), \
      filter: {date_geq: "\(previousStartDay)", date_leq: "\(previousEndDay)"}, \
      orderBy: [date_ASC]) { count dimensions { date } } \
      queryTypes: dnsAnalyticsAdaptiveGroups(limit: 8, \
      filter: {date_geq: "\(currentStartDay)", date_leq: "\(endDay)"}, \
      orderBy: [count_DESC]) { count dimensions { queryType } } } } }
      """
    return try await decodeDNSAnalytics(
      query: query,
      mapPoint: { DNSAnalyticsPoint(datetime: $0.dimensions.date ?? "", queries: $0.count) },
      mapQueryType: true)
  }

  /// Email Routing volume for the last `hours` via `emailRoutingAdaptiveGroups`.
  /// Requires `analytics.read`. Empty results are success, not an error.
  public func emailRoutingAnalytics(zoneID: String, hours: Int = 24) async throws
    -> EmailRoutingAnalyticsSummary
  {
    let window = max(hours, 1)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(identifier: "UTC")
    let until = Date()
    let since = until.addingTimeInterval(-TimeInterval(window) * 3600)
    let query = """
      { viewer { zones(filter: {zoneTag: "\(zoneID)"}) { \
      emailRoutingAdaptiveGroups(limit: \(window + 1), \
      filter: {datetimeHour_geq: "\(formatter.string(from: since))", \
      datetimeHour_leq: "\(formatter.string(from: until))"}, \
      orderBy: [datetimeHour_ASC]) { count dimensions { datetimeHour } } } } }
      """
    let response = try await graphQL(query: query)
    let envelope = try JSONDecoder().decode(
      GraphQLEnvelope<EmailRoutingAnalyticsData>.self, from: response)
    if let error = envelope.errors?.first {
      throw CloudflareAPIError.request(
        status: error.semanticStatusCode,
        errors: [APIErrorItem(code: 0, message: error.message)])
    }
    let series = (envelope.data?.viewer.zones.first?.emailRoutingAdaptiveGroups ?? []).map {
      EmailRoutingAnalyticsPoint(datetime: $0.dimensions.datetimeHour, count: $0.count)
    }
    return EmailRoutingAnalyticsSummary(
      hours: window,
      total: series.reduce(0) { $0 + $1.count },
      series: series)
  }

  /// R2 operation counts for one bucket over complete UTC days.
  /// Requires account analytics access for GraphQL storage nodes.
  public func r2BucketAnalytics(accountID: String, bucketName: String, days: Int = 7)
    async throws -> StorageAnalyticsSummary
  {
    try await storageOperationsAnalytics(
      accountID: accountID,
      days: days,
      dataset: "r2OperationsAdaptiveGroups",
      resourceFilter: "bucketName: \"\(Self.escapeGraphQLString(bucketName))\"")
  }

  /// KV operation counts for one namespace over complete UTC days.
  public func kvNamespaceAnalytics(accountID: String, namespaceID: String, days: Int = 7)
    async throws -> StorageAnalyticsSummary
  {
    try await storageOperationsAnalytics(
      accountID: accountID,
      days: days,
      dataset: "kvOperationsAdaptiveGroups",
      resourceFilter: "namespaceId: \"\(Self.escapeGraphQLString(namespaceID))\"")
  }

  private func storageOperationsAnalytics(
    accountID: String,
    days: Int,
    dataset: String,
    resourceFilter: String
  ) async throws -> StorageAnalyticsSummary {
    let window = max(days, 1)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
    let end = calendar.startOfDay(for: Date())
    let currentStart = calendar.date(byAdding: .day, value: -window, to: end) ?? end
    let previousStart =
      calendar.date(byAdding: .day, value: -window, to: currentStart) ?? currentStart
    let dayFormatter = DateFormatter()
    dayFormatter.dateFormat = "yyyy-MM-dd"
    dayFormatter.locale = Locale(identifier: "en_US_POSIX")
    dayFormatter.timeZone = TimeZone(identifier: "UTC")
    let endDay = dayFormatter.string(from: calendar.date(byAdding: .day, value: -1, to: end) ?? end)
    let currentStartDay = dayFormatter.string(from: currentStart)
    let previousEndDay =
      dayFormatter.string(
        from: calendar.date(byAdding: .day, value: -1, to: currentStart) ?? currentStart)
    let previousStartDay = dayFormatter.string(from: previousStart)
    let query = """
      { viewer { accounts(filter: {accountTag: "\(accountID)"}) { \
      current: \(dataset)(limit: \(window + 1), \
      filter: {date_geq: "\(currentStartDay)", date_leq: "\(endDay)", \(resourceFilter)}, \
      orderBy: [date_ASC]) { sum { requests } dimensions { date } } \
      previous: \(dataset)(limit: \(window + 1), \
      filter: {date_geq: "\(previousStartDay)", date_leq: "\(previousEndDay)", \(resourceFilter)}, \
      orderBy: [date_ASC]) { sum { requests } dimensions { date } } } } }
      """
    let response = try await graphQL(query: query)
    let envelope = try JSONDecoder().decode(
      GraphQLEnvelope<StorageOperationsAnalyticsData>.self, from: response)
    if let error = envelope.errors?.first {
      throw CloudflareAPIError.request(
        status: error.semanticStatusCode,
        errors: [APIErrorItem(code: 0, message: error.message)])
    }
    let account = envelope.data?.viewer.accounts.first
    let points = (account?.current ?? []).map {
      StorageAnalyticsPoint(date: $0.dimensions.date, requests: $0.sum.requests)
    }
    let total = points.reduce(0) { $0 + $1.requests }
    let previousTotal = account?.previous.map { rows in
      rows.reduce(0) { $0 + $1.sum.requests }
    }
    return StorageAnalyticsSummary(
      days: window,
      totalRequests: total,
      previousTotalRequests: previousTotal,
      points: points)
  }

  private func decodeDNSAnalytics(
    query: String,
    mapPoint: (DNSAnalyticsData.Group) -> DNSAnalyticsPoint,
    mapQueryType: Bool
  ) async throws -> DNSAnalyticsSummary {
    let response = try await graphQL(query: query)
    let envelope = try JSONDecoder().decode(
      GraphQLEnvelope<DNSAnalyticsData>.self, from: response)
    if let error = envelope.errors?.first {
      throw CloudflareAPIError.request(
        status: error.semanticStatusCode,
        errors: [APIErrorItem(code: 0, message: error.message)])
    }
    let zone = envelope.data?.viewer.zones.first
    let points = (zone?.current ?? []).map(mapPoint).filter { !$0.datetime.isEmpty }
    let total = points.reduce(0) { $0 + $1.queries }
    let previousTotal = zone?.previous.map { rows in
      rows.reduce(0) { $0 + $1.count }
    }
    let queryTypes: [DNSAnalyticsBucket]
    if mapQueryType {
      queryTypes = (zone?.queryTypes ?? []).compactMap { group in
        guard
          let label = group.dimensions.queryType?.trimmingCharacters(in: .whitespacesAndNewlines),
          !label.isEmpty
        else { return nil }
        return DNSAnalyticsBucket(label: label, count: group.count)
      }
    } else {
      queryTypes = []
    }
    return DNSAnalyticsSummary(
      points: points,
      totalQueries: total,
      previousTotalQueries: previousTotal,
      queryTypes: queryTypes)
  }

  private static func escapeGraphQLString(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
  }
}

// MARK: - Decode shapes

private struct DNSAnalyticsData: Decodable, Sendable {
  let viewer: Viewer
  struct Viewer: Decodable, Sendable { let zones: [Zone] }
  struct Zone: Decodable, Sendable {
    let current: [Group]?
    let previous: [Group]?
    let queryTypes: [Group]?
  }
  struct Group: Decodable, Sendable {
    let count: Int
    let dimensions: Dimensions
    struct Dimensions: Decodable, Sendable {
      let datetimeHour: String?
      let date: String?
      let queryType: String?
    }
  }
}

private struct EmailRoutingAnalyticsData: Decodable, Sendable {
  let viewer: Viewer
  struct Viewer: Decodable, Sendable { let zones: [Zone] }
  struct Zone: Decodable, Sendable {
    let emailRoutingAdaptiveGroups: [Group]
  }
  struct Group: Decodable, Sendable {
    let count: Int
    let dimensions: Dimensions
    struct Dimensions: Decodable, Sendable { let datetimeHour: String }
  }
}

private struct StorageOperationsAnalyticsData: Decodable, Sendable {
  let viewer: Viewer
  struct Viewer: Decodable, Sendable { let accounts: [Account] }
  struct Account: Decodable, Sendable {
    let current: [Group]?
    let previous: [Group]?
  }
  struct Group: Decodable, Sendable {
    let sum: Sum
    let dimensions: Dimensions
    struct Sum: Decodable, Sendable { let requests: Int }
    struct Dimensions: Decodable, Sendable { let date: String }
  }
}
