import CloudflareAPI
import SwiftDitherKit
import SwiftUI

/// A single normalized point for the chart, independent of whether it came
/// from the hourly or daily dataset.
struct ZoneAnalyticsChartPoint: Identifiable, Hashable, Sendable {
  let date: Date
  let requests: Int
  let threats: Int
  let bytes: Int64
  let pageViews: Int
  let uniques: Int
  let cachedRequests: Int

  var id: Date { date }
}

struct ZoneAnalyticsSnapshot: Hashable, Sendable {
  static let empty = ZoneAnalyticsSnapshot(
    points: [],
    requestsData: [],
    visitorsData: [],
    bandwidthData: [],
    totalRequests: 0,
    totalThreats: 0,
    totalCachedRequests: 0,
    totalBytes: 0,
    peakUniques: 0,
    previousTotalRequests: nil,
    previousTotalBytes: nil,
    previousPeakUniques: nil)

  let points: [ZoneAnalyticsChartPoint]
  let requestsData: [DitherDatum]
  let visitorsData: [DitherDatum]
  let bandwidthData: [DitherDatum]
  let totalRequests: Int
  let totalThreats: Int
  let totalCachedRequests: Int
  let totalBytes: Int64
  let peakUniques: Int
  let previousTotalRequests: Int?
  let previousTotalBytes: Int64?
  let previousPeakUniques: Int?

  var isEmpty: Bool { points.isEmpty }
}

/// Pure conversion + parsing, so the date handling is unit-tested away from
/// the view. Both builders return ascending, dropping unparseable stamps.
enum ZoneAnalyticsChartModel {
  private static func makeDayParser() -> DateFormatter {
    let parser = DateFormatter()
    parser.dateFormat = "yyyy-MM-dd"
    parser.locale = Locale(identifier: "en_US_POSIX")
    parser.timeZone = TimeZone(identifier: "UTC")
    return parser
  }

  static func chartAccessibilitySummary(rangeLabel: String, requests: Int, threats: Int) -> String {
    if threats > 0 {
      return DashL10n.string(
        "Requests chart for \(rangeLabel). Total \(requests.formatted()) requests, \(threats.formatted()) threats."
      )
    }
    return DashL10n.string(
      "Requests chart for \(rangeLabel). Total \(requests.formatted()) requests.")
  }

  /// Visitors are deduplicated per bucket, so the summary quotes the busiest
  /// bucket instead of a total that would count returning visitors twice.
  static func visitorsAccessibilitySummary(rangeLabel: String, peak: Int, isHourly: Bool) -> String
  {
    if isHourly {
      return DashL10n.string(
        "Unique visitors chart for \(rangeLabel). Busiest hour \(peak.formatted()) visitors.")
    }
    return DashL10n.string(
      "Unique visitors chart for \(rangeLabel). Busiest day \(peak.formatted()) visitors.")
  }

  static func bandwidthAccessibilitySummary(rangeLabel: String, total: String) -> String {
    DashL10n.string("Bandwidth chart for \(rangeLabel). Total \(total).")
  }

  static func points(fromDaily days: [ZoneAnalyticsDay]) -> [ZoneAnalyticsChartPoint] {
    let dayParser = makeDayParser()
    return days.compactMap { day in
      guard let date = dayParser.date(from: day.date) else { return nil }
      return ZoneAnalyticsChartPoint(
        date: date, requests: day.requests, threats: day.threats, bytes: day.bytes,
        pageViews: day.pageViews, uniques: day.uniques, cachedRequests: day.cachedRequests)
    }
    .sorted { $0.date < $1.date }
  }

