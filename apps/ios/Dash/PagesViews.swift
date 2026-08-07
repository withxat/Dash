import CloudflareAPI
import SwiftDitherKit
import SwiftUI
import UIKit

struct PagesProjectsView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.openURL) private var openURL
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var projects: [PagesProject] = []
  @State private var loading = true
  @State private var error: String?

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      hasContent: !projects.isEmpty,
      empty: DashFeatureEmpty(
        icon: SolarAsset.Content.codeCircle,
        title: DashL10n.string("No Pages projects"),
        message: DashL10n.string(
          "Create projects in the dashboard or with Wrangler — manage deployments and domains here."
        ),
        actionTitle: "Open Pages docs",
        action: { openURL(PagesExternalURL.getStarted) }
      ),
      retry: { Task { await load(force: true) } }
    ) { mode in
      dashListCard {
        dashModeListRows(mode: mode, items: projects, reduceMotion: reduceMotion) { project in
          DashListGroupLink(value: .pagesProject(project.name)) {
            DashListRow(
              title: project.name,
              subtitle: pagesProjectSubtitle(project),
              icon: SolarAsset.Content.codeCircle
            )
            .accessibilityLabel(pagesProjectAccessibilityLabel(project))
          }
        }
      }
    }
    .refreshable { await load(force: true) }
    .task { await load() }
  }

  private func load(force: Bool = false) async {
    guard let accountID = model.activeAccountID else { return }
    let key = FeatureCacheKey.pagesProjects(accountID)
    if !force, let cached: [PagesProject] = model.featureCache.get(key) {
      projects = cached
      loading = false
      error = nil
      return
    }
    // Cold but a stale copy exists on disk: paint it now and refresh in place.
    if projects.isEmpty, let stale: [PagesProject] = model.featureCache.getStale(key) {
      projects = stale
      loading = true
    }
    if projects.isEmpty { loading = true }
    error = nil
    do {
      projects = try await model.client.listPagesProjects(accountID: accountID)
      model.featureCache.set(key, projects)
    } catch {
      self.error = error.dashActionableMessage
    }
    loading = false
  }
}

