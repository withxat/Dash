import SwiftUI

/// The Watchtower tab: account traffic charts, plus the floated inbox of
/// Cloudflare's own notification deliveries.
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
  @State private var trafficState = WatchtowerTrafficState()
  @State private var dragVisual = WatchtowerMetricDragVisualState()
  @State private var editorInteractionsReady = false
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
    // Freshness + range tabs sit in `DashPageChromeHost` above the header
    // frost (same stacking as the nav bar). Inside the scroll they would sit
    // in the blur tail and go soft.
    DashPageChromeHost {
      if model.activeAccountID != nil, !customization.isEditing {
        VStack(alignment: .leading, spacing: DashTheme.Spacing.itemGap) {
          chartsHeader
          DashTextTabs(
            items: [("24h", AnalyticsRange.day), ("7d", .week), ("30d", .month)],
            selection: $trafficState.range
          )
        }
        .transition(.opacity)
      }
    } content: {
      content
    }
    .dashSectionEntrance()
    .dashCatalogScreen()
    .toolbar {
      if customization.isEditing {
        ToolbarItem(placement: .topBarLeading) {
          DashToolbarIconButton(
            asset: SolarAsset.editClose,
            accessibilityLabel: "Cancel",
            action: cancelCustomization
          )
          .accessibilityIdentifier("watchtower-customize-cancel")
        }
        .dashSeparateToolbarBackground()
        ToolbarItem(placement: .topBarTrailing) {
          DashToolbarActionGroup {
            addChartMenu
            DashToolbarIconButton(
              asset: SolarAsset.unread,
              accessibilityLabel: "Done",
              variant: .confirmation,
              action: commitCustomization
            )
            .accessibilityIdentifier("watchtower-customize-done")
          }
        }
        .dashSeparateToolbarBackground()
      }
    }
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
  }

  private var content: some View {
    ScrollView {
      LazyVStack(spacing: DashTheme.Spacing.section) {
        if model.activeAccountID == nil {
          accountUnavailableCard
            .dashSectionReveal()
        } else {
          WatchtowerTrafficView(
            state: trafficState,
            customization: customization,
            dragVisual: dragVisual,
            isEditing: customization.isEditing,
            editorControlsVisible: editorControlsVisible,
            usesPlaceholderCharts: customization.isEditing
          )
          .dashSectionContentReveal()
        }
      }
      .padding(.horizontal, DashTheme.Spacing.screen)
      // Match the old in-scroll gap between range tabs and the first chart.
      .padding(.top, DashTheme.Spacing.section)
      .padding(.bottom, DashTheme.Spacing.scrollBottomInset)
    }
    .modifier(DashScrollEdgeEffectsHidden())
    .refreshable {
      guard !customization.isEditing else { return }
      await load(force: true)
    }
  }

  /// Freshness is the section title itself (clock + relative time). Pull-to-
  /// refresh owns reloading, so the charts need neither a Refresh control nor
  /// an inline spinner. The timeline only re-reads the relative wording.
  private var chartsHeader: some View {
    TimelineView(.periodic(from: .now, by: 60)) { context in
      let freshness = WatchtowerAnalyticsChartModel.updatedBadge(
        fetchedAt: trafficState.fetchedAt,
        now: context.date)
      DashSectionHeader(
        freshness ?? "",
        icon: freshness == nil ? nil : SolarAsset.Content.clock,
        titleAccessibilityLabel: freshness.map(
          WatchtowerAnalyticsChartModel.updatedAccessibilityLabel),
        actionIcon: SolarAsset.pen,
        actionLabel: DashL10n.string("Edit charts"),
        action: beginCustomization
      )
    }
  }

  private var addChartMenu: some View {
    Menu {
      if customization.addableMetrics.isEmpty {
        Button(DashL10n.string("All charts are shown")) {}
          .disabled(true)
      } else {
        ForEach(customization.addableMetrics) { metric in
          Button(DashL10n.ui(metric.title)) {
            withAnimation(reduceMotion ? nil : DashTheme.Motion.morph) {
              customization.add(metric)
            }
            DashDelight.selectionChanged()
          }
        }
      }
    } label: {
      WatchtowerAddChartToolbarLabel()
    }
    .buttonStyle(DashPressButtonStyle())
    .disabled(!editorInteractionsReady)
    .accessibilityLabel(DashL10n.string("Add chart"))
    .accessibilityIdentifier("watchtower-add-chart")
  }

  /// The inbox loads its own deliveries; the tab only owns the charts.
  private func load(force: Bool = false) async {
    await trafficState.load(model: model, force: force)
    await model.refreshWatchtowerAlerts(force: force)
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

private struct WatchtowerAddChartToolbarLabel: View {
  var body: some View {
    if #available(iOS 26.0, *) {
      DashToolbarActionIcon(asset: SolarAsset.plus)
        .frame(
          width: AvatarHeaderMetrics.barSize,
          height: AvatarHeaderMetrics.barSize
        )
        .contentShape(Circle())
        .glassEffect(.regular.interactive(), in: .circle)
    } else {
      DashToolbarActionIcon(asset: SolarAsset.plus)
        .dashCompactHitTarget()
    }
  }
}
