import Foundation

/// Matching buckets for a selected analytics window and the immediately
/// preceding window of the same length.
public struct AnalyticsPeriodComparison<Element: Hashable & Sendable>: Hashable, Sendable {
  public var current: [Element]
  /// Nil when the account can read the selected window but its plan's
  /// retention boundary does not reach the preceding window.
  public var previous: [Element]?

  public init(current: [Element], previous: [Element]? = nil) {
    self.current = current
    self.previous = previous
  }
}

/// One hour bucket of HTTP request totals; `datetime` is an ISO 8601 instant.
public struct ZoneAnalyticsPoint: Codable, Hashable, Sendable {
  public let datetime: String
  public let requests: Int
  public let pageViews: Int
  public let threats: Int
  public let bytes: Int64
  /// Unique visitors in this bucket. Deduplicated per bucket only — summing
  /// across buckets double counts anyone who came back.
  public let uniques: Int
  public let cachedRequests: Int
  public let cachedBytes: Int64

  public init(
    datetime: String, requests: Int, pageViews: Int, threats: Int, bytes: Int64, uniques: Int = 0,
    cachedRequests: Int = 0, cachedBytes: Int64 = 0
  ) {
    self.datetime = datetime
    self.requests = requests
    self.pageViews = pageViews
    self.threats = threats
    self.bytes = bytes
    self.uniques = uniques
    self.cachedRequests = cachedRequests
    self.cachedBytes = cachedBytes
  }
}

public struct ZoneAnalyticsDay: Codable, Hashable, Sendable {
  public let date: String
  public let requests: Int
  public let pageViews: Int
  public let threats: Int
  public let bytes: Int64
  /// Unique visitors that day. Deduplicated per day only — see
  /// ``ZoneAnalyticsPoint/uniques``.
  public let uniques: Int
  public let cachedRequests: Int
  public let cachedBytes: Int64

  public init(
    date: String, requests: Int, pageViews: Int, threats: Int, bytes: Int64, uniques: Int = 0,
    cachedRequests: Int = 0, cachedBytes: Int64 = 0
  ) {
    self.date = date
    self.requests = requests
    self.pageViews = pageViews
    self.threats = threats
    self.bytes = bytes
    self.uniques = uniques
    self.cachedRequests = cachedRequests
    self.cachedBytes = cachedBytes
  }
}

/// One Web Analytics (RUM) site. `ruleset.zoneTag` is what ties a site back to
/// a zone — the site itself is identified only by its own tag.
public struct RUMSite: Codable, Hashable, Identifiable, Sendable {
  public let siteTag: String
  public let siteToken: String?
  public let snippet: String?
  /// True when Cloudflare injects the beacon at the edge for a proxied zone,
  /// so the site needs no snippet in its HTML.
  public let autoInstall: Bool
  public let rules: [RUMRule]?
  public let ruleset: RUMRuleset?

  public var id: String { siteTag }
  public var zoneTag: String? { ruleset?.zoneTag }
  /// Auto-install only counts when the injecting ruleset is switched on.
  public var isCollecting: Bool { !autoInstall || (ruleset?.enabled ?? false) }
  /// Human-readable site identity for account-wide analytics. Zone-backed sites
  /// name themselves through the ruleset; manually installed sites fall back to
  /// the first included host rule instead of exposing an opaque `siteTag`.
  public var analyticsName: String {
    if let name = ruleset?.zoneName, !name.isEmpty { return name }
    if let host = rules?.first(where: {
      $0.inclusive != false && $0.isPaused != true && !($0.host?.isEmpty ?? true)
    })?.host {
      return host
    }
    if let host = rules?.first(where: { !($0.host?.isEmpty ?? true) })?.host {
      return host
    }
    return siteTag
  }

  public init(
    siteTag: String, siteToken: String? = nil, snippet: String? = nil, autoInstall: Bool = false,
    rules: [RUMRule]? = nil, ruleset: RUMRuleset? = nil
  ) {
    self.siteTag = siteTag
    self.siteToken = siteToken
    self.snippet = snippet
    self.autoInstall = autoInstall
    self.rules = rules
    self.ruleset = ruleset
  }

  private enum CodingKeys: String, CodingKey {
    case siteTag = "site_tag"
    case siteToken = "site_token"
    case snippet
    case autoInstall = "auto_install"
    case rules
    case ruleset
  }
}