struct PagesProjectDetailView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @AppStorage(RecentResources.key) private var recentsRaw = ""
  let projectName: String
  @State private var project: PagesProject?
  @State private var deployments: [PagesDeployment] = []
  @State private var loading = true
  @State private var error: String?
  @State private var deploymentsError: String?
  @State private var selectedSliceID: String?
  /// False until the first load settles — Cold skeleton for the whole first
  /// paint, even if the project cache hydrates before deployments finish.
  @State private var hasPresentedContent = false

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      hasContent: hasPresentedContent,
      retry: { Task { await load(force: true) } }
    ) { mode in
      pagesProjectDetailBody(mode: mode)
    }
    .detailHeader(
      icon: .solar(SolarAsset.Content.codeCircle),
      title: projectName,
      tint: FeatureVisualIdentity.heroColor(for: .pages)
    )
    .task {
      if let accountID = model.activeAccountID {
        recentsRaw = RecentResources.recording(
          RecentResource(
            accountID: accountID, kind: .pagesProject, resourceID: projectName, title: projectName),
          in: recentsRaw)
      }
      await load()
    }
    .refreshable { await load(force: true) }
  }

  /// Fuller first-paint reserve: summary, Domains, build outcomes, deployments.
  /// Live mode drops empty outcomes; that slot exits upward.
  @ViewBuilder
  private func pagesProjectDetailBody(mode: DashBodyMode) -> some View {
    DashSurfaceStack {
      if mode.isPlaceholder {
        DashCard {
          VStack(alignment: .leading, spacing: 8) {
            Text(projectName)
              .dashTextStyle(.sheetTitle)
              .foregroundStyle(DashTheme.text)
            Text(verbatim: "project.pages.dev")
              .dashTextStyle(.code)
              .foregroundStyle(DashTheme.subtle)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .dashBodyPlaceholder(true)
        .dashBodySlot(reduceMotion: reduceMotion)
      } else if let project {
        DashCard {
          VStack(alignment: .leading, spacing: 8) {
            Text(project.name)
              .dashTextStyle(.sheetTitle)
              .foregroundStyle(DashTheme.text)
            if let subdomain = project.subdomain {
              Text(subdomain)
                .dashTextStyle(.code)
                .foregroundStyle(DashTheme.subtle)
                .textSelection(.enabled)
            }
            if let latest = project.latestDeployment?.latestStage?.status {
              StatusBadge(StatusToken(pagesStatus: latest))
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .dashBodySlot(reduceMotion: reduceMotion)
      }

      dashListCard {
        DashListGroupLink(value: .pagesDomains(projectName)) {
          DashListRow(
            title: DashL10n.string("Domains"),
            icon: SolarAsset.globe,
            showsIconPlate: false
          )
          .accessibilityLabel(DashL10n.string("Domains, Custom domains for this project"))
        }
        .dashListCardInset()
      }
      .dashBodyPlaceholder(mode.isPlaceholder)
      .dashBodySlot(reduceMotion: reduceMotion)

      if mode.isPlaceholder {
        DashChartPanelPlaceholder(showsLegend: true)
          .dashBodySlot(reduceMotion: reduceMotion)
      } else if !deployments.isEmpty {
        buildOutcomesCard
          .dashBodySlot(reduceMotion: reduceMotion)
      }
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
        if deploymentsError != nil {
          // A failed deployments fetch keeps the rows' shape on the ground
          // and veils the message over it — swapping in a bare notice was
          // the section popping out of its own frame.
          DashListRowPlaceholders(rows: 3)
            .dashSectionFailure(
              deploymentsError,
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
      dashListCardRows(items: visibleDeployments) { deployment in
        let title = pagesDeploymentTitle(deployment)
        let subtitle = pagesDeploymentSubtitle(deployment)
        DashListGroupLink(
          value: .pagesDeployment(project: projectName, deploymentID: deployment.id)
        ) {
          DashListRow(
            title: title,
            subtitle: subtitle,
            icon: SolarAsset.Content.codeCircle,
            iconColor: pagesStatusColor(deployment.latestStage?.status),
            showsChevron: true
          )
          .accessibilityLabel(
            pagesDeploymentAccessibilityLabel(title: title, subtitle: subtitle)
          )
        }
        .transition(morphTransition)
        // dashListCardRows supplies the row's existing inset; this one
        // replaces DashListGroup's former content inset.
        .dashListCardInset()
      }
    }
  }

  private var buildOutcomesCard: some View {
    // Chart cards stay on the glass surface, not the info-group band — see the
    // surface split on `DashGlassCard`. No detail chevron: the donut is a filter
    // control for the list below, and its legend already names every slice, so a
    // pushed copy would only restate what the card shows.
    DashGlassCard {
      VStack(alignment: .leading, spacing: 12) {
        Text("Build outcomes")
          .dashTextStyle(.footnoteSemibold)
          .foregroundStyle(DashTheme.subtle)
          .frame(maxWidth: .infinity, alignment: .leading)
        DashPieChart(
          slices: outcomeSlices,
          innerRadiusRatio: 0.62,
          options: DashTheme.DitherChart.polarOptions(
            accessibility: DitherAccessibility(
              title: DashL10n.ui("Deployment build outcomes"),
              summary: PagesDeploymentChartModel.chartAccessibilitySummary(
                buckets: PagesDeploymentChartModel.buckets(deployments)),
              categoryAxisLabel: DashL10n.ui("Outcome"),
              valueAxisLabel: DashL10n.ui("Deployments"))),
          // Slice and legend taps drive the outcome strip and deployment-list
          // diff in the same transaction, matching DNS record filtering.
          selection: $selectedSliceID.animation(DashTheme.Motion.morph)
        )
        .frame(
          height: DashTheme.DitherChart.height(
            dynamicTypeSize: dynamicTypeSize,
            showsLegend: true))
        filterStrip
      }
    }
  }

  @ViewBuilder
  private var filterStrip: some View {
    if let bucket = selectedBucket {
      DashChartFilterStrip(
        label: PagesDeploymentChartModel.label(for: bucket.outcome),
        countText: DashL10n.string(
          "\(bucket.count.formatted()) of \(deployments.count.formatted()) deployments"),
        color: sliceColor(for: bucket.outcome),
        clearAccessibilityLabel: DashL10n.string("Show all build outcomes"),
        clearAccessibilityIdentifier: "pages-outcome-filter-clear"
      ) {
        withAnimation(DashTheme.Motion.morph) { selectedSliceID = nil }
      }
      .transition(morphTransition)
    }
  }

  private var visibleDeployments: [PagesDeployment] {
    PagesDeploymentChartModel.deployments(deployments, in: selectedSliceID)
  }

  private var selectedBucket: PagesDeploymentChartModel.Bucket? {
    PagesDeploymentChartModel.bucket(deployments, withID: selectedSliceID)
  }

  /// Filtered-out deployments dissolve while surviving rows glide into their
  /// new slots. Reduce Motion keeps only the opacity half of the transition.
  private var morphTransition: AnyTransition {
    reduceMotion ? .opacity : .dashMorph
  }

  private var outcomeSlices: [DitherSlice] {
    PagesDeploymentChartModel.buckets(deployments).map { bucket in
      DitherSlice(
        id: bucket.id,
        label: PagesDeploymentChartModel.label(for: bucket.outcome),
        value: Double(bucket.count),
        color: sliceColor(for: bucket.outcome))
    }
  }

  private func sliceColor(for outcome: PagesDeploymentChartModel.Outcome) -> DitherColor {
    switch outcome {
    case .success:
      DashTheme.DitherChart.positive(colorScheme: colorScheme, contrast: colorSchemeContrast)
    case .inFlight:
      DashTheme.DitherChart.brand(colorScheme: colorScheme, contrast: colorSchemeContrast)
    case .failure:
      DashTheme.DitherChart.negative(colorScheme: colorScheme, contrast: colorSchemeContrast)
    case .canceled, .other:
      DashTheme.DitherChart.neutral(colorScheme: colorScheme, contrast: colorSchemeContrast)
    }
  }

  private func load(force: Bool = false) async {
    guard let accountID = model.activeAccountID else {
      loading = false
      return
    }
    if !hasPresentedContent || force { loading = true }
    error = nil
    let projectKey = FeatureCacheKey.pagesProject(accountID: accountID, name: projectName)
    if !force, let cached: PagesProject = model.featureCache.get(projectKey) {
      project = cached
    } else {
      do {
        let fetched = try await model.client.getPagesProject(
          accountID: accountID, projectName: projectName)
        project = fetched
        model.featureCache.set(projectKey, fetched)
      } catch {
        // Cold: the veil over the skeleton. Warm: the inline banner over the
        // kept project — a pull-to-refresh that fails must say so.
        if !error.dashIsCancellation { self.error = error.dashActionableMessage }
      }
    }

    let deployKey = FeatureCacheKey.pagesDeployments(accountID: accountID, name: projectName)
    if !force, let cached: [PagesDeployment] = model.featureCache.get(deployKey) {
      deployments = cached
      deploymentsError = nil
    } else {
      do {
        let page = try await model.client.listPagesDeployments(
          accountID: accountID, projectName: projectName)
        deployments = page.items
        deploymentsError = nil
        model.featureCache.set(deployKey, deployments)
      } catch {
        if !error.dashIsCancellation {
          deploymentsError = error.dashActionableMessage
          // With rows on screen the section keeps them; the shared warm
          // banner is the only surface that can carry the refresh failure.
          if !deployments.isEmpty, self.error == nil {
            self.error = error.dashActionableMessage
          }
        }
      }
    }
    loading = false
    if project != nil || error == nil {
      hasPresentedContent = true
    }
  }
}

struct PagesDeploymentDetailView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.featureAllowsWrites) private var featureAllowsWrites
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let projectName: String
  let deploymentID: String
  @State private var deployment: PagesDeployment?
  @State private var logs: PagesDeploymentLogs?
  @State private var loading = true
  @State private var error: String?
  @State private var logsError: String?
  @State private var actionError: String?
  @State private var retryPhase: DashActionPhase = .idle
  @State private var rollbackPhase: DashActionPhase = .idle
  @State private var confirmingRollback = false
  @State private var hasPresentedContent = false
  @State private var replacementDeploymentID: String?
  @State private var hasRequestedLogs = false
  @State private var observedKey: PagesBuildMonitorKey?

  private var monitoredDeploymentID: String {
    replacementDeploymentID ?? deploymentID
  }

  private var working: Bool {
    retryPhase.isActive || rollbackPhase.isActive
  }

  private var monitorKey: PagesBuildMonitorKey? {
    guard let context = model.accountRequestContext else { return nil }
    return PagesBuildMonitorKey(
      accountID: context.accountID,
      accountGeneration: context.generation,
      projectName: projectName,
      deploymentID: monitoredDeploymentID)
  }

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      hasContent: hasPresentedContent,
      retry: { Task { await refreshManually() } }
    ) { mode in
      pagesDeploymentDetailBody(mode: mode)
    }
    .detailHeader(
      icon: .solar(SolarAsset.Content.codeCircle),
      title: deployment.map(pagesDeploymentTitle) ?? "Deployment"
    )
    .refreshable { await refreshManually() }
    .task(id: monitorKey) {
      guard let key = monitorKey else {
        loading = false
        return
      }
      await monitorDeployment(key)
    }
  }

  /// Fuller first-paint reserve: Deployment + Stages. Actions and the build
  /// log stay live-only (log is section-cold after the deployment lands).
  @ViewBuilder
  private func pagesDeploymentDetailBody(mode: DashBodyMode) -> some View {
    if mode.isPlaceholder {
      DashInfoGroup(title: "Deployment", phase: .loading, placeholderRows: 4) {
        EmptyView()
      }
      .dashBodySlot(reduceMotion: reduceMotion)
      DashInfoGroup(title: "Stages", phase: .loading, placeholderRows: 3) {
        EmptyView()
      }
      .dashSectionBoundary()
      .dashBodySlot(reduceMotion: reduceMotion)
    } else if let deployment {
      deploymentGroup(deployment)
        .dashBodySlot(reduceMotion: reduceMotion)
      stagesGroup(deployment)
      if let actionError {
        DashNotice(kind: .error, message: actionError)
          .dashItemBoundary()
      }
      actions(for: deployment)
        .dashSectionBoundary(featureAllowsWrites)
        .dashBodySlot(reduceMotion: reduceMotion)
      logsSection
        .dashSectionBoundary()
        .dashBodySlot(reduceMotion: reduceMotion)
    }
  }

  /// The commit message is the screen's `detailHeader` title, so it is not
  /// repeated here. What the old summary card ran together into one “env ·
  /// status · when” caption is split back into its own fields, and the status
  /// appears once — as the badge — instead of as a badge *and* a word in that
  /// caption.
  private func deploymentGroup(_ deployment: PagesDeployment) -> some View {
    DashInfoGroup(title: "Deployment") {
      if let environment = deployment.environment {
        DashInfoRow("Environment", value: DashL10n.ui(environment.capitalized))
      }
      DashInfoRow("Status") {
        StatusBadge(
          StatusToken(
            pagesStatus: deployment.latestStage?.status,
            isSkipped: deployment.isSkipped == true))
      }
      if let created = deployment.createdOn {
        DashInfoRow("Created", value: pagesRelativeDate(created))
      }
      if let urlString = deployment.url, let link = URL(string: urlString) {
        DashInfoRow("URL") {
          Link(urlString, destination: link)
            .dashTextStyle(.code)
            .foregroundStyle(DashTheme.brand)
            .multilineTextAlignment(.trailing)
            .lineLimit(2)
        }
      }
    }
  }

  /// Cloudflare runs a fixed set of build stages, so this stays bounded.
  ///
  /// Deliberately *not* `StatusToken(pagesStatus:)`: that maps `idle` to “In
  /// progress”, which is right for the deployment's latest stage — the pipeline
  /// is sitting on it — and wrong for every stage after it, which is also
  /// `idle` and has not started. A per-stage status is its own vocabulary.
  @ViewBuilder
  private func stagesGroup(_ deployment: PagesDeployment) -> some View {
    if let stages = deployment.stages, !stages.isEmpty {
      DashInfoGroup(title: "Stages") {
        ForEach(Array(stages.enumerated()), id: \.offset) { _, stage in
          DashInfoRow(
            pagesStageLabel(stage.name),
            value: pagesStageStatusLabel(stage.status))
        }
      }
      .dashSectionBoundary()
      .dashBodySlot(reduceMotion: reduceMotion)
    }
  }

  @ViewBuilder
  private func actions(for deployment: PagesDeployment) -> some View {
    if featureAllowsWrites {
      DashListGroup(title: "Actions") {
        DashCard {
          VStack(spacing: 10) {
            DashActionButton(
              title: "Retry deployment",
              phase: retryPhase,
              onSuccessPresentationCompleted: { retryPhase = .idle }
            ) {
              Task { await retry() }
            }
            .disabled(working)

            if deployment.environment == "production" {
              DashActionButton(
                title: "Rollback to this",
                role: .destructive,
                phase: rollbackPhase,
                onSuccessPresentationCompleted: completeRollbackPresentation
              ) {
                if confirmingRollback {
                  Task { await rollback() }
                } else {
                  confirmingRollback = true
                }
              }
              .disabled(working)
              if confirmingRollback {
                Button("Cancel") { confirmingRollback = false }
                  .dashTextStyle(.buttonMedium)
                  .foregroundStyle(DashTheme.subtle)
              }
            }
          }
        }
      }
    }
  }

  @ViewBuilder private var logsSection: some View {
    DashListGroup(title: "Build log") {
      if let logs {
        DashCard {
          DashFadedScrollView(
            surface: DashTheme.recessed,
            maxHeight: 360,
            bounceBasedOnSize: true
          ) {
            LazyVStack(alignment: .leading, spacing: 2) {
              ForEach(logs.data) { line in
                Text(line.line.isEmpty ? " " : line.line)
                  .dashTextStyle(.code)
                  .foregroundStyle(DashTheme.text)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
            }
          }
        }
        if let logsError {
          // Warm: the monitor's forced refresh failed mid-build — keep the
          // visible log and say so beside it instead of tearing it down.
          DashNotice(kind: .warning, message: logsError)
            .dashItemBoundary()
        }
      } else {
        // The log's own shape holds the section while it loads, and a failure
        // veils over the same lines — the card never swaps to a bare notice.
        DashCard {
          logPlaceholder
            .dashSectionFailure(logsError, retry: retryLogs)
        }
      }
    }
  }

  private var logPlaceholder: some View {
    let widths: [CGFloat] = [200, 148, 232, 120, 184, 96]
    return VStack(alignment: .leading, spacing: 8) {
      ForEach(0..<6, id: \.self) { index in
        RoundedRectangle(cornerRadius: 3, style: .continuous)
          .dashSkeletonFill(index.isMultiple(of: 2) ? 0.5 : 0.35)
          .frame(width: widths[index], height: 10)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Loading")
  }

  private func retryLogs() {
    guard let key = monitorKey else { return }
    withAnimation(DashTheme.Motion.content) { logsError = nil }
    Task { await loadLogs(key: key, force: true) }
  }

  private func monitorDeployment(_ key: PagesBuildMonitorKey) async {
    if let observedKey,
      observedKey.accountID != key.accountID || observedKey.deploymentID != key.deploymentID
    {
      deployment = nil
      logs = nil
      logsError = nil
      hasRequestedLogs = false
      hasPresentedContent = false
    }
    observedKey = key
    if !hasPresentedContent { loading = true }
    error = nil

    let client = model.client
    let updates = PagesBuildActivityController.shared.updates(for: key, client: client)
    let initialRefresh = Task {
      await PagesBuildActivityController.shared.refresh(
        key: key,
        client: client,
        source: .initial)
    }
    defer { initialRefresh.cancel() }

    for await event in updates {
      guard !Task.isCancelled, monitorKey == key else { return }
      await apply(event, key: key)
    }
  }

  private func refreshManually() async {
    guard let key = monitorKey else {
      loading = false
      return
    }
    loading = true
    error = nil
    await PagesBuildActivityController.shared.refresh(
      key: key,
      client: model.client,
      source: .manual)
  }

  private func apply(_ event: PagesBuildMonitorEvent, key: PagesBuildMonitorKey) async {
    let context = AccountRequestContext(
      accountID: key.accountID,
      generation: key.accountGeneration)
    guard model.isCurrentAccount(context), monitorKey == key else { return }

    switch event {
    case .deployment(let latest, let source):
      let previous = deployment
      deployment = latest
      loading = false
      error = nil
      hasPresentedContent = true

      let refreshesLogs = PagesBuildLogRefreshPolicy.shouldRefresh(
        hasRequestedLogs: hasRequestedLogs,
        previousWasInProgress: previous?.isInProgress == true,
        latestIsInProgress: latest.isInProgress,
        source: source)
      if refreshesLogs {
        await loadLogs(key: key, force: hasRequestedLogs)
      }

    case .failure(let message, _, _):
      loading = false
      error = message
      if deployment != nil {
        hasPresentedContent = true
      }
    }
  }

  private func loadLogs(key: PagesBuildMonitorKey, force: Bool) async {
    if !force, hasRequestedLogs { return }
    hasRequestedLogs = true
    let context = AccountRequestContext(
      accountID: key.accountID,
      generation: key.accountGeneration)
    let client = model.client
    let loadKey =
      "pagesDeploymentLogs:\(key.accountID):\(key.projectName):\(key.deploymentID)"
    do {
      let fetched: PagesDeploymentLogs = try await model.featureCache.coalescedLoad(loadKey) {
        try await client.getPagesDeploymentLogs(
          accountID: key.accountID,
          projectName: key.projectName,
          deploymentID: key.deploymentID)
      }
      guard !Task.isCancelled, model.isCurrentAccount(context), monitorKey == key else {
        return
      }
      logs = fetched
      logsError = nil
    } catch {
      guard !Task.isCancelled, !error.dashIsCancellation, model.isCurrentAccount(context),
        monitorKey == key
      else {
        return
      }
      logsError = error.dashActionableMessage
    }
  }

  private func retry() async {
    guard let key = monitorKey else { return }
    let context = AccountRequestContext(
      accountID: key.accountID,
      generation: key.accountGeneration)
    retryPhase = .loading
    actionError = nil
    do {
      let created = try await model.client.retryPagesDeployment(
        accountID: key.accountID,
        projectName: key.projectName,
        deploymentID: key.deploymentID)
      guard model.isCurrentAccount(context), monitorKey == key else {
        retryPhase = .idle
        return
      }
      model.featureCache.remove(
        FeatureCacheKey.pagesDeployments(accountID: key.accountID, name: projectName))
      model.toasts.success(DashL10n.string("Retry started"))
      // Jump to the new deployment when retry returns one.
      if created.id != key.deploymentID {
        let replacementKey = PagesBuildMonitorKey(
          accountID: key.accountID,
          accountGeneration: key.accountGeneration,
          projectName: key.projectName,
          deploymentID: created.id)
        // Prime the monitor before re-keying the screen, so the Live Activity
        // is up on this build immediately instead of after the re-keyed task's
        // first fetch comes back.
        await PagesBuildActivityController.shared.adopt(
          deployment: created,
          key: replacementKey,
          client: model.client)
        guard model.isCurrentAccount(context), monitorKey == key else {
          retryPhase = .idle
          return
        }
        observedKey = replacementKey
        deployment = created
        hasPresentedContent = true
        logs = nil
        logsError = nil
        hasRequestedLogs = false
        replacementDeploymentID = created.id
      } else {
        await PagesBuildActivityController.shared.adopt(
          deployment: created,
          key: key,
          client: model.client)
        guard model.isCurrentAccount(context), monitorKey == key else {
          retryPhase = .idle
          return
        }
        await refreshManually()
      }
      guard !Task.isCancelled else {
        retryPhase = .idle
        return
      }
      retryPhase = .succeeded
    } catch {
      retryPhase = .idle
      guard !error.dashIsCancellation, model.isCurrentAccount(context), monitorKey == key else {
        return
      }
      actionError = error.dashActionableMessage
      DashDelight.failError()
    }
  }

  private func rollback() async {
    guard let key = monitorKey else { return }
    let context = AccountRequestContext(
      accountID: key.accountID,
      generation: key.accountGeneration)
    rollbackPhase = .loading
    actionError = nil
    do {
      _ = try await model.client.rollbackPagesDeployment(
        accountID: key.accountID,
        projectName: key.projectName,
        deploymentID: key.deploymentID)
      guard !Task.isCancelled, model.isCurrentAccount(context), monitorKey == key else {
        rollbackPhase = .idle
        return
      }
      model.featureCache.remove(
        FeatureCacheKey.pagesDeployments(accountID: key.accountID, name: projectName))
      model.toasts.success(DashL10n.string("Rolled back successfully"))
      rollbackPhase = .succeeded
    } catch {
      rollbackPhase = .idle
      guard !error.dashIsCancellation, model.isCurrentAccount(context), monitorKey == key else {
        return
      }
      actionError = error.dashActionableMessage
      DashDelight.failError()
    }
  }

  private func completeRollbackPresentation() {
    guard rollbackPhase == .succeeded else { return }
    rollbackPhase = .idle
    confirmingRollback = false
    Task { await refreshManually() }
  }
}

struct PagesDomainsView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.featureAllowsWrites) private var featureAllowsWrites
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let projectName: String
  @State private var domains: [PagesDomain] = []
  @State private var loading = true
  @State private var error: String?
  @State private var addsDomain = false
  @State private var selected: PagesDomain?
  @State private var deletePhase: DashActionPhase = .idle
  @State private var deleteError: String?

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      hasContent: !domains.isEmpty,
      empty: DashFeatureEmpty(
        icon: SolarAsset.Content.globe,
        title: DashL10n.string("No custom domains"),
        message: featureAllowsWrites
          ? DashL10n.string("Attach a hostname from one of this account's zones.")
          : DashL10n.string("Grant Pages write access to attach a custom domain."),
        actionTitle: featureAllowsWrites ? DashL10n.string("Add domain") : nil,
        action: featureAllowsWrites ? { addsDomain = true } : nil
      ),
      retry: { Task { await load(force: true) } }
    ) { mode in
      dashListCard {
        dashModeListRows(mode: mode, items: domains, reduceMotion: reduceMotion) { domain in
          // Hoisted out of the row: inlining the lookup inside the builder
          // pushed this body past the type checker's budget and surfaced as an
          // "ambiguous use of toolbar" error 20 lines down.
          let status = DashL10n.ui((domain.status ?? "unknown").capitalized)
          Button {
            deleteError = nil
            selected = domain
          } label: {
            DashListRow(
              title: domain.name,
              subtitle: status,
              icon: SolarAsset.Content.globe,
              iconColor: domain.status == "active"
                ? FeatureVisualIdentity.catalogColor(for: .pages) : DashTheme.iconMuted,
              showsChevron: false
            )
          }
          .buttonStyle(DashSurfaceButtonStyle())
          .accessibilityLabel("\(domain.name), \(status)")
        }
      }
    }
    .detailHeader(
      icon: .solar(SolarAsset.Content.globe),
      title: "Domains",
      tint: FeatureVisualIdentity.heroColor(for: .pages)
    )
    .dashPageActions(
      trailing: featureAllowsWrites
        ? [
          .icon(
            id: "pages-add-domain",
            asset: SolarAsset.plus,
            accessibilityLabel: DashL10n.string("Add domain")
          ) {
            addsDomain = true
          }
        ] : []
    )
    .refreshable { await load(force: true) }
    .task { await load() }
    .dashTray(
      isPresented: $addsDomain, title: "Add custom domain",
      tone: FeatureVisualIdentity.tone(for: .pages)
    ) {
      PagesAddDomainForm(projectName: projectName) {
        await load(force: true)
      }
    }
    .dashTray(
      item: $selected,
      title: { $0.name },
      tone: FeatureVisualIdentity.tone(for: .pages),
      content: { domain in
        DashDetailTray(
          fields: [
            DashDetailField(label: "Hostname", value: domain.name),
            DashDetailField(label: "Status", value: (domain.status ?? "—").capitalized),
            DashDetailField(label: "Zone", value: domain.zoneTag ?? "—", mono: true),
          ],
          deleteMessage: featureAllowsWrites
            ? DashL10n.string("Detach \(domain.name) from \(projectName).")
            : nil,
          deletePhase: deletePhase,
          onDeleteSuccessPresentationCompleted: completeDeletePresentation,
          deleteError: deleteError,
          onDelete: featureAllowsWrites ? { Task { await remove(domain) } } : nil
        )
      }
    )
  }

  private func load(force: Bool = false) async {
    guard let accountID = model.activeAccountID else { return }
    let key = FeatureCacheKey.pagesDomains(accountID: accountID, name: projectName)
    if !force, let cached: [PagesDomain] = model.featureCache.get(key) {
      domains = cached
      loading = false
      error = nil
      return
    }
    if domains.isEmpty { loading = true }
    do {
      domains = try await model.client.listPagesDomains(
        accountID: accountID, projectName: projectName)
      model.featureCache.set(key, domains)
      error = nil
    } catch {
      self.error = error.dashActionableMessage
    }
    loading = false
  }

  private func remove(_ domain: PagesDomain) async {
    guard let context = model.accountRequestContext else { return }
    deletePhase = .loading
    deleteError = nil
    do {
      try await model.client.deletePagesDomain(
        accountID: context.accountID, projectName: projectName, domainName: domain.name)
      guard !Task.isCancelled, model.isCurrentAccount(context) else {
        deletePhase = .idle
        return
      }
      model.featureCache.remove(
        FeatureCacheKey.pagesDomains(accountID: context.accountID, name: projectName))
      model.toasts.success(DashL10n.string("Deleted successfully"))
      deletePhase = .succeeded
    } catch {
      deletePhase = .idle
      guard !error.dashIsCancellation, model.isCurrentAccount(context) else { return }
      deleteError = error.dashActionableMessage
      DashDelight.failError()
    }
  }

  private func completeDeletePresentation() {
    guard deletePhase == .succeeded else { return }
    deletePhase = .idle
    selected = nil
    Task { await load(force: true) }
  }
}

struct PagesAddDomainForm: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dashTrayDismiss) private var dismiss
  let projectName: String
  let onAdded: () async -> Void
  @State private var hostname = ""
  @State private var actionPhase: DashActionPhase = .idle
  @State private var error: String?

  private var normalized: String {
    hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  var body: some View {
    DashFormSheet(
      saveTitle: "Add domain",
      actionPhase: actionPhase,
      onSuccessPresentationCompleted: completeSavePresentation,
      canSave: normalized.contains("."),
      onSave: { Task { await save() } },
      content: {
        VStack(alignment: .leading, spacing: 14) {
          DashFormField(
            label: "Hostname",
            text: $hostname,
            keyboard: .URL,
            contentType: .URL)
          if let error {
            DashNotice(kind: .error, message: error)
          }
        }
      }
    )
    .dashTrayDescription(
      DashL10n.string("Cloudflare validates DNS and issues a certificate for the hostname."))
  }

  private func save() async {
    guard let context = model.accountRequestContext else { return }
    let client = model.client
    let domain = normalized
    actionPhase = .loading
    error = nil
    do {
      try await client.addPagesDomain(
        accountID: context.accountID, projectName: projectName, name: domain)
      guard !Task.isCancelled, model.isCurrentAccount(context) else {
        actionPhase = .idle
        return
      }
      model.featureCache.remove(
        FeatureCacheKey.pagesDomains(accountID: context.accountID, name: projectName))
      model.toasts.success(DashL10n.string("Added successfully"))
      actionPhase = .succeeded
    } catch {
      actionPhase = .idle
      guard !error.dashIsCancellation, model.isCurrentAccount(context) else { return }
      self.error = error.dashActionableMessage
    }
  }

  private func completeSavePresentation() {
    guard actionPhase == .succeeded else {
      actionPhase = .idle
      return
    }
    actionPhase = .idle
    dismiss()
    Task { await onAdded() }
  }
}

