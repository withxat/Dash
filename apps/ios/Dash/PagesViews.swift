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
  @State private var searchQuery = ""

  private var isSearching: Bool {
    DashSearchMatcher.isActive(searchQuery)
  }

  private var filteredProjects: [PagesProject] {
    guard isSearching else { return projects }
    return projects.filter { project in
      DashSearchMatcher.matches(searchQuery, in: [project.name, project.subdomain ?? ""])
    }
  }

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      hasContent: !projects.isEmpty,
      empty: DashFeatureEmpty(
        icon: SolarAsset.Content.codeCircle,
        title: DashL10n.string("No Pages projects"),
        message: DashL10n.string(
          "Create one in the dashboard or with Wrangler."
        ),
        actionTitle: "Open Pages docs",
        action: { openURL(PagesExternalURL.getStarted) }
      ),
      retry: { Task { await load(force: true) } }
    ) { mode in
      if !mode.isPlaceholder {
        DashSearchBar(
          text: $searchQuery,
          prompt: DashL10n.string("Search Pages projects"),
          accessibilityIdentifier: "pages-projects-search-field"
        )
        .padding(.bottom, DashTheme.Spacing.itemGap)
      }
      if !mode.isPlaceholder, isSearching, filteredProjects.isEmpty {
        DashSearchEmptyState(query: searchQuery) {
          searchQuery = ""
        }
      } else {
        dashModeListRows(
          mode: mode,
          items: filteredProjects,
          reduceMotion: reduceMotion,
          inset: false,
          placeholder: { index in
            FeatureResourceCardFace(content: pagesResourceCardPlaceholder(index: index))
              .dashBodyPlaceholder(true)
              .dashItemBoundary(index > 0)
          }
        ) { project in
          let displayedProject =
            model.activeAccountID.flatMap {
              PagesResourceCardCache.latestProject(
                accountID: $0,
                projectName: project.name,
                fallback: project,
                cache: model.featureCache)
            } ?? project
          let content = pagesResourceCardContent(displayedProject)
          let hero = DashNavigationHero.featureResourceCard(
            accountID: model.activeAccountID ?? "",
            content: content)
          DashListGroupLink(value: .pagesProject(project.name), hero: hero) {
            FeatureResourceCardFace(content: content)
          }
          .accessibilityIdentifier("pages-project-\(project.name)")
          .dashItemBoundary(project.id != filteredProjects.first?.id)
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
  static let deploymentsPageSize = 25

  @Environment(AppModel.self) private var model
  @Environment(\.dashNavigationEntryHero) private var navigationEntryHero
  @Environment(\.dashPageTransitionActive) private var pageTransitionActive
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @AppStorage(RecentResources.key) private var recentsRaw = ""
  let projectName: String
  @State private var project: PagesProject?
  @State private var deployments: [PagesDeployment] = []
  @State private var deploymentsPageState = DashPageState()
  @State private var isLoadingMoreDeployments = false
  @State private var deploymentsGeneration = 0
  @State private var loading = true
  @State private var error: String?
  @State private var deploymentsError: String?
  @State private var selectedSliceID: String?
  @State private var environmentFilter: PagesDeploymentEnvironmentFilter = .all
  /// Exact project-list identity captured before the detail fetch. A card-led
  /// push can therefore hand off into the first destination frame without a
  /// placeholder or a second network request.
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
    .task(id: model.accountRequestContext) {
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
      pagesProjectResourceCard(mode: mode)

      // Same frame as Email Routing's "Destination addresses → Manage
      // addresses": the band names the subject, the row is the door. It was a
      // bare row on the canvas — the one unframed thing on the screen.
      DashTwoToneListGroup(title: "Domains") {
        DashListGroupLink(value: .pagesDomains(projectName)) {
          DashListRow(
            title: DashL10n.string("Custom domains"),
            icon: SolarAsset.globe,
            showsIconPlate: false
          )
          .accessibilityLabel(DashL10n.string("Domains, Custom domains for this project"))
        }
      }
      .dashBodyPlaceholder(mode.isPlaceholder)
      .dashBodySlot(reduceMotion: reduceMotion)

      DashTwoToneListGroup(title: "Configuration") {
        DashListGroupLink(value: .pagesConfiguration(projectName)) {
          DashListRow(
            title: DashL10n.string("Settings & variables"),
            icon: SolarAsset.slider,
            showsIconPlate: false
          )
          .accessibilityLabel(
            DashL10n.string("Configuration, Settings and environment variables"))
        }
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

    if !mode.isPlaceholder, hasMultipleEnvironments {
      DashTextTabs(
        items: PagesDeploymentEnvironmentFilter.allCases.map { ($0.title, $0) },
        selection: $environmentFilter.animation(DashTheme.Motion.morph)
      )
      .dashSectionBoundary()
      .padding(.bottom, DashTheme.Spacing.itemGap)
      .dashBodySlot(reduceMotion: reduceMotion)
    }

    // Keep the unbounded deployment ForEach as a direct child of
    // DashFeatureList's LazyVStack. DashListGroup's eager inner VStack would
    // otherwise mount every deployment row at once.
    DashListGroupHeader(title: DashL10n.ui("Deployments"))
      .dashTwoToneHeaderBand()
      .dashSectionBoundary(mode.isPlaceholder || !hasMultipleEnvironments)
    if mode.isPlaceholder || !visibleDeployments.isEmpty {
      dashModeListRows(
        mode: mode,
        items: visibleDeployments,
        placeholderRows: 3,
        reduceMotion: reduceMotion,
        frame: .twoTone
      ) { deployment in
        let title = pagesDeploymentTitle(deployment)
        let subtitle = pagesDeploymentSubtitle(deployment)
        let statusToken = StatusToken(
          pagesStatus: deployment.latestStage?.status,
          isSkipped: deployment.isSkipped == true)
        DashListGroupLink(
          value: .pagesDeployment(project: projectName, deploymentID: deployment.id)
        ) {
          DashListRow(
            title: title,
            subtitle: subtitle,
            icon: SolarAsset.Content.codeCircle,
            iconColor: pagesStatusColor(deployment.latestStage?.status),
            showsChevron: true
          ) {
            StatusBadge(statusToken)
          }
          .accessibilityLabel(
            pagesDeploymentAccessibilityLabel(
              title: title, status: statusToken.label, subtitle: subtitle)
          )
        }
        .transition(morphTransition)
      }
      if !mode.isPlaceholder, deploymentsPageState.canLoadMore || isLoadingMoreDeployments {
        if selectedSliceID != nil {
          Group {
            if isLoadingMoreDeployments {
              DashLoadingRing(color: DashTheme.brand, size: 16, lineWidth: 2.5)
                .accessibilityLabel("Loading")
            } else {
              DashSecondaryPillButton(title: DashL10n.string("Load more")) {
                Task { await loadMoreDeployments() }
              }
            }
          }
          .frame(maxWidth: .infinity)
          .dashSectionBoundary()
        } else {
          DashInfiniteScrollFooter(
            loaded: deployments.count,
            isLoading: isLoadingMoreDeployments
          ) {
            guard error == nil else { return }
            Task { await loadMoreDeployments() }
          }
        }
      }
    } else {
      // The group's one slice: its settled-empty answer or its failure.
      Group {
        if deploymentsError != nil {
          // A failed deployments fetch keeps the rows' shape on the ground
          // and veils the message over it — swapping in a bare notice was
          // the section popping out of its own frame.
          DashSectionListRowPlaceholders(rows: 3)
            .dashSectionFailure(
              deploymentsError,
              retry: { Task { await load(force: true) } })
        } else if !deployments.isEmpty {
          Text("No deployments match this filter.")
            .dashTwoToneNote()
        } else {
          Text("No deployments yet.")
            .dashTwoToneNote()
        }
      }
      .dashTwoToneRowSlice()
      .dashBodySlot(reduceMotion: reduceMotion)
    }
  }

  private func pagesProjectResourceCard(mode: DashBodyMode) -> some View {
    let latestContent = model.activeAccountID.flatMap {
      PagesResourceCardCache.latestContent(
        accountID: $0,
        projectName: projectName,
        fallback: project,
        cache: model.featureCache)
    }
    // The immutable push hero owns the arriving frame. Once the handoff has
    // settled, the detail and underlying catalog converge on the same newest
    // list/detail cache snapshot; Back resolves its proxy through that rule too.
    let fallback = FeatureResourceCardContent(
      kind: .pages,
      resourceID: projectName,
      routeKey: projectName,
      title: projectName,
      metadata: .pages(subdomain: "project.pages.dev", deploymentStatus: nil))
    let content = FeatureResourceCardLandingRules.content(
      transitionActive: pageTransitionActive,
      captured: capturedPagesCardContent,
      latest: latestContent,
      fallback: fallback)
    return FeatureResourceCardFace(content: content)
      .dashBodyPlaceholder(
        mode.isPlaceholder && latestContent == nil && capturedPagesCardContent == nil
      )
      .dashNavigationLanding(.pagesProjectHero(projectName))
      .frame(maxWidth: .infinity)
      .dashBodySlot(reduceMotion: reduceMotion)
  }

  private var capturedPagesCardContent: FeatureResourceCardContent? {
    guard case .featureResourceCard(_, let content) = navigationEntryHero,
      content.kind == .pages,
      content.routeKey == projectName
    else { return nil }
    return content
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

  private var hasMultipleEnvironments: Bool {
    let envs = Set(deployments.compactMap { $0.environment?.lowercased() })
    return envs.contains("production") && envs.contains("preview")
  }

  private var visibleDeployments: [PagesDeployment] {
    let byOutcome = PagesDeploymentChartModel.deployments(deployments, in: selectedSliceID)
    return environmentFilter.filter(byOutcome)
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
    guard let context = model.accountRequestContext else {
      loading = false
      return
    }
    let accountID = context.accountID
    if !hasPresentedContent || force { loading = true }
    error = nil
    let projectKey = FeatureCacheKey.pagesProject(accountID: accountID, name: projectName)
    if !force, let cached: PagesProject = model.featureCache.get(projectKey) {
      project = cached
    } else {
      do {
        let fetched = try await model.client.getPagesProject(
          accountID: accountID, projectName: projectName)
        guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
        project = fetched
        model.featureCache.set(projectKey, fetched)
      } catch {
        // Cold: the veil over the skeleton. Warm: the inline banner over the
        // kept project — a pull-to-refresh that fails must say so.
        if !error.dashIsCancellation, model.isCurrentAccount(context) {
          self.error = error.dashActionableMessage
        }
      }
    }

    let deployKey = FeatureCacheKey.pagesDeployments(accountID: accountID, name: projectName)
    if !force, let cached: [PagesDeployment] = model.featureCache.get(deployKey) {
      deployments = cached
      deploymentsError = nil
      // Keep cached deployments painted while page one refreshes below so
      // `deploymentsPageState` stays authoritative.
    }
    deploymentsGeneration += 1
    let generation = deploymentsGeneration
    isLoadingMoreDeployments = false
    deploymentsPageState.reset()
    do {
      let page = try await model.client.listPagesDeployments(
        accountID: accountID, projectName: projectName, page: 1,
        perPage: Self.deploymentsPageSize)
      guard !Task.isCancelled, generation == deploymentsGeneration,
        model.isCurrentAccount(context)
      else { return }
      deployments = page.items
      deploymentsPageState.absorb(
        info: page.resultInfo,
        requestedPage: 1,
        received: page.items.count,
        added: page.items.count,
        loaded: deployments.count,
        pageSize: Self.deploymentsPageSize)
      deploymentsError = nil
      model.featureCache.set(deployKey, deployments)
    } catch {
      if !error.dashIsCancellation, generation == deploymentsGeneration,
        model.isCurrentAccount(context)
      {
        deploymentsError = error.dashActionableMessage
        // With rows on screen the section keeps them; the shared warm
        // banner is the only surface that can carry the refresh failure.
        if !deployments.isEmpty, self.error == nil {
          self.error = error.dashActionableMessage
        }
      }
    }
    guard model.isCurrentAccount(context) else { return }
    loading = false
    if project != nil || error == nil {
      hasPresentedContent = true
    }
  }

  private func loadMoreDeployments() async {
    guard
      let context = model.accountRequestContext,
      !isLoadingMoreDeployments,
      deploymentsPageState.canLoadMore
    else { return }
    let generation = deploymentsGeneration
    let pageNumber = deploymentsPageState.nextPage
    isLoadingMoreDeployments = true
    defer {
      if generation == deploymentsGeneration, model.isCurrentAccount(context) {
        isLoadingMoreDeployments = false
      }
    }
    do {
      let page = try await model.client.listPagesDeployments(
        accountID: context.accountID,
        projectName: projectName,
        page: pageNumber,
        perPage: Self.deploymentsPageSize)
      guard !Task.isCancelled, generation == deploymentsGeneration,
        model.isCurrentAccount(context)
      else { return }
      var seenIDs = Set(deployments.map(\.id))
      let unique = page.items.filter { seenIDs.insert($0.id).inserted }
      deployments += unique
      deploymentsPageState.absorb(
        info: page.resultInfo,
        requestedPage: pageNumber,
        received: page.items.count,
        added: unique.count,
        loaded: deployments.count,
        pageSize: Self.deploymentsPageSize)
      model.featureCache.set(
        FeatureCacheKey.pagesDeployments(accountID: context.accountID, name: projectName),
        deployments)
      deploymentsError = nil
      error = nil
    } catch {
      guard !error.dashIsCancellation, generation == deploymentsGeneration,
        model.isCurrentAccount(context)
      else { return }
      self.error = error.dashActionableMessage
    }
  }
}

enum PagesDeploymentEnvironmentFilter: String, CaseIterable, Hashable, Sendable {
  case all
  case production
  case preview

  var title: String {
    switch self {
    case .all: DashL10n.string("All")
    case .production: DashL10n.string("Production")
    case .preview: DashL10n.string("Preview")
    }
  }

  func filter(_ deployments: [PagesDeployment]) -> [PagesDeployment] {
    switch self {
    case .all: deployments
    case .production: deployments.filter { $0.environment?.lowercased() == "production" }
    case .preview: deployments.filter { $0.environment?.lowercased() == "preview" }
    }
  }
}

struct PagesDeploymentDetailView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.destinationNavigator) private var navigator
  @Environment(\.dashNavigationEntryID) private var navigationEntryID
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
  @State private var deletePhase: DashActionPhase = .idle
  @State private var confirmingRollback = false
  @State private var confirmingDelete = false
  @State private var hasPresentedContent = false
  @State private var replacementDeploymentID: String?
  @State private var hasRequestedLogs = false
  @State private var observedKey: PagesBuildMonitorKey?

  private var monitoredDeploymentID: String {
    replacementDeploymentID ?? deploymentID
  }

  private var working: Bool {
    retryPhase.isActive || rollbackPhase.isActive || deletePhase.isActive
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

  /// Fuller first-paint reserve: Deployment + Source + Stages. Build
  /// configuration is not reserved — a direct upload has none, and a section
  /// that is taken back is worse than one that arrives. Actions and the build
  /// log stay live-only (log is section-cold after the deployment lands).
  @ViewBuilder
  private func pagesDeploymentDetailBody(mode: DashBodyMode) -> some View {
    if mode.isPlaceholder {
      DashInfoGroup(title: "Deployment", phase: .loading, placeholderRows: 6) {
        EmptyView()
      }
      .dashBodySlot(reduceMotion: reduceMotion)
      DashInfoGroup(title: "Source", phase: .loading, placeholderRows: 3) {
        EmptyView()
      }
      .dashSectionBoundary()
      .dashBodySlot(reduceMotion: reduceMotion)
      DashInfoGroup(title: "Stages", phase: .loading, placeholderRows: 3) {
        EmptyView()
      }
      .dashSectionBoundary()
      .dashBodySlot(reduceMotion: reduceMotion)
    } else if let deployment {
      deploymentGroup(deployment)
        .dashBodySlot(reduceMotion: reduceMotion)
      sourceGroup(deployment)
      stagesGroup(deployment)
      buildConfigurationGroup(deployment)
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
      // The exact time, not "2h ago": the deployments list already carries the
      // relative one, and this is the screen a "when did this ship" question
      // lands on.
      if let created = deployment.createdOn {
        DashInfoRow("Created", value: DashDateFormatting.dateAndTime(fromISO8601: created))
      }
      if let duration = deployment.buildDuration.flatMap({ pagesDurationText($0) }) {
        DashInfoRow("Duration", value: duration)
      }
      if let urlString = deployment.url, let link = URL(string: urlString) {
        DashInfoRow("URL") { pagesLinkValue(urlString, destination: link) }
      }
      // Branch and custom-domain aliases this deployment also answers on.
      // Bounded: a deployment carries a branch alias and its custom domains.
      ForEach(pagesAliases(deployment), id: \.self) { alias in
        if let link = URL(string: alias) {
          DashInfoRow("Alias") { pagesLinkValue(alias, destination: link) }
        }
      }
      deploymentIDRow(deployment)
    }
  }

  /// The id is what the API, Wrangler, and a support ticket all ask for, and a
  /// 36-character UUID is not something to retype — the row copies it.
  private func deploymentIDRow(_ deployment: PagesDeployment) -> some View {
    Button {
      copyDeploymentID(deployment.id)
    } label: {
      DashInfoRow("Deployment ID", value: deployment.id, mono: true)
    }
    .buttonStyle(DashSurfaceButtonStyle())
    .accessibilityLabel(DashL10n.string("Deployment ID, \(deployment.id)"))
    .accessibilityAction(named: DashL10n.string("Copy deployment ID")) {
      copyDeploymentID(deployment.id)
    }
  }

  private func copyDeploymentID(_ id: String) {
    UIPasteboard.general.string = id
    model.toasts.success(DashL10n.string("Deployment ID copied"))
  }

  /// What was deployed and what started it. Hidden when Cloudflare sent none of
  /// it, rather than shown as a group of dashes.
  @ViewBuilder
  private func sourceGroup(_ deployment: PagesDeployment) -> some View {
    let kind = deployment.deploymentTrigger?.kind
    let branch = deployment.branch.flatMap { $0.isEmpty ? nil : $0 }
    let commit = deployment.shortCommit
    if kind != nil || deployment.repository != nil || branch != nil || commit != nil {
      DashInfoGroup(title: "Source") {
        if let kind {
          DashInfoRow("Trigger", value: pagesTriggerLabel(kind))
        }
        if let repository = deployment.repository {
          DashInfoRow("Repository", value: repository)
        }
        if let branch {
          DashInfoRow("Branch", value: branch, mono: true)
        }
        if let commit {
          if let link = deployment.commitURL {
            DashInfoRow("Commit") { pagesLinkValue(commit, destination: link) }
          } else {
            DashInfoRow("Commit", value: commit, mono: true)
          }
        }
      }
      .dashSectionBoundary()
      .dashBodySlot(reduceMotion: reduceMotion)
    }
  }

  /// The settings this deployment was built with — which can differ from the
  /// project's current ones, and is the first thing to check when a build that
  /// used to pass stops. A direct upload builds nothing and has no group.
  @ViewBuilder
  private func buildConfigurationGroup(_ deployment: PagesDeployment) -> some View {
    if let config = deployment.buildConfig,
      config.buildCommand != nil || config.destinationDirectory != nil
        || config.rootDirectory != nil
    {
      DashInfoGroup(title: "Build configuration") {
        if let command = config.buildCommand {
          DashInfoRow("Build command", value: command, mono: true)
        }
        if let directory = config.destinationDirectory {
          DashInfoRow("Output directory", value: directory, mono: true)
        }
        if let directory = config.rootDirectory {
          DashInfoRow("Root directory", value: directory, mono: true)
        }
        if let caching = config.buildCaching {
          DashInfoRow(
            "Build cache",
            value: caching ? DashL10n.string("Enabled") : DashL10n.string("Disabled"))
        }
      }
      .dashSectionBoundary()
      .dashBodySlot(reduceMotion: reduceMotion)
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
        DashTimelineRows(
          steps: stages.enumerated().map { index, stage in
            pagesTimelineStep(stage, index: index)
          })
      }
      .dashSectionBoundary()
      .dashBodySlot(reduceMotion: reduceMotion)
    }
  }

  private func isActiveCanonicalDeployment(_ deployment: PagesDeployment) -> Bool {
    guard let accountID = model.activeAccountID else { return false }
    guard
      let project: PagesProject = model.featureCache.get(
        FeatureCacheKey.pagesProject(accountID: accountID, name: projectName))
    else { return false }
    return project.canonicalDeployment?.id == deployment.id
  }

  @ViewBuilder
  private func actions(for deployment: PagesDeployment) -> some View {
    if featureAllowsWrites {
      DashTwoToneListGroup(title: "Actions") {
        // Pills, not rows: retry and rollback are the screen's two commits,
        // and a submit stays a pill wherever it sits. The group's inner card
        // replaces the grey `DashCard` they used to sit in.
        Group {
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
                  confirmingDelete = false
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

            if !isActiveCanonicalDeployment(deployment) {
              DashActionButton(
                title: confirmingDelete ? "Confirm delete" : "Delete deployment",
                role: .destructive,
                phase: deletePhase,
                onSuccessPresentationCompleted: completeDeletePresentation
              ) {
                if confirmingDelete {
                  Task { await deleteDeployment() }
                } else {
                  confirmingRollback = false
                  confirmingDelete = true
                }
              }
              .disabled(working)
              if confirmingDelete {
                Button("Cancel") { confirmingDelete = false }
                  .dashTextStyle(.buttonMedium)
                  .foregroundStyle(DashTheme.subtle)
              }
            }
          }
        }
        .padding(.vertical, DashTheme.Spacing.comfortable)
      }
    }
  }

  /// Same two-tone frame as the fields above it and as the Worker build log,
  /// with Copy on the header band. It used to be a recessed `DashCard` under a
  /// bandless title — a third frame on a screen whose every other section is
  /// an info group.
  @ViewBuilder private var logsSection: some View {
    let hasLines = logs?.data.isEmpty == false
    // One stack, so the call site's section boundary lands once — on the
    // group — and not again on the notice under it.
    VStack(alignment: .leading, spacing: 0) {
      DashTwoToneListGroup(
        title: "Build log",
        actionTitle: hasLines ? "Copy" : nil,
        action: hasLines ? { copyLogs() } : nil
      ) {
        if let logs {
          DashFadedScrollView(
            surface: DashTheme.homeCardSurface,
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
            .padding(.vertical, 12)
          }
          .dashBodySlot(reduceMotion: reduceMotion)
        } else {
          // The log's own shape holds the section while it loads, and a
          // failure veils over the same lines — never a bare notice.
          DashLogPlaceholder()
            .padding(.vertical, 14)
            .dashSectionFailure(logsError, retry: retryLogs)
            .dashBodySlot(reduceMotion: reduceMotion)
        }
      }
      if logs != nil, let logsError {
        // Warm: the monitor's forced refresh failed mid-build — keep the
        // visible log and say so beside it instead of tearing it down.
        DashNotice(kind: .warning, message: logsError)
          .dashItemBoundary()
      }
    }
  }

  private func copyLogs() {
    guard let logs, !logs.data.isEmpty else { return }
    UIPasteboard.general.string = logs.data.map(\.line).joined(separator: "\n")
    model.toasts.success(DashL10n.string("Build log copied"))
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
      presentLogs(fetched)
    } catch {
      guard !Task.isCancelled, !error.dashIsCancellation, model.isCurrentAccount(context),
        monitorKey == key
      else {
        return
      }
      logsError = error.dashActionableMessage
    }
  }

  private func presentLogs(_ fetched: PagesDeploymentLogs) {
    if reduceMotion {
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        logs = fetched
        logsError = nil
      }
    } else {
      withAnimation(DashBodyTransition.handoff) {
        logs = fetched
        logsError = nil
      }
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

  private func deleteDeployment() async {
    guard let key = monitorKey else { return }
    let context = AccountRequestContext(
      accountID: key.accountID,
      generation: key.accountGeneration)
    deletePhase = .loading
    actionError = nil
    do {
      try await model.client.deletePagesDeployment(
        accountID: key.accountID,
        projectName: key.projectName,
        deploymentID: key.deploymentID,
        force: true)
      guard !Task.isCancelled, model.isCurrentAccount(context), monitorKey == key else {
        deletePhase = .idle
        return
      }
      model.featureCache.remove(
        FeatureCacheKey.pagesDeployments(accountID: key.accountID, name: projectName))
      model.featureCache.remove(
        FeatureCacheKey.pagesProject(accountID: key.accountID, name: projectName))
      model.toasts.success(DashL10n.string("Deployment deleted"))
      deletePhase = .succeeded
    } catch {
      deletePhase = .idle
      guard !error.dashIsCancellation, model.isCurrentAccount(context), monitorKey == key else {
        return
      }
      actionError = error.dashActionableMessage
      DashDelight.failError()
    }
  }

  private func completeDeletePresentation() {
    guard deletePhase == .succeeded else {
      deletePhase = .idle
      return
    }
    deletePhase = .idle
    confirmingDelete = false
    guard let navigationEntryID else { return }
    navigator?.dismiss(entryID: navigationEntryID)
  }
}

struct PagesDomainsView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.openURL) private var openURL
  @Environment(\.featureAllowsWrites) private var featureAllowsWrites
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let projectName: String
  @State private var domains: [PagesDomain] = []
  @State private var zoneNamesByID: [String: String] = [:]
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
          fields: pagesDomainFields(domain),
          deleteMessage: featureAllowsWrites
            ? DashL10n.string("Detach \(domain.name) from \(projectName).")
            : nil,
          deletePhase: deletePhase,
          onDeleteSuccessPresentationCompleted: completeDeletePresentation,
          deleteError: deleteError,
          onDelete: featureAllowsWrites ? { Task { await remove(domain) } } : nil
        ) {
          VStack(spacing: 10) {
            if let url = URL(string: "https://\(domain.name)") {
              DashTrayPillButton(title: "Open in Safari") {
                openURL(url)
              }
            }
            DashActionButton(title: "Copy hostname") {
              UIPasteboard.general.string = domain.name
              DashDelight.lightImpact()
              model.toasts.success(DashL10n.string("Hostname copied"))
            }
          }
        }
      }
    )
  }

  private func pagesDomainFields(_ domain: PagesDomain) -> [DashDetailField] {
    var fields = [
      DashDetailField(label: "Hostname", value: domain.name),
      DashDetailField(
        label: "Status",
        value: DashL10n.ui((domain.status ?? "unknown").capitalized)),
    ]
    if let zoneTag = domain.zoneTag, !zoneTag.isEmpty {
      if let zoneName = zoneNamesByID[zoneTag] {
        fields.append(DashDetailField(label: "Zone", value: zoneName))
      } else {
        fields.append(DashDetailField(label: "Zone", value: zoneTag, mono: true))
      }
    }
    if let createdOn = domain.createdOn, !createdOn.isEmpty {
      fields.append(
        DashDetailField(
          label: "Added",
          value: DashDateFormatting.dateAndTime(fromISO8601: createdOn)))
    }
    return fields
  }

  private func load(force: Bool = false) async {
    guard let context = model.accountRequestContext else { return }
    let accountID = context.accountID
    seedZoneNamesFromCache(accountID: accountID)
    let key = FeatureCacheKey.pagesDomains(accountID: accountID, name: projectName)
    if !force, let cached: [PagesDomain] = model.featureCache.get(key) {
      domains = cached
      loading = false
      error = nil
      await resolveMissingZoneNames(for: cached, context: context)
      return
    }
    if domains.isEmpty { loading = true }
    do {
      domains = try await model.client.listPagesDomains(
        accountID: accountID, projectName: projectName)
      guard model.isCurrentAccount(context) else { return }
      model.featureCache.set(key, domains)
      error = nil
      loading = false
      await resolveMissingZoneNames(for: domains, context: context)
    } catch {
      guard model.isCurrentAccount(context) else { return }
      self.error = error.dashActionableMessage
      loading = false
    }
  }

  private func seedZoneNamesFromCache(accountID: String) {
    let zonesKey = FeatureCacheKey.zones(accountID)
    let cachedZones: [CloudflareZone] =
      model.featureCache.get(zonesKey)
      ?? model.featureCache.getStale(zonesKey)
      ?? []
    for zone in cachedZones {
      zoneNamesByID[zone.id] = zone.name
    }
  }

  /// Best-effort lookup turning raw 32-hex `zone_tag` values into readable
  /// domain names. A missing `zone.read` scope never surfaces an error here.
  private func resolveMissingZoneNames(
    for domains: [PagesDomain],
    context: AccountRequestContext
  ) async {
    let missingTags = Set(
      domains.compactMap(\.zoneTag).filter { !$0.isEmpty && zoneNamesByID[$0] == nil })
    guard !missingTags.isEmpty else { return }
    guard
      let page = try? await model.client.listZones(
        accountID: context.accountID, page: 1, perPage: 50)
    else { return }
    guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
    for zone in page.items {
      zoneNamesByID[zone.id] = zone.name
    }
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

func pagesResourceCardContent(_ project: PagesProject) -> FeatureResourceCardContent {
  FeatureResourceCardContent(
    kind: .pages,
    resourceID: project.id,
    routeKey: project.name,
    title: project.name,
    metadata: .pages(
      subdomain: project.subdomain,
      deploymentStatus: project.latestDeployment?.latestStage?.status))
}

/// One freshness rule for the Pages list card, detail landing, and return
/// proxy. A newer account-wide list refresh beats a stale detail snapshot; a
/// detail fetch made after that list beats it in turn.
enum PagesResourceCardCache {
  @MainActor
  static func latestProject(
    accountID: String,
    projectName: String,
    fallback: PagesProject? = nil,
    cache: FeatureDataCache
  ) -> PagesProject? {
    let list: (value: [PagesProject], fetchedAt: Date)? =
      cache.getWithFetchedAt(FeatureCacheKey.pagesProjects(accountID))
    let listProject = list?.value.first { $0.name == projectName }
    let detail: (value: PagesProject, fetchedAt: Date)? =
      cache.getWithFetchedAt(
        FeatureCacheKey.pagesProject(accountID: accountID, name: projectName))

    if let detail, detail.fetchedAt >= (list?.fetchedAt ?? .distantPast) {
      return detail.value
    }
    return listProject ?? detail?.value ?? fallback
  }

  @MainActor
  static func latestContent(
    accountID: String,
    projectName: String,
    fallback: PagesProject? = nil,
    cache: FeatureDataCache
  ) -> FeatureResourceCardContent? {
    latestProject(
      accountID: accountID,
      projectName: projectName,
      fallback: fallback,
      cache: cache
    ).map(pagesResourceCardContent)
  }
}

private func pagesResourceCardPlaceholder(index: Int) -> FeatureResourceCardContent {
  FeatureResourceCardContent(
    kind: .pages,
    resourceID: "dash.placeholder.pages.\(index)",
    routeKey: "dash.placeholder.pages.\(index)",
    title: "pages-project",
    metadata: .pages(subdomain: "project.pages.dev", deploymentStatus: "success"))
}

/// Takes the row's already-computed strings: recomputing the subtitle here ran
/// the deployment's date formatting a second time for every row.
private func pagesDeploymentAccessibilityLabel(
  title: String, status: String, subtitle: String
) -> String {
  subtitle.isEmpty ? "\(title), \(status)" : "\(title), \(status), \(subtitle)"
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

/// One stage as a rail step — the same component the Worker build screen draws
/// its lifecycle with, so the two build screens read as one product.
///
/// The node carries the status and the trailing seat the duration. A status
/// the rail has no node for keeps Cloudflare's own word in that seat instead:
/// a hollow node alone would report "not started" about a stage whose state
/// Dash simply does not model.
@MainActor
private func pagesTimelineStep(_ stage: PagesDeploymentStage, index: Int) -> DashTimelineStep {
  let classification = PagesDeploymentStatusClassification.classify(stage.status)
  let tone: DashTimelineStep.Tone =
    switch classification {
    case .success: .done
    case .failure: .failed
    case .cancelled: .stopped
    case .active: .active
    case .idle, .unknown: .pending
    }
  let statusLabel = pagesStageStatusLabel(stage.status)
  let duration = stage.duration.flatMap { pagesDurationText($0) }
  return DashTimelineStep(
    id: "\(index)",
    title: pagesStageLabel(stage.name),
    caption: stage.startedDate.map { DashDateFormatting.timeWithSeconds($0) },
    duration: duration ?? (classification == .unknown ? statusLabel : nil),
    runningSince: tone == .active ? stage.startedDate : nil,
    tone: tone,
    stateLabel: statusLabel)
}

@MainActor
private func pagesDurationText(_ seconds: TimeInterval) -> String? {
  DashDateFormatting.durationText(seconds)
}

private func pagesTriggerLabel(_ kind: PagesDeploymentTrigger.Kind) -> String {
  switch kind {
  case .gitPush: DashL10n.string("Git push")
  case .manual: DashL10n.string("Manual")
  case .deployHook: DashL10n.string("Deploy hook")
  // A trigger Cloudflare added after this build: show its own word rather than
  // hide the row.
  case .other(let raw): DashL10n.ui(raw.replacingOccurrences(of: "_", with: " ").capitalized)
  }
}

/// Aliases other than the deployment's own URL, capped so the info group stays
/// bounded.
private func pagesAliases(_ deployment: PagesDeployment) -> [String] {
  var seen: Set<String> = [deployment.url ?? ""]
  return Array(
    (deployment.aliases ?? []).filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(3))
}

/// A tappable value in an info row's trailing slot — the deployment URL, an
/// alias, the commit on its Git host.
@MainActor
private func pagesLinkValue(_ title: String, destination: URL) -> some View {
  Link(title, destination: destination)
    .dashTextStyle(.code)
    .foregroundStyle(DashTheme.brand)
    .multilineTextAlignment(.trailing)
    .lineLimit(2)
}

@MainActor
private func pagesDeploymentSubtitle(_ deployment: PagesDeployment) -> String {
  var parts: [String] = []
  if let environment = deployment.environment {
    parts.append(DashL10n.ui(environment.capitalized))
  }
  if let created = deployment.createdOn {
    parts.append(pagesRelativeDate(created))
  }
  return parts.joined(separator: " · ")
}

private func pagesStatusColor(_ status: String?) -> Color {
  switch PagesDeploymentStatusClassification.classify(status) {
  case .success: DashTheme.success
  case .failure, .cancelled: DashTheme.danger
  case .active, .idle: DashTheme.warning
  case .unknown: DashTheme.iconMuted
  }
}

@MainActor
private func pagesRelativeDate(_ value: String) -> String {
  guard let date = DashDateFormatting.date(fromISO8601: value) else {
    return value
  }
  return DashDateFormatting.abbreviatedRelativeTime(
    date,
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
    switch PagesDeploymentStatusClassification.classify(status) {
    case .success:
      return .success
    case .failure:
      return .failure
    case .cancelled:
      return .canceled
    case .active, .idle:
      return .inFlight
    case .unknown:
      return isSkipped ? .canceled : .other
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
