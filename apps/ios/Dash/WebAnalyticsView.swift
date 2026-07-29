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

/// The three figures Cloudflare's Web Analytics dashboard leads with.
struct WebAnalyticsMetricsSnapshot: Hashable, Sendable {
  static let empty = WebAnalyticsMetricsSnapshot(
    pageLoadTimeMs: .zero, visits: .zero, pageViews: .zero, hasData: false)

  let pageLoadTimeMs: WebAnalyticsMetric
  let visits: WebAnalyticsMetric
  let pageViews: WebAnalyticsMetric
  let hasData: Bool

  var isEmpty: Bool { !hasData }
}

private struct WebAnalyticsDay {
  let date: Date
  let pageviews: Int
  let visits: Int
  let pageLoadTimeP50Ms: Int?
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
        pageLoadTimeP50Ms: day.pageLoadTimeP50Ms)
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

    return WebAnalyticsMetricsSnapshot(
      pageLoadTimeMs: pageLoad,
      visits: visits,
      pageViews: pageViews,
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
        }
      }
    }
    .detailHeader(icon: .solar(SolarAsset.Content.graph), title: "Web analytics")
    .refreshable { await load(force: true) }
    .task(id: model.accountRequestContext) { await load() }
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
      metric: metric,
      color: color,
      value: value,
      valueAxisLabel: valueAxisLabel,
      axisValueFormat: axisValueFormat,
      tableValueFormat: tableValueFormat,
      trend: trend)
    return DestinationLink(destination: .chartDetail(detail)) {
      DashGlassCard {
        VStack(alignment: .leading, spacing: 14) {
          VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Text(title)
                .dashTextStyle(.footnoteSemibold)
                .foregroundStyle(DashTheme.subtle)
              Spacer(minLength: 4)
              Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DashTheme.placeholder)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Text(value)
                .dashTextStyle(.sectionTitle)
                .monospacedDigit()
                .foregroundStyle(DashTheme.strong)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
              DashChartTrendLabel(trend: trend)
            }
          }
          if metric.series.count >= 2 {
            DitherSparkline(values: metric.series, color: color, variant: .gradient)
              .frame(height: 52)
              .frame(maxWidth: .infinity)
              .accessibilityHidden(true)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityHint("Shows chart details")
  }

  private func webChartDetail(
    title: String,
    metric: WebAnalyticsMetric,
    color: DitherColor,
    value: String,
    valueAxisLabel: String,
    axisValueFormat: DashChartValueFormat,
    tableValueFormat: DashChartValueFormat,
    trend: DashChartTrend?
  ) -> DashChartDetail {
    let seriesID = "value"
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
    return DashChartDetail(
      title: title,
      rangeLabel: range.totalsHeading,
      summaryValue: value,
      trend: trend,
      categoryAxisLabel: "Day",
      valueAxisLabel: valueAxisLabel,
      axisValueFormat: axisValueFormat,
      tableValueFormat: tableValueFormat,
      accessibilitySummary: "\(DashL10n.ui(title)), \(value)",
      content: .area(
        points: points,
        series: [
          DitherSeries(
            id: seriesID,
            label: DashL10n.ui(title),
            color: color,
            variant: .gradient)
        ]),
      featureID: .zones,
      readScopes: DashAuthorizationScopes.webAnalytics)
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
      if snapshotsByRange[target] == nil {
        errorByRange[target] = error.dashActionableMessage
      }
    }
    loadingRanges.remove(target)
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
