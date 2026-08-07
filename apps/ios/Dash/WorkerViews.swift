import CloudflareAPI
import SwiftDitherKit
import SwiftUI

struct WorkersView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.openURL) private var openURL
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var workers: [WorkerScript] = []
  @State private var error: String?
  @State private var loading = true

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      hasContent: !workers.isEmpty,
      empty: DashFeatureEmpty(
        icon: SolarAsset.Content.code,
        title: DashL10n.string("No Workers yet"),
        message: DashL10n.string(
          "Deploy with Wrangler or the dashboard — manage cut-over, domains, and analytics here."
        ),
        actionTitle: "Open Workers docs",
        action: { openURL(FeatureExternalURL.workersGuide) }
      ),
      retry: { Task { await load() } }
    ) { mode in
      dashListCard {
        dashModeListRows(mode: mode, items: workers, reduceMotion: reduceMotion) { worker in
          DashListGroupLink(value: .worker(worker.id)) {
            DashListRow(title: worker.id, icon: SolarAsset.Content.code)
              .accessibilityLabel(workerRowAccessibilityLabel(worker))
          }
          .accessibilityIdentifier("worker-\(worker.id)")
        }
      }
    }
    .refreshable { await load(force: true) }.task {
      await load()
    }
    .onAppear { reloadIfInvalidated() }
  }

  /// The cache drops under this list on memory pressure while it stays alive
  /// below a child screen; refresh on return when the cache went cold.
  private func reloadIfInvalidated() {
    guard let accountID = model.activeAccountID, !workers.isEmpty else { return }
    let cached: [WorkerScript]? = model.featureCache.get(FeatureCacheKey.workers(accountID))
    if cached == nil { Task { await load(force: true) } }
  }

  private func load(force: Bool = false) async {
    guard let accountID = model.activeAccountID else { return }
    let key = FeatureCacheKey.workers(accountID)
    if !force, let cached: [WorkerScript] = model.featureCache.get(key) {
      workers = cached
      loading = false
      error = nil
      return
    }
    // Cold but a stale copy exists on disk: paint it now and refresh in place
    // so an offline relaunch shows last-known data instead of a skeleton.
    if workers.isEmpty, let stale: [WorkerScript] = model.featureCache.getStale(key) {
      workers = stale
      loading = true
    }
    if workers.isEmpty { loading = true }
    error = nil
    do {
      workers = try await model.client.listWorkers(accountID: accountID)
      model.featureCache.set(key, workers)
    } catch { self.error = error.dashActionableMessage }
    loading = false
  }
}

/// A single normalized point for the worker metrics charts. CPU arrives from
/// the API in microseconds and is stored here in milliseconds.
struct WorkerAnalyticsChartPoint: Identifiable, Hashable {
  let date: Date
  let requests: Int
  let errors: Int
  let cpuTimeP50Ms: Double

  var id: Date { date }
}

/// The two collapsed charts below the worker metrics panel. Each is its own
/// card, and each pushes its own chart detail — the pair replaced a tab strip
/// that hid half the data behind a switch.
private enum WorkerChartMetric: Hashable, CaseIterable {
  case requests
  case cpu

  /// Catalog key; also the pushed detail's title.
  var title: String {
    switch self {
    case .requests: "Requests"
    case .cpu: "CPU Time"
    }
  }

  /// Series id shared by the collapsed sparkline and the detail chart.
  var seriesKey: String {
    switch self {
    case .requests: "requests"
    case .cpu: "cpu"
    }
  }

  var detailAccessibilityIdentifier: String {
    switch self {
    case .requests: "worker-chart-detail-requests"
    case .cpu: "worker-chart-detail-cpu"
    }
  }

  func value(in point: WorkerAnalyticsChartPoint) -> Double {
    switch self {
    case .requests: Double(point.requests)
    case .cpu: point.cpuTimeP50Ms
    }
  }
}

/// Pure conversion + accessibility strings, so date parsing and the µs → ms
/// conversion are unit-tested away from the view. `points(from:)` returns
/// ascending, dropping unparseable stamps.
enum WorkerAnalyticsChartModel {
  static func points(from buckets: [WorkerAnalyticsBucket]) -> [WorkerAnalyticsChartPoint] {
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime]
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return buckets.compactMap { bucket in
      guard
        let date = parser.date(from: bucket.datetime) ?? fractional.date(from: bucket.datetime)
      else { return nil }
      return WorkerAnalyticsChartPoint(
        date: date,
        requests: bucket.requests,
        errors: bucket.errors,
        cpuTimeP50Ms: bucket.cpuTimeP50Us / 1000)
    }
    .sorted { $0.date < $1.date }
  }

  static func requestsAccessibilitySummary(requests: Int, errors: Int) -> String {
    if errors > 0 {
      return DashL10n.string(
        "Invocations chart for the last 24 hours. Total \(requests.formatted()) requests, \(errors.formatted()) errors."
      )
    }
    return DashL10n.string(
      "Invocations chart for the last 24 hours. Total \(requests.formatted()) requests.")
  }

  static func cpuAccessibilitySummary(points: [WorkerAnalyticsChartPoint]) -> String {
    let peak = points.map(\.cpuTimeP50Ms).max() ?? 0
    return DashL10n.string(
      "CPU time chart for the last 24 hours. Peak median \(String(format: "%.1f", peak)) milliseconds."
    )
  }
}

