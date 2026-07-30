import CloudflareAPI
import SwiftDitherKit
import SwiftUI

struct DNSAnalyticsChartPoint: Identifiable, Hashable, Sendable {
  let date: Date
  let queries: Int
  var id: Date { date }
}

struct DNSAnalyticsSnapshot: Hashable, Sendable {
  static let empty = DNSAnalyticsSnapshot(
    points: [], data: [], totalQueries: 0, previousTotalQueries: nil, queryTypes: [])

  let points: [DNSAnalyticsChartPoint]
  let data: [DitherDatum]
  let totalQueries: Int
  let previousTotalQueries: Int?
  let queryTypes: [DNSAnalyticsBucket]

  var isEmpty: Bool { points.isEmpty }
}

enum DNSAnalyticsChartModel {
  static func points(from summary: DNSAnalyticsSummary) -> [DNSAnalyticsChartPoint] {
    let dayParser = DateFormatter()
    dayParser.dateFormat = "yyyy-MM-dd"
    dayParser.locale = Locale(identifier: "en_US_POSIX")
    dayParser.timeZone = TimeZone(identifier: "UTC")
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return summary.points.compactMap { point in
      let date =
        dayParser.date(from: point.datetime)
        ?? iso.date(from: point.datetime)
        ?? fractional.date(from: point.datetime)
      guard let date else { return nil }
      return DNSAnalyticsChartPoint(date: date, queries: point.queries)
    }
    .sorted { $0.date < $1.date }
  }

  static func snapshot(
    from summary: DNSAnalyticsSummary,
    range: AnalyticsRange,
    locale: Locale
  ) -> DNSAnalyticsSnapshot {
    let chartPoints = points(from: summary)
    let labelStyle: Date.FormatStyle =
      range == .day
      ? Date.FormatStyle.dateTime.hour().locale(locale)
      : Date.FormatStyle.dateTime.month(.abbreviated).day().locale(locale)
    let data = chartPoints.map {
      DitherDatum(
        id: $0.date.ISO8601Format(),
        label: $0.date.formatted(labelStyle),
        values: ["queries": Double($0.queries)])
    }
    return DNSAnalyticsSnapshot(
      points: chartPoints,
      data: data,
      totalQueries: summary.totalQueries,
      previousTotalQueries: summary.previousTotalQueries,
      queryTypes: summary.queryTypes)
  }

  static func accessibilitySummary(rangeLabel: String, queries: Int) -> String {
    DashL10n.string(
      "DNS queries chart for \(rangeLabel). Total \(queries.formatted()) queries.")
  }
}