private func pagesProjectAccessibilityLabel(_ project: PagesProject) -> String {
  if let subtitle = pagesProjectSubtitle(project) {
    return "\(project.name), \(subtitle)"
  }
  return project.name
}

private func pagesProjectSubtitle(_ project: PagesProject) -> String? {
  let status = project.latestDeployment?.latestStage?.status
  if let status {
    // The raw lowercase API token used to surface here ("Latest · success")
    // while the badge one screen in localized the same value.
    return DashL10n.string("Latest · \(StatusToken(pagesStatus: status).label)")
  }
  // API returns the full hostname (e.g. helloworld.pages.dev).
  return project.subdomain
}

/// Takes the row's already-computed strings: recomputing the subtitle here ran
/// the deployment's date formatting a second time for every row.
private func pagesDeploymentAccessibilityLabel(title: String, subtitle: String) -> String {
  "\(title), \(subtitle)"
}

private func pagesDeploymentTitle(_ deployment: PagesDeployment) -> String {
  if let message = deployment.commitMessage, !message.isEmpty {
    return message
  }
  if let branch = deployment.branch { return branch }
  return deployment.shortID ?? String(deployment.id.prefix(8))
}

/// Cloudflare names build stages in snake_case (`clone_repo`). Fold that into
/// one English source form so a single catalog key localizes it; unknown stage
/// names pass through `DashL10n.ui` unchanged.
private func pagesStageLabel(_ name: String?) -> String {
  guard let name, !name.isEmpty else { return DashL10n.string("Stage") }
  return name.replacingOccurrences(of: "_", with: " ").capitalized
}