struct WorkerDetailView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.featureAllowsWrites) private var featureAllowsWrites
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @AppStorage(RecentResources.key) private var recentsRaw = ""
  let name: String
  @State private var analytics: WorkerAnalyticsPayload?
  @State private var analyticsError: String?
  @State private var deployments: [WorkerDeploymentSummary] = []
  @State private var deploymentError: String?
  @State private var selectedDeployment: WorkerDeploymentSummary?
  @State private var confirmingActivation = false
  @State private var activationPhase: DashActionPhase = .idle
  @State private var activationContext: AccountRequestContext?
  @State private var activationError: String?
  @State private var domains: [WorkerDomain] = []
  @State private var domainsError: String?
  @State private var selectedDomain: WorkerDomain?
  @State private var routes: [WorkerZoneRoute] = []
  @State private var routesError: String?
  @State private var routesLoading = false
  @State private var routesLoadID = UUID()
  @State private var selectedRoute: WorkerZoneRoute?
  @State private var addsDomain = false
  @State private var deleteDomainPhase: DashActionPhase = .idle
  @State private var deleteDomainError: String?
  @State private var error: String?
  @State private var loading = true
  /// Re-keys the builds section on pull-to-refresh; it owns its own task and
  /// is not reached by this screen's `load(force:)`.
  @State private var buildsRefreshID = UUID()
  @State private var loadedSubdomain = false
  @State private var subdomainEnabled = false
  @State private var subdomainUpdating = false
  /// Composed `{script}.{account}.workers.dev` when the account subdomain is known.
  @State private var workersDevHostname: String?
  /// False until the five primary sections settle, so route discovery cannot
  /// prematurely replace the Cold skeleton with an Updating… strip.
  @State private var hasPresentedContent = false

  private var hasPrimaryContent: Bool {
    !deployments.isEmpty || loadedSubdomain || analytics != nil || !domains.isEmpty
      || workersDevHostname != nil
  }

  private var workersDevSubtitle: String? {
    if let workersDevHostname { return workersDevHostname }
    if !featureAllowsWrites {
      return "Grant Workers write access to change this setting."
    }
    return nil
  }

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      hasContent: hasPresentedContent,
      retry: { Task { await load(force: true) } }
    ) { mode in
      workerDetailBody(mode: mode)
    }
    .detailHeader(
      icon: .solar(SolarAsset.Content.code),
      title: name,
      tint: FeatureVisualIdentity.heroColor(for: .workers)
    )
    .task(id: model.accountRequestContext) {
      if let accountID = model.accountRequestContext?.accountID {
        recentsRaw = RecentResources.recording(
          RecentResource(accountID: accountID, kind: .worker, resourceID: name, title: name),
          in: recentsRaw)
      }
      await load()
    }
    .refreshable { await load(force: true) }
    .dashTray(
      item: $selectedDeployment,
      title: { workerDeploymentTitle($0) },
      tone: FeatureVisualIdentity.tone(for: .workers),
      content: { deployment in
        workerDeploymentTray(deployment)
      }
    )
    .dashTray(
      isPresented: $addsDomain, title: "Add custom domain",
      tone: FeatureVisualIdentity.tone(for: .workers)
    ) {
      WorkerAddDomainForm(service: name) {
        await loadDomains(force: true)
      }
    }
    .dashTray(
      item: $selectedRoute,
      title: { $0.pattern },
      tone: FeatureVisualIdentity.tone(for: .workers),
      content: { route in
        DashDetailTray(
          fields: [
            DashDetailField(label: "Pattern", value: route.pattern, mono: true),
            DashDetailField(label: "Zone", value: route.zoneName),
            DashDetailField(label: "Managed by", value: "wrangler or the zone's Workers Routes"),
          ]
        )
      }
    )
    .dashTray(
      item: $selectedDomain,
      title: { $0.hostname },
      tone: FeatureVisualIdentity.tone(for: .workers),
      content: { domain in
        DashDetailTray(
          fields: [
            DashDetailField(label: "Hostname", value: domain.hostname),
            DashDetailField(label: "Zone", value: domain.zoneName),
            DashDetailField(label: "Environment", value: domain.environment ?? "production"),
          ],
          deleteMessage: featureAllowsWrites
            ? DashL10n.string(
              "Detaches \(domain.hostname) from \(name). DNS for the hostname is left in place."
            )
            : nil,
          deletePhase: deleteDomainPhase,
          onDeleteSuccessPresentationCompleted: completeDomainDeletionPresentation,
          deleteError: deleteDomainError,
          onDelete: featureAllowsWrites ? { Task { await detachDomain(domain) } } : nil
        )
      }
    )
  }

  private var subdomainBinding: Binding<Bool> {
    Binding(
      get: { subdomainEnabled },
      set: { enabled in
        guard loadedSubdomain, featureAllowsWrites, !subdomainUpdating else { return }
        subdomainEnabled = enabled
        Task { await setSubdomain(enabled) }
      })
  }

  @ViewBuilder private var domainsGroup: some View {
    // Same reason as Deployments above: `routes` is the account-wide route sweep
    // filtered to this script, which on a fan-out Worker is one row per zone.
    // DashListGroup's eager inner VStack would mount every one of them at once.
    DashListGroupHeader(
      title: DashL10n.ui("Domains & Routes"),
      actionTitle: featureAllowsWrites ? DashL10n.ui("Add") : nil,
      actionIcon: featureAllowsWrites ? SolarAsset.plus : nil,
      action: featureAllowsWrites ? { addsDomain = true } : nil
    )
    .padding(.horizontal, 4)
    .dashSectionBoundary()
    .padding(.bottom, 8)
    if let domainsError, domains.isEmpty {
      DashCard {
        DashListRowPlaceholders(rows: 2)
          .dashSectionFailure(
            domainsError,
            retry: { Task { await loadDomains(force: true) } })
      }
      .dashListCardInset()
    } else if domains.isEmpty, routes.isEmpty, routesError == nil, !routesLoading {
      DashCard {
        Text("Route a hostname from one of this account's zones to this Worker.")
          .dashTextStyle(.footnote)
          .foregroundStyle(DashTheme.subtle)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .dashListCardInset()
    }
    // Sibling ForEach collections, each insetting its own rows — never a shared
    // wrapper, whose padding would re-eagerize both lists inside LazyVStack.
    if !domains.isEmpty {
      dashListCardRows(items: domains) { domain in
        Button {
          deleteDomainError = nil
          selectedDomain = domain
        } label: {
          DashListRow(
            title: domain.hostname,
            subtitle: workerDomainSubtitle(domain),
            icon: SolarAsset.Content.globe,
            iconColor: FeatureVisualIdentity.catalogColor(for: .workers),
            showsChevron: false
          )
        }
        .buttonStyle(DashSurfaceButtonStyle())
        .accessibilityLabel("\(domain.hostname), \(workerDomainSubtitle(domain))")
        // dashListCardRows supplies the row's existing inset; this one
        // replaces DashListGroup's former content inset.
        .dashListCardInset()
      }
    }
    if routesLoading {
      DashCard {
        HStack(spacing: 10) {
          DashLoadingRing(color: DashTheme.brand, size: 18, lineWidth: 2.5)
          Text("Loading routes…")
            .dashTextStyle(.footnote)
            .foregroundStyle(DashTheme.subtle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .dashListCardInset()
    }
    if !routes.isEmpty {
      dashListCardRows(items: routes) { route in
        Button {
          selectedRoute = route
        } label: {
          DashListRow(
            title: route.pattern,
            subtitle: route.zoneName,
            icon: SolarAsset.Content.globe,
            iconColor: DashTheme.iconMuted,
            showsChevron: false
          ) {
            StatusBadge(.route)
          }
        }
        .buttonStyle(DashSurfaceButtonStyle())
        .accessibilityLabel("\(route.pattern), \(route.zoneName), Route")
        .dashListCardInset()
      }
    }
    if let routesError {
      if routes.isEmpty {
        // Cold: route discovery came back with nothing to show — keep the
        // rows' shape under the veil instead of swapping the loading card
        // for a one-line notice.
        DashCard {
          DashListRowPlaceholders(rows: 2)
            .dashSectionFailure(
              routesError,
              retry: { Task { await load(force: true) } })
        }
        .dashListCardInset()
      } else {
        // Warm/partial: preserved route rows stay, the notice rides beside
        // them.
        DashNotice(kind: .warning, message: routesError)
          .dashListCardInset()
      }
    }
  }

  @ViewBuilder private func workerDeploymentTray(_ deployment: WorkerDeploymentSummary) -> some View
  {
    let isActive = deployment.id == deployments.first?.id
    let versionID = workerPrimaryVersionID(deployment)
    let canActivate = featureAllowsWrites && !isActive && versionID != nil
    DashConfirmMorph(
      confirming: $confirmingActivation,
      message: versionID.map {
        DashL10n.string(
          "Switch all traffic to version \($0.prefix(8)). Gradual rollouts are not supported.")
      },
      actionPhase: activationPhase,
      onSuccessPresentationCompleted: completeActivationPresentation,
      actionTitle: canActivate ? "Make active" : nil,
      confirmingActionTitle: "Switch traffic",
      confirmingActionRole: .destructive,
      errorMessage: activationError,
      action: {
        if confirmingActivation {
          Task { await activate(deployment) }
        } else {
          confirmingActivation = true
        }
      },
      content: {
        VStack(alignment: .leading, spacing: 12) {
          Text(workerDeploymentTitle(deployment))
            .dashTextStyle(.bodySemibold)
            .foregroundStyle(DashTheme.text)
          Text(workerDeploymentAgeText(deployment.createdOn))
            .dashTextStyle(.caption)
            .foregroundStyle(DashTheme.subtle)
          Text(workerDeploymentTrafficText(deployment))
            .dashTextStyle(.caption)
            .foregroundStyle(DashTheme.rowSubtitle)
          if let author = deployment.authorEmail {
            Text(author)
              .dashTextStyle(.caption)
              .foregroundStyle(DashTheme.placeholder)
          }
          if isActive {
            StatusBadge(.current)
          } else if !featureAllowsWrites {
            DashNotice(kind: .warning, message: "Grant Workers write access to switch deployments.")
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    )
  }

  /// Fuller first-paint reserve: metrics + charts, deployments, workers.dev,
  /// Domains & Routes. Builds stay live-only (often renders nothing). Empty
  /// live sections exit upward via `dashBodySlot`.
  @ViewBuilder
  private func workerDetailBody(mode: DashBodyMode) -> some View {
    if mode.isPlaceholder {
      DashSurfaceStack {
        DashMetricPanelPlaceholder(tiles: 3)
        HStack(alignment: .top, spacing: DashTheme.Spacing.itemGap) {
          ForEach(WorkerChartMetric.allCases, id: \.self) { metric in
            DashCollapsedChartPlaceholder(title: metric.title, showsMetricHeader: true)
              .frame(maxWidth: .infinity)
          }
        }
      }
      .dashBodySlot(reduceMotion: reduceMotion)
    } else if let analytics {
      workerMetricsSection(analytics)
        .dashBodySlot(reduceMotion: reduceMotion)
    } else if analyticsError != nil {
      workerMetricsFallbackCard
        .dashBodySlot(reduceMotion: reduceMotion)
    }

    if !mode.isPlaceholder {
      // Builds sit above deployments: a build is what *produces* a deployment,
      // and it renders nothing at all unless this Worker is repo-connected.
      WorkerBuildsSection(scriptName: name, refreshID: buildsRefreshID)
        .dashSectionBoundary(analytics != nil || analyticsError != nil)
        .dashBodySlot(reduceMotion: reduceMotion)
    }

    // Keep the unbounded deployment ForEach as a direct child of
    // DashFeatureList's LazyVStack. DashListGroup's eager inner VStack would
    // otherwise mount every deployment row at once.
    DashListGroupHeader(title: DashL10n.ui("Deployments"))
      .padding(.horizontal, 4)
      .dashSectionBoundary()
      .padding(.bottom, 8)
    if mode.isPlaceholder {
      dashListCard {
        DashListRowPlaceholders(rows: 3)
          .dashListCardInset()
      }
      .dashBodySlot(reduceMotion: reduceMotion)
    } else if deployments.isEmpty {
      DashCard {
        if deploymentError != nil {
          // Failed is not empty: the rows' shape stays and the message
          // veils over it. "No deployments yet." is reserved for the
          // settled zero-row answer below.
          DashListRowPlaceholders(rows: 3)
            .dashSectionFailure(
              deploymentError,
              retry: { Task { await load(force: true) } })
        } else {
          Text("No deployments yet.")
            .dashTextStyle(.footnote)
            .foregroundStyle(DashTheme.subtle)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      // Replaces DashListGroup's content inset for the empty state.
      .dashListCardInset()
      .dashBodySlot(reduceMotion: reduceMotion)
    } else {
      dashListCardRows(items: deployments) { deployment in
        let isActive = deployment.id == deployments.first?.id
        let title = workerDeploymentTitle(deployment)
        let subtitle = workerDeploymentRowSubtitle(deployment, isActive: isActive)
        Button {
          activationError = nil
          confirmingActivation = false
          selectedDeployment = deployment
        } label: {
          DashListRow(
            title: title,
            subtitle: subtitle,
            icon: SolarAsset.Content.code,
            iconColor: isActive
              ? FeatureVisualIdentity.catalogColor(for: .workers) : DashTheme.iconMuted,
            showsChevron: false
          ) {
            if isActive { StatusBadge(.current) }
          }
        }
        .buttonStyle(DashSurfaceButtonStyle())
        .accessibilityLabel(
          workerDeploymentAccessibilityLabel(title: title, subtitle: subtitle)
        )
        // dashListCardRows supplies the row's existing inset; this one
        // replaces DashListGroup's former content inset.
        .dashListCardInset()
      }
    }

    if mode.isPlaceholder {
      DashToggleRowPlaceholder()
        .dashSectionBoundary()
        .dashBodySlot(reduceMotion: reduceMotion)
      DashListGroup(title: "Domains & Routes") {
        DashListRowPlaceholders(rows: 2)
      }
      .dashSectionBoundary()
      .dashBodySlot(reduceMotion: reduceMotion)
    } else {
      DashToggleRow(
        title: "workers.dev",
        subtitle: workersDevSubtitle,
        isOn: subdomainBinding,
        isEnabled: loadedSubdomain && featureAllowsWrites,
        isLoading: subdomainUpdating
      )
      .dashSectionBoundary()
      .dashBodySlot(reduceMotion: reduceMotion)
      // No modifier here: padding this TupleView would re-eagerize the route
      // rows. The section boundary rides domainsGroup's own header instead.
      domainsGroup
        .dashBodySlot(reduceMotion: reduceMotion)
    }
  }

  /// The metrics panel's own shape — heading over three stat tiles — holding the
  /// slot when analytics failed cold, with the failure veiled over it.
  /// Collapsing the glass card to a one-line notice was the section popping out
  /// of its frame. The two collapsed chart cards are separate surfaces and stay
  /// absent here: with no payload there is no series to paint, exactly as when a
  /// loaded worker has no chart points.
  private var workerMetricsFallbackCard: some View {
    DashMetricPanelPlaceholder(tiles: 3)
      .dashSectionFailure(
        analyticsError,
        retry: { Task { await load(force: true) } })
  }

  /// Totals panel (requests / errors / CPU p50), then Watchtower-matched
  /// collapsed charts — each card carries its own total + trend over the
  /// sparkline so the pair reads like the Charts tab, not a second pose.
  private func workerMetricsSection(_ summary: WorkerAnalyticsPayload) -> some View {
    let chartPoints = WorkerAnalyticsChartModel.points(from: summary.points)
    return DashSurfaceStack {
      workerMetricsPanel(summary)
      if !chartPoints.isEmpty {
        workerChartRow(summary, points: chartPoints)
      }
    }
  }

  private func workerMetricsPanel(_ summary: WorkerAnalyticsPayload) -> some View {
    DashGlassCard {
      // The whole panel is one accessibility element; each chart card below is
      // its own.
      VStack(alignment: .leading, spacing: 10) {
        Text("Last 24 hours")
          .dashTextStyle(.footnoteSemibold)
          .foregroundStyle(DashTheme.subtle)
        if dynamicTypeSize.isAccessibilitySize {
          VStack(alignment: .leading, spacing: 12) {
            workerMetric("Requests", summary.requests.formatted())
            workerMetric("Errors", summary.errors.formatted())
            workerMetric(
              "CPU p50",
              String(format: "%.1f ms", summary.cpuTimeP50Us / 1000))
          }
        } else {
          HStack(spacing: 12) {
            workerMetric("Requests", summary.requests.formatted())
            workerMetric("Errors", summary.errors.formatted())
            workerMetric(
              "CPU p50",
              String(format: "%.1f ms", summary.cpuTimeP50Us / 1000))
          }
        }
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel(
        DashL10n.string("Worker metrics. \(summary.requests) requests, \(summary.errors) errors")
      )
    }
  }

  @ViewBuilder
  private func workerChartRow(
    _ summary: WorkerAnalyticsPayload,
    points: [WorkerAnalyticsChartPoint]
  ) -> some View {
    if dynamicTypeSize.isAccessibilitySize {
      // A half-width card cannot hold its title at these sizes — the same
      // reflow Watchtower's card layout performs.
      VStack(alignment: .leading, spacing: DashTheme.Spacing.itemGap) {
        ForEach(WorkerChartMetric.allCases, id: \.self) { metric in
          workerChartCard(metric, summary: summary, points: points)
        }
      }
    } else {
      // Both cards share Watchtower's collapsed chrome (two-line title + total
      // + trend over a fixed-height plot), so halving the row keeps them even.
      HStack(alignment: .top, spacing: DashTheme.Spacing.itemGap) {
        ForEach(WorkerChartMetric.allCases, id: \.self) { metric in
          workerChartCard(metric, summary: summary, points: points)
            .frame(maxWidth: .infinity)
        }
      }
    }
  }

  /// One collapsed chart. The sparkline is an area band for both metrics — the
  /// floor lift that keeps a quiet series visible is a band's device, and a line
  /// pinned to 10% would state a value the worker never had. The CPU detail
  /// behind it stays a line chart.
  private func workerChartCard(
    _ metric: WorkerChartMetric,
    summary: WorkerAnalyticsPayload,
    points: [WorkerAnalyticsChartPoint]
  ) -> some View {
    let collapsed = CollapsedDitherTrendSeries(values: points.map { metric.value(in: $0) })
    let data = zip(points, collapsed.values).map { point, value in
      DitherDatum(
        id: point.date.ISO8601Format(),
        label: point.date.formatted(workerChartAxisFormat),
        values: [metric.seriesKey: value])
    }
    let (summaryValue, trend) = workerChartSummary(metric, summary: summary)
    return DashCollapsedChartCard(
      title: metric.title,
      summaryValue: summaryValue,
      trend: trend,
      data: data,
      series: workerCollapsedSeries(metric),
      valueCeiling: collapsed.valueCeiling,
      accessibilitySummary: workerChartAccessibilitySummary(
        metric,
        summary: summary,
        points: points),
      detail: workerChartDetail(metric, summary: summary, points: points),
      detailAccessibilityIdentifier: metric.detailAccessibilityIdentifier)
  }

  private func workerChartSummary(
    _ metric: WorkerChartMetric,
    summary: WorkerAnalyticsPayload
  ) -> (String, DashChartTrend?) {
    switch metric {
    case .requests:
      (
        summary.requests.formatted(.number.locale(DashL10n.activeLocale)),
        DashChartTrend(
          current: Double(summary.requests),
          previous: summary.previousRequests.map(Double.init),
          polarity: .neutral)
      )
    case .cpu:
      (
        String(format: "%.1f ms", summary.cpuTimeP50Us / 1000),
        DashChartTrend(
          current: summary.cpuTimeP50Us,
          previous: summary.previousCPUTimeP50Us,
          polarity: .lowerIsBetter)
      )
    }
  }

  /// A collapsed card paints its own metric only: the errors overlay would be a
  /// second band with no legend to name it, and it survives in the requests
  /// detail where the legend does.
  private func workerCollapsedSeries(_ metric: WorkerChartMetric) -> [DitherSeries] {
    switch metric {
    case .requests: workerRequestSeries(showsErrors: false)
    case .cpu: workerCPUSeries
    }
  }

  private func workerChartAccessibilitySummary(
    _ metric: WorkerChartMetric,
    summary: WorkerAnalyticsPayload,
    points: [WorkerAnalyticsChartPoint]
  ) -> String {
    switch metric {
    case .requests:
      WorkerAnalyticsChartModel.requestsAccessibilitySummary(
        requests: summary.requests,
        errors: summary.errors)
    case .cpu:
      WorkerAnalyticsChartModel.cpuAccessibilitySummary(points: points)
    }
  }

  private func workerDitherData(_ points: [WorkerAnalyticsChartPoint]) -> [DitherDatum] {
    points.map { point in
      DitherDatum(
        id: point.date.ISO8601Format(),
        label: point.date.formatted(workerChartAxisFormat),
        values: [
          "requests": Double(point.requests),
          "errors": Double(point.errors),
          "cpu": point.cpuTimeP50Ms,
        ])
    }
  }

  private func workerRequestSeries(showsErrors: Bool) -> [DitherSeries] {
    var series = [
      DitherSeries(
        id: "requests",
        label: DashL10n.ui("Requests"),
        color: DashTheme.DitherChart.brand(
          colorScheme: colorScheme,
          contrast: colorSchemeContrast),
        variant: .gradient)
    ]
    if showsErrors {
      series.append(
        DitherSeries(
          id: "errors",
          label: DashL10n.ui("Errors"),
          color: DashTheme.DitherChart.warning(
            colorScheme: colorScheme,
            contrast: colorSchemeContrast),
          variant: .hatched))
    }
    return series
  }

  private var workerCPUSeries: [DitherSeries] {
    [
      DitherSeries(
        id: "cpu",
        label: DashL10n.ui("CPU p50"),
        color: DashTheme.DitherChart.accentPurple(
          colorScheme: colorScheme,
          contrast: colorSchemeContrast),
        variant: .gradient)
    ]
  }

  private func workerChartDetail(
    _ metric: WorkerChartMetric,
    summary: WorkerAnalyticsPayload,
    points: [WorkerAnalyticsChartPoint]
  ) -> DashChartDetail {
    let data = workerDitherData(points)
    let detailPoints = zip(data, points).map { datum, point in
      DashChartDataPoint(
        datum: datum,
        tableLabel: point.date.formatted(
          .dateTime.month(.abbreviated).day().hour().minute()
            .locale(DashL10n.activeLocale)))
    }
    switch metric {
    case .requests:
      let showsErrors = summary.errors > 0
      return DashChartDetail(
        title: metric.title,
        rangeLabel: "Last 24 hours",
        summaryValue: summary.requests.formatted(
          .number.locale(DashL10n.activeLocale)),
        trend: DashChartTrend(
          current: Double(summary.requests),
          previous: summary.previousRequests.map(Double.init),
          polarity: .neutral),
        categoryAxisLabel: "Time",
        valueAxisLabel: "Events",
        axisValueFormat: .compact,
        tableValueFormat: .number(maximumFractionDigits: 0),
        accessibilitySummary: WorkerAnalyticsChartModel.requestsAccessibilitySummary(
          requests: summary.requests,
          errors: summary.errors),
        content: .area(
          points: detailPoints,
          series: workerRequestSeries(showsErrors: showsErrors)),
        featureID: .workers,
        readScopes: FeatureID.workers.capability.read)
    case .cpu:
      return DashChartDetail(
        title: metric.title,
        rangeLabel: "Last 24 hours",
        summaryValue: String(format: "%.1f ms", summary.cpuTimeP50Us / 1000),
        trend: DashChartTrend(
          current: summary.cpuTimeP50Us,
          previous: summary.previousCPUTimeP50Us,
          polarity: .lowerIsBetter),
        categoryAxisLabel: "Time",
        valueAxisLabel: "Milliseconds",
        axisValueFormat: .milliseconds(maximumFractionDigits: 1),
        tableValueFormat: .milliseconds(maximumFractionDigits: 2),
        accessibilitySummary: WorkerAnalyticsChartModel.cpuAccessibilitySummary(
          points: points),
        content: .line(points: detailPoints, series: workerCPUSeries),
        featureID: .workers,
        readScopes: FeatureID.workers.capability.read)
    }
  }

  private var workerChartAxisFormat: Date.FormatStyle {
    Date.FormatStyle.dateTime.hour().minute().locale(DashL10n.activeLocale)
  }

  private func workerMetric(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(value)
        .dashTextStyle(.sectionTitle)
        .foregroundStyle(DashTheme.text)
        .monospacedDigit()
      Text(DashL10n.ui(title))
        .dashTextStyle(.caption)
        .foregroundStyle(DashTheme.subtle)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func load(force: Bool = false) async {
    guard let context = model.accountRequestContext else {
      loading = false
      return
    }
    let accountID = context.accountID
    let cacheKey = WorkerDetailSnapshot.cacheKey(accountID: accountID, name: name)
    if force {
      WorkerDetailCache.invalidate(
        model.featureCache,
        accountID: accountID,
        name: name)
      buildsRefreshID = UUID()
    }
    if !hasPresentedContent || force { loading = true }
    error = nil
    analyticsError = nil
    deploymentError = nil
    domainsError = nil
    routesError = nil

    if !force, let cached: WorkerDetailSnapshot = model.featureCache.get(cacheKey) {
      apply(cached)
      loading = false
      hasPresentedContent = true
      return
    }

    do {
      let client = model.client
      let workerName = name
      let primaryKey = WorkerDetailSnapshot.primaryLoadKey(accountID: accountID, name: name)
      let result: WorkerDetailLoadResult = try await model.featureCache.coalescedLoad(primaryKey) {
        try await WorkerDetailLoader.load(client: client, accountID: accountID, name: workerName)
      }
      try Task.checkCancellation()
      guard model.isCurrentAccount(context) else { return }

      apply(result)
      loading = false

      // Promote as soon as the five primary sections settle. Route discovery
      // can span hundreds of zones and loads as a section-cold continuation.
      if hasPrimaryContent || error == nil {
        hasPresentedContent = true
      }
      await loadRoutes(context: context, primary: result)
    } catch is CancellationError {
      return
    } catch let loadError as URLError where loadError.code == .cancelled {
      return
    } catch {
      guard model.isCurrentAccount(context) else { return }
      self.error = error.dashActionableMessage
      loading = false
    }
  }

  private func apply(_ snapshot: WorkerDetailSnapshot) {
    subdomainEnabled = snapshot.subdomainEnabled
    loadedSubdomain = true
    workersDevHostname = snapshot.workersDevHostname
    deployments = snapshot.deployments
    analytics = snapshot.analytics
    domains = snapshot.domains
    routes = snapshot.routes.filter { $0.script == name }
    error = nil
    analyticsError = nil
    deploymentError = nil
    domainsError = nil
    routesError = nil
  }

  private func apply(_ result: WorkerDetailLoadResult) {
    switch result.subdomain {
    case .success(let enabled):
      subdomainEnabled = enabled
      loadedSubdomain = true
    case .failure(let message):
      error = message
    }

    if let hostname = result.workersDevHostname.value {
      workersDevHostname = hostname
    }

    deployments = result.deployments.value ?? deployments
    deploymentError = result.deployments.failureMessage
    analytics = result.analytics.value ?? analytics
    analyticsError = result.analytics.failureMessage
    domains = result.domains.value ?? domains
    domainsError = result.domains.failureMessage

    // A section that failed while its stale content is still showing has no
    // in-place slot — failed-empty sections veil over their own placeholders,
    // but kept rows are live content, so the shared warm banner carries the
    // first such failure. The hostname lookup never has rows of its own and
    // rides the same banner rather than silently rendering as "no hostname".
    if error == nil {
      if let message = deploymentError, !deployments.isEmpty {
        error = message
      } else if let message = analyticsError, analytics != nil {
        error = message
      } else if let message = domainsError, !domains.isEmpty {
        error = message
      } else if let message = result.workersDevHostname.failureMessage {
        error = message
      }
    }
  }

  private func loadRoutes(
    context: AccountRequestContext,
    primary: WorkerDetailLoadResult
  ) async {
    guard model.isCurrentAccount(context) else { return }
    let loadID = UUID()
    routesLoadID = loadID
    routesLoading = true
    defer {
      if routesLoadID == loadID {
        routesLoading = false
      }
    }

    let accountID = context.accountID
    let client = model.client
    let routesKey = FeatureCacheKey.workerRoutes(accountID)
    do {
      let result: WorkerRoutesLoad
      if let cached: [WorkerZoneRoute] = model.featureCache.get(routesKey) {
        result = WorkerRoutesLoad(routes: cached, isComplete: true, failureMessage: nil)
      } else {
        result = try await model.featureCache.coalescedLoad(routesKey) {
          try await WorkerDetailLoader.loadRoutes(client: client, accountID: accountID)
        }
      }
      try Task.checkCancellation()
      guard model.isCurrentAccount(context), routesLoadID == loadID else { return }

      routes = result.presentedRoutes(for: name, preserving: routes)
      routesError = result.failureMessage
      if result.isComplete {
        model.featureCache.set(routesKey, result.routes)
      }
      if let snapshot = primary.completeSnapshot(routes: result) {
        model.featureCache.set(
          WorkerDetailSnapshot.cacheKey(accountID: accountID, name: name),
          snapshot)
      }
    } catch {
      if error.dashIsCancellation || !model.isCurrentAccount(context) || routesLoadID != loadID {
        return
      }
      routesError = error.dashActionableMessage
    }
  }

  private func invalidateWorkerDetailCache(_ context: AccountRequestContext) {
    WorkerDetailCache.invalidate(
      model.featureCache,
      accountID: context.accountID,
      name: name)
  }

  /// Mutation-scoped refreshes update only the visible section. They invalidate
  /// the composite snapshot and never publish a partial replacement.
  private func loadDeployments(context: AccountRequestContext, force: Bool) async {
    guard model.isCurrentAccount(context) else { return }
    let accountID = context.accountID
    if force {
      invalidateWorkerDetailCache(context)
    }
    do {
      let fetched = try await model.client.listWorkerDeployments(
        accountID: accountID, scriptName: name)
      try Task.checkCancellation()
      guard model.isCurrentAccount(context) else { return }
      deployments = fetched
      deploymentError = nil
    } catch {
      if error.dashIsCancellation || !model.isCurrentAccount(context) { return }
      deploymentError = error.dashActionableMessage
    }
  }

  private func loadDomains(force: Bool = false) async {
    guard let context = model.accountRequestContext else { return }
    await loadDomains(context: context, force: force)
  }

  private func loadDomains(context: AccountRequestContext, force: Bool) async {
    guard model.isCurrentAccount(context) else { return }
    let accountID = context.accountID
    if force {
      invalidateWorkerDetailCache(context)
    }
    do {
      let fetched = try await model.client.listWorkerDomains(accountID: accountID, service: name)
      try Task.checkCancellation()
      guard model.isCurrentAccount(context) else { return }
      domains = fetched
      domainsError = nil
    } catch {
      if error.dashIsCancellation || !model.isCurrentAccount(context) { return }
      domainsError = error.dashActionableMessage
    }
  }

  private func activate(_ deployment: WorkerDeploymentSummary) async {
    guard let context = model.accountRequestContext,
      let versionID = workerPrimaryVersionID(deployment)
    else { return }
    let accountID = context.accountID
    activationPhase = .loading
    activationContext = nil
    activationError = nil
    do {
      _ = try await model.client.createWorkerDeployment(
        accountID: accountID, scriptName: name, versionID: versionID,
        message: "Activated from Dash")
      try Task.checkCancellation()
      guard model.isCurrentAccount(context) else {
        activationPhase = .idle
        return
      }
      model.featureCache.remove(
        FeatureCacheKey.workerDeployments(accountID: accountID, name: name))
      invalidateWorkerDetailCache(context)
      model.toasts.success(DashL10n.string("Deployment activated"))
      activationContext = context
      activationPhase = .succeeded
    } catch {
      activationPhase = .idle
      activationContext = nil
      if error.dashIsCancellation || !model.isCurrentAccount(context) { return }
      activationError = error.dashActionableMessage
      DashDelight.failError()
    }
  }

  private func completeActivationPresentation() {
    guard activationPhase == .succeeded, let context = activationContext else { return }
    confirmingActivation = false
    selectedDeployment = nil
    activationPhase = .idle
    activationContext = nil
    Task {
      guard model.isCurrentAccount(context) else { return }
      await loadDeployments(context: context, force: true)
    }
  }

  private func detachDomain(_ domain: WorkerDomain) async {
    guard let context = model.accountRequestContext else { return }
    let accountID = context.accountID
    deleteDomainPhase = .loading
    deleteDomainError = nil
    do {
      try await model.client.detachWorkerDomain(accountID: accountID, domainID: domain.id)
      try Task.checkCancellation()
      guard model.isCurrentAccount(context) else {
        deleteDomainPhase = .idle
        return
      }
      model.featureCache.remove(FeatureCacheKey.workerDomains(accountID: accountID, name: name))
      invalidateWorkerDetailCache(context)
      model.toasts.success(DashL10n.string("Deleted successfully"))
      await loadDomains(context: context, force: true)
      guard model.isCurrentAccount(context) else {
        deleteDomainPhase = .idle
        return
      }
      deleteDomainPhase = .succeeded
    } catch {
      deleteDomainPhase = .idle
      if error.dashIsCancellation || !model.isCurrentAccount(context) { return }
      deleteDomainError = error.dashActionableMessage
      DashDelight.failError()
    }
  }

  private func completeDomainDeletionPresentation() {
    guard deleteDomainPhase == .succeeded else { return }
    selectedDomain = nil
    deleteDomainPhase = .idle
  }

  private func setSubdomain(_ enabled: Bool) async {
    guard let context = model.accountRequestContext else { return }
    let accountID = context.accountID
    subdomainUpdating = true
    let op = model.optimistic.begin(.toggle(enabled)) {
      subdomainEnabled = !enabled
      subdomainUpdating = false
    }
    defer { subdomainUpdating = false }
    do {
      try await model.optimistic.waitForCommit(op)
      let result = try await model.client.setWorkerSubdomain(
        accountID: accountID, name: name, enabled: enabled)
      try Task.checkCancellation()
      guard model.isCurrentAccount(context) else {
        model.optimistic.finishFailure(op)
        return
      }
      subdomainEnabled = result.enabled
      model.featureCache.set(
        FeatureCacheKey.workerSubdomain(accountID: accountID, name: name), result.enabled)
      invalidateWorkerDetailCache(context)
      model.optimistic.finishSuccess(op)
    } catch is CancellationError {
      // Undo during grace already reverted local state.
    } catch {
      if error.dashIsCancellation || !model.isCurrentAccount(context) {
        model.optimistic.finishFailure(op)
        return
      }
      subdomainEnabled = !enabled
      model.optimistic.finishFailure(op)
      model.toasts.error(error.dashActionableMessage)
    }
  }
}

private func workerPrimaryVersionID(_ deployment: WorkerDeploymentSummary) -> String? {
  if let full = deployment.versions.first(where: { $0.percentage >= 100 }) {
    return full.versionID
  }
  return deployment.versions.first?.versionID
}

private func workerDeploymentAccessibilityLabel(title: String, subtitle: String) -> String {
  "\(title), \(subtitle)"
}

private func workerDeploymentTitle(_ deployment: WorkerDeploymentSummary) -> String {
  if let message = deployment.annotations?.message, !message.isEmpty { return message }
  switch deployment.source.lowercased() {
  case "api": return DashL10n.string("API deployment")
  case "wrangler": return DashL10n.string("Wrangler deployment")
  default: return DashL10n.string("Deployment")
  }
}

private func workerDomainSubtitle(_ domain: WorkerDomain) -> String {
  domain.hostname.caseInsensitiveCompare(domain.zoneName) == .orderedSame
    ? DashL10n.string("Custom domain") : domain.zoneName
}

@MainActor
private func workerDeploymentRowSubtitle(
  _ deployment: WorkerDeploymentSummary, isActive: Bool
) -> String {
  let age = workerDeploymentAgeText(deployment.createdOn)
  if let version = workerPrimaryVersionID(deployment) {
    // Reads the badge's own token rather than a second copy of the word, so the
    // row and the badge beside it cannot end up in different languages.
    let mark = isActive ? "\(StatusToken.current.label) · " : ""
    return "\(mark)\(age) · \(version.prefix(8))"
  }
  return age
}

struct WorkerAddDomainForm: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dashTrayDismiss) private var dismiss
  let service: String
  let onAdded: () async -> Void
  @State private var hostname = ""
  @State private var zones: [CloudflareZone] = []
  @State private var zonesLoaded = false
  @State private var zonesError: String?
  @State private var zonesContext: AccountRequestContext?
  @State private var actionPhase: DashActionPhase = .idle
  @State private var error: String?

  private var normalizedHost: String {
    hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private var matchedZone: CloudflareZone? {
    let host = normalizedHost
    guard !host.isEmpty else { return nil }
    return
      zones
      .filter { host == $0.name || host.hasSuffix("." + $0.name) }
      .max { $0.name.count < $1.name.count }
  }

  var body: some View {
    DashFormSheet(
      saveTitle: "Add domain",
      actionPhase: actionPhase,
      onSuccessPresentationCompleted: completeSuccessPresentation,
      canSave: matchedZone != nil,
      onSave: { Task { await save() } },
      content: {
        VStack(alignment: .leading, spacing: 14) {
          DashFormField(
            label: "Hostname",
            text: $hostname,
            keyboard: .URL,
            contentType: .URL)
          if let zone = matchedZone {
            Text("Will route through the \(zone.name) zone.")
              .dashTextStyle(.footnote)
              .foregroundStyle(DashTheme.subtle)
          } else if !normalizedHost.isEmpty, zonesLoaded {
            DashNotice(
              kind: .warning,
              message: "No zone in this account matches that hostname.")
          }
          if let zonesError {
            // A failed zones lookup is not "no zone matches": say so, and
            // offer the retry the .task won't repeat on its own.
            DashNotice(kind: .error, message: zonesError)
            Button(DashL10n.string("Try again")) {
              withAnimation(DashTheme.Motion.content) { self.zonesError = nil }
              Task { await loadZones() }
            }
            .dashTextStyle(.supportingSemibold)
            .foregroundStyle(DashTheme.brand)
            .buttonStyle(DashPressButtonStyle())
            .dashCompactHitTarget()
          }
          if let error {
            DashNotice(kind: .error, message: error)
          }
        }
      }
    )
    .dashTrayDescription(
      DashL10n.string(
        "Cloudflare provisions the edge certificate. DNS for the hostname must already point at this account."
      )
    )
    .task(id: model.accountRequestContext) { await loadZones() }
  }

  private func loadZones() async {
    let context = model.accountRequestContext
    zonesContext = context
    zones = []
    zonesLoaded = false
    zonesError = nil
    guard let context else { return }
    if let cached: [CloudflareZone] = model.featureCache.get(
      FeatureCacheKey.zones(context.accountID))
    {
      guard model.isCurrentAccount(context), zonesContext == context else { return }
      zones = cached
      zonesLoaded = true
      return
    }
    let client = model.client
    do {
      let loaded = try await client.listZones(accountID: context.accountID, perPage: 50).items
      guard !Task.isCancelled, model.isCurrentAccount(context), zonesContext == context else {
        return
      }
      zones = loaded
      zonesLoaded = true
    } catch {
      // `zonesLoaded` stays false: an empty list from a thrown lookup must
      // never present the "No zone matches" answer.
      guard !Task.isCancelled, !error.dashIsCancellation, model.isCurrentAccount(context),
        zonesContext == context
      else { return }
      zonesError = error.dashActionableMessage
    }
  }

  private func save() async {
    guard let context = model.accountRequestContext,
      zonesContext == context,
      let zone = matchedZone
    else { return }
    let accountID = context.accountID
    actionPhase = .loading
    error = nil
    do {
      try await model.client.attachWorkerDomain(
        accountID: accountID, hostname: normalizedHost, service: service,
        zoneID: zone.id, zoneName: zone.name)
      try Task.checkCancellation()
      guard model.isCurrentAccount(context) else {
        actionPhase = .idle
        return
      }
      model.featureCache.remove(
        FeatureCacheKey.workerDomains(accountID: accountID, name: service))
      WorkerDetailCache.invalidate(
        model.featureCache,
        accountID: accountID,
        name: service)
      await onAdded()
      guard model.isCurrentAccount(context) else {
        actionPhase = .idle
        return
      }
      model.toasts.success(DashL10n.string("Added successfully"))
      actionPhase = .succeeded
    } catch {
      actionPhase = .idle
      if error.dashIsCancellation || !model.isCurrentAccount(context) { return }
      self.error = error.dashActionableMessage
    }
  }

  private func completeSuccessPresentation() {
    guard actionPhase == .succeeded else { return }
    dismiss()
  }
}

@MainActor
private enum WorkerDeploymentDateFormatting {
  private static let fractionalISO8601: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  private static let plainISO8601: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()

  private static var relativeCache: (locale: Locale, formatter: RelativeDateTimeFormatter)?

  static func date(from value: String) -> Date? {
    fractionalISO8601.date(from: value) ?? plainISO8601.date(from: value)
  }

  static func relativeString(for date: Date, relativeTo now: Date, locale: Locale) -> String {
    let formatter: RelativeDateTimeFormatter
    if let cached = relativeCache, cached.locale == locale {
      formatter = cached.formatter
    } else {
      formatter = RelativeDateTimeFormatter()
      formatter.unitsStyle = .abbreviated
      formatter.locale = locale
      relativeCache = (locale, formatter)
    }
    return formatter.localizedString(for: date, relativeTo: now)
  }
}

private func workerRowAccessibilityLabel(_ worker: WorkerScript) -> String {
  DashL10n.string("\(worker.id), Worker")
}

@MainActor
func workerDeploymentAgeText(_ value: String, now: Date = .now) -> String {
  guard let date = WorkerDeploymentDateFormatting.date(from: value) else {
    return DashL10n.string("Deployed \(value)")
  }
  let relative = WorkerDeploymentDateFormatting.relativeString(
    for: date,
    relativeTo: now,
    locale: DashL10n.activeLocale)
  return DashL10n.string("Deployed \(relative)")
}

private func workerDeploymentTrafficText(_ deployment: WorkerDeploymentSummary) -> String {
  guard !deployment.versions.isEmpty else {
    // Cloudflare's own upload-source vocabulary; no fixed set to translate.
    return DashL10n.ui(deployment.source.capitalized)
  }
  if deployment.versions.count == 1, let version = deployment.versions.first {
    let id = String(version.versionID.prefix(8))
    return DashL10n.string("Version \(id) · \(version.percentage.formatted())% traffic")
  }
  return DashL10n.string("Traffic split across \(deployment.versions.count) versions")
}

private enum FeatureExternalURL {
  static let workersGuide = URL(
    string: "https://developers.cloudflare.com/workers/get-started/guide/")!
}
