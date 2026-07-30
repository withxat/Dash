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

// MARK: - Cards

/// The Web Analytics cards, in order. Each case owns its catalog title, series
/// key, snapshot key path, polarity, and formats.
///
/// The screen used to switch on a card's English title to find both its key path
/// and its value formatter — the one thing `StatusBadge` and the relay's
/// `mapAlert` already forbid: identity and presentation must never be
/// re-derived from wording, because the wording is what gets localized.
private enum WebAnalyticsChartMetric: String, Hashable, CaseIterable, Identifiable {
  case pageLoadTime
  case visits
  case pageViews
  case lcpP75
  case inpP75
  case clsP75

  /// Shown whenever the beacon reported page loads at all.
  static let headline: [Self] = [.pageLoadTime, .visits, .pageViews]

  var id: String { rawValue }

  /// Catalog key; also the pushed detail's title.
  var title: String {
    switch self {
    case .pageLoadTime: "Page load time"
    case .visits: "Visits"
    case .pageViews: "Page views"
    case .lcpP75: "LCP p75"
    case .inpP75: "INP p75"
    case .clsP75: "CLS p75"
    }
  }

  /// Series id shared by the collapsed sparkline and the detail chart.
  var seriesKey: String { rawValue }

  /// Where this card's figures live in a loaded snapshot.
  var keyPath: KeyPath<WebAnalyticsMetricsSnapshot, WebAnalyticsMetric> {
    switch self {
    case .pageLoadTime: \.pageLoadTimeMs
    case .visits: \.visits
    case .pageViews: \.pageViews
    case .lcpP75: \.lcpP75Ms
    case .inpP75: \.inpP75Ms
    case .clsP75: \.clsP75
    }
  }

  /// Timings and layout shift are better when they fall; traffic counts carry no
  /// opinion.
  var trendPolarity: DashChartTrend.Polarity {
    switch self {
    case .visits, .pageViews: .neutral
    case .pageLoadTime, .lcpP75, .inpP75, .clsP75: .lowerIsBetter
    }
  }

  var valueAxisLabel: String {
    switch self {
    case .pageLoadTime, .lcpP75, .inpP75: "Milliseconds"
    case .visits: "Visits"
    case .pageViews: "Page views"
    case .clsP75: "CLS"
    }
  }

  var axisValueFormat: DashChartValueFormat {
    switch self {
    case .pageLoadTime, .lcpP75, .inpP75: .milliseconds(maximumFractionDigits: 0)
    case .visits, .pageViews: .compact
    case .clsP75: .number(maximumFractionDigits: 3)
    }
  }

  var tableValueFormat: DashChartValueFormat {
    switch self {
    case .pageLoadTime, .lcpP75, .inpP75: .milliseconds(maximumFractionDigits: 0)
    case .visits, .pageViews: .number(maximumFractionDigits: 0)
    case .clsP75: .number(maximumFractionDigits: 3)
    }
  }