/// A stage's own status vocabulary — `idle` here means “has not started”, not
/// the “In progress” `StatusToken` reads it as for a deployment's latest stage.
/// Same shape as `rdapStatusLabel`: keep Cloudflare's English token, capitalize
/// it into one catalog key, and localize at this last render step.
private func pagesStageStatusLabel(_ status: String?) -> String {
  guard let status, !status.isEmpty else { return "—" }
  return DashL10n.ui(status.replacingOccurrences(of: "_", with: " ").capitalized)
}

@MainActor
private func pagesDeploymentSubtitle(_ deployment: PagesDeployment) -> String {
  var parts: [String] = []
  if let environment = deployment.environment {
    parts.append(DashL10n.ui(environment.capitalized))
  }
  // Same token the badge above this line renders, so the two never disagree —
  // `statusLabel` is Cloudflare's raw wording and has no catalog entry.
  parts.append(
    StatusToken(
      pagesStatus: deployment.latestStage?.status,
      isSkipped: deployment.isSkipped == true
    ).label)
  if let created = deployment.createdOn {
    parts.append(pagesRelativeDate(created))
  }
  return parts.joined(separator: " · ")
}

/// Keep in sync with `WidgetColor.pagesStatus` in DashWidgets.swift.
private func pagesStatusColor(_ status: String?) -> Color {
  switch status?.lowercased() {
  case "success": DashTheme.brand
  case "failure", "canceled": DashTheme.danger
  case "active", "idle": DashTheme.accent
  default: DashTheme.iconMuted
  }
}

