import SwiftUI

/// The Watchtower tab: account traffic charts, the floated inbox of
/// Cloudflare's own notification deliveries, and the Cloudflare status panel
/// fixed at the foot of the scroll.
///
/// There is no Diagnostics section. Dash used to roll zones, tunnels, pools,
/// registrar, Pages, certificates and Health Checks into a client-side health
/// verdict, but Cloudflare publishes no account-wide diagnostics to base that
/// on — the severity was Dash's own invention. Cloudflare's notification
/// policies are the official channel for "something needs attention", and they
/// arrive through the inbox.
struct WatchtowerView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// The pager keeps every tab mounted, so defer the (analytics-heavy) load
  /// until this tab is actually shown. The badge is warmed separately by
  /// `MainTabView`, so nothing here is needed for cold-launch status.
  @Environment(\.dashTabActive) private var tabActive
  let customization: WatchtowerChartCustomizationState
  /// Changes when the shared leading header asks this screen to cancel. The
  /// screen keeps ownership of the staged exit so controls still animate out
  /// before the chart layout returns to its saved draft.
  let cancelRequest: Int
  let commitRequest: Int
  @Binding var editorInteractionsReady: Bool
  @State private var trafficState = WatchtowerTrafficState()
  @State private var statusState = CloudflareStatusState()
  @State private var dragVisual = WatchtowerMetricDragVisualState()
  @State private var editorControlsVisible = false
  @State private var editorTransitionGeneration = 0

  /// Re-keys the load task on both account and activation so the deferred load
  /// fires the moment the tab is first swiped or tapped into view.
  private struct LoadKey: Equatable {
    let context: AccountRequestContext?
    let active: Bool
  }

  var body: some View {
    @Bindable var trafficState = trafficState
    // The range tabs stay mounted for measurement but fade away while editing,
    // so their inset collapses in the same morph transaction instead of jumping
    // through a later preference update. Freshness + Edit live in the scrolling
    // chart section below and leave alongside them.
    DashPageChromeHost(isChromeVisible: !customization.isEditing) {
      if model.activeAccountID != nil {
        DashTextTabs(
          items: [("24h", AnalyticsRange.day), ("7d", .week), ("30d", .month)],
          selection: $trafficState.range
        )
      }
    } content: {
      content
    }
    .dashSectionEntrance()
    .dashCatalogScreen()
    .task(id: LoadKey(context: model.accountRequestContext, active: tabActive)) {
      guard tabActive else { return }
      await load()
    }
    .onChange(of: model.grantedScopes) {
      guard tabActive else { return }
      Task {
        await trafficState.load(model: model, force: true)
      }
    }
    .onChange(of: customization.isEditing) { _, isEditing in
      guard !isEditing else { return }
      editorInteractionsReady = false
      editorControlsVisible = false
    }
    .onChange(of: cancelRequest) {
      guard customization.isEditing else { return }
      cancelCustomization()
    }
    .onChange(of: commitRequest) {
      guard customization.isEditing else { return }
      commitCustomization()
    }
  }

  private var content: some View {
    ScrollView {
      LazyVStack(spacing: DashTheme.Spacing.section) {
        if model.activeAccountID == nil {
          accountUnavailableCard
            .dashSectionReveal()
        } else {
          chartsSection
            .dashSectionContentReveal()
        }

        // Cloudflare's own status page, fixed at the tab's foot. Not one of
        // the reorderable metric cards, so it hides with the rest of the
        // non-editing chrome while the layout editor is up. It needs no
        // account at all, which is why it sits outside the branch above.
        if !customization.isEditing {
          CloudflareStatusSection(state: statusState) {
            Task { await statusState.load(model: model, force: true) }
          }
          .dashSectionContentReveal()
          .transition(.opacity)
        }
      }
      .padding(.horizontal, DashTheme.Spacing.screen)
      // Same gap `DashFeatureList` leaves between fixed text tabs and content.
      .padding(.top, DashTheme.Spacing.section)
      .padding(.bottom, DashTheme.Spacing.scrollBottomInset)
    }
    .modifier(DashScrollEdgeEffectsHidden())
    .refreshable {
      guard !customization.isEditing else { return }
      await load(force: true)
    }
  }

  private var chartsSection: some View {
    VStack(alignment: .leading, spacing: DashTheme.Spacing.itemGap) {
      if !customization.isEditing {
        chartsHeader
          .transition(.opacity)
      }
      WatchtowerTrafficView(
        state: trafficState,
        customization: customization,
        dragVisual: dragVisual,
        isEditing: customization.isEditing,
        editorControlsVisible: editorControlsVisible,
        usesPlaceholderCharts: customization.isEditing
      )
    }
  }

  /// Freshness is the section title itself (clock + relative time). Cold loads
  /// paint a pulsing bar in that slot; a cold failure freezes it. Pull-to-
  /// refresh owns reloading, so the charts need neither a Refresh control nor
  /// an inline spinner. The timeline only re-reads the relative wording.
  private var chartsHeader: some View {
    TimelineView(.periodic(from: .now, by: 60)) { context in
      let freshness = WatchtowerAnalyticsChartModel.updatedBadge(
        fetchedAt: trafficState.fetchedAt,
        now: context.date)
      let coldFailed =
        trafficState.overview == nil && trafficState.currentError != nil
      let coldLoading =
        trafficState.overview == nil && trafficState.isLoadingCurrent
      let showsSkeleton = freshness == nil && (coldLoading || coldFailed)
      DashSectionHeader(
        freshness ?? "",
        icon: (freshness != nil || showsSkeleton) ? SolarAsset.Content.clock : nil,
        titleAccessibilityLabel: freshness.map(
          WatchtowerAnalyticsChartModel.updatedAccessibilityLabel),
        showsTitleSkeleton: showsSkeleton,
        titleIsMeta: true,
        actionIcon: SolarAsset.pen,
        actionLabel: DashL10n.string("Edit charts"),
        action: beginCustomization
      )
      .environment(\.dashSkeletonPulseActive, !coldFailed)
    }
  }

  /// The inbox loads its own deliveries; the tab owns the charts and the
  /// status panel. The status fetch is unauthenticated and independent, so it
  /// runs alongside the analytics load instead of queueing behind it.
  private func load(force: Bool = false) async {
    async let status: Void = statusState.load(model: model, force: force)
    await trafficState.load(model: model, force: force)
    await model.refreshWatchtowerAlerts(force: force)
    await status
  }

  private var accountUnavailableCard: some View {
    DashCard {
      Text("No Cloudflare account is available for this user.")
        .dashTextStyle(.supporting)
        .foregroundStyle(DashTheme.subtle)
    }
  }

  private func beginCustomization() {
    DashDelight.lightImpact()
    editorTransitionGeneration += 1
    let generation = editorTransitionGeneration
    editorInteractionsReady = false
    editorControlsVisible = false
    withAnimation(
      reduceMotion ? nil : DashTheme.Motion.morph,
      completionCriteria: .removed
    ) {
      customization.beginEditing()
    } completion: {
      Task { @MainActor in
        // The controls need a committed hidden frame after the editor morph.
        // Updating inside the completion transaction makes their transition
        // collapse into an immediate insertion.
        await Task.yield()
        guard
          generation == editorTransitionGeneration,
          customization.isEditing
        else { return }
        // Mount the drag bridge before the controls animate. Coupling both to
        // one state can spend the controls' entire entrance building UIKit
        // interactions, so their first painted frame is already fully visible.
        editorInteractionsReady = true
        await Task.yield()
        guard
          generation == editorTransitionGeneration,
          customization.isEditing
        else { return }
        withAnimation(
          reduceMotion ? DashTheme.Motion.reduced : DashTheme.Motion.content
        ) {
          editorControlsVisible = true
        }
      }
    }
  }

  private func cancelCustomization() {
    finishCustomization(commit: false)
  }

  private func commitCustomization() {
    finishCustomization(commit: true)
    DashDelight.selectionChanged()
  }

  private func finishCustomization(commit: Bool) {
    editorTransitionGeneration += 1
    let generation = editorTransitionGeneration

    // Finish the controls' own transition before changing the editor layout.
    // Without the explicit transaction, SwiftUI removes them in one frame;
    // changing both states together also lets the parent morph cut them off.
    withAnimation(
      reduceMotion ? DashTheme.Motion.reduced : DashTheme.Motion.morphExit
    ) {
      editorControlsVisible = false
    }

    Task { @MainActor in
      try? await Task.sleep(
        for: reduceMotion ? .milliseconds(120) : .milliseconds(240))
      guard
        generation == editorTransitionGeneration,
        customization.isEditing
      else { return }

      editorInteractionsReady = false
      await Task.yield()
      guard
        generation == editorTransitionGeneration,
        customization.isEditing
      else { return }

      withAnimation(reduceMotion ? nil : DashTheme.Motion.morphExit) {
        if commit {
          customization.commitEditing()
          ICloudPreferencesSync.shared.publish(.watchtowerLayout)
        } else {
          customization.cancelEditing()
        }
      }
    }
  }
}
