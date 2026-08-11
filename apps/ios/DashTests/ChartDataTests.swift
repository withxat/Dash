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

@Test func zoneDailyChartPreservesCalendarDayAcrossExtremeTimeZones() throws {
  let day = ZoneAnalyticsDay(
    date: "2026-07-03",
    requests: 10,
    pageViews: 1,
    threats: 0,
    bytes: 100,
    uniques: 4)
  let cases = [
    (secondsFromGMT: -8 * 60 * 60, instant: "2026-07-03T08:00:00Z"),
    (secondsFromGMT: 14 * 60 * 60, instant: "2026-07-02T10:00:00Z"),
  ]

  for testCase in cases {
    let timeZone = try #require(TimeZone(secondsFromGMT: testCase.secondsFromGMT))
    let points = ZoneAnalyticsChartModel.points(
      fromDaily: [day],
      timeZone: timeZone)
    let point = try #require(points.first)
    let snapshot = ZoneAnalyticsChartModel.snapshot(
      points: points,
      range: .week,
      locale: Locale(identifier: "en_US"),
      timeZone: timeZone)

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    #expect(calendar.component(.day, from: point.date) == 3)
    #expect(point.date.ISO8601Format() == testCase.instant)
    #expect(snapshot.requestsData.first?.label == "Jul 3")
  }
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

@Test func chartTrendArrowRotatesOneBoldMarkForDown() {
  #expect(DashChartTrendArrowRules.rotationDegrees(for: .up) == 0)
  #expect(DashChartTrendArrowRules.rotationDegrees(for: .down) == 90)
  #expect(DashChartTrendArrowRules.rotationDegrees(for: .flat) == nil)
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

@Test func analyticsChartPointsParseAndSortAscending() {
  let daily = [
    ZoneAnalyticsDay(
      date: "2026-07-14", requests: 3, pageViews: 1, threats: 0, bytes: 30, uniques: 3),
    ZoneAnalyticsDay(
      date: "2026-07-12", requests: 1, pageViews: 0, threats: 0, bytes: 10, uniques: 1),
    ZoneAnalyticsDay(date: "not-a-date", requests: 9, pageViews: 9, threats: 9, bytes: 9),
    ZoneAnalyticsDay(
      date: "2026-07-13", requests: 2, pageViews: 0, threats: 1, bytes: 20, uniques: 2),
  ]
  let dayPoints = ZoneAnalyticsChartModel.points(fromDaily: daily)
  #expect(dayPoints.map(\.requests) == [1, 2, 3])  // bad date dropped, sorted ascending
  #expect(dayPoints.map(\.uniques) == [1, 2, 3])

  let hourly = [
    ZoneAnalyticsPoint(
      datetime: "2026-07-14T09:00:00Z", requests: 20, pageViews: 8, threats: 0, bytes: 40,
      uniques: 6),
    ZoneAnalyticsPoint(
      datetime: "2026-07-14T08:00:00.000Z", requests: 10, pageViews: 4, threats: 1, bytes: 20,
      uniques: 4),
    ZoneAnalyticsPoint(datetime: "garbage", requests: 99, pageViews: 0, threats: 0, bytes: 0),
  ]
  let hourPoints = ZoneAnalyticsChartModel.points(fromHourly: hourly)
  #expect(hourPoints.map(\.requests) == [10, 20])  // fractional seconds parsed, garbage dropped
  #expect(hourPoints.map(\.uniques) == [4, 6])
}

@Test func webAnalyticsSiteResolvesByRulesetZoneTag() {
  let sites = [
    RUMSite(
      siteTag: "site-other", autoInstall: true,
      ruleset: RUMRuleset(zoneTag: "zone-other", zoneName: "other.example", enabled: true)),
    RUMSite(
      siteTag: "site-mine", autoInstall: true,
      ruleset: RUMRuleset(zoneTag: "zone-mine", zoneName: "mine.example", enabled: true)),
    // A site created by host instead of zone carries no ruleset at all.
    RUMSite(siteTag: "site-hostonly", autoInstall: false),
  ]

  #expect(WebAnalyticsChartModel.site(for: "zone-mine", in: sites)?.siteTag == "site-mine")
  #expect(WebAnalyticsChartModel.site(for: "zone-absent", in: sites) == nil)
}

@Test func zoneWebAnalyticsToolFollowsTheAccountSiteList() {
  let sites = [
    RUMSite(
      siteTag: "site-mine", autoInstall: true,
      ruleset: RUMRuleset(zoneTag: "zone-mine", zoneName: "mine.example", enabled: true)),
    // Added, then switched off at the ruleset. Still the user's site, still has
    // history, still one dashboard toggle from collecting — it keeps its row.
    RUMSite(
      siteTag: "site-paused", autoInstall: true,
      ruleset: RUMRuleset(zoneTag: "zone-paused", zoneName: "paused.example", enabled: false)),
  ]

  #expect(ZoneWebAnalyticsAvailability.resolved(zoneID: "zone-mine", in: sites) == .present)
  #expect(ZoneWebAnalyticsAvailability.resolved(zoneID: "zone-paused", in: sites) == .present)
  #expect(ZoneWebAnalyticsAvailability.resolved(zoneID: "zone-absent", in: sites) == .absent)
  #expect(ZoneWebAnalyticsAvailability.resolved(zoneID: "zone-mine", in: []) == .absent)

  // Only a settled "this account has no site for this zone" removes the row.
  // An unanswered list holds it back rather than offering a row it may take
  // away; an unreadable one (no grant, no account, failed request) leaves it,
  // because a missing answer must never delete a feature the user has.
  #expect(!ZoneWebAnalyticsAvailability.absent.showsTool)
  #expect(!ZoneWebAnalyticsAvailability.pending.showsTool)
  #expect(ZoneWebAnalyticsAvailability.present.showsTool)
  #expect(ZoneWebAnalyticsAvailability.indeterminate.showsTool)
}

// MARK: - Pages deployment build-outcomes donut

private func decodePagesDeployments(_ json: String) throws -> [PagesDeployment] {
  try JSONDecoder().decode([PagesDeployment].self, from: Data(json.utf8))
}

@Test func pagesDeploymentChartNormalizesStatuses() {
  #expect(PagesDeploymentChartModel.outcome(forStatus: "Success") == .success)
  #expect(PagesDeploymentChartModel.outcome(forStatus: "failure") == .failure)
  #expect(PagesDeploymentChartModel.outcome(forStatus: "FAILED") == .failure)
  #expect(PagesDeploymentChartModel.outcome(forStatus: "canceled") == .canceled)
  #expect(PagesDeploymentChartModel.outcome(forStatus: "cancelled") == .canceled)
  #expect(PagesDeploymentChartModel.outcome(forStatus: "skipped") == .canceled)
  #expect(PagesDeploymentChartModel.outcome(forStatus: "active") == .inFlight)
  #expect(PagesDeploymentChartModel.outcome(forStatus: "idle") == .inFlight)
  #expect(PagesDeploymentChartModel.outcome(forStatus: "Building") == .inFlight)
  #expect(PagesDeploymentChartModel.outcome(forStatus: "deploying") == .inFlight)
  #expect(PagesDeploymentChartModel.outcome(forStatus: "queued") == .inFlight)
  #expect(PagesDeploymentChartModel.outcome(forStatus: "initializing") == .inFlight)
  #expect(PagesDeploymentChartModel.outcome(forStatus: nil) == .other)
  #expect(PagesDeploymentChartModel.outcome(forStatus: nil, isSkipped: true) == .canceled)
  #expect(PagesDeploymentChartModel.outcome(forStatus: "mystery") == .other)
}

@Test func pagesDeploymentChartBucketsDropZeroCountsAndKeepOrder() throws {
  // No canceled deployments — that bucket must be dropped, and the rest keep
  // the stable success → in-flight → failure → other order regardless of the
  // input order.
  let deployments = try decodePagesDeployments(
    """
    [
      {"id":"a","latest_stage":{"name":"build","status":"failure"}},
      {"id":"b","latest_stage":{"name":"deploy","status":"Success"}},
      {"id":"c","latest_stage":{"name":"build","status":"building"}},
      {"id":"d","latest_stage":{"name":"deploy","status":"success"}},
      {"id":"e","latest_stage":{"name":"queued","status":null}}
    ]
    """)
  let buckets = PagesDeploymentChartModel.buckets(deployments)
  #expect(buckets.map(\.outcome) == [.success, .inFlight, .failure, .other])
  #expect(buckets.map(\.count) == [2, 1, 1, 1])
  #expect(buckets.map(\.id) == ["success", "in-flight", "failure", "other"])

  #expect(PagesDeploymentChartModel.buckets([]).isEmpty)
}

@Test func pagesDeploymentChartBucketsMatchDemoFixtureShape() throws {
  // Mirrors DemoBackend's marketing-site deployments: two successful deploys
  // around one failed build.
  let deployments = try decodePagesDeployments(
    """
    [
      {"id":"pd-3","is_skipped":false,"latest_stage":{"name":"deploy","status":"success"}},
      {"id":"pd-2","is_skipped":false,"latest_stage":{"name":"build","status":"failure"}},
      {"id":"pd-1","is_skipped":false,"latest_stage":{"name":"deploy","status":"success"}}
    ]
    """)
  let buckets = PagesDeploymentChartModel.buckets(deployments)
  #expect(buckets.map(\.outcome) == [.success, .failure])
  #expect(buckets.map(\.count) == [2, 1])
}

@Test func pagesDeploymentChartFilterNarrowsToSelectedOutcome() throws {
  let deployments = try decodePagesDeployments(
    """
    [
      {"id":"success-1","latest_stage":{"name":"deploy","status":"success"}},
      {"id":"failure-1","latest_stage":{"name":"build","status":"failure"}},
      {"id":"success-2","latest_stage":{"name":"deploy","status":"Success"}},
      {"id":"skipped-1","is_skipped":true,"latest_stage":{"name":"queued","status":null}}
    ]
    """)

  let successes = PagesDeploymentChartModel.deployments(deployments, in: "success")
  let failures = PagesDeploymentChartModel.deployments(deployments, in: "failure")
  let canceled = PagesDeploymentChartModel.deployments(deployments, in: "canceled")

  #expect(successes.map(\.id) == ["success-1", "success-2"])
  #expect(failures.map(\.id) == ["failure-1"])
  #expect(canceled.map(\.id) == ["skipped-1"])

  let buckets = PagesDeploymentChartModel.buckets(deployments)
  #expect(
    buckets.allSatisfy {
      PagesDeploymentChartModel.deployments(deployments, in: $0.id).count == $0.count
    })
}

@Test func pagesDeploymentChartFilterFallsBackForMissingOrStaleSelection() throws {
  let deployments = try decodePagesDeployments(
    """
    [
      {"id":"success-1","latest_stage":{"name":"deploy","status":"success"}},
      {"id":"failure-1","latest_stage":{"name":"build","status":"failure"}}
    ]
    """)

  #expect(PagesDeploymentChartModel.deployments(deployments, in: nil).count == 2)
  #expect(PagesDeploymentChartModel.deployments(deployments, in: "canceled").count == 2)
  #expect(PagesDeploymentChartModel.bucket(deployments, withID: nil) == nil)
  #expect(PagesDeploymentChartModel.bucket(deployments, withID: "canceled") == nil)
  #expect(PagesDeploymentChartModel.bucket(deployments, withID: "failure")?.count == 1)
}

extension LocalizationTests {
  @Test func pagesDeploymentChartAccessibilitySummaryCountsOutcomes() {
    let previousLocale = DashL10n.localeOverrideForTesting
    DashL10n.localeOverrideForTesting = Locale(identifier: "en")
    defer { DashL10n.localeOverrideForTesting = previousLocale }

    let summary = PagesDeploymentChartModel.chartAccessibilitySummary(buckets: [
      PagesDeploymentChartModel.Bucket(outcome: .success, count: 2),
      PagesDeploymentChartModel.Bucket(outcome: .failure, count: 1),
    ])
    #expect(summary.contains("3"))
    #expect(summary.contains("2"))
    #expect(summary.contains("1"))
    #expect(summary.contains("Success"))
    #expect(summary.contains("Failed"))

    let empty = PagesDeploymentChartModel.chartAccessibilitySummary(buckets: [])
    #expect(empty.contains("No deployments"))
  }
}

@Test func workerAnalyticsChartPointsSortDropUnparseableAndConvertToMilliseconds() {
  let buckets = [
    WorkerAnalyticsBucket(
      datetime: "2026-07-23T10:10:00Z", requests: 30, errors: 1, cpuTimeP50Us: 1500),
    WorkerAnalyticsBucket(
      datetime: "not-a-date", requests: 99, errors: 9, cpuTimeP50Us: 5000),
    WorkerAnalyticsBucket(
      datetime: "2026-07-23T10:05:00.000Z", requests: 20, errors: 0, cpuTimeP50Us: 500),
  ]

  let points = WorkerAnalyticsChartModel.points(from: buckets)

  #expect(points.count == 2)
  #expect(points.map(\.requests) == [20, 30])
  #expect(points.map(\.errors) == [0, 1])
  #expect(points[0].cpuTimeP50Ms == 0.5)
  #expect(points[1].cpuTimeP50Ms == 1.5)
}

extension LocalizationTests {
  @Test func workerAnalyticsRequestsSummaryMentionsErrorsOnlyWhenPresent() {
    let previousLocale = DashL10n.localeOverrideForTesting
    DashL10n.localeOverrideForTesting = Locale(identifier: "en")
    defer { DashL10n.localeOverrideForTesting = previousLocale }

    let withErrors = WorkerAnalyticsChartModel.requestsAccessibilitySummary(
      requests: 1200, errors: 4)
    #expect(withErrors.contains("1,200") || withErrors.contains("1200"))
    #expect(withErrors.contains("4"))
    #expect(withErrors.contains("errors"))

    let clean = WorkerAnalyticsChartModel.requestsAccessibilitySummary(requests: 50, errors: 0)
    #expect(clean.contains("50"))
    #expect(!clean.contains("errors"))
  }
}

extension LocalizationTests {
  @Test func workerAnalyticsCPUSummaryNamesPeakMilliseconds() {
    let previousLocale = DashL10n.localeOverrideForTesting
    DashL10n.localeOverrideForTesting = Locale(identifier: "en")
    defer { DashL10n.localeOverrideForTesting = previousLocale }

    let points = WorkerAnalyticsChartModel.points(from: [
      WorkerAnalyticsBucket(
        datetime: "2026-07-23T10:00:00Z", requests: 10, errors: 0, cpuTimeP50Us: 900),
      WorkerAnalyticsBucket(
        datetime: "2026-07-23T10:05:00Z", requests: 10, errors: 0, cpuTimeP50Us: 1440),
    ])

    let summary = WorkerAnalyticsChartModel.cpuAccessibilitySummary(points: points)
    #expect(summary.contains("1.4"))
    #expect(summary.contains("milliseconds"))
  }
}

@Test func wafChartModelCapsCountriesToTopSixByCount() {
  let buckets = (1...9).map { FirewallEventsBucket(label: "C\($0)", count: $0 * 10) }
  let top = WAFChartModel.topCountries(buckets)

  #expect(top.count == 6)
  #expect(top.map(\.count) == [90, 80, 70, 60, 50, 40])
  #expect(top.first?.label == "C9")
}

@Test func wafChartModelKeepsShortListsAndUsesStableTieOrder() {
  let buckets = [
    FirewallEventsBucket(label: "US", count: 64),
    FirewallEventsBucket(label: "CN", count: 38),
    FirewallEventsBucket(label: "RU", count: 21),
    FirewallEventsBucket(label: "DE", count: 21),
  ]
  let top = WAFChartModel.topCountries(buckets)
  #expect(top.map(\.label) == ["US", "CN", "DE", "RU"])
}

extension LocalizationTests {
  @Test func wafCountriesSummaryNamesLeaderAndTotal() {
    let previousLocale = DashL10n.localeOverrideForTesting
    DashL10n.localeOverrideForTesting = Locale(identifier: "en")
    defer { DashL10n.localeOverrideForTesting = previousLocale }

    let summary = WAFChartModel.countriesAccessibilitySummary(buckets: [
      FirewallEventsBucket(label: "US", count: 64),
      FirewallEventsBucket(label: "CN", count: 38),
      FirewallEventsBucket(label: "RU", count: 21),
    ])
    #expect(summary.contains("United States"))
    #expect(summary.contains("64"))
    #expect(summary.contains("123"))

    let fullSummary = WAFChartModel.countriesAccessibilitySummary(
      buckets: [FirewallEventsBucket(label: "US", count: 64)],
      totalBlocked: 400)
    #expect(fullSummary.contains("64"))
    #expect(fullSummary.contains("400"))

    let empty = WAFChartModel.countriesAccessibilitySummary(buckets: [])
    #expect(empty.contains("No blocked events"))
  }
}

/// The card lifts a quiet series off the floor so the sparkline stays visible;
/// the pushed detail plots and tabulates what Cloudflare actually counted.
extension LocalizationTests {
  @Test func wafDetailPointsKeepRealCountsInAscendingHourOrder() {
    let previousLocale = DashL10n.localeOverrideForTesting
    DashL10n.localeOverrideForTesting = Locale(identifier: "en")
    defer { DashL10n.localeOverrideForTesting = previousLocale }

    let series = [
      FirewallEventsSeriesPoint(datetime: "2026-08-03T23:00:00Z", count: 7),
      FirewallEventsSeriesPoint(datetime: "not-a-datetime", count: 999),
      FirewallEventsSeriesPoint(datetime: "2026-08-03T22:00:00Z", count: 0),
    ]
    let points = WAFChartModel.detailPoints(series)

    #expect(points.count == 2)
    #expect(points.map { $0.datum["blocked"] } == [0, 7])
    #expect(points.map(\.id) == WAFChartModel.seriesData(series).map(\.id))
    // The table spells out the day — a 24-hour window crosses midnight, so two
    // rows would otherwise read the same hour.
    #expect(points.allSatisfy { $0.tableLabel.contains("Aug") })
    #expect(points.allSatisfy { !$0.datum.label.contains("Aug") })
  }
}

@Test func wafGlobeCentroidsCoverISOAlpha2AndCloudflareKosovoExtension() throws {
  let expectedCodes = Set(
    ("AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ BA BB BD BE BF BG BH BI BJ "
      + "BL BM BN BO BQ BR BS BT BV BW BY BZ CA CC CD CF CG CH CI CK CL CM CN CO CR "
      + "CU CV CW CX CY CZ DE DJ DK DM DO DZ EC EE EG EH ER ES ET FI FJ FK FM FO FR "
      + "GA GB GD GE GF GG GH GI GL GM GN GP GQ GR GS GT GU GW GY HK HM HN HR HT HU "
      + "ID IE IL IM IN IO IQ IR IS IT JE JM JO JP KE KG KH KI KM KN KP KR KW KY KZ "
      + "LA LB LC LI LK LR LS LT LU LV LY MA MC MD ME MF MG MH MK ML MM MN MO MP MQ "
      + "MR MS MT MU MV MW MX MY MZ NA NC NE NF NG NI NL NO NP NR NU NZ OM PA PE PF "
      + "PG PH PK PL PM PN PR PS PT PW PY QA RE RO RS RU RW SA SB SC SD SE SG SH SI "
      + "SJ SK SL SM SN SO SR SS ST SV SX SY SZ TC TD TF TG TH TJ TK TL TM TN TO TR "
      + "TT TV TW TZ UA UG UM US UY UZ VA VC VE VG VI VN VU WF WS XK YE YT ZA ZM ZW").split(
        separator: " "
      ).map(String.init))

  #expect(WAFISOCountryCentroids.supportedCodes == expectedCodes)
  #expect(WAFISOCountryCentroids.coordinate(for: " us ")?.latitude == 39.538479)
  let bqLongitude = try #require(WAFISOCountryCentroids.coordinate(for: "bq")?.longitude)
  #expect(abs(bqLongitude - (-63.1334)) < 1e-9)
  #expect(WAFISOCountryCentroids.coordinate(for: "UM") != nil)
  #expect(WAFISOCountryCentroids.coordinate(for: "XX") == nil)
  #expect(WAFISOCountryCentroids.coordinate(for: "T1") == nil)
  #expect(WAFISOCountryCentroids.coordinate(for: "United States") == nil)
}

@Test func wafGlobeModelMergesSortsAndSafelyDropsUnknownCountries() throws {
  let buckets = [
    FirewallEventsBucket(label: "ru", count: 1),
    FirewallEventsBucket(label: " CN ", count: 16),
    FirewallEventsBucket(label: "cn", count: 9),
    FirewallEventsBucket(label: "US", count: 64),
    FirewallEventsBucket(label: "US", count: 0),
    FirewallEventsBucket(label: "DE", count: -2),
    FirewallEventsBucket(label: "XX", count: 10_000),
    FirewallEventsBucket(label: "T1", count: 10_000),
    FirewallEventsBucket(label: "not-a-country", count: 10_000),
  ]
  let points = WAFGlobeModel.points(from: buckets)

  #expect(points.map(\.countryCode) == ["US", "CN", "RU"])
  #expect(points.map(\.count) == [64, 25, 1])
  #expect(points[0].markerSize == WAFGlobeModel.maximumMarkerSize)
  #expect(points[0].markerSize > points[1].markerSize)
  #expect(points[1].markerSize > points[2].markerSize)
  #expect(
    points.allSatisfy {
      (WAFGlobeModel.minimumMarkerSize...WAFGlobeModel.maximumMarkerSize).contains($0.markerSize)
    })

  let marker = try #require(points.first?.marker(accessibilityLabel: "United States, 64 blocks"))
  #expect(marker.id == "US")
  #expect(marker.coordinate == points[0].coordinate)
  #expect(marker.size == points[0].markerSize)
  #expect(marker.accessibilityLabel == "United States, 64 blocks")
}

