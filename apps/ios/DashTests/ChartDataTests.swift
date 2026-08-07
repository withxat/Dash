import CloudflareAPI
import Foundation
import Testing

@testable import Dash

@Test func watchtowerChartSnapshotNormalizesOnceWithStableAscendingIdentity() throws {
  let raw = AccountAnalyticsSnapshot(
    overview: emptyAccountOverview,
    httpPoints: [
      AccountAnalyticsPoint(datetime: "2026-07-24T10:00:00Z", requests: 30),
      AccountAnalyticsPoint(datetime: "not-a-date", requests: 99),
      AccountAnalyticsPoint(datetime: "2026-07-24T08:00:00Z", requests: 10),
      AccountAnalyticsPoint(datetime: "2026-07-24T10:00:00Z", requests: 40),
    ],
    workerPoints: [])

  let snapshot = WatchtowerAnalyticsChartModel.snapshot(
    from: raw,
    range: .day,
    locale: Locale(identifier: "en_US"))
  let traffic = try #require(snapshot.charts[.webTraffic])

  #expect(
    traffic.expandedData.map(\.id) == [
      "2026-07-24T08:00:00Z",
      "2026-07-24T10:00:00Z",
      "2026-07-24T10:00:00Z#1",
    ])
  #expect(traffic.expandedData.map { $0["webTraffic"] } == [10, 30, 40])
  #expect(traffic.collapsedData.map(\.id) == traffic.expandedData.map(\.id))
  // There is no synthetic 09:00 bucket: API gaps remain gaps.
  #expect(traffic.expandedData.count == 3)
  #expect(traffic.tableLabels.count == traffic.expandedData.count)
}

@Test func watchtowerDetailLabelsDisambiguateMatchingHoursAcrossDays() throws {
  let raw = AccountAnalyticsSnapshot(
    overview: emptyAccountOverview,
    httpPoints: [
      AccountAnalyticsPoint(datetime: "2026-07-23T08:00:00Z", requests: 10),
      AccountAnalyticsPoint(datetime: "2026-07-24T08:00:00Z", requests: 20),
    ],
    workerPoints: [])

  let snapshot = WatchtowerAnalyticsChartModel.snapshot(
    from: raw,
    range: .week,
    locale: Locale(identifier: "en_US"))
  let traffic = try #require(snapshot.charts[.webTraffic])

  #expect(traffic.expandedData[0].label == traffic.expandedData[1].label)
  #expect(traffic.tableLabels.count == 2)
  #expect(traffic.tableLabels[0] != traffic.tableLabels[1])
  #expect(traffic.tableLabels.allSatisfy { $0.contains("Jul") })
}

@Test func watchtowerEmptySeriesKeepsTheExistingQuietChartSemantics() throws {
  let raw = AccountAnalyticsSnapshot(
    overview: emptyAccountOverview,
    httpPoints: [],
    workerPoints: [])
  let snapshot = WatchtowerAnalyticsChartModel.snapshot(
    from: raw,
    range: .month,
    locale: Locale(identifier: "en_US"))
  let traffic = try #require(snapshot.charts[.webTraffic])

  #expect(traffic.isEmpty)
  #expect(traffic.expandedData.isEmpty)
  #expect(traffic.collapsedData.isEmpty)
  #expect(traffic.collapsedValueCeiling == 1)
}

@Test func zoneChartSnapshotPrecomputesTotalsAndAlignedSeriesWithoutFillingGaps() {
  let points = ZoneAnalyticsChartModel.points(fromDaily: [
    ZoneAnalyticsDay(
      date: "2026-07-03", requests: 30, pageViews: 3, threats: 2, bytes: 300,
      uniques: 8, cachedRequests: 12),
    ZoneAnalyticsDay(date: "bad-date", requests: 99, pageViews: 9, threats: 9, bytes: 999),
    ZoneAnalyticsDay(
      date: "2026-07-01", requests: 10, pageViews: 1, threats: 1, bytes: 100,
      uniques: 4, cachedRequests: 6),
  ])
  let snapshot = ZoneAnalyticsChartModel.snapshot(
    points: points,
    range: .week,
    locale: Locale(identifier: "en_US"))

  #expect(snapshot.points.map(\.requests) == [10, 30])
  #expect(snapshot.requestsData.count == 2)
  #expect(snapshot.requestsData.map(\.id) == snapshot.visitorsData.map(\.id))
  #expect(snapshot.requestsData.map(\.id) == snapshot.bandwidthData.map(\.id))
  #expect(snapshot.totalRequests == 40)
  #expect(snapshot.totalThreats == 3)
  #expect(snapshot.totalCachedRequests == 18)
  #expect(snapshot.totalBytes == 400)
  #expect(snapshot.peakUniques == 8)

  let empty = ZoneAnalyticsChartModel.snapshot(
    points: [],
    range: .week,
    locale: Locale(identifier: "en_US"))
  #expect(empty.isEmpty)
  #expect(empty.requestsData.isEmpty)
  #expect(empty.totalRequests == 0)
  #expect(empty.totalBytes == 0)
  #expect(empty.previousTotalRequests == nil)
  #expect(empty.previousTotalBytes == nil)
  #expect(empty.previousPeakUniques == nil)
}

