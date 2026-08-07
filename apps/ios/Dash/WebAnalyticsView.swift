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

/// Headline Web Analytics figures.
struct WebAnalyticsMetricsSnapshot: Hashable, Sendable {
  static let empty = WebAnalyticsMetricsSnapshot(
    visits: .zero, pageViews: .zero, hasData: false)

  let visits: WebAnalyticsMetric
  let pageViews: WebAnalyticsMetric
  let hasData: Bool

  var isEmpty: Bool { !hasData }
}

private struct WebAnalyticsDay {
  let date: Date
  let pageviews: Int
  let visits: Int
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

  /// Folds `comparison.days` (which spans `window * 2` calendar days) into the two
  /// dashboard metrics. The most recent `window` days form the current period;
  /// the `window` days before that form the comparison period. Page views and
  /// visits sum over each.
  static func metrics(from comparison: RUMMetricsComparison, window: Int, now: Date)
    -> WebAnalyticsMetricsSnapshot
  {
    let parser = makeDayParser()
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone

    let parsed = comparison.days.compactMap { day -> WebAnalyticsDay? in
      guard let date = parser.date(from: day.date) else { return nil }
      return WebAnalyticsDay(date: date, pageviews: day.pageviews, visits: day.visits)
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

    return WebAnalyticsMetricsSnapshot(
      visits: visits,
      pageViews: pageViews,
      hasData: pageViews.current > 0 || visits.current > 0)
  }

}

/// The account's Web Analytics site list, fetched once per account and read by
/// both surfaces that need it: this screen, to find the zone's `siteTag`, and
/// the zone screen, to decide whether the Web analytics row exists at all. One
/// loader over one cache key, so the two can never disagree about whether a
/// zone has a site.
@MainActor
enum WebAnalyticsSiteIndex {
  /// The list this session already holds, if any. Reading it before any `await`
  /// is what keeps a warm account from inserting the zone screen's row a beat
  /// after the rest of its tools.
  static func cached(accountID: String, model: AppModel) -> [RUMSite]? {
    model.featureCache.get(FeatureCacheKey.webAnalyticsSites(accountID))
  }

  static func load(accountID: String, model: AppModel, force: Bool = false) async throws
    -> [RUMSite]
  {
    if !force, let cached = cached(accountID: accountID, model: model) { return cached }
    let sites = try await model.client.webAnalyticsSites(accountID: accountID)
    model.featureCache.set(FeatureCacheKey.webAnalyticsSites(accountID), sites)
    return sites
  }
}

/// Whether the zone screen offers Web Analytics at all.
///
/// Web Analytics is not a zone setting Cloudflare turns on: someone has to add
/// a site for the domain first, and until one exists the screen has nothing to
/// show but a link back to the dashboard — Cloudflare publishes no OAuth scope
/// for Web Analytics writes, so Dash cannot even offer to add it. That makes
/// the tool row a fact about the account's site list, not a fixed part of a
/// zone's toolset.
///
/// A site whose injecting ruleset is switched off still counts as present: it
/// has history, it is one dashboard toggle from collecting again, and hiding it
/// would strand data the user deliberately set up. Only a zone with no site at
/// all loses the row.
enum ZoneWebAnalyticsAvailability: Hashable, Sendable {
  /// The site list has not answered yet. The row stays out rather than
  /// appearing and then being taken back from under a reaching finger.
  case pending
  /// A site on this account injects into this zone.
  case present
  /// The account's site list is known and this zone is not in it.
  case absent
  /// The list could not be read — no account, no grant, or a failed request. A
  /// missing answer must never hide a feature the user may well have, so the
  /// row stays and its own screen reports what it found.
  case indeterminate

  var showsTool: Bool {
    switch self {
    case .present, .indeterminate: true
    case .pending, .absent: false
    }
  }

