import CloudflareAPI
import SwiftDitherKit
import SwiftUI

/// A single day of beacon-reported page loads.
struct WebAnalyticsChartPoint: Identifiable, Hashable {
  let date: Date
  let pageviews: Int

  var id: Date { date }
}

/// Pure parsing + summaries, unit-tested away from the view.
enum WebAnalyticsChartModel {
  private static let dayParser: DateFormatter = {
    let parser = DateFormatter()
    parser.dateFormat = "yyyy-MM-dd"
    parser.locale = Locale(identifier: "en_US_POSIX")
    parser.timeZone = TimeZone(identifier: "UTC")
    return parser
  }()

  static func points(from days: [RUMPageviewsDay]) -> [WebAnalyticsChartPoint] {
    days.compactMap { day in
      guard let date = dayParser.date(from: day.date) else { return nil }
      return WebAnalyticsChartPoint(date: date, pageviews: day.pageviews)
    }
    .sorted { $0.date < $1.date }
  }

  /// The site whose injecting ruleset points at this zone. A zone can only
  /// have one, but the account list carries every site it owns.
  static func site(for zoneID: String, in sites: [RUMSite]) -> RUMSite? {
    sites.first { $0.zoneTag == zoneID }
  }

  static func accessibilitySummary(rangeLabel: String, pageviews: Int) -> String {
    DashL10n.string(
      "Page views chart for \(rangeLabel). Total \(pageviews.formatted()) page views.")
  }
}

/// Beacon-reported Web Analytics for one zone. Deliberately separate from
/// `ZoneAnalyticsView`: that screen is what the edge saw, this one is what real
/// browsers reported, and the two page-view numbers never match.
struct WebAnalyticsView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.openURL) private var openURL
  let zoneID: String

  @State private var range: AnalyticsRange = .week
  @State private var site: RUMSite?
  @State private var siteResolved = false
  @State private var pointsByRange: [AnalyticsRange: [WebAnalyticsChartPoint]] = [:]
  @State private var errorByRange: [AnalyticsRange: String] = [:]
  @State private var loadingRanges: Set<AnalyticsRange> = [.week, .month]

  private var points: [WebAnalyticsChartPoint] { pointsByRange[range] ?? [] }
  private var isLoadingCurrent: Bool { !siteResolved || loadingRanges.contains(range) }
  private var currentError: String? { errorByRange[range] }
  private var totalPageviews: Int { points.reduce(0) { $0 + $1.pageviews } }

  var body: some View {
    DashFeatureList(
      isLoading: isLoadingCurrent,
      error: currentError,
      hasContent: !points.isEmpty,
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
      } else if points.isEmpty {
        DashEmptyState(
          icon: SolarAsset.Content.graph,
          title: "No page loads yet",
          message: "Web Analytics reports a page view once a real browser loads a page."
        )
      } else {
        DashSurfaceStack {
          summaryCard
          chartCard
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

  private var summaryCard: some View {
    DashGlassCard {
      VStack(alignment: .leading, spacing: 4) {
        Text("Page views")
          .dashTextStyle(.footnoteSemibold)
          .foregroundStyle(DashTheme.subtle)
        Text(totalPageviews.formatted())
          .dashTextStyle(.sectionTitle)
          .monospacedDigit()
          .foregroundStyle(DashTheme.strong)
        Text("Reported by the beacon, not counted at the edge.")
          .dashTextStyle(.footnote)
          .foregroundStyle(DashTheme.subtle)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .combine)
  }

  private var chartCard: some View {
    DashGlassCard {
      VStack(alignment: .leading, spacing: 12) {
        Text("Page views").dashTextStyle(.footnoteSemibold).foregroundStyle(DashTheme.subtle)
        DitherAreaChart(
          data: points.map { point in
            DitherDatum(
              id: point.date.ISO8601Format(),
              label: point.date.formatted(
                Date.FormatStyle.dateTime.month(.abbreviated).day()
                  .locale(DashL10n.activeLocale)),
              values: ["pageviews": Double(point.pageviews)])
          },
          series: [
            DitherSeries(
              id: "pageviews",
              label: DashL10n.ui("Page views"),
              color: DashTheme.DitherChart.accentPurple(
                colorScheme: colorScheme,
                contrast: colorSchemeContrast),
              variant: .gradient)
          ],
          options: DashTheme.DitherChart.options(
            showsLegend: false,
            accessibility: DitherAccessibility(
              title: DashL10n.ui("Page views"),
              summary: WebAnalyticsChartModel.accessibilitySummary(
                rangeLabel: DashL10n.ui(range.totalsHeading),
                pageviews: totalPageviews),
              categoryAxisLabel: DashL10n.ui("Day"),
              valueAxisLabel: DashL10n.ui("Page views")))
        )
        .frame(height: DashTheme.DitherChart.height(dynamicTypeSize: dynamicTypeSize))
      }
    }
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
      errorByRange[range] = error.dashActionableMessage
    }
    siteResolved = true
    guard let siteTag = site?.siteTag else {
      loadingRanges.removeAll()
      return
    }
    loadingRanges =
      force ? [.week, .month] : Set([.week, .month].filter { pointsByRange[$0] == nil })
    async let week: Void = loadRange(.week, siteTag: siteTag, force: force)
    async let month: Void = loadRange(.month, siteTag: siteTag, force: force)
    _ = await (week, month)
  }

  private func resolveSites(accountID: String, force: Bool) async throws -> [RUMSite] {
    let key = FeatureCacheKey.webAnalyticsSites(accountID)
    if !force, let cached: [RUMSite] = model.featureCache.get(key) { return cached }
    let sites = try await model.client.webAnalyticsSites(accountID: accountID)
    model.featureCache.set(key, sites)
    return sites
  }

  private func loadRange(_ target: AnalyticsRange, siteTag: String, force: Bool) async {
    let days = target == .month ? 30 : 7
    let key = FeatureCacheKey.webAnalyticsPageviews(siteTag, days: days)
    do {
      if !force, let cached: [RUMPageviewsDay] = model.featureCache.get(key) {
        pointsByRange[target] = WebAnalyticsChartModel.points(from: cached)
      } else {
        let fetched = try await model.client.webAnalyticsPageviews(siteTag: siteTag, days: days)
        model.featureCache.set(key, fetched)
        pointsByRange[target] = WebAnalyticsChartModel.points(from: fetched)
      }
      errorByRange[target] = nil
    } catch {
      if pointsByRange[target] == nil { errorByRange[target] = error.dashActionableMessage }
    }
    loadingRanges.remove(target)
  }
}