public struct RUMRule: Codable, Hashable, Sendable {
  public let host: String?
  public let inclusive: Bool?
  public let isPaused: Bool?

  public init(host: String? = nil, inclusive: Bool? = nil, isPaused: Bool? = nil) {
    self.host = host
    self.inclusive = inclusive
    self.isPaused = isPaused
  }

  private enum CodingKeys: String, CodingKey {
    case host, inclusive
    case isPaused = "is_paused"
  }
}

public struct RUMRuleset: Codable, Hashable, Sendable {
  public let id: String?
  public let zoneTag: String?
  public let zoneName: String?
  public let enabled: Bool

  public init(id: String? = nil, zoneTag: String? = nil, zoneName: String? = nil, enabled: Bool) {
    self.id = id
    self.zoneTag = zoneTag
    self.zoneName = zoneName
    self.enabled = enabled
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case zoneTag = "zone_tag"
    case zoneName = "zone_name"
    case enabled
  }
}

/// One bucket of RUM page loads. `count` is beacon-reported page loads — a
/// different measurement from the edge's HTML-response `pageViews`.
public struct RUMPageviewsDay: Codable, Hashable, Sendable {
  public let date: String
  public let pageviews: Int

  public init(date: String, pageviews: Int) {
    self.date = date
    self.pageviews = pageviews
  }
}

/// One day of Web Analytics (RUM) beacon metrics for a site. `pageviews` and
/// `visits` both come from the pageload dataset — the only one this endpoint
/// queries. Page-load time and Core Web Vitals are deliberately absent: the
/// screen dropped both, and with them the only reason to query the performance
/// and web-vitals datasets at all.
public struct RUMDailyMetrics: Codable, Hashable, Sendable {
  public let date: String
  public let pageviews: Int
  public let visits: Int

  public init(date: String, pageviews: Int, visits: Int) {
    self.date = date
    self.pageviews = pageviews
    self.visits = visits
  }
}

/// Two adjacent complete-day Web Analytics windows. `days` contains the daily
/// buckets for both windows, so the caller splits the current period from its
/// comparison by date without a second request.
///
/// There are no whole-window totals here any more: they existed for page-load
/// time and Core Web Vitals, the two metrics whose exact p50 / p75 could not be
/// re-derived by averaging daily quantiles. Both are gone from the screen, and
/// page views and visits simply sum.
public struct RUMMetricsComparison: Codable, Hashable, Sendable {
  public let days: [RUMDailyMetrics]

  public init(days: [RUMDailyMetrics]) {
    self.days = days
  }
}

/// One hourly blocked-count bucket from `firewallEventsAdaptiveByTimeGroups`.
public struct FirewallEventsSeriesPoint: Codable, Hashable, Identifiable, Sendable {
  public var id: String { datetime }
  public let datetime: String
  public let count: Int

  public init(datetime: String, count: Int) {
    self.datetime = datetime
    self.count = count
  }
}

/// Aggregated firewall / WAF activity for a zone over a short window.
///
/// `blocked` and `series` come from Free-friendly
/// `firewallEventsAdaptiveByTimeGroups`. Country / rule tops are rolled up from
/// a bounded `firewallEventsAdaptive` sample (Groups stays plan-gated).
public struct FirewallEventsSummary: Codable, Hashable, Sendable {
  public let hours: Int
  public let blocked: Int
  public let series: [FirewallEventsSeriesPoint]
  public let countries: [FirewallEventsBucket]
  public let rules: [FirewallEventsBucket]

  public init(
    hours: Int, blocked: Int, series: [FirewallEventsSeriesPoint] = [],
    countries: [FirewallEventsBucket] = [],
    rules: [FirewallEventsBucket] = []
  ) {
    self.hours = hours
    self.blocked = blocked
    self.series = series
    self.countries = countries
    self.rules = rules
  }
}

public struct FirewallEventsBucket: Codable, Hashable, Identifiable, Sendable {
  public var id: String { label }
  public let label: String
  public let count: Int

  public init(label: String, count: Int) {
    self.label = label
    self.count = count
  }
}

private struct ZoneAnalyticsData: Decodable, Sendable {
  let viewer: Viewer

  struct Viewer: Decodable, Sendable { let zones: [Zone] }
  struct Zone: Decodable, Sendable {
    let current: [Group]?
    let previous: [Group]?
    /// Response key used by the single-window query.
    let httpRequests1dGroups: [Group]?
  }
  struct Group: Decodable, Sendable {
    let dimensions: Dimensions
    let sum: Sum
    // Optional so a response without the uniq block still decodes.
    let uniq: Uniq?

