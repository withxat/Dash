import CloudflareAPI
import SwiftDitherKit
import SwiftUI

// MARK: - Pure model

/// One headline metric on the Web Analytics screen: its value for the selected
/// window, the same value for the immediately preceding window (which feeds the
/// shared trend label), and the per-day series that draws the sparkline.
struct WebAnalyticsSeriesPoint: Identifiable, Hashable, Sendable {
  let date: Date
  let value: Double

  var id: Date { date }
}

struct WebAnalyticsMetric: Hashable, Sendable {
  static let zero = WebAnalyticsMetric(current: 0, previous: nil, points: [])

  let current: Double
  let previous: Double?
  let points: [WebAnalyticsSeriesPoint]

  var series: [Double] { points.map(\.value) }

  /// Fractional change versus the preceding window, or `nil` when there is no
  /// comparable prior window (first-ever data, or a zero baseline).
  var delta: Double? {
    guard let previous, previous != 0 else { return nil }
    return (current - previous) / previous
  }
}

/// Headline Web Analytics figures plus optional Core Web Vitals p75s.
struct WebAnalyticsMetricsSnapshot: Hashable, Sendable {
  static let empty = WebAnalyticsMetricsSnapshot(
    pageLoadTimeMs: .zero, visits: .zero, pageViews: .zero,
    lcpP75Ms: .zero, inpP75Ms: .zero, clsP75: .zero, hasData: false)

  let pageLoadTimeMs: WebAnalyticsMetric
  let visits: WebAnalyticsMetric
  let pageViews: WebAnalyticsMetric
  let lcpP75Ms: WebAnalyticsMetric
  let inpP75Ms: WebAnalyticsMetric
  let clsP75: WebAnalyticsMetric
  let hasData: Bool

  var isEmpty: Bool { !hasData }
  var hasWebVitals: Bool {
    lcpP75Ms.current > 0 || inpP75Ms.current > 0 || clsP75.current > 0
      || !lcpP75Ms.points.isEmpty || !inpP75Ms.points.isEmpty || !clsP75.points.isEmpty
  }
}

private struct WebAnalyticsDay {
  let date: Date
  let pageviews: Int
  let visits: Int
  let pageLoadTimeP50Ms: Int?
  let lcpP75Ms: Double?
  let inpP75Ms: Double?
  let clsP75: Double?
}

/// Pure parsing + summaries, unit-tested away from the view.
enum WebAnalyticsChartModel {
  private static func makeDayParser() -> DateFormatter {
    let parser = DateFormatter()
    parser.dateFormat = "yyyy-MM-dd"
    parser.locale = Locale(identifier: "en_US_POSIX")
    parser.timeZone = TimeZone(identifier: "UTC")
    return parser
  }

  /// The site whose injecting ruleset points at this zone. A zone can only
  /// have one, but the account list carries every site it owns.
  static func site(for zoneID: String, in sites: [RUMSite]) -> RUMSite? {
    sites.first { $0.zoneTag == zoneID }
  }

