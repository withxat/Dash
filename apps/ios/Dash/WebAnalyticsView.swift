import CloudflareAPI
import SwiftDitherKit
import SwiftUI

// MARK: - Pure model

/// One headline metric on the Web Analytics screen: its value for the selected
/// window, the same value for the immediately preceding window (which feeds the
/// delta chip), and the per-day series that draws the sparkline.
struct WebAnalyticsMetric: Hashable, Sendable {
  static let zero = WebAnalyticsMetric(current: 0, previous: nil, series: [])

  let current: Double
  let previous: Double?
  let series: [Double]

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

  /// Folds `days` (which spans `window * 2` calendar days) into the three
  /// dashboard metrics. The most recent `window` days form the current period;
  /// the `window` days before that form the comparison period. Page views and
  /// visits sum; page-load time is the page-view-weighted mean of the daily
  /// medians — a single representative figure (the exact window quantile would
  /// need a second, ungrouped query).
  static func metrics(from days: [RUMDailyMetrics], window: Int, now: Date)
    -> WebAnalyticsMetricsSnapshot
  {
    let parser = makeDayParser()
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone

    let parsed = days.compactMap { day -> WebAnalyticsDay? in
      guard let date = parser.date(from: day.date) else { return nil }
      return WebAnalyticsDay(
        date: date, pageviews: day.pageviews, visits: day.visits,
        pageLoadTimeP50Ms: day.pageLoadTimeP50Ms)
    }

    let step = max(window, 1)
    let dayLength: TimeInterval = 86400
    let currentStart = calendar.startOfDay(for: now)
      .addingTimeInterval(-Double(step - 1) * dayLength)
    let previousStart = currentStart.addingTimeInterval(-Double(step) * dayLength)

    let current = parsed.filter { $0.date >= currentStart }.sorted { $0.date < $1.date }
    let previous =
      parsed
      .filter { $0.date >= previousStart && $0.date < currentStart }
      .sorted { $0.date < $1.date }

    func summed(_ value: @escaping (WebAnalyticsDay) -> Int) -> WebAnalyticsMetric {
      WebAnalyticsMetric(
        current: Double(current.reduce(0) { $0 + value($1) }),
        previous: previous.isEmpty ? nil : Double(previous.reduce(0) { $0 + value($1) }),
        series: current.map { Double(value($0)) })
    }

    let pageViews = summed { $0.pageviews }
    let visits = summed { $0.visits }
    let pageLoad = WebAnalyticsMetric(
      current: weightedMedian(current) ?? 0,
      previous: previous.isEmpty ? nil : weightedMedian(previous),
      series: current.map { Double($0.pageLoadTimeP50Ms ?? 0) })

    return WebAnalyticsMetricsSnapshot(
      pageLoadTimeMs: pageLoad,
      visits: visits,
      pageViews: pageViews,
      hasData: pageViews.current > 0 || visits.current > 0)
  }

  /// Page-view-weighted mean of the days that reported a median. Falls back to a
  /// plain mean if those days recorded no page views, and to `nil` if no day had
  /// a timing sample at all.
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
  let zoneID: String