  static func resolved(zoneID: String, in sites: [RUMSite]) -> Self {
    WebAnalyticsChartModel.site(for: zoneID, in: sites) == nil ? .absent : .present
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
  case visits
  case pageViews

  var id: String { rawValue }

  /// Catalog key; also the pushed detail's title.
  var title: String {
    switch self {
    case .visits: "Visits"
    case .pageViews: "Page views"
    }
  }

  /// Series id shared by the collapsed sparkline and the detail chart.
  var seriesKey: String { rawValue }

  /// Where this card's figures live in a loaded snapshot.
  var keyPath: KeyPath<WebAnalyticsMetricsSnapshot, WebAnalyticsMetric> {
    switch self {
    case .visits: \.visits
    case .pageViews: \.pageViews
    }
  }

  /// Traffic counts carry no opinion about which direction is better.
  var trendPolarity: DashChartTrend.Polarity { .neutral }

  var valueAxisLabel: String {
    switch self {
    case .visits: "Visits"
    case .pageViews: "Page views"
    }
  }

  var axisValueFormat: DashChartValueFormat { .compact }

  var tableValueFormat: DashChartValueFormat { .number(maximumFractionDigits: 0) }

  /// A card's headline, a detail's summary, and a range tab's total all read the
  /// same figure, so they format in one place.
  func valueText(_ value: Double) -> String {
    Int(value.rounded()).formatted(.number.locale(DashL10n.activeLocale))
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
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
  /// Beacon off is a product CTA in content, not a zero-row list empty.
  private var isBeaconOff: Bool {
    siteResolved && (site == nil || (site?.isCollecting == false && snapshot.isEmpty))
  }

  var body: some View {
    DashFeatureList(
      isLoading: isLoadingCurrent,
      error: currentError,
      hasContent: !snapshot.isEmpty || isBeaconOff,
      empty: DashFeatureEmpty(
        icon: SolarAsset.Content.graph,
        title: "No page loads yet",
        message: "Web Analytics reports a page view once a real browser loads a page."
      ),
      retry: { Task { await load(force: true) } },
      header: {
        if site != nil {
          DashTextTabs(
            items: [("7d", AnalyticsRange.week), ("30d", .month)],
            selection: $range
          )
        }
      }
    ) { mode in
      webAnalyticsBody(mode: mode)
    }
    .detailHeader(icon: .solar(SolarAsset.Content.graph), title: "Web analytics")
    .refreshable { await load(force: true) }
    .task(id: model.accountRequestContext) { await load() }
  }

  /// Shared body for cold + live: the two headline cards in their 2-up row.
  /// Beacon-off replaces the whole thing.
  @ViewBuilder
  private func webAnalyticsBody(mode: DashBodyMode) -> some View {
    if !mode.isPlaceholder, isBeaconOff {
      beaconMissingState
        .dashBodySlot(reduceMotion: reduceMotion)
    } else {
      DashSurfaceStack {
        cardGrid(WebAnalyticsChartMetric.allCases) { metric in
          Group {
            if mode.isPlaceholder {
              DashCollapsedChartPlaceholder(title: metric.title, showsMetricHeader: true)
            } else {
              metricCard(metric)
            }
          }
          .dashBodySlot(reduceMotion: reduceMotion)
        }
      }
    }
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
    // No DashSurfaceStack here: the caller owns the outer stack so these rows
    // sit in its rhythm.
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

  /// Detail freezes every warm window at push; wait out in-flight ranges that
  /// have not landed yet so a first tap cannot omit a still-loading 30d tab.
  private var areChartDetailRangesSettled: Bool {
    DashChartDetail.areSourceRangesSettled(
      expected: [.week, .month],
      loaded: snapshotsByRange.keys,
      loading: loadingRanges)
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
      // Nil until sibling windows settle — the card stays visible, just not a
      // navigation target, so an early tap cannot freeze a partial tab set.
      detail: areChartDetailRangesSettled ? chartDetail(for: metric) : nil,
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
    case .visits:
      DashTheme.DitherChart.accentPurple(
        colorScheme: colorScheme, contrast: colorSchemeContrast)
    case .pageViews:
      DashTheme.DitherChart.accentTeal(
        colorScheme: colorScheme, contrast: colorSchemeContrast)
    }
  }

  /// The pushed detail carries both settled windows, so its 7d / 30d tabs swap
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
    try await WebAnalyticsSiteIndex.load(accountID: accountID, model: model, force: force)
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