@Test func zoneChartSnapshotKeepsPreviousTotalsAndFullDetailDates() {
  let current = ZoneAnalyticsChartModel.points(fromDaily: [
    ZoneAnalyticsDay(
      date: "2026-07-23", requests: 30, pageViews: 3, threats: 2, bytes: 300,
      uniques: 8, cachedRequests: 12),
    ZoneAnalyticsDay(
      date: "2026-07-24", requests: 40, pageViews: 4, threats: 1, bytes: 400,
      uniques: 6, cachedRequests: 18),
  ])
  let previous = ZoneAnalyticsChartModel.points(fromDaily: [
    ZoneAnalyticsDay(
      date: "2026-07-21", requests: 5, pageViews: 1, threats: 0, bytes: 50,
      uniques: 4, cachedRequests: 2),
    ZoneAnalyticsDay(
      date: "2026-07-22", requests: 7, pageViews: 2, threats: 1, bytes: 70,
      uniques: 9, cachedRequests: 3),
  ])
  let snapshot = ZoneAnalyticsChartModel.snapshot(
    points: current,
    previousPoints: previous,
    range: .week,
    locale: Locale(identifier: "en_US"))

  #expect(snapshot.previousTotalRequests == 12)
  #expect(snapshot.previousTotalBytes == 120)
  #expect(snapshot.previousPeakUniques == 9)

  let labels = current.map {
    ZoneAnalyticsChartModel.detailLabel(
      $0.date,
      range: .week,
      locale: Locale(identifier: "en_US"))
  }
  #expect(labels.count == 2)
  #expect(labels[0] != labels[1])
  #expect(labels.allSatisfy { $0.contains("2026") })
}

@Test func chartTrendCoversMissingRisingFallingFlatAndZeroBaselines() throws {
  #expect(DashChartTrend(current: 120, previous: nil) == nil)

  let rising = try #require(
    DashChartTrend(current: 120, previous: 100, polarity: .higherIsBetter))
  #expect(rising.direction == .up)
  #expect(abs((rising.percentChange ?? 0) - 0.2) < 0.000_001)
  #expect(rising.polarity == .higherIsBetter)

  let falling = try #require(
    DashChartTrend(current: 80, previous: 100, polarity: .lowerIsBetter))
  #expect(falling.direction == .down)
  #expect(abs((falling.percentChange ?? 0) + 0.2) < 0.000_001)
  #expect(falling.polarity == .lowerIsBetter)

  let flat = try #require(DashChartTrend(current: 100, previous: 100))
  #expect(flat.direction == .flat)
  #expect(flat.percentChange == 0)

  let risingFromZero = try #require(DashChartTrend(current: 5, previous: 0))
  #expect(risingFromZero.direction == .up)
  #expect(risingFromZero.percentChange == nil)

  let allZero = try #require(DashChartTrend(current: 0, previous: 0))
  #expect(allZero.direction == .flat)
  #expect(allZero.percentChange == 0)
}

@Test func chartTrendColorConventionFollowsLanguage() {
  #expect(
    DashChartTrendColorConvention.resolved(locale: Locale(identifier: "zh-Hans"))
      == .redUpGreenDown)
  #expect(
    DashChartTrendColorConvention.resolved(locale: Locale(identifier: "zh-Hant-TW"))
      == .redUpGreenDown)
  #expect(
    DashChartTrendColorConvention.resolved(locale: Locale(identifier: "en"))
      == .greenUpRedDown)
}