    struct Dimensions: Decodable, Sendable { let date: String }
    struct Sum: Decodable, Sendable {
      let requests: Int
      let pageViews: Int
      let threats: Int
      let bytes: Int64
      let cachedRequests: Int?
      let cachedBytes: Int64?
    }
    struct Uniq: Decodable, Sendable { let uniques: Int }
  }
}
private struct RUMPageviewsData: Decodable, Sendable {
  let viewer: Viewer

  struct Viewer: Decodable, Sendable { let accounts: [Account] }
  struct Account: Decodable, Sendable { let rumPageloadEventsAdaptiveGroups: [Group] }
  struct Group: Decodable, Sendable {
    let count: Int
    let dimensions: Dimensions

    struct Dimensions: Decodable, Sendable { let date: String }
  }
}
private struct RUMMetricsData: Decodable, Sendable {
  let viewer: Viewer

  struct Viewer: Decodable, Sendable { let accounts: [Account] }
  struct Account: Decodable, Sendable {
    let pageload: [PageloadGroup]
  }
  struct DateDimension: Decodable, Sendable { let date: String }
  struct PageloadGroup: Decodable, Sendable {
    let count: Int
    let sum: Sum
    let dimensions: DateDimension

    struct Sum: Decodable, Sendable { let visits: Int }
  }
}
private struct ZoneAnalyticsHourlyData: Decodable, Sendable {
  let viewer: Viewer

  struct Viewer: Decodable, Sendable { let zones: [Zone] }
  struct Zone: Decodable, Sendable {
    let current: [Group]?
    let previous: [Group]?
  }
  struct Group: Decodable, Sendable {
    let dimensions: Dimensions
    let sum: Sum
    let uniq: Uniq?

    struct Dimensions: Decodable, Sendable { let datetime: String }
    struct Sum: Decodable, Sendable {
      let requests: Int
      let pageViews: Int
      let threats: Int
      let bytes: Int64
      let cachedRequests: Int?
      let cachedBytes: Int64?
    }
    struct Uniq: Decodable, Sendable { let uniques: Int }
  }
}
private struct ZoneRequestsHourlyData: Decodable, Sendable {
  let viewer: Viewer

  struct Viewer: Decodable, Sendable { let zones: [Zone] }
  struct Zone: Decodable, Sendable { let httpRequestsAdaptiveGroups: [Group] }
  struct Group: Decodable, Sendable {
    let count: Int
    let dimensions: Dimensions

    struct Dimensions: Decodable, Sendable { let datetimeHour: String }
  }
}

private struct FirewallEventsSummaryData: Decodable, Sendable {
  let viewer: Viewer

  struct Viewer: Decodable, Sendable { let zones: [Zone] }
  struct Zone: Decodable, Sendable {
    let byTime: [ByTimeGroup]?
    let samples: [FirewallAdaptiveEvent]?
  }
  struct ByTimeGroup: Decodable, Sendable {
    let count: Int
    let dimensions: Dimensions
    struct Dimensions: Decodable, Sendable { let datetimeHour: String }
  }
}

struct FirewallAdaptiveEvent: Decodable, Hashable, Sendable {
  let clientCountryName: String?
  let ruleId: String?

  init(clientCountryName: String? = nil, ruleId: String? = nil) {
    self.clientCountryName = clientCountryName
    self.ruleId = ruleId
  }
}

extension CloudflareClient {
  /// Daily HTTP request totals for a zone via the GraphQL Analytics API —
  /// the REST zone-analytics endpoints no longer exist.
  public func zoneAnalytics(zoneID: String, days: Int = 7) async throws -> [ZoneAnalyticsDay] {
    let bounds = Self.zoneAnalyticsDailyBounds(days: days)
    let query = """
      { viewer { zones(filter: {zoneTag: "\(zoneID)"}) { \
      httpRequests1dGroups(limit: \(bounds.window), \
      filter: {date_geq: "\(bounds.currentStart)", \
      date_lt: "\(bounds.end)"}, orderBy: [date_DESC]) { \
      dimensions { date } sum { requests pageViews threats bytes cachedRequests cachedBytes } \
      uniq { uniques } } } } }
      """
    let payload = try JSONEncoder().encode(["query": query])
    let response = try await graphQLRaw(payload)
    let envelope = try JSONDecoder().decode(
      GraphQLEnvelope<ZoneAnalyticsData>.self, from: response)
    if let error = envelope.errors?.first {
      throw CloudflareAPIError.request(
        status: error.semanticStatusCode,
        errors: [APIErrorItem(code: 0, message: error.message)])
    }
    let rows =
      envelope.data?.viewer.zones.first?.httpRequests1dGroups
      ?? envelope.data?.viewer.zones.first?.current
      ?? []
    return mapZoneAnalyticsDays(rows)
  }