  static func points(fromHourly hourly: [ZoneAnalyticsPoint]) -> [ZoneAnalyticsChartPoint] {
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime]
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return hourly.compactMap { point in
      guard let date = parser.date(from: point.datetime) ?? fractional.date(from: point.datetime)
      else { return nil }
      return ZoneAnalyticsChartPoint(
        date: date, requests: point.requests, threats: point.threats, bytes: point.bytes,
        pageViews: point.pageViews, uniques: point.uniques, cachedRequests: point.cachedRequests)
    }
    .sorted { $0.date < $1.date }
  }

  static func snapshot(
    points: [ZoneAnalyticsChartPoint],
    previousPoints: [ZoneAnalyticsChartPoint]? = nil,
    range: AnalyticsRange,
    locale: Locale
  ) -> ZoneAnalyticsSnapshot {
    let labelStyle: Date.FormatStyle
    if range == .day {
      labelStyle = Date.FormatStyle.dateTime.hour().locale(locale)
    } else {
      labelStyle = Date.FormatStyle.dateTime.month(.abbreviated).day().locale(locale)
    }

    var totalRequests = 0
    var totalThreats = 0
    var totalCachedRequests = 0
    var totalBytes: Int64 = 0
    var peakUniques = 0
    for point in points {
      totalRequests += point.requests
      totalThreats += point.threats
      totalCachedRequests += point.cachedRequests
      totalBytes += point.bytes
      peakUniques = max(peakUniques, point.uniques)
    }
    let previousTotalRequests = previousPoints.map {
      $0.reduce(0) { $0 + $1.requests }
    }
    let previousTotalBytes = previousPoints.map {
      $0.reduce(Int64(0)) { $0 + $1.bytes }
    }
    let previousPeakUniques = previousPoints.map {
      $0.reduce(0) { max($0, $1.uniques) }
    }

    let identities = points.map {
      (
        id: $0.date.ISO8601Format(),
        label: $0.date.formatted(labelStyle),
        point: $0
      )
    }
    return ZoneAnalyticsSnapshot(
      points: points,
      requestsData: identities.map {
        DitherDatum(
          id: $0.id,
          label: $0.label,
          values: [
            "requests": Double($0.point.requests),
            "threats": Double($0.point.threats),
          ])
      },
      visitorsData: identities.map {
        DitherDatum(
          id: $0.id,
          label: $0.label,
          values: ["uniques": Double($0.point.uniques)])
      },
      bandwidthData: identities.map {
        DitherDatum(
          id: $0.id,
          label: $0.label,
          values: ["bytes": Double($0.point.bytes)])
      },
      totalRequests: totalRequests,
      totalThreats: totalThreats,
      totalCachedRequests: totalCachedRequests,
      totalBytes: totalBytes,
      peakUniques: peakUniques,
      previousTotalRequests: previousTotalRequests,
      previousTotalBytes: previousTotalBytes,
      previousPeakUniques: previousPeakUniques)
  }

  static func detailLabel(
    _ date: Date,
    range: AnalyticsRange,
    locale: Locale
  ) -> String {
    if range == .day {
      return date.formatted(
        .dateTime.month(.abbreviated).day().hour().minute().locale(locale))
    }
    return date.formatted(
      .dateTime.year().month(.abbreviated).day().locale(locale))
  }
}

enum AnalyticsRange: Hashable, CaseIterable, Sendable {
  case day, week, month

  var title: String {
    switch self {
    case .day: "24h"
    case .week: "7d"
    case .month: "30d"
    }
  }
  var totalsHeading: String {
    switch self {
    case .day: "Last 24 hours"
    case .week: "Last 7 days"
    case .month: "Last 30 days"
    }
  }
}