@Test func wafGlobeModelUsesStableTieOrderAndSquareRootMarkerScale() {
  let tied = WAFGlobeModel.points(from: [
    FirewallEventsBucket(label: "FR", count: 10),
    FirewallEventsBucket(label: "DE", count: 10),
  ])
  #expect(tied.map(\.countryCode) == ["DE", "FR"])
  #expect(tied.allSatisfy { $0.markerSize == WAFGlobeModel.maximumMarkerSize })

  let quarterScale = WAFGlobeModel.markerSize(count: 25, maximumCount: 100)
  let expected =
    WAFGlobeModel.minimumMarkerSize
    + (WAFGlobeModel.maximumMarkerSize - WAFGlobeModel.minimumMarkerSize) * 0.5
  #expect(abs(quarterScale - expected) < 0.000_001)
  #expect(
    WAFGlobeModel.markerSize(count: 0, maximumCount: 100)
      == WAFGlobeModel.minimumMarkerSize)
  #expect(
    WAFGlobeModel.markerSize(count: 200, maximumCount: 100)
      == WAFGlobeModel.maximumMarkerSize)
}

// MARK: - DNS record-type donut chart model

/// `DNSRecord` has no public memberwise init — decode minimal JSON like the
/// API layer does.
private func makeDNSRecords(types: [String]) throws -> [DNSRecord] {
  let objects = types.enumerated().map { index, type in
    #"{"id":"dns-\#(index)","type":"\#(type)","name":"example.com","content":"203.0.113.1","ttl":300}"#
  }
  return try JSONDecoder().decode(
    [DNSRecord].self, from: Data("[\(objects.joined(separator: ","))]".utf8))
}