/// Formatters are expensive to build and this ran three times per deployment
/// row. Held on the main actor because the relative formatter is not `Sendable`.
@MainActor
private enum PagesDeploymentDateFormatting {
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

  /// Keyed by locale, not a bare `static let`: Settings → Language is in-app, and
  /// a formatter cached for the process lifetime would keep printing "3d ago"
  /// beside Chinese copy after the switch.
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

@MainActor
private func pagesRelativeDate(_ value: String) -> String {
  guard let date = PagesDeploymentDateFormatting.date(from: value) else {
    return value
  }
  return PagesDeploymentDateFormatting.relativeString(
    for: date,
    relativeTo: .now,
    locale: DashL10n.activeLocale)
}

/// Pure bucketing + accessibility copy for the deployment build-outcomes
/// donut, kept off the view so it is unit-testable (mirrors
/// `ZoneAnalyticsChartModel`).
enum PagesDeploymentChartModel {
  /// Semantic bucket ids — display labels resolve at render time.
  enum Outcome: String, CaseIterable {
    case success
    case inFlight = "in-flight"
    case failure
    case canceled
    case other
  }

  struct Bucket: Hashable, Identifiable {
    let outcome: Outcome
    let count: Int
    var id: String { outcome.rawValue }
  }

  static func outcome(forStatus status: String?, isSkipped: Bool = false) -> Outcome {
    switch status?.lowercased() {
    case "success":
      return .success
    case "failure", "failed":
      return .failure
    case "canceled", "cancelled", "skipped":
      return .canceled
    case "active", "idle", "building", "deploying", "queued", "initializing":
      return .inFlight
    case nil where isSkipped:
      return .canceled
    default:
      return .other
    }
  }