struct ZoneAnalyticsView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.destinationNavigator) private var navigator
  let zoneID: String
  @State private var range: AnalyticsRange = .day
  @State private var snapshotsByRange: [AnalyticsRange: ZoneAnalyticsSnapshot] = [:]
  @State private var errorByRange: [AnalyticsRange: String] = [:]
  @State private var loadingRanges: Set<AnalyticsRange> = Set(AnalyticsRange.allCases)
  @State private var selectedSeriesID: String?

  private var snapshot: ZoneAnalyticsSnapshot { snapshotsByRange[range] ?? .empty }
  private var isLoadingCurrent: Bool { loadingRanges.contains(range) }
  private var currentError: String? { errorByRange[range] }

  private var metricColumns: [GridItem] {
    let count = dynamicTypeSize.isAccessibilitySize ? 1 : 2
    return Array(
      repeating: GridItem(.flexible(), spacing: DashTheme.Spacing.itemGap),
      count: count)
  }

  var body: some View {
    DashFeatureList(
      isLoading: isLoadingCurrent,
      error: currentError,
      hasContent: !snapshot.isEmpty,
      retry: { Task { await loadAll(force: true) } },
      header: {
        DashTextTabs(
          items: [("24h", AnalyticsRange.day), ("7d", .week), ("30d", .month)],
          selection: $range
        )
      }
    ) {
      if snapshot.isEmpty {
        DashEmptyState(
          icon: SolarAsset.Content.chart,
          title: "No traffic yet",
          message: "HTTP request analytics for this domain will appear here."
        )
      } else {
        DashSurfaceStack {
          metricsGrid
          requestsChartCard
          if showsVisitors { visitorsChartCard }
          if totalBytes > 0 { bandwidthChartCard }
        }
      }
    }
    .detailHeader(icon: .solar(SolarAsset.Content.chart), title: "HTTP traffic")
    .refreshable { await loadAll(force: true) }
    .onChange(of: range) { selectedSeriesID = nil }
    .task { await loadAll() }
  }

  private var metricsGrid: some View {
    LazyVGrid(columns: metricColumns, spacing: DashTheme.Spacing.itemGap) {
      metricCard(
        title: "Requests",
        value: totalRequests.formatted(),
        numericValue: Double(totalRequests))
      metricCard(
        title: "Bandwidth",
        value: bandwidth(totalBytes),
        numericValue: Double(totalBytes))
      metricCard(
        title: "Cached",
        value: cacheHitRatio.formatted(
          .percent.precision(.fractionLength(0)).locale(DashL10n.activeLocale)),
        numericValue: cacheHitRatio)
      metricCard(
        title: "Threats",
        value: totalThreats.formatted(),
        numericValue: Double(totalThreats))
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(DashL10n.ui(range.totalsHeading))
  }

  private func metricCard(title: String, value: String, numericValue: Double) -> some View {
    DashGlassCard {
      VStack(alignment: .leading, spacing: 4) {
        Text(DashL10n.ui(title))
          .dashTextStyle(.footnoteSemibold)
          .foregroundStyle(DashTheme.subtle)
        Text(value)
          .dashTextStyle(.sectionTitle)
          .monospacedDigit()
          .foregroundStyle(DashTheme.strong)
          .lineLimit(1)
          .minimumScaleFactor(0.7)
          .contentTransition(
            reduceMotion ? .opacity : .numericText(value: numericValue))
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .combine)
  }

  private func chartCard<Chart: View>(
    detail: DashChartDetail,
    @ViewBuilder chart: () -> Chart
  ) -> some View {
    DashGlassCard {
      VStack(alignment: .leading, spacing: 12) {
        DestinationLink(destination: .chartDetail(detail)) {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(DashL10n.ui(detail.title))
              .dashTextStyle(.footnoteSemibold)
              .foregroundStyle(DashTheme.subtle)
            Spacer(minLength: 4)
            DashChartDisclosure(trend: detail.trend)
          }
          .contentShape(Rectangle())
        }
        .accessibilityHint("Shows chart details")
        chart()
      }
    }
  }

  private var requestsChartCard: some View {
    chartCard(detail: requestsDetail) {
      DitherAreaChart(
        data: snapshot.requestsData,
        series: ditherSeries,
        options: DashTheme.DitherChart.options(
          showsLegend: totalThreats > 0,
          accessibility: DitherAccessibility(
            title: DashL10n.ui("HTTP request analytics"),
            summary: ZoneAnalyticsChartModel.chartAccessibilitySummary(
              rangeLabel: DashL10n.ui(range.totalsHeading),
              requests: totalRequests,
              threats: totalThreats),
            categoryAxisLabel: DashL10n.ui(range == .day ? "Hour" : "Day"),
            valueAxisLabel: DashL10n.ui("Events"))),
        highlighted: selectedSeriesID != nil,
        selection: $selectedSeriesID,
        onTap: { navigator?.push(.chartDetail(requestsDetail)) }
      )
      .frame(
        height: DashTheme.DitherChart.height(
          dynamicTypeSize: dynamicTypeSize,
          showsLegend: totalThreats > 0))
    }
  }

  /// Visitors get a line rather than an area: the value is a per-bucket count
  /// of people, not a quantity that accumulates under the curve.
  private var visitorsChartCard: some View {
    chartCard(detail: visitorsDetail) {
      DitherLineChart(
        data: snapshot.visitorsData,
        series: [
          DitherSeries(
            id: "uniques",
            label: DashL10n.ui("Unique visitors"),
            color: DashTheme.DitherChart.accentPurple(
              colorScheme: colorScheme,
              contrast: colorSchemeContrast),
            variant: .gradient)
        ],
        options: DashTheme.DitherChart.options(
          showsLegend: false,
          accessibility: DitherAccessibility(
            title: DashL10n.ui("Unique visitors"),
            summary: ZoneAnalyticsChartModel.visitorsAccessibilitySummary(
              rangeLabel: DashL10n.ui(range.totalsHeading),
              peak: peakUniques,
              isHourly: range == .day),
            categoryAxisLabel: DashL10n.ui(range == .day ? "Hour" : "Day"),
            valueAxisLabel: DashL10n.ui("Visitors"))),
        onTap: { navigator?.push(.chartDetail(visitorsDetail)) }
      )
      .frame(height: DashTheme.DitherChart.height(dynamicTypeSize: dynamicTypeSize))
    }
  }

  private var bandwidthChartCard: some View {
    chartCard(detail: bandwidthDetail) {
      DitherAreaChart(
        data: snapshot.bandwidthData,
        series: [
          DitherSeries(
            id: "bytes",
            label: DashL10n.ui("Bandwidth"),
            color: DashTheme.DitherChart.accentTeal(
              colorScheme: colorScheme,
              contrast: colorSchemeContrast),
            variant: .gradient)
        ],
        options: DashTheme.DitherChart.options(
          showsLegend: false,
          accessibility: DitherAccessibility(
            title: DashL10n.ui("Bandwidth"),
            summary: ZoneAnalyticsChartModel.bandwidthAccessibilitySummary(
              rangeLabel: DashL10n.ui(range.totalsHeading),
              total: bandwidth(totalBytes)),
            categoryAxisLabel: DashL10n.ui(range == .day ? "Hour" : "Day"),
            valueAxisLabel: DashL10n.ui("Bytes")),
          valueFormat: .byteCount(),
          leadingMargin: 58),
        onTap: { navigator?.push(.chartDetail(bandwidthDetail)) }
      )
      .frame(height: DashTheme.DitherChart.height(dynamicTypeSize: dynamicTypeSize))
    }
  }

  private var ditherSeries: [DitherSeries] {
    var series = [
      DitherSeries(
        id: "requests",
        label: DashL10n.ui("Requests"),
        color: DashTheme.DitherChart.brand(
          colorScheme: colorScheme,
          contrast: colorSchemeContrast),
        variant: .gradient)
    ]
    if totalThreats > 0 {
      series.append(
        DitherSeries(
          id: "threats",
          label: DashL10n.ui("Threats"),
          color: DashTheme.DitherChart.warning(
            colorScheme: colorScheme,
            contrast: colorSchemeContrast),
          variant: .hatched))
    }
    return series
  }

  private var requestsDetail: DashChartDetail {
    chartDetail(
      title: "Requests",
      summaryValue: totalRequests.formatted(.number.locale(DashL10n.activeLocale)),
      trend: DashChartTrend(
        current: Double(totalRequests),
        previous: snapshot.previousTotalRequests.map(Double.init),
        polarity: .neutral),
      data: snapshot.requestsData,
      series: ditherSeries,
      valueAxisLabel: "Events",
      axisValueFormat: .compact,
      tableValueFormat: .number(maximumFractionDigits: 0),
      accessibilitySummary: ZoneAnalyticsChartModel.chartAccessibilitySummary(
        rangeLabel: DashL10n.ui(range.totalsHeading),
        requests: totalRequests,
        threats: totalThreats),
      isLine: false)
  }

  private var visitorsDetail: DashChartDetail {
    let series = [
      DitherSeries(
        id: "uniques",
        label: DashL10n.ui("Unique visitors"),
        color: DashTheme.DitherChart.accentPurple(
          colorScheme: colorScheme,
          contrast: colorSchemeContrast),
        variant: .gradient)
    ]
    return chartDetail(
      title: "Unique visitors",
      summaryValue: peakUniques.formatted(.number.locale(DashL10n.activeLocale)),
      trend: DashChartTrend(
        current: Double(peakUniques),
        previous: snapshot.previousPeakUniques.map(Double.init),
        polarity: .neutral),
      data: snapshot.visitorsData,
      series: series,
      valueAxisLabel: "Visitors",
      axisValueFormat: .compact,
      tableValueFormat: .number(maximumFractionDigits: 0),
      accessibilitySummary: ZoneAnalyticsChartModel.visitorsAccessibilitySummary(
        rangeLabel: DashL10n.ui(range.totalsHeading),
        peak: peakUniques,
        isHourly: range == .day),
      isLine: true)
  }

  private var bandwidthDetail: DashChartDetail {
    let series = [
      DitherSeries(
        id: "bytes",
        label: DashL10n.ui("Bandwidth"),
        color: DashTheme.DitherChart.accentTeal(
          colorScheme: colorScheme,
          contrast: colorSchemeContrast),
        variant: .gradient)
    ]
    return chartDetail(
      title: "Bandwidth",
      summaryValue: bandwidth(totalBytes),
      trend: DashChartTrend(
        current: Double(totalBytes),
        previous: snapshot.previousTotalBytes.map(Double.init),
        polarity: .neutral),
      data: snapshot.bandwidthData,
      series: series,
      valueAxisLabel: "Bytes",
      axisValueFormat: .byteCount,
      tableValueFormat: .byteCount,
      accessibilitySummary: ZoneAnalyticsChartModel.bandwidthAccessibilitySummary(
        rangeLabel: DashL10n.ui(range.totalsHeading),
        total: bandwidth(totalBytes)),
      isLine: false)
  }

  private func chartDetail(
    title: String,
    summaryValue: String,
    trend: DashChartTrend?,
    data: [DitherDatum],
    series: [DitherSeries],
    valueAxisLabel: String,
    axisValueFormat: DashChartValueFormat,
    tableValueFormat: DashChartValueFormat,
    accessibilitySummary: String,
    isLine: Bool
  ) -> DashChartDetail {
    let points = zip(data, snapshot.points).map { datum, point in
      DashChartDataPoint(
        datum: datum,
        tableLabel: ZoneAnalyticsChartModel.detailLabel(
          point.date,
          range: range,
          locale: DashL10n.activeLocale))
    }
    let content: DashChartDetailContent =
      isLine
      ? .line(points: points, series: series)
      : .area(points: points, series: series)
    return DashChartDetail(
      title: title,
      rangeLabel: range.totalsHeading,
      summaryValue: summaryValue,
      trend: trend,
      categoryAxisLabel: range == .day ? "Hour" : "Day",
      valueAxisLabel: valueAxisLabel,
      axisValueFormat: axisValueFormat,
      tableValueFormat: tableValueFormat,
      accessibilitySummary: accessibilitySummary,
      content: content,
      featureID: .zones,
      readScopes: DashAuthorizationScopes.zoneAnalytics)
  }

  /// Zones on plans that do not return `uniq { uniques }` come back as all
  /// zeroes; a flat line at zero is noise, so drop the card instead.
  private var showsVisitors: Bool { peakUniques > 0 }
  private var peakUniques: Int { snapshot.peakUniques }

  private var totalRequests: Int { snapshot.totalRequests }
  private var totalThreats: Int { snapshot.totalThreats }
  private var totalCachedRequests: Int { snapshot.totalCachedRequests }
  /// Share of requests the edge answered without touching the origin — the
  /// reason the zone is on Cloudflare at all.
  private var cacheHitRatio: Double {
    totalRequests > 0 ? Double(totalCachedRequests) / Double(totalRequests) : 0
  }
  private var totalBytes: Int64 { snapshot.totalBytes }

  private func bandwidth(_ bytes: Int64) -> String {
    bytes.formatted(.byteCount(style: .binary).locale(DashL10n.activeLocale))
  }

  private func loadAll(force: Bool = false) async {
    if force {
      loadingRanges = Set(AnalyticsRange.allCases)
    } else {
      loadingRanges = Set(AnalyticsRange.allCases.filter { snapshotsByRange[$0] == nil })
    }
    // Fan out all three ranges up front so tab switches only swap already-warm
    // points instead of kicking a cold load. Client calls hop off MainActor.
    async let day: Void = loadRange(.day, force: force)
    async let week: Void = loadRange(.week, force: force)
    async let month: Void = loadRange(.month, force: force)
    _ = await (day, week, month)
  }

  private func loadRange(_ target: AnalyticsRange, force: Bool) async {
    defer { loadingRanges.remove(target) }
    guard force || snapshotsByRange[target] == nil else { return }
    guard let context = model.accountRequestContext else { return }
    do {
      let loaded = try await fetchSnapshot(range: target, force: force)
      guard model.isCurrentAccount(context) else { return }
      snapshotsByRange[target] = loaded.snapshot
      errorByRange[target] = nil
      if loaded.isNewData {
        let domainName = model.featureCache
          .cachedZone(id: zoneID, accountID: context.accountID)?.name
        MetricsWidgetPublisher.publishDomain(
          snapshot: loaded.snapshot,
          accountID: context.accountID,
          accountName: model.activeAccount?.name ?? context.accountID,
          domainID: zoneID,
          domainName: domainName,
          range: target,
          fetchedAt: loaded.fetchedAt)
      }
    } catch {
      guard model.isCurrentAccount(context) else { return }
      if snapshotsByRange[target] == nil {
        errorByRange[target] = error.dashActionableMessage
      }
    }
  }

  private func fetchSnapshot(
    range: AnalyticsRange,
    force: Bool
  ) async throws -> (snapshot: ZoneAnalyticsSnapshot, fetchedAt: Date, isNewData: Bool) {
    let points: [ZoneAnalyticsChartPoint]
    let previousPoints: [ZoneAnalyticsChartPoint]?
    let fetchedAt: Date
    let isNewData: Bool
    switch range {
    case .day:
      let key = FeatureCacheKey.zoneAnalyticsHourly(zoneID)
      if !force,
        let cached:
          (
            value: AnalyticsPeriodComparison<ZoneAnalyticsPoint>,
            fetchedAt: Date
          ) =
          model.featureCache.getWithFetchedAt(key)
      {
        points = ZoneAnalyticsChartModel.points(fromHourly: cached.value.current)
        previousPoints = cached.value.previous.map {
          ZoneAnalyticsChartModel.points(fromHourly: $0)
        }
        fetchedAt = cached.fetchedAt
        isNewData = false
        break
      }
      let hourly = try await model.client.zoneAnalyticsHourlyComparison(
        zoneID: zoneID,
        hours: 24)
      fetchedAt = .now
      model.featureCache.set(key, hourly, fetchedAt: fetchedAt)
      points = ZoneAnalyticsChartModel.points(fromHourly: hourly.current)
      previousPoints = hourly.previous.map {
        ZoneAnalyticsChartModel.points(fromHourly: $0)
      }
      isNewData = true
    case .week, .month:
      let days = range == .week ? 7 : 30
      let key = FeatureCacheKey.zoneAnalytics(zoneID, days: days)
      if !force,
        let cached:
          (
            value: AnalyticsPeriodComparison<ZoneAnalyticsDay>,
            fetchedAt: Date
          ) =
          model.featureCache.getWithFetchedAt(key)
      {
        points = ZoneAnalyticsChartModel.points(fromDaily: cached.value.current)
        previousPoints = cached.value.previous.map {
          ZoneAnalyticsChartModel.points(fromDaily: $0)
        }
        fetchedAt = cached.fetchedAt
        isNewData = false
        break
      }
      let daily = try await model.client.zoneAnalyticsComparison(
        zoneID: zoneID,
        days: days)
      fetchedAt = .now
      model.featureCache.set(key, daily, fetchedAt: fetchedAt)
      points = ZoneAnalyticsChartModel.points(fromDaily: daily.current)
      previousPoints = daily.previous.map {
        ZoneAnalyticsChartModel.points(fromDaily: $0)
      }
      isNewData = true
    }
    return (
      ZoneAnalyticsChartModel.snapshot(
        points: points,
        previousPoints: previousPoints,
        range: range,
        locale: DashL10n.activeLocale),
      fetchedAt,
      isNewData
    )
  }
}