@Test func dnsChartModelKeepsTopFiveTypesAndFoldsOther() throws {
  // 7 types with distinct counts: A×6, CNAME×5, TXT×4, MX×3, AAAA×2, SRV×1, CAA×1.
  let types =
    Array(repeating: "A", count: 6) + Array(repeating: "CNAME", count: 5)
    + Array(repeating: "TXT", count: 4) + Array(repeating: "MX", count: 3)
    + Array(repeating: "AAAA", count: 2) + ["SRV", "CAA"]
  let buckets = DNSChartModel.buckets(try makeDNSRecords(types: types.shuffled()))

  #expect(buckets.map(\.id) == ["A", "CNAME", "TXT", "MX", "AAAA", DNSChartModel.otherBucketID])
  #expect(buckets.map(\.count) == [6, 5, 4, 3, 2, 2])
}

@Test func dnsChartModelBreaksCountTiesAlphabeticallyAndUppercases() throws {
  // Lowercase "a" merges into "A"; ties (2,2,2) order alphabetically, and the
  // sixth tied type folds into Other deterministically.
  let types = ["a", "A", "TXT", "TXT", "MX", "MX", "CNAME", "CNAME", "AAAA", "AAAA", "SRV", "SRV"]
  let buckets = DNSChartModel.buckets(try makeDNSRecords(types: types))

  #expect(buckets.map(\.id) == ["A", "AAAA", "CNAME", "MX", "SRV", DNSChartModel.otherBucketID])
  #expect(buckets.map(\.count) == [2, 2, 2, 2, 2, 2])
}