struct DNSAnalyticsView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let zoneID: String
  @State private var range: AnalyticsRange = .day
  @State private var snapshotsByRange: [AnalyticsRange: DNSAnalyticsSnapshot] = [:]
  @State private var errorByRange: [AnalyticsRange: String] = [:]
  @State private var loadingRanges: Set<AnalyticsRange> = Set(AnalyticsRange.allCases)
  @State private var selectedSeriesID: String?

  private var snapshot: DNSAnalyticsSnapshot { snapshotsByRange[range] ?? .empty }
  private var isLoadingCurrent: Bool { loadingRanges.contains(range) }
  private var currentError: String? { errorByRange[range] }

  var body: some View {
    DashFeatureList(
      isLoading: isLoadingCurrent,
      error: currentError,
      hasContent: !snapshot.isEmpty,
      retry: { Task { await loadAll(force: true) } },
      skeleton: { dnsAnalyticsSkeleton },
      header: {
        DashTextTabs(
          items: [("24h", AnalyticsRange.day), ("7d", .week), ("30d", .month)],
          selection: $range
        )
      }
    ) {
      if snapshot.isEmpty {
        DashEmptyState(
          icon: SolarAsset.Content.globus,
          title: "No DNS queries yet",
          message: "Query volume for this domain will appear here."
        )
      } else {
        DashSurfaceStack {
          queriesMetric
          queriesChartCard
          if !snapshot.queryTypes.isEmpty {
            queryTypesGroup
          }
        }
      }
    }
    .detailHeader(icon: .solar(SolarAsset.Content.globus), title: "DNS analytics")
    .refreshable { await loadAll(force: true) }
    .onChange(of: range) { selectedSeriesID = nil }
    .task { await loadAll() }
  }

  private var dnsAnalyticsSkeleton: some View {
    DashSurfaceStack {
      DashMetricTilePlaceholder()
      DashChartPanelPlaceholder()
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Loading")
  }

  private var queriesMetric: some View {
    DashGlassCard {
      VStack(alignment: .leading, spacing: 4) {
        Text(DashL10n.ui(range.totalsHeading))
          .dashTextStyle(.footnoteSemibold)
          .foregroundStyle(DashTheme.subtle)
        Text(snapshot.totalQueries.formatted())
          .dashTextStyle(.sectionTitle)
          .monospacedDigit()
          .foregroundStyle(DashTheme.strong)
          .lineLimit(1)
          .minimumScaleFactor(0.7)
          .contentTransition(
            reduceMotion
              ? .opacity : .numericText(value: Double(snapshot.totalQueries)))
        Text("Queries")
          .dashTextStyle(.caption)
          .foregroundStyle(DashTheme.subtle)
        DashChartTrendLabel(
          trend: DashChartTrend(
            current: Double(snapshot.totalQueries),
            previous: snapshot.previousTotalQueries.map(Double.init),
            polarity: .neutral))
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .combine)
  }

  private var queriesChartCard: some View {
    DashGlassCard {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .center, spacing: 8) {
          Text("Queries")
            .dashTextStyle(.footnoteSemibold)
            .foregroundStyle(DashTheme.subtle)
          Spacer(minLength: 4)
          DashChartDetailButton(detail: queriesDetail)
        }
        DashAreaChart(
          data: snapshot.data,
          series: [
            DitherSeries(
              id: "queries",
              label: DashL10n.ui("Queries"),
              color: DashTheme.DitherChart.brand(
                colorScheme: colorScheme,
                contrast: colorSchemeContrast),
              variant: .gradient)
          ],
          options: DashTheme.DitherChart.options(
            showsLegend: false,
            accessibility: DitherAccessibility(
              title: DashL10n.ui("DNS queries"),
              summary: DNSAnalyticsChartModel.accessibilitySummary(
                rangeLabel: DashL10n.ui(range.totalsHeading),
                queries: snapshot.totalQueries),
              categoryAxisLabel: DashL10n.ui(range == .day ? "Hour" : "Day"),
              valueAxisLabel: DashL10n.ui("Queries"))),
          highlighted: selectedSeriesID != nil,
          selection: $selectedSeriesID
        )
        .frame(height: DashTheme.DitherChart.height(dynamicTypeSize: dynamicTypeSize))
      }
    }
  }

  private var queryTypesGroup: some View {
    DashListGroup(title: "Query types") {
      dashListCard {
        dashListCardRows(items: snapshot.queryTypes) { bucket in
          DashListRow(
            title: bucket.label,
            subtitle: DashL10n.string("\(bucket.count.formatted()) queries"),
            icon: SolarAsset.Content.globus,
            showsChevron: false
          )
        }
      }
    }
  }

  private var queriesDetail: DashChartDetail {
    let series = [
      DitherSeries(
        id: "queries",
        label: DashL10n.ui("Queries"),
        color: DashTheme.DitherChart.brand(
          colorScheme: colorScheme,
          contrast: colorSchemeContrast),
        variant: .gradient)
    ]
    let ranges = AnalyticsRange.allCases.compactMap { item -> DashChartDetailRange? in
      guard let snap = snapshotsByRange[item], !snap.isEmpty else { return nil }
      let points = zip(snap.data, snap.points).map { datum, point in
        DashChartDataPoint(
          datum: datum,
          tableLabel: point.date.formatted(
            item == .day
              ? .dateTime.month(.abbreviated).day().hour().minute().locale(DashL10n.activeLocale)
              : .dateTime.year().month(.abbreviated).day().locale(DashL10n.activeLocale)))
      }
      return DashChartDetailRange(
        range: item,
        rangeLabel: item.totalsHeading,
        summaryValue: snap.totalQueries.formatted(.number.locale(DashL10n.activeLocale)),
        trend: DashChartTrend(
          current: Double(snap.totalQueries),
          previous: snap.previousTotalQueries.map(Double.init),
          polarity: .neutral),
        categoryAxisLabel: item == .day ? "Hour" : "Day",
        accessibilitySummary: DNSAnalyticsChartModel.accessibilitySummary(
          rangeLabel: DashL10n.ui(item.totalsHeading),
          queries: snap.totalQueries),
        content: .area(points: points, series: series))
    }
    let current = ranges.first(where: { $0.range == range }) ?? ranges.first
    return DashChartDetail(
      title: "Queries",
      rangeLabel: current?.rangeLabel ?? range.totalsHeading,
      summaryValue: current?.summaryValue,
      trend: current?.trend,
      categoryAxisLabel: current?.categoryAxisLabel ?? (range == .day ? "Hour" : "Day"),
      valueAxisLabel: "Queries",
      accessibilitySummary: current?.accessibilitySummary ?? "",
      content: current?.content ?? .area(points: [], series: series),
      featureID: .zones,
      readScopes: DashAuthorizationScopes.zoneAnalytics,
      ranges: ranges,
      selectedRange: range)
  }

  private func loadAll(force: Bool = false) async {
    await withTaskGroup(of: Void.self) { group in
      for item in AnalyticsRange.allCases {
        group.addTask { await loadRange(item, force: force) }
      }
    }
  }

  private func loadRange(_ range: AnalyticsRange, force: Bool) async {
    loadingRanges.insert(range)
    errorByRange[range] = nil
    defer { loadingRanges.remove(range) }
    do {
      let summary: DNSAnalyticsSummary
      switch range {
      case .day:
        let key = FeatureCacheKey.zoneDNSAnalyticsHourly(zoneID)
        if !force, let cached: DNSAnalyticsSummary = model.featureCache.get(key) {
          apply(cached, range: range)
          return
        }
        summary = try await model.client.dnsAnalyticsHourlyComparison(zoneID: zoneID, hours: 24)
        model.featureCache.set(key, summary)
      case .week, .month:
        let days = range == .week ? 7 : 30
        let key = FeatureCacheKey.zoneDNSAnalytics(zoneID, days: days)
        if !force, let cached: DNSAnalyticsSummary = model.featureCache.get(key) {
          apply(cached, range: range)
          return
        }
        summary = try await model.client.dnsAnalyticsDailyComparison(zoneID: zoneID, days: days)
        model.featureCache.set(key, summary)
      }
      apply(summary, range: range)
    } catch {
      guard !error.dashIsCancellation else { return }
      errorByRange[range] = error.dashActionableMessage
    }
  }

  private func apply(_ summary: DNSAnalyticsSummary, range: AnalyticsRange) {
    snapshotsByRange[range] = DNSAnalyticsChartModel.snapshot(
      from: summary,
      range: range,
      locale: DashL10n.activeLocale)
  }
}