  /// Daily HTTP totals for the selected window and its immediately preceding
  /// equal window. Both series normally arrive in one GraphQL request. If the
  /// account's retention limit rejects only the older window, the current
  /// window remains available and the comparison is omitted.
  public func zoneAnalyticsComparison(zoneID: String, days: Int = 7) async throws
    -> AnalyticsPeriodComparison<ZoneAnalyticsDay>
  {
    let bounds = Self.zoneAnalyticsDailyBounds(days: days)
    let query = """
      { viewer { zones(filter: {zoneTag: "\(zoneID)"}) { \
      current: httpRequests1dGroups(limit: \(bounds.window), \
      filter: {date_geq: "\(bounds.currentStart)", \
      date_lt: "\(bounds.end)"}, orderBy: [date_DESC]) { \
      dimensions { date } sum { requests pageViews threats bytes cachedRequests cachedBytes } \
      uniq { uniques } } \
      previous: httpRequests1dGroups(limit: \(bounds.window), \
      filter: {date_geq: "\(bounds.previousStart)", \
      date_lt: "\(bounds.currentStart)"}, orderBy: [date_DESC]) { \
      dimensions { date } sum { requests pageViews threats bytes cachedRequests cachedBytes } \
      uniq { uniques } } } } }
      """
    let payload = try JSONEncoder().encode(["query": query])
    let response: Data
    do {
      response = try await graphQLRaw(payload)
    } catch let error as CloudflareAPIError {
      guard case .request(let status, _) = error, status == 400 else { throw error }
      return AnalyticsPeriodComparison(
        current: try await zoneAnalytics(zoneID: zoneID, days: days),
        previous: nil)
    }
    let envelope = try JSONDecoder().decode(
      GraphQLEnvelope<ZoneAnalyticsData>.self, from: response)
    if envelope.errors?.first != nil {
      if let currentRows = envelope.data?.viewer.zones.first?.current {
        return AnalyticsPeriodComparison(
          current: mapZoneAnalyticsDays(currentRows),
          previous: nil)
      }
      // Some GraphQL validation failures null the whole aliased document
      // before execution. Retry only the current window so an unavailable
      // older comparison cannot blank an otherwise readable chart.
      return AnalyticsPeriodComparison(
        current: try await zoneAnalytics(zoneID: zoneID, days: days),
        previous: nil)
    }
    let zone = envelope.data?.viewer.zones.first
    let currentRows = zone?.current ?? []
    return AnalyticsPeriodComparison(
      current: mapZoneAnalyticsDays(currentRows),
      previous: zone?.previous.map(mapZoneAnalyticsDays))
  }

  static func zoneAnalyticsDailyBounds(days: Int, now: Date = Date()) -> (
    window: Int,
    previousStart: String,
    currentStart: String,
    end: String
  ) {
    let window = max(days, 1)
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
    // Daily groups cannot represent a partial day. Compare the last complete
    // UTC days with the equally long block immediately before them.
    let end = calendar.startOfDay(for: now)
    let currentStart = calendar.date(byAdding: .day, value: -window, to: end)!
    let previousStart = calendar.date(byAdding: .day, value: -window, to: currentStart)!
    return (
      window,
      formatter.string(from: previousStart),
      formatter.string(from: currentStart),
      formatter.string(from: end)
    )
  }

  private func mapZoneAnalyticsDays(
    _ rows: [ZoneAnalyticsData.Group]
  ) -> [ZoneAnalyticsDay] {
    rows.map {
      ZoneAnalyticsDay(
        date: $0.dimensions.date,
        requests: $0.sum.requests,
        pageViews: $0.sum.pageViews,
        threats: $0.sum.threats,
        bytes: $0.sum.bytes,
        uniques: $0.uniq?.uniques ?? 0,
        cachedRequests: $0.sum.cachedRequests ?? 0,
        cachedBytes: $0.sum.cachedBytes ?? 0)
    }
  }

