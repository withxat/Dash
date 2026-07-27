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
}

@Test func webMetricsSplitCurrentAndPreviousWindowsWithDeltas() {
  // window = 2: the two most recent UTC days are the current window, the two
  // before them the comparison window. `now` is fixed so the split is stable.
  let now = ISO8601DateFormatter().date(from: "2026-07-24T12:00:00Z")!
  let days = [
    RUMDailyMetrics(date: "2026-07-21", pageviews: 10, visits: 4, pageLoadTimeP50Ms: 500),
    RUMDailyMetrics(date: "2026-07-22", pageviews: 20, visits: 6, pageLoadTimeP50Ms: 700),
    RUMDailyMetrics(date: "bad-date", pageviews: 999, visits: 999, pageLoadTimeP50Ms: 999),
    RUMDailyMetrics(date: "2026-07-23", pageviews: 30, visits: 10, pageLoadTimeP50Ms: 300),
    RUMDailyMetrics(date: "2026-07-24", pageviews: 40, visits: 12, pageLoadTimeP50Ms: 200),
  ]
  let snapshot = WebAnalyticsChartModel.metrics(from: days, window: 2, now: now)

  #expect(snapshot.hasData)
  // Current window = 07-23 + 07-24; bad date dropped; series ascending.
  #expect(snapshot.pageViews.current == 70)
  #expect(snapshot.visits.current == 22)
  #expect(snapshot.pageViews.series == [30, 40])
  // Previous window = 07-21 + 07-22.
  #expect(snapshot.pageViews.previous == 30)
  #expect(snapshot.pageViews.delta == (70.0 - 30.0) / 30.0)
  // Page-view-weighted median of the daily medians: (300*30 + 200*40) / 70.
  #expect(abs(snapshot.pageLoadTimeMs.current - (300.0 * 30 + 200.0 * 40) / 70) < 0.0001)
  // Lower load time is better, so the drop is an improvement (negative delta).
  #expect((snapshot.pageLoadTimeMs.delta ?? 0) < 0)

  let empty = WebAnalyticsChartModel.metrics(from: [], window: 7, now: now)
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
  #expect(detail.count == 14)
  #expect(detail.allSatisfy { $0.pageviews > 0 && $0.visits > 0 })
}

@Test func chartSnapshotsAreSendable() {
  requireSendable(WatchtowerAnalyticsChartModel.Snapshot.self)
  requireSendable(WatchtowerAnalyticsChartModel.MetricSnapshot.self)
  requireSendable(ZoneAnalyticsSnapshot.self)
  requireSendable(WebAnalyticsMetricsSnapshot.self)
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