  /// Folds `comparison.days` (which spans `window * 2` calendar days) into the three
  /// dashboard metrics. The most recent `window` days form the current period;
  /// the `window` days before that form the comparison period. Page views and
  /// visits sum. Page-load time uses Cloudflare's exact whole-window p50; the
  /// daily p50 buckets are retained only for the chart.
  static func metrics(from comparison: RUMMetricsComparison, window: Int, now: Date)
    -> WebAnalyticsMetricsSnapshot
  {
    let parser = makeDayParser()
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone

    let parsed = comparison.days.compactMap { day -> WebAnalyticsDay? in
      guard let date = parser.date(from: day.date) else { return nil }
      return WebAnalyticsDay(
        date: date, pageviews: day.pageviews, visits: day.visits,
        pageLoadTimeP50Ms: day.pageLoadTimeP50Ms,
        lcpP75Ms: day.lcpP75Ms, inpP75Ms: day.inpP75Ms, clsP75: day.clsP75)
    }

    let step = max(window, 1)
    let end = calendar.startOfDay(for: now)
    let currentStart = calendar.date(byAdding: .day, value: -step, to: end) ?? end
    let previousStart =
      calendar.date(byAdding: .day, value: -step, to: currentStart) ?? currentStart

    let current =
      parsed
      .filter { $0.date >= currentStart && $0.date < end }
      .sorted { $0.date < $1.date }
    let previous =
      parsed
      .filter { $0.date >= previousStart && $0.date < currentStart }
      .sorted { $0.date < $1.date }

    func summed(_ value: @escaping (WebAnalyticsDay) -> Int) -> WebAnalyticsMetric {
      WebAnalyticsMetric(
        current: Double(current.reduce(0) { $0 + value($1) }),
        previous: previous.isEmpty ? nil : Double(previous.reduce(0) { $0 + value($1) }),
        points: current.map {
          WebAnalyticsSeriesPoint(date: $0.date, value: Double(value($0)))
        })
    }

    let pageViews = summed { $0.pageviews }
    let visits = summed { $0.visits }
    // Older GraphQL fixtures do not contain the two whole-window aliases. Keep
    // their current headline useful, but never manufacture a comparison trend
    // from an average of daily medians.
    let currentPageLoad =
      comparison.currentPageLoadTimeP50Ms.map(Double.init)
      ?? weightedMedian(current)
      ?? 0
    let previousPageLoad =
      comparison.currentPageLoadTimeP50Ms == nil
      ? nil
      : comparison.previousPageLoadTimeP50Ms.map(Double.init)
    let pageLoad = WebAnalyticsMetric(
      current: currentPageLoad,
      previous: previousPageLoad,
      points: current.compactMap { day in
        day.pageLoadTimeP50Ms.map {
          WebAnalyticsSeriesPoint(date: day.date, value: Double($0))
        }
      })

    func vital(
      currentTotal: Double?,
      previousTotal: Double?,
      daily: @escaping (WebAnalyticsDay) -> Double?
    ) -> WebAnalyticsMetric {
      WebAnalyticsMetric(
        current: currentTotal ?? 0,
        previous: previousTotal,
        points: current.compactMap { day in
          daily(day).map { WebAnalyticsSeriesPoint(date: day.date, value: $0) }
        })
    }

    return WebAnalyticsMetricsSnapshot(
      pageLoadTimeMs: pageLoad,
      visits: visits,
      pageViews: pageViews,
      lcpP75Ms: vital(
        currentTotal: comparison.currentLcpP75Ms,
        previousTotal: comparison.previousLcpP75Ms,
        daily: \.lcpP75Ms),
      inpP75Ms: vital(
        currentTotal: comparison.currentInpP75Ms,
        previousTotal: comparison.previousInpP75Ms,
        daily: \.inpP75Ms),
      clsP75: vital(
        currentTotal: comparison.currentClsP75,
        previousTotal: comparison.previousClsP75,
        daily: \.clsP75),
      hasData: pageViews.current > 0 || visits.current > 0)
  }

  /// Compatibility fallback for old fixtures that predate whole-window totals.
  /// This is display-only; it must never feed a period-over-period trend.
  private static func weightedMedian(_ days: [WebAnalyticsDay]) -> Double? {
    let sampled = days.compactMap { day in
      day.pageLoadTimeP50Ms.map { (p50: $0, weight: day.pageviews) }
    }
    guard !sampled.isEmpty else { return nil }
    let weight = sampled.reduce(0) { $0 + $1.weight }
    if weight > 0 {
      let total = sampled.reduce(0.0) { $0 + Double($1.p50) * Double($1.weight) }
      return total / Double(weight)
    }
    let total = sampled.reduce(0.0) { $0 + Double($1.p50) }
    return total / Double(sampled.count)
  }
}

// MARK: - View