@Test func webMetricsUseCompleteUTCWindows() {
  // window = 2: the two complete UTC days before `now` are current. Today is
  // intentionally present in the fixture and must be excluded.
  let now = ISO8601DateFormatter().date(from: "2026-07-24T12:00:00Z")!
  let days = [
    RUMDailyMetrics(date: "2026-07-20", pageviews: 10, visits: 4),
    RUMDailyMetrics(date: "2026-07-21", pageviews: 20, visits: 6),
    RUMDailyMetrics(date: "bad-date", pageviews: 999, visits: 999),
    RUMDailyMetrics(date: "2026-07-22", pageviews: 30, visits: 10),
    RUMDailyMetrics(date: "2026-07-23", pageviews: 40, visits: 12),
    RUMDailyMetrics(date: "2026-07-24", pageviews: 900, visits: 400),
  ]
  let snapshot = WebAnalyticsChartModel.metrics(
    from: RUMMetricsComparison(days: days), window: 2, now: now)

  #expect(snapshot.hasData)
  // Current window = 07-22 + 07-23; bad date and partial 07-24 dropped.
  #expect(snapshot.pageViews.current == 70)
  #expect(snapshot.visits.current == 22)
  #expect(snapshot.pageViews.series == [30, 40])
  #expect(
    snapshot.pageViews.points.map { $0.date.ISO8601Format() } == [
      "2026-07-22T00:00:00Z",
      "2026-07-23T00:00:00Z",
    ])
  // Previous window = 07-20 + 07-21.
  #expect(snapshot.pageViews.previous == 30)
  #expect(snapshot.pageViews.delta == (70.0 - 30.0) / 30.0)
  #expect(snapshot.visits.previous == 10)

  let empty = WebAnalyticsChartModel.metrics(
    from: RUMMetricsComparison(days: []), window: 7, now: now)
  #expect(empty.isEmpty)
  #expect(empty.pageViews.delta == nil)
}

@Test func webAnalyticsDomainDestinationUsesDomainReadScopesOnly() {
  let destination = Destination.zoneWebAnalytics("zone")
  #expect(featureID(for: destination) == .zones)
  #expect(readScopes(for: destination) == DashAuthorizationScopes.webAnalytics)
  #expect(writeScopes(for: destination).isEmpty)
}

@Test func demoServesDomainWebAnalyticsDetail() async throws {
  let client = CloudflareClient(
    clientID: "demo", tokenStore: DemoTokenStore(), session: DemoBackend.session)

  let resolvedSites = try await client.webAnalyticsSites(accountID: DemoBackend.accountID)
  #expect(resolvedSites.count >= 5)
  #expect(
    WebAnalyticsChartModel.site(for: "zone-example", in: resolvedSites)?.siteTag == "demo-site")

  let detail = try await client.webAnalyticsMetrics(
    accountID: DemoBackend.accountID, siteTag: "demo-site", days: 7)
  #expect(detail.days.count == 14)
  #expect(detail.days.allSatisfy { $0.pageviews > 0 && $0.visits > 0 })
}

@Test func chartDetailWaitsOnlyForInFlightRangesWithoutSnapshots() {
  // Cold: current window painted, siblings still loading — block the push.
  #expect(
    !DashChartDetail.areSourceRangesSettled(
      expected: AnalyticsRange.allCases,
      loaded: [AnalyticsRange.day],
      loading: [.week, .month]))
  // Warm refresh: last-good snapshots stay open even while ranges reload.
  #expect(
    DashChartDetail.areSourceRangesSettled(
      expected: AnalyticsRange.allCases,
      loaded: AnalyticsRange.allCases,
      loading: Set(AnalyticsRange.allCases)))
  // Settled failure: a missing window that is no longer loading must not lock
  // the chevron forever — the push freezes whatever succeeded.
  #expect(
    DashChartDetail.areSourceRangesSettled(
      expected: AnalyticsRange.allCases,
      loaded: [.day, .week],
      loading: []))
  #expect(
    DashChartDetail.areSourceRangesSettled(
      expected: [AnalyticsRange.week, .month],
      loaded: [.week, .month],
      loading: []))
}

@Test func chartSnapshotsAreSendable() {
  requireSendable(WatchtowerAnalyticsChartModel.Snapshot.self)
  requireSendable(WatchtowerAnalyticsChartModel.MetricSnapshot.self)
  requireSendable(ZoneAnalyticsSnapshot.self)
  requireSendable(WebAnalyticsMetricsSnapshot.self)
  requireSendable(RUMMetricsComparison.self)
}

private let emptyAccountOverview = AccountAnalyticsOverview(
  webRequests: 0,
  bytes: 0,
  cacheRate: 0,
  clientErrorRate: 0,
  encryptedRequestRate: 0,
  encryptedBytes: 0,
  workerInvocations: 0,
  workerErrors: 0,
  cpuTimeP90Us: 0,
  hours: 24)

private func requireSendable<Value: Sendable>(_: Value.Type) {}