  /// Every Web Analytics site on the account. The list is the only way to map
  /// a zone to its `siteTag`, so callers cache it per account.
  public func webAnalyticsSites(accountID: String) async throws -> [RUMSite] {
    try await listAllPages(
      "/accounts/\(accountID)/rum/site_info/list", perPage: 50)
  }

  /// Daily beacon-reported page loads for one RUM site, ascending. This is the
  /// Web Analytics number, not the edge's HTML-response count.
  public func webAnalyticsPageviews(siteTag: String, days: Int = 7) async throws
    -> [RUMPageviewsDay]
  {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(identifier: "UTC")
    let until = Date()
    let since = until.addingTimeInterval(-TimeInterval(max(days - 1, 0)) * 86400)
    let query = """
      { viewer { accounts { \
      rumPageloadEventsAdaptiveGroups(limit: \(max(days, 1)), \
      filter: {siteTag: "\(siteTag)", \
      datetime_geq: "\(formatter.string(from: since))", \
      datetime_leq: "\(formatter.string(from: until))"}, orderBy: [date_ASC]) { \
      count dimensions { date } } } } }
      """
    let response = try await graphQLRaw(try JSONEncoder().encode(["query": query]))
    let envelope = try JSONDecoder().decode(
      GraphQLEnvelope<RUMPageviewsData>.self, from: response)
    if let error = envelope.errors?.first {
      throw CloudflareAPIError.request(
        status: error.semanticStatusCode,
        errors: [APIErrorItem(code: 0, message: error.message)])
    }
    return (envelope.data?.viewer.accounts.first?.rumPageloadEventsAdaptiveGroups ?? []).map {
      RUMPageviewsDay(date: $0.dimensions.date, pageviews: $0.count)
    }
  }

  /// Web Analytics metrics for one RUM site — page views and visits from
  /// `rumPageloadEventsAdaptiveGroups`, which is the only dataset queried.
  /// `rumPerformanceEventsAdaptiveGroups` (page-load time) and
  /// `rumWebVitalsEventsAdaptiveGroups` (LCP / INP / CLS) are deliberately NOT
  /// queried: both metrics were removed from the screen, and querying them again
  /// would pay for numbers nothing reads.
  ///
  /// The dataset is account-scoped, so the account is selected by `accountTag`
  /// and the site by `siteTag`. Daily buckets span two adjacent complete UTC-day
  /// windows and are ascending by date, which is what lets one request serve both
  /// the current period and its comparison.
  public func webAnalyticsMetrics(accountID: String, siteTag: String, days: Int = 7) async throws
    -> RUMMetricsComparison
  {
    let window = max(days, 1)
    let span = window * 2
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(identifier: "UTC")
    let bounds = webAnalyticsComparisonWindow(days: window)
    let dailyFilter =
      "{siteTag: \"\(siteTag)\", "
      + "datetime_geq: \"\(formatter.string(from: bounds.start))\", "
      + "datetime_lt: \"\(formatter.string(from: bounds.end))\"}"
    let query = """
      { viewer { accounts(filter: {accountTag: "\(accountID)"}) { \
      pageload: rumPageloadEventsAdaptiveGroups(limit: \(span), \
      filter: \(dailyFilter), orderBy: [date_ASC]) { \
      count sum { visits } dimensions { date } } } } }
      """
    let response = try await graphQLRaw(try JSONEncoder().encode(["query": query]))
    let envelope = try JSONDecoder().decode(
      GraphQLEnvelope<RUMMetricsData>.self, from: response)
    if let error = envelope.errors?.first {
      throw CloudflareAPIError.request(
        status: error.semanticStatusCode,
        errors: [APIErrorItem(code: 0, message: error.message)])
    }
    guard let account = envelope.data?.viewer.accounts.first else {
      return RUMMetricsComparison(days: [])
    }
    return RUMMetricsComparison(
      days: account.pageload.map { group in
        RUMDailyMetrics(
          date: group.dimensions.date,
          pageviews: group.count,
          visits: group.sum.visits)
      })
  }