/// Beacon-reported Web Analytics for one zone. Deliberately separate from
/// `ZoneAnalyticsView`: that screen is what the edge saw, this one is what real
/// browsers reported, and the two page-view numbers never match.
struct WebAnalyticsView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  @Environment(\.openURL) private var openURL
  private let zoneID: String

  @State private var range: AnalyticsRange = .week
  @State private var site: RUMSite?
  @State private var siteResolved = false
  @State private var snapshotsByRange: [AnalyticsRange: WebAnalyticsMetricsSnapshot] = [:]
  @State private var errorByRange: [AnalyticsRange: String] = [:]
  @State private var loadingRanges: Set<AnalyticsRange> = [.week, .month]
  @State private var loadedContext: AccountRequestContext?

  init(zoneID: String) {
    self.zoneID = zoneID
  }

  private var snapshot: WebAnalyticsMetricsSnapshot { snapshotsByRange[range] ?? .empty }
  private var isLoadingCurrent: Bool { !siteResolved || loadingRanges.contains(range) }
  private var currentError: String? { errorByRange[range] }

  var body: some View {
    DashFeatureList(
      isLoading: isLoadingCurrent,
      error: currentError,
      hasContent: !snapshot.isEmpty,
      retry: { Task { await load(force: true) } },
      skeleton: { webAnalyticsSkeleton },
      header: {
        if site != nil {
          DashTextTabs(
            items: [("7d", AnalyticsRange.week), ("30d", .month)],
            selection: $range
          )
        }
      }
    ) {
      if site == nil || (site?.isCollecting == false && snapshot.isEmpty) {
        beaconMissingState
      } else if snapshot.isEmpty {
        DashEmptyState(
          icon: SolarAsset.Content.graph,
          title: "No page loads yet",
          message: "Web Analytics reports a page view once a real browser loads a page."
        )
      } else {
        DashSurfaceStack {
          metricCard(
            title: "Page load time",
            detailTitle: "Page load time",
            metric: snapshot.pageLoadTimeMs,
            color: DashTheme.DitherChart.accentBlue(
              colorScheme: colorScheme, contrast: colorSchemeContrast),
            trendPolarity: .lowerIsBetter,
            value: durationString(snapshot.pageLoadTimeMs.current),
            valueAxisLabel: "Milliseconds",
            axisValueFormat: .milliseconds(maximumFractionDigits: 0),
            tableValueFormat: .milliseconds(maximumFractionDigits: 0))
          metricCard(
            title: "Visits",
            detailTitle: "Visits",
            metric: snapshot.visits,
            color: DashTheme.DitherChart.accentPurple(
              colorScheme: colorScheme, contrast: colorSchemeContrast),
            trendPolarity: .neutral,
            value: countString(snapshot.visits.current),
            valueAxisLabel: "Visits",
            axisValueFormat: .compact,
            tableValueFormat: .number(maximumFractionDigits: 0))
          metricCard(
            title: "Page views",
            detailTitle: "Page views",
            metric: snapshot.pageViews,
            color: DashTheme.DitherChart.accentTeal(
              colorScheme: colorScheme, contrast: colorSchemeContrast),
            trendPolarity: .neutral,
            value: countString(snapshot.pageViews.current),
            valueAxisLabel: "Page views",
            axisValueFormat: .compact,
            tableValueFormat: .number(maximumFractionDigits: 0))
          if snapshot.hasWebVitals {
            metricCard(
              title: "LCP p75",
              detailTitle: "LCP p75",
              metric: snapshot.lcpP75Ms,
              color: DashTheme.DitherChart.warning(
                colorScheme: colorScheme, contrast: colorSchemeContrast),
              trendPolarity: .lowerIsBetter,
              value: durationString(snapshot.lcpP75Ms.current),
              valueAxisLabel: "Milliseconds",
              axisValueFormat: .milliseconds(maximumFractionDigits: 0),
              tableValueFormat: .milliseconds(maximumFractionDigits: 0))
            metricCard(
              title: "INP p75",
              detailTitle: "INP p75",
              metric: snapshot.inpP75Ms,
              color: DashTheme.DitherChart.accentPurple(
                colorScheme: colorScheme, contrast: colorSchemeContrast),
              trendPolarity: .lowerIsBetter,
              value: durationString(snapshot.inpP75Ms.current),
              valueAxisLabel: "Milliseconds",
              axisValueFormat: .milliseconds(maximumFractionDigits: 0),
              tableValueFormat: .milliseconds(maximumFractionDigits: 0))
            metricCard(
              title: "CLS p75",
              detailTitle: "CLS p75",
              metric: snapshot.clsP75,
              color: DashTheme.DitherChart.accentTeal(
                colorScheme: colorScheme, contrast: colorSchemeContrast),
              trendPolarity: .lowerIsBetter,
              value: clsString(snapshot.clsP75.current),
              valueAxisLabel: "CLS",
              axisValueFormat: .number(maximumFractionDigits: 3),
              tableValueFormat: .number(maximumFractionDigits: 3))
          }
        }
      }
    }
    .detailHeader(icon: .solar(SolarAsset.Content.graph), title: "Web analytics")
    .refreshable { await load(force: true) }
    .task(id: model.accountRequestContext) { await load() }
  }

  /// Three sparkline metric cards — Page load time / Visits / Page views.
  private var webAnalyticsSkeleton: some View {
    DashSurfaceStack {
      DashSparklineCardPlaceholder()
      DashSparklineCardPlaceholder()
      DashSparklineCardPlaceholder()
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Loading")
  }

  /// Dash cannot turn the beacon on: Cloudflare publishes no OAuth scope for
  /// Web Analytics writes, so the account link is the honest affordance.
  private var beaconMissingState: some View {
    DashEmptyState(
      icon: SolarAsset.Content.graph,
      title: "Web Analytics is off",
      message:
        "Cloudflare collects page views once the Web Analytics beacon runs on this domain. Proxied domains can turn it on without editing any HTML.",
      actionTitle: "Open in Cloudflare",
      action: {
        guard let accountID = model.activeAccountID,
          let url = URL(string: "https://dash.cloudflare.com/\(accountID)/web-analytics")
        else { return }
        openURL(url)
      }
    )
  }

  private func metricCard(
    title: LocalizedStringKey,
    detailTitle: String,
    metric: WebAnalyticsMetric,
    color: DitherColor,
    trendPolarity: DashChartTrend.Polarity,
    value: String,
    valueAxisLabel: String,
    axisValueFormat: DashChartValueFormat,
    tableValueFormat: DashChartValueFormat
  ) -> some View {
    let trend = DashChartTrend(
      current: metric.current,
      previous: metric.previous,
      polarity: trendPolarity)
    let detail = webChartDetail(
      title: detailTitle,
      metricKeyPath: webMetricKeyPath(for: detailTitle),
      color: color,
      valueFormatter: { snap in
        switch detailTitle {
        case "Page load time": durationString(snap.pageLoadTimeMs.current)
        case "Visits": countString(snap.visits.current)
        case "LCP p75": durationString(snap.lcpP75Ms.current)
        case "INP p75": durationString(snap.inpP75Ms.current)
        case "CLS p75": clsString(snap.clsP75.current)
        default: countString(snap.pageViews.current)
        }
      },
      valueAxisLabel: valueAxisLabel,
      axisValueFormat: axisValueFormat,
      tableValueFormat: tableValueFormat,
      trendPolarity: trendPolarity)
    return DashGlassCard {
      VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .top, spacing: 8) {
          VStack(alignment: .leading, spacing: 6) {
            Text(title)
              .dashTextStyle(.footnoteSemibold)
              .foregroundStyle(DashTheme.subtle)
            HStack(alignment: .lastTextBaseline, spacing: 8) {
              Text(value)
                .dashTextStyle(.emptyTitle)
                .monospacedDigit()
                .foregroundStyle(DashTheme.strong)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
              DashChartTrendLabel(trend: trend)
              Spacer(minLength: 4)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityElement(children: .combine)
          DashChartDetailButton(detail: detail)
        }
        if metric.series.count >= 2 {
          DashSparkline(values: metric.series, color: color, variant: .gradient)
            .frame(height: 52)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func webMetricKeyPath(
    for detailTitle: String
  ) -> KeyPath<WebAnalyticsMetricsSnapshot, WebAnalyticsMetric> {
    switch detailTitle {
    case "Page load time": \.pageLoadTimeMs
    case "Visits": \.visits
    case "LCP p75": \.lcpP75Ms
    case "INP p75": \.inpP75Ms
    case "CLS p75": \.clsP75
    default: \.pageViews
    }
  }

  private func clsString(_ value: Double) -> String {
    value.formatted(
      .number.precision(.fractionLength(0...3)).locale(DashL10n.activeLocale))
  }

  private func webChartDetail(
    title: String,
    metricKeyPath: KeyPath<WebAnalyticsMetricsSnapshot, WebAnalyticsMetric>,
    color: DitherColor,
    valueFormatter: (WebAnalyticsMetricsSnapshot) -> String,
    valueAxisLabel: String,
    axisValueFormat: DashChartValueFormat,
    tableValueFormat: DashChartValueFormat,
    trendPolarity: DashChartTrend.Polarity
  ) -> DashChartDetail {
    let seriesID = "value"
    let available: [AnalyticsRange] = [.week, .month]
    let ranges: [DashChartDetailRange] = available.compactMap { target in
      guard let snap = snapshotsByRange[target], !snap.isEmpty else { return nil }
      let metric = snap[keyPath: metricKeyPath]
      let value = valueFormatter(snap)
      let points = metric.points.map { point in
        DashChartDataPoint(
          datum: DitherDatum(
            id: point.date.ISO8601Format(),
            label: point.date.formatted(
              .dateTime.month(.abbreviated).day().locale(DashL10n.activeLocale)),
            values: [seriesID: point.value]),
          tableLabel: point.date.formatted(
            .dateTime.year().month(.abbreviated).day().locale(DashL10n.activeLocale)))
      }
      return DashChartDetailRange(
        range: target,
        rangeLabel: target.totalsHeading,
        summaryValue: value,
        trend: DashChartTrend(
          current: metric.current,
          previous: metric.previous,
          polarity: trendPolarity),
        categoryAxisLabel: "Day",
        accessibilitySummary: "\(DashL10n.ui(title)), \(value)",
        content: .area(
          points: points,
          series: [
            DitherSeries(
              id: seriesID,
              label: DashL10n.ui(title),
              color: color,
              variant: .gradient)
          ]))
    }
    let current = ranges.first(where: { $0.range == range }) ?? ranges.first
    return DashChartDetail(
      title: title,
      rangeLabel: current?.rangeLabel ?? range.totalsHeading,
      summaryValue: current?.summaryValue,
      trend: current?.trend,
      categoryAxisLabel: "Day",
      valueAxisLabel: valueAxisLabel,
      axisValueFormat: axisValueFormat,
      tableValueFormat: tableValueFormat,
      accessibilitySummary: current?.accessibilitySummary ?? "",
      content: current?.content ?? .area(points: [], series: []),
      featureID: .zones,
      readScopes: DashAuthorizationScopes.webAnalytics,
      ranges: ranges,
      selectedRange: range)
  }

  private func countString(_ value: Double) -> String {
    Int(value.rounded()).formatted(.number.locale(DashL10n.activeLocale))
  }

  private func durationString(_ ms: Double) -> String {
    "\(Int(ms.rounded()).formatted(.number.locale(DashL10n.activeLocale)))ms"
  }

  private func load(force: Bool = false) async {
    guard let context = model.accountRequestContext else {
      reset()
      siteResolved = true
      loadingRanges.removeAll()
      return
    }
    if loadedContext != context {
      reset()
      loadedContext = context
    }
    if force {
      loadingRanges = [.week, .month]
    }

    let resolvedSite: RUMSite?
    do {
      let sites = try await resolveSites(accountID: context.accountID, force: force)
      resolvedSite = WebAnalyticsChartModel.site(for: zoneID, in: sites)
    } catch {
      guard model.isCurrentAccount(context), !error.dashIsCancellation else { return }
      let message = error.dashActionableMessage
      errorByRange[.week] = message
      errorByRange[.month] = message
      siteResolved = true
      loadingRanges.removeAll()
      return
    }
    guard model.isCurrentAccount(context), !Task.isCancelled else { return }
    site = resolvedSite
    siteResolved = true
    guard let siteTag = site?.siteTag else {
      loadingRanges.removeAll()
      return
    }
    loadingRanges =
      force ? [.week, .month] : Set([.week, .month].filter { snapshotsByRange[$0] == nil })
    async let week: Void = loadRange(.week, context: context, siteTag: siteTag, force: force)
    async let month: Void = loadRange(.month, context: context, siteTag: siteTag, force: force)
    _ = await (week, month)
  }

  private func resolveSites(accountID: String, force: Bool) async throws -> [RUMSite] {
    let key = FeatureCacheKey.webAnalyticsSites(accountID)
    if !force, let cached: [RUMSite] = model.featureCache.get(key) { return cached }
    let sites = try await model.client.webAnalyticsSites(accountID: accountID)
    model.featureCache.set(key, sites)
    return sites
  }

  private func loadRange(
    _ target: AnalyticsRange,
    context: AccountRequestContext,
    siteTag: String,
    force: Bool
  ) async {
    defer { loadingRanges.remove(target) }
    let days = target == .month ? 30 : 7
    let key = FeatureCacheKey.webAnalyticsMetrics(siteTag, days: days)
    do {
      let raw: RUMMetricsComparison
      if !force, let cached: RUMMetricsComparison = model.featureCache.get(key) {
        raw = cached
      } else {
        raw = try await model.client.webAnalyticsMetrics(
          accountID: context.accountID, siteTag: siteTag, days: days)
        guard model.isCurrentAccount(context), !Task.isCancelled else { return }
        model.featureCache.set(key, raw)
      }
      guard model.isCurrentAccount(context), !Task.isCancelled else { return }
      snapshotsByRange[target] = WebAnalyticsChartModel.metrics(
        from: raw, window: days, now: Date())
      errorByRange[target] = nil
    } catch {
      guard model.isCurrentAccount(context), !error.dashIsCancellation else { return }
      errorByRange[target] = error.dashActionableMessage
    }
  }

  private func reset() {
    loadedContext = nil
    site = nil
    siteResolved = false
    snapshotsByRange = [:]
    errorByRange = [:]
    loadingRanges = [.week, .month]
  }
}