  /// A card's headline, a detail's summary, and a range tab's total all read the
  /// same figure, so they format in one place.
  func valueText(_ value: Double) -> String {
    switch self {
    case .pageLoadTime, .lcpP75, .inpP75:
      let milliseconds = Int(value.rounded())
        .formatted(.number.locale(DashL10n.activeLocale))
      return "\(milliseconds)ms"
    case .visits, .pageViews:
      return Int(value.rounded()).formatted(.number.locale(DashL10n.activeLocale))
    case .clsP75:
      return value.formatted(
        .number.precision(.fractionLength(0...3)).locale(DashL10n.activeLocale))
    }
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
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
        cardGrid(visibleMetrics) { metric in
          metricCard(metric)
        }
      }
    }
    .detailHeader(icon: .solar(SolarAsset.Content.graph), title: "Web analytics")
    .refreshable { await load(force: true) }
    .task(id: model.accountRequestContext) { await load() }
  }

  /// Core Web Vitals only exist on sites whose beacon collects them, so they
  /// join the grid rather than reserving three permanently empty cards.
  private var visibleMetrics: [WebAnalyticsChartMetric] {
    snapshot.hasWebVitals
      ? WebAnalyticsChartMetric.allCases
      : WebAnalyticsChartMetric.headline
  }

  /// Cold: the three headline metrics in the same paired collapsed shape the
  /// loaded screen paints, so the arriving cards land in place. Web Vitals stay
  /// out — whether the beacon reports them is only known once the payload lands.
  private var webAnalyticsSkeleton: some View {
    cardGrid(WebAnalyticsChartMetric.headline) { metric in
      DashCollapsedChartPlaceholder(title: metric.title, showsMetricHeader: true)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Loading")
  }

  /// Collapsed cards pair into half-width rows, the same pose as Watchtower's
  /// charts and the Worker screen's Requests / CPU pair; a lone trailing card
  /// keeps its half width instead of stretching across the row. Accessibility
  /// sizes cannot hold a half-width title, so they reflow to one per row.
  @ViewBuilder
  private func cardGrid<Card: View>(
    _ metrics: [WebAnalyticsChartMetric],
    @ViewBuilder card: @escaping (WebAnalyticsChartMetric) -> Card
  ) -> some View {
    DashSurfaceStack {
      ForEach(rows(metrics), id: \.self) { row in
        HStack(alignment: .top, spacing: DashTheme.Spacing.itemGap) {
          ForEach(row) { metric in
            card(metric)
              .frame(maxWidth: .infinity)
          }
          if row.count == 1, !dynamicTypeSize.isAccessibilitySize {
            Color.clear
              .frame(maxWidth: .infinity)
          }
        }
      }
    }
  }

  private func rows(
    _ metrics: [WebAnalyticsChartMetric]
  ) -> [[WebAnalyticsChartMetric]] {
    if dynamicTypeSize.isAccessibilitySize { return metrics.map { [$0] } }
    return stride(from: 0, to: metrics.count, by: 2).map { start in
      Array(metrics[start..<min(start + 2, metrics.count)])
    }
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

  /// One collapsed chart per metric: title, the window's figure and its trend
  /// over a sparkline flush to the card's bottom edge, and the whole surface
  /// pushes the interactive detail.
  private func metricCard(_ metric: WebAnalyticsChartMetric) -> some View {
    let payload = snapshot[keyPath: metric.keyPath]
    let value = metric.valueText(payload.current)
    // The floor lift is a band's device — it keeps a quiet series visible — and
    // the ceiling it reports is why a flat week does not fill the plot.
    let collapsed = CollapsedDitherTrendSeries(values: payload.series)
    let data = zip(payload.points, collapsed.values).map { point, lifted in
      DitherDatum(
        id: point.date.ISO8601Format(),
        label: dayLabel(point.date),
        values: [metric.seriesKey: lifted])
    }
    return DashCollapsedChartCard(
      title: metric.title,
      summaryValue: value,
      trend: DashChartTrend(
        current: payload.current,
        previous: payload.previous,
        polarity: metric.trendPolarity),
      data: data,
      series: [series(for: metric)],
      valueCeiling: collapsed.valueCeiling,
      // The sentence Watchtower's collapsed cards already speak, so the two
      // screens read alike and no new catalog key is needed.
      accessibilitySummary: DashL10n.string(
        "\(DashL10n.ui(metric.title)) for \(DashL10n.ui(range.totalsHeading)). Total \(value)."),
      detail: chartDetail(for: metric),
      detailAccessibilityIdentifier: "web-analytics-chart-detail-\(metric.rawValue)")
  }

  private func series(for metric: WebAnalyticsChartMetric) -> DitherSeries {
    DitherSeries(
      id: metric.seriesKey,
      label: DashL10n.ui(metric.title),
      color: color(for: metric),
      variant: .gradient)
  }

  private func color(for metric: WebAnalyticsChartMetric) -> DitherColor {
    switch metric {
    case .pageLoadTime:
      DashTheme.DitherChart.accentBlue(
        colorScheme: colorScheme, contrast: colorSchemeContrast)
    case .visits, .inpP75:
      DashTheme.DitherChart.accentPurple(
        colorScheme: colorScheme, contrast: colorSchemeContrast)
    case .pageViews, .clsP75:
      DashTheme.DitherChart.accentTeal(
        colorScheme: colorScheme, contrast: colorSchemeContrast)
    case .lcpP75:
      DashTheme.DitherChart.warning(
        colorScheme: colorScheme, contrast: colorSchemeContrast)
    }
  }

  /// The pushed detail carries both loaded windows, so its 7d / 30d tabs swap
  /// already-fetched points. It plots the real values, not the lifted ones.
  private func chartDetail(for metric: WebAnalyticsChartMetric) -> DashChartDetail {
    let plotSeries = series(for: metric)
    let available: [AnalyticsRange] = [.week, .month]
    let ranges: [DashChartDetailRange] = available.compactMap { target in
      guard let snap = snapshotsByRange[target], !snap.isEmpty else { return nil }
      let payload = snap[keyPath: metric.keyPath]
      let value = metric.valueText(payload.current)
      let points = payload.points.map { point in
        DashChartDataPoint(
          datum: DitherDatum(
            id: point.date.ISO8601Format(),
            label: dayLabel(point.date),
            values: [metric.seriesKey: point.value]),
          tableLabel: tableLabel(point.date))
      }
      return DashChartDetailRange(
        range: target,
        rangeLabel: target.totalsHeading,
        summaryValue: value,
        trend: DashChartTrend(
          current: payload.current,
          previous: payload.previous,
          polarity: metric.trendPolarity),
        categoryAxisLabel: "Day",
        accessibilitySummary: "\(DashL10n.ui(metric.title)), \(value)",
        content: .area(points: points, series: [plotSeries]))
    }
    let current = ranges.first(where: { $0.range == range }) ?? ranges.first
    return DashChartDetail(
      title: metric.title,
      rangeLabel: current?.rangeLabel ?? range.totalsHeading,
      summaryValue: current?.summaryValue,
      trend: current?.trend,
      categoryAxisLabel: "Day",
      valueAxisLabel: metric.valueAxisLabel,
      axisValueFormat: metric.axisValueFormat,
      tableValueFormat: metric.tableValueFormat,
      accessibilitySummary: current?.accessibilitySummary ?? "",
      content: current?.content ?? .area(points: [], series: []),
      featureID: .zones,
      readScopes: DashAuthorizationScopes.webAnalytics,
      ranges: ranges,
      selectedRange: range)
  }

  private func dayLabel(_ date: Date) -> String {
    date.formatted(.dateTime.month(.abbreviated).day().locale(DashL10n.activeLocale))
  }

  private func tableLabel(_ date: Date) -> String {
    date.formatted(
      .dateTime.year().month(.abbreviated).day().locale(DashL10n.activeLocale))
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