@Test func dnsChartModelSkipsOtherBucketWhenFiveOrFewerTypes() throws {
  let buckets = DNSChartModel.buckets(try makeDNSRecords(types: ["A", "A", "CNAME"]))
  #expect(buckets.map(\.id) == ["A", "CNAME"])
  #expect(buckets.map(\.count) == [2, 1])
  #expect(!buckets.contains { $0.id == DNSChartModel.otherBucketID })
}

@Test func dnsChartFilterNarrowsToTheSelectedNamedType() throws {
  let records = try makeDNSRecords(types: ["A", "a", "CNAME", "TXT"])
  let filtered = DNSChartModel.records(records, in: "A")

  // Bucketing uppercases, so the lowercase "a" record filters with its bucket.
  #expect(filtered.map(\.type) == ["A", "a"])
}

@Test func dnsChartFilterCollectsEveryFoldedTypeUnderOther() throws {
  // 6 distinct types: A×3, AAAA×2, CNAME×2, MX×2, TXT×2 stay named; SRV and
  // CAA lose the cut and fold into Other.
  let types =
    Array(repeating: "A", count: 3) + ["AAAA", "AAAA", "CNAME", "CNAME", "MX", "MX", "TXT", "TXT"]
    + ["SRV", "CAA"]
  let records = try makeDNSRecords(types: types)
  let filtered = DNSChartModel.records(records, in: DNSChartModel.otherBucketID)

  #expect(Set(filtered.map(\.type)) == ["SRV", "CAA"])

  // The buckets partition the loaded records: every slice filters to exactly
  // its own count, and together they account for the whole list.
  let buckets = DNSChartModel.buckets(records)
  let matchesSliceCounts = buckets.allSatisfy {
    DNSChartModel.records(records, in: $0.id, buckets: buckets).count == $0.count
  }
  #expect(matchesSliceCounts)
  #expect(buckets.reduce(0) { $0 + $1.count } == records.count)
}