  /// The single-site detail uses complete UTC days so a partial today never
  /// makes the current period look artificially lower than its comparison. One
  /// filter spans both windows — the caller splits them by date.
  private func webAnalyticsComparisonWindow(days: Int, now: Date = Date()) -> (
    start: Date, end: Date
  ) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
    let window = max(days, 1)
    let end = calendar.startOfDay(for: now)
    let currentStart = calendar.date(byAdding: .day, value: -window, to: end) ?? end
    let start = calendar.date(byAdding: .day, value: -window, to: currentStart) ?? currentStart
    return (start: start, end: end)
  }

  /// Hourly HTTP request totals via the GraphQL `httpRequests1hGroups`
  /// dataset. Returned ascending so charts can plot it directly.
  public func zoneAnalyticsHourly(zoneID: String, hours: Int = 24) async throws
    -> [ZoneAnalyticsPoint]
  {
    try await zoneAnalyticsHourlyComparison(zoneID: zoneID, hours: hours).current
  }

  /// Hourly HTTP totals for adjacent equal windows, returned ascending within
  /// each period and fetched through two aliases in one GraphQL document.
  public func zoneAnalyticsHourlyComparison(zoneID: String, hours: Int = 24) async throws
    -> AnalyticsPeriodComparison<ZoneAnalyticsPoint>
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
      current: httpRequests1hGroups(limit: \(window + 1), \
      filter: {datetime_geq: "\(currentStartStamp)", \
      datetime_lt: "\(endStamp)"}, orderBy: [datetime_ASC]) { \
      dimensions { datetime } sum { requests pageViews threats bytes cachedRequests cachedBytes } \
      uniq { uniques } } \
      previous: httpRequests1hGroups(limit: \(window + 1), \
      filter: {datetime_geq: "\(previousStartStamp)", \
      datetime_lt: "\(currentStartStamp)"}, orderBy: [datetime_ASC]) { \
      dimensions { datetime } sum { requests pageViews threats bytes cachedRequests cachedBytes } \
      uniq { uniques } } } } }
      """
    let payload = try JSONEncoder().encode(["query": query])
    let response = try await graphQLRaw(payload)
    let envelope = try JSONDecoder().decode(
      GraphQLEnvelope<ZoneAnalyticsHourlyData>.self, from: response)
    if let error = envelope.errors?.first {
      throw CloudflareAPIError.request(
        status: error.semanticStatusCode,
        errors: [APIErrorItem(code: 0, message: error.message)])
    }
    let zone = envelope.data?.viewer.zones.first
    let currentRows = zone?.current ?? []
    func map(_ rows: [ZoneAnalyticsHourlyData.Group]) -> [ZoneAnalyticsPoint] {
      rows.map {
        ZoneAnalyticsPoint(
          datetime: $0.dimensions.datetime, requests: $0.sum.requests,
          pageViews: $0.sum.pageViews,
          threats: $0.sum.threats, bytes: $0.sum.bytes, uniques: $0.uniq?.uniques ?? 0,
          cachedRequests: $0.sum.cachedRequests ?? 0, cachedBytes: $0.sum.cachedBytes ?? 0)
      }
    }
    return AnalyticsPeriodComparison(
      current: map(currentRows),
      previous: zone?.previous.map(map))
  }

  /// Blocked firewall events for the last `hours`, with hourly series plus
  /// country / rule tops. Requires `analytics.read`.
  ///
  /// Totals and the time series come from Free-enabled
  /// `firewallEventsAdaptiveByTimeGroups`. Top countries / rules still need
  /// dimensions that ByTimeGroups does not expose on Free, so a bounded
  /// `firewallEventsAdaptive` sample fills those lists. Extended
  /// `firewallEventsAdaptiveGroups` stays unused — it is disabled on Free.
  public func firewallEventsSummary(zoneID: String, hours: Int = 24) async throws
    -> FirewallEventsSummary
  {
    let window = max(hours, 1)
    let bounds = Self.firewallEventsTimeBounds(hours: window)
    // Security Events caps the page at 10_000; stay under that so the request
    // itself does not fail for page size while still covering a busy hour of
    // Bot Fight Mode samples.
    let pageLimit = 2500
    let filter =
      "{datetime_geq: \"\(bounds.since)\", datetime_leq: \"\(bounds.until)\", action: \"block\"}"
    let query = """
      { viewer { zones(filter: {zoneTag: "\(zoneID)"}) { \
      byTime: firewallEventsAdaptiveByTimeGroups(limit: \(window + 1), \
      filter: \(filter), orderBy: [datetimeHour_ASC]) { \
      count dimensions { datetimeHour } } \
      samples: firewallEventsAdaptive(limit: \(pageLimit), \
      filter: \(filter), orderBy: [datetime_DESC]) { \
      clientCountryName ruleId } } } }
      """
    let payload = try JSONEncoder().encode(["query": query])
    let response = try await graphQLRaw(payload)
    let envelope = try JSONDecoder().decode(
      GraphQLEnvelope<FirewallEventsSummaryData>.self, from: response)
    if let error = envelope.errors?.first {
      throw CloudflareAPIError.request(
        status: error.semanticStatusCode,
        errors: [APIErrorItem(code: 0, message: error.message)])
    }
    let zone = envelope.data?.viewer.zones.first
    let series = (zone?.byTime ?? []).map {
      FirewallEventsSeriesPoint(datetime: $0.dimensions.datetimeHour, count: $0.count)
    }
    let blocked = series.reduce(0) { $0 + $1.count }
    let tops = Self.firewallAdaptiveTopBuckets(zone?.samples ?? [])
    return FirewallEventsSummary(
      hours: window,
      blocked: blocked,
      series: series,
      countries: tops.countries,
      rules: tops.rules)
  }

  static func firewallEventsTimeBounds(
    hours: Int, now: Date = Date()
  ) -> (since: String, until: String) {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(identifier: "UTC")
    let until = now
    let since = until.addingTimeInterval(-TimeInterval(max(hours, 1)) * 3600)
    return (formatter.string(from: since), formatter.string(from: until))
  }

  static func firewallAdaptiveTopBuckets(
    _ events: [FirewallAdaptiveEvent],
    countryLimit: Int = 8,
    ruleLimit: Int = 8
  ) -> (countries: [FirewallEventsBucket], rules: [FirewallEventsBucket]) {
    var countries: [String: Int] = [:]
    var rules: [String: Int] = [:]
    for event in events {
      if let country = event.clientCountryName?.trimmingCharacters(in: .whitespacesAndNewlines),
        !country.isEmpty
      {
        countries[country, default: 0] += 1
      }
      if let rule = event.ruleId?.trimmingCharacters(in: .whitespacesAndNewlines), !rule.isEmpty {
        rules[rule, default: 0] += 1
      }
    }
    return (
      countries: topFirewallBuckets(countries, limit: countryLimit),
      rules: topFirewallBuckets(rules, limit: ruleLimit)
    )
  }

  private static func topFirewallBuckets(_ counts: [String: Int], limit: Int)
    -> [FirewallEventsBucket]
  {
    counts
      .map { FirewallEventsBucket(label: $0.key, count: $0.value) }
      .sorted {
        if $0.count != $1.count { return $0.count > $1.count }
        return $0.label < $1.label
      }
      .prefix(max(limit, 0))
      .map { $0 }
  }

  /// Hourly request counts from the adaptive HTTP Traffic dataset available to
  /// every plan. Paid-only metrics such as page views are intentionally omitted.
  public func zoneRequestsHourly(zoneID: String, hours: Int = 24) async throws
    -> [ZoneAnalyticsPoint]
  {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(identifier: "UTC")
    let until = Date()
    let since = until.addingTimeInterval(-TimeInterval(max(hours, 1)) * 3600)
    let query = """
      { viewer { zones(filter: {zoneTag: "\(zoneID)"}) { \
      httpRequestsAdaptiveGroups(limit: \(hours + 1), \
      filter: {datetime_geq: "\(formatter.string(from: since))", \
      datetime_leq: "\(formatter.string(from: until))", requestSource: "eyeball"}, \
      orderBy: [datetimeHour_ASC]) { count dimensions { datetimeHour } } } } }
      """
    let payload = try JSONEncoder().encode(["query": query])
    let response = try await graphQLRaw(payload)
    let envelope = try JSONDecoder().decode(
      GraphQLEnvelope<ZoneRequestsHourlyData>.self, from: response)
    if let error = envelope.errors?.first {
      throw CloudflareAPIError.request(
        status: error.semanticStatusCode,
        errors: [APIErrorItem(code: 0, message: error.message)])
    }
    return (envelope.data?.viewer.zones.first?.httpRequestsAdaptiveGroups ?? []).map {
      ZoneAnalyticsPoint(
        datetime: $0.dimensions.datetimeHour,
        requests: $0.count,
        pageViews: 0,
        threats: 0,
        bytes: 0)
    }
  }
}
