import CloudflareAPI
import SwiftDitherKit
import SwiftUI

/// A single normalized point for the chart, independent of whether it came
/// from the hourly or daily dataset.
struct ZoneAnalyticsChartPoint: Identifiable, Hashable {
  let date: Date
  let requests: Int
  let threats: Int
  let bytes: Int64
  let pageViews: Int
  let uniques: Int
  let cachedRequests: Int

  var id: Date { date }
}

/// Pure conversion + parsing, so the date handling is unit-tested away from
/// the view. Both builders return ascending, dropping unparseable stamps.
enum ZoneAnalyticsChartModel {
  private static let dayParser: DateFormatter = {
    let parser = DateFormatter()
    parser.dateFormat = "yyyy-MM-dd"
    parser.locale = Locale(identifier: "en_US_POSIX")
    parser.timeZone = TimeZone(identifier: "UTC")
    return parser
  }()

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
    days.compactMap { day in
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
}

enum AnalyticsRange: Hashable, CaseIterable {
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
  let zoneID: String
  @State private var range: AnalyticsRange = .day
  @State private var pointsByRange: [AnalyticsRange: [ZoneAnalyticsChartPoint]] = [:]
  @State private var errorByRange: [AnalyticsRange: String] = [:]
  @State private var loadingRanges: Set<AnalyticsRange> = Set(AnalyticsRange.allCases)
  @State private var selectedSeriesID: String?

  private var points: [ZoneAnalyticsChartPoint] { pointsByRange[range] ?? [] }
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
      hasContent: !points.isEmpty,
      retry: { Task { await loadAll(force: true) } },
      header: {
        DashTextTabs(
          items: [("24h", AnalyticsRange.day), ("7d", .week), ("30d", .month)],
          selection: $range
        )
      }
    ) {
      if points.isEmpty {
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
    title: LocalizedStringKey,
    @ViewBuilder chart: () -> Chart
  ) -> some View {
    DashGlassCard {
      VStack(alignment: .leading, spacing: 12) {
        Text(title).dashTextStyle(.footnoteSemibold).foregroundStyle(DashTheme.subtle)
        chart()
      }
    }
  }

  private var requestsChartCard: some View {
    chartCard(title: "Requests") {
      DitherAreaChart(
        data: ditherData { ["requests": Double($0.requests), "threats": Double($0.threats)] },
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
        selection: $selectedSeriesID
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
    chartCard(title: "Unique visitors") {
      DitherLineChart(
        data: ditherData { ["uniques": Double($0.uniques)] },
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
            valueAxisLabel: DashL10n.ui("Visitors")))
      )
      .frame(height: DashTheme.DitherChart.height(dynamicTypeSize: dynamicTypeSize))
    }
  }

  private var bandwidthChartCard: some View {
    chartCard(title: "Bandwidth") {
      DitherAreaChart(
        data: ditherData { ["bytes": Double($0.bytes)] },
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
          leadingMargin: 58)
      )
      .frame(height: DashTheme.DitherChart.height(dynamicTypeSize: dynamicTypeSize))
    }
  }

  private func ditherData(
    values: (ZoneAnalyticsChartPoint) -> [String: Double]
  ) -> [DitherDatum] {
    points.map { point in
      DitherDatum(
        id: point.date.ISO8601Format(),
        label: point.date.formatted(xAxisFormat),
        values: values(point))
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

  private var xAxisFormat: Date.FormatStyle {
    (range == .day
      ? Date.FormatStyle.dateTime.hour()
      : Date.FormatStyle.dateTime.month(.abbreviated).day())
      .locale(DashL10n.activeLocale)
  }

  /// Zones on plans that do not return `uniq { uniques }` come back as all
  /// zeroes; a flat line at zero is noise, so drop the card instead.
  private var showsVisitors: Bool { peakUniques > 0 }
  private var peakUniques: Int { points.map(\.uniques).max() ?? 0 }

  private var totalRequests: Int { points.reduce(0) { $0 + $1.requests } }
  private var totalThreats: Int { points.reduce(0) { $0 + $1.threats } }
  private var totalCachedRequests: Int { points.reduce(0) { $0 + $1.cachedRequests } }
  /// Share of requests the edge answered without touching the origin — the
  /// reason the zone is on Cloudflare at all.
  private var cacheHitRatio: Double {
    totalRequests > 0 ? Double(totalCachedRequests) / Double(totalRequests) : 0
  }
  private var totalBytes: Int64 { points.reduce(0) { $0 + $1.bytes } }

  private func bandwidth(_ bytes: Int64) -> String {
    bytes.formatted(.byteCount(style: .binary).locale(DashL10n.activeLocale))
  }

  private func loadAll(force: Bool = false) async {
    if force {
      loadingRanges = Set(AnalyticsRange.allCases)
    } else {
      loadingRanges = Set(AnalyticsRange.allCases.filter { pointsByRange[$0] == nil })
    }
    // Fan out all three ranges up front so tab switches only swap already-warm
    // points instead of kicking a cold load. Client calls hop off MainActor.
    async let day: Void = loadRange(.day, force: force)
    async let week: Void = loadRange(.week, force: force)
    async let month: Void = loadRange(.month, force: force)
    _ = await (day, week, month)
  }

  private func loadRange(_ target: AnalyticsRange, force: Bool) async {
    do {
      let points = try await fetchPoints(range: target, force: force)
      pointsByRange[target] = points
      errorByRange[target] = nil
    } catch {
      if pointsByRange[target] == nil {
        errorByRange[target] = error.dashActionableMessage
      }
    }
    loadingRanges.remove(target)
  }

  private func fetchPoints(range: AnalyticsRange, force: Bool) async throws
    -> [ZoneAnalyticsChartPoint]
  {
    switch range {
    case .day:
      let key = FeatureCacheKey.zoneAnalyticsHourly(zoneID)
      if !force, let cached: [ZoneAnalyticsPoint] = model.featureCache.get(key) {
        return ZoneAnalyticsChartModel.points(fromHourly: cached)
      }
      let hourly = try await model.client.zoneAnalyticsHourly(zoneID: zoneID, hours: 24)
      model.featureCache.set(key, hourly)
      return ZoneAnalyticsChartModel.points(fromHourly: hourly)
    case .week, .month:
      let days = range == .week ? 7 : 30
      let key = FeatureCacheKey.zoneAnalytics(zoneID, days: days)
      if !force, let cached: [ZoneAnalyticsDay] = model.featureCache.get(key) {
        return ZoneAnalyticsChartModel.points(fromDaily: cached)
      }
      let daily = try await model.client.zoneAnalytics(zoneID: zoneID, days: days)
      model.featureCache.set(key, daily)
      return ZoneAnalyticsChartModel.points(fromDaily: daily)
    }
  }
}