@Test func dnsChartFilterFallsBackToTheFullListForAStaleSelection() throws {
  let records = try makeDNSRecords(types: ["A", "CNAME"])

  // No selection, an id no bucket claims, and the Other bucket in a list that
  // never folded one all widen back to every loaded record rather than empty.
  #expect(DNSChartModel.records(records, in: nil).count == 2)
  #expect(DNSChartModel.records(records, in: "MX").count == 2)
  #expect(DNSChartModel.records(records, in: DNSChartModel.otherBucketID).count == 2)
  #expect(DNSChartModel.bucket(records, withID: "MX") == nil)
  #expect(DNSChartModel.bucket(records, withID: nil) == nil)
  #expect(DNSChartModel.bucket(records, withID: "A")?.count == 1)
}

extension LocalizationTests {
  @Test func dnsChartSummaryDescribesLoadedRecordsOnly() throws {
    let previousLocale = DashL10n.localeOverrideForTesting
    DashL10n.localeOverrideForTesting = Locale(identifier: "en")
    defer { DashL10n.localeOverrideForTesting = previousLocale }

    let buckets = DNSChartModel.buckets(
      try makeDNSRecords(types: ["A", "A", "CNAME", "TXT", "MX", "AAAA", "SRV", "CAA"]))
    let summary = DNSChartModel.chartAccessibilitySummary(buckets: buckets)
    // Names the LOADED total (the list paginates) and every bucket label.
    #expect(summary.contains("loaded"))
    #expect(summary.contains("8"))
    #expect(summary.contains("A 2"))
    #expect(summary.contains("Other"))

    let empty = DNSChartModel.chartAccessibilitySummary(buckets: [])
    #expect(empty.contains("No DNS records loaded"))
  }
}
