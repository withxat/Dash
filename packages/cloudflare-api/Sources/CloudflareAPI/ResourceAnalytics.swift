import Foundation

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

// MARK: - Client

extension CloudflareClient {
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
}

// MARK: - Decode shapes

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