  @State private var range: AnalyticsRange = .week
  @State private var site: RUMSite?
  @State private var siteResolved = false
  @State private var snapshotsByRange: [AnalyticsRange: WebAnalyticsMetricsSnapshot] = [:]
  @State private var errorByRange: [AnalyticsRange: String] = [:]
  @State private var loadingRanges: Set<AnalyticsRange> = [.week, .month]

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
      if site == nil {
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
            metric: snapshot.pageLoadTimeMs,
            color: DashTheme.DitherChart.accentBlue(
              colorScheme: colorScheme, contrast: colorSchemeContrast),
            lowerIsBetter: true,
            value: durationString(snapshot.pageLoadTimeMs.current))
          metricCard(
            title: "Visits",
            metric: snapshot.visits,
            color: DashTheme.DitherChart.accentPurple(
              colorScheme: colorScheme, contrast: colorSchemeContrast),
            lowerIsBetter: false,
            value: countString(snapshot.visits.current))
          metricCard(
            title: "Page views",
            metric: snapshot.pageViews,
            color: DashTheme.DitherChart.accentTeal(
              colorScheme: colorScheme, contrast: colorSchemeContrast),
            lowerIsBetter: false,
            value: countString(snapshot.pageViews.current))
        }
      }
    }
    .detailHeader(icon: .solar(SolarAsset.Content.graph), title: "Web analytics")
    .refreshable { await load(force: true) }
    .task { await load() }
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
    metric: WebAnalyticsMetric,
    color: DitherColor,
    lowerIsBetter: Bool,
    value: String
  ) -> some View {
    DashGlassCard {
      VStack(alignment: .leading, spacing: 14) {
        VStack(alignment: .leading, spacing: 6) {
          Text(title)
            .dashTextStyle(.footnoteSemibold)
            .foregroundStyle(DashTheme.subtle)
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(value)
              .dashTextStyle(.sectionTitle)
              .monospacedDigit()
              .foregroundStyle(DashTheme.strong)
              .lineLimit(1)
              .minimumScaleFactor(0.7)
            deltaChip(metric.delta, lowerIsBetter: lowerIsBetter)
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
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private func deltaChip(_ delta: Double?, lowerIsBetter: Bool) -> some View {
    if let delta, delta != 0 {
      let improved = lowerIsBetter ? delta < 0 : delta > 0
      HStack(spacing: 2) {
        Image(systemName: delta > 0 ? "arrow.up.right" : "arrow.down.right")
          .font(.system(size: 11, weight: .bold))
        Text(
          abs(delta).formatted(
            .percent.precision(.fractionLength(2)).locale(DashL10n.activeLocale))
        )
        .dashTextStyle(.footnoteSemibold)
        .monospacedDigit()
      }
      .foregroundStyle(improved ? DashTheme.success : DashTheme.danger)
    }
  }

  private func countString(_ value: Double) -> String {
    Int(value.rounded()).formatted(.number.locale(DashL10n.activeLocale))
  }

  private func durationString(_ ms: Double) -> String {
    "\(Int(ms.rounded()).formatted(.number.locale(DashL10n.activeLocale)))ms"
  }

  private func load(force: Bool = false) async {
    guard let accountID = model.activeAccountID else {
      siteResolved = true
      loadingRanges.removeAll()
      return
    }
    do {
      let sites = try await resolveSites(accountID: accountID, force: force)
      site = WebAnalyticsChartModel.site(for: zoneID, in: sites)
    } catch {
      if !error.dashIsCancellation { errorByRange[range] = error.dashActionableMessage }
    }
    siteResolved = true
    guard let siteTag = site?.siteTag else {
      loadingRanges.removeAll()
      return
    }
    loadingRanges =
      force ? [.week, .month] : Set([.week, .month].filter { snapshotsByRange[$0] == nil })
    async let week: Void = loadRange(.week, accountID: accountID, siteTag: siteTag, force: force)
    async let month: Void = loadRange(.month, accountID: accountID, siteTag: siteTag, force: force)
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
    _ target: AnalyticsRange, accountID: String, siteTag: String, force: Bool
  ) async {
    let days = target == .month ? 30 : 7
    let key = FeatureCacheKey.webAnalyticsMetrics(siteTag, days: days)
    do {
      let raw: [RUMDailyMetrics]
      if !force, let cached: [RUMDailyMetrics] = model.featureCache.get(key) {
        raw = cached
      } else {
        raw = try await model.client.webAnalyticsMetrics(
          accountID: accountID, siteTag: siteTag, days: days)
        model.featureCache.set(key, raw)
      }
      snapshotsByRange[target] = WebAnalyticsChartModel.metrics(
        from: raw, window: days, now: Date())
      errorByRange[target] = nil
    } catch {
      if snapshotsByRange[target] == nil, !error.dashIsCancellation {
        errorByRange[target] = error.dashActionableMessage
      }
    }
    loadingRanges.remove(target)
  }
}