  /// Ordered success → in-flight → failure → canceled → other, with
  /// zero-count buckets dropped.
  static func buckets(_ deployments: [PagesDeployment]) -> [Bucket] {
    var counts: [Outcome: Int] = [:]
    for deployment in deployments {
      let bucket = outcome(
        forStatus: deployment.latestStage?.status,
        isSkipped: deployment.isSkipped == true)
      counts[bucket, default: 0] += 1
    }
    return Outcome.allCases.compactMap { outcome in
      guard let count = counts[outcome], count > 0 else { return nil }
      return Bucket(outcome: outcome, count: count)
    }
  }

  /// The current bucket, resolved against fresh data so a selection can safely
  /// survive a refresh while its outcome still exists.
  static func bucket(_ deployments: [PagesDeployment], withID bucketID: String?) -> Bucket? {
    guard let bucketID else { return nil }
    return buckets(deployments).first { $0.id == bucketID }
  }

  /// Deployments belonging to the selected build outcome. Missing or stale
  /// selections widen back to the complete list instead of showing an empty
  /// result.
  static func deployments(
    _ deployments: [PagesDeployment],
    in bucketID: String?
  ) -> [PagesDeployment] {
    guard let bucket = bucket(deployments, withID: bucketID) else { return deployments }
    return deployments.filter {
      outcome(
        forStatus: $0.latestStage?.status,
        isSkipped: $0.isSkipped == true
      ) == bucket.outcome
    }
  }

  static func label(for outcome: Outcome) -> String {
    switch outcome {
    case .success: DashL10n.string("Success")
    case .inFlight: DashL10n.string("In progress")
    case .failure: DashL10n.string("Failed")
    case .canceled: DashL10n.string("Canceled")
    case .other: DashL10n.string("Other")
    }
  }

  static func chartAccessibilitySummary(buckets: [Bucket]) -> String {
    let total = buckets.reduce(0) { $0 + $1.count }
    guard total > 0 else {
      return DashL10n.string("Deployment outcomes chart. No deployments.")
    }
    let parts = buckets.map { bucket in
      DashL10n.string("\(bucket.count.formatted()) \(label(for: bucket.outcome))")
    }
    let list = parts.formatted(
      .list(type: .and, width: .standard).locale(DashL10n.activeLocale))
    return DashL10n.string(
      "Deployment outcomes chart. \(total.formatted()) deployments: \(list)."
    )
  }
}

private enum PagesExternalURL {
  static let getStarted = URL(string: "https://developers.cloudflare.com/pages/get-started/")!
}
