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
  @State private var editorInteractionsReady = false
  @State private var editorTransitionGeneration = 0

  /// Re-keys the load task on both account and activation so the deferred load
  /// fires the moment the tab is first swiped or tapped into view.
  private struct LoadKey: Equatable {
    let context: AccountRequestContext?
    let active: Bool
  }

  var body: some View {
    content
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
      }
      .padding(.horizontal, DashTheme.Spacing.screen)
      .padding(.top, DashTheme.Spacing.compact)
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
        DashSectionHeader(
          DashL10n.string("Charts"),
          icon: SolarAsset.Content.chartSquare,
          actionIcon: SolarAsset.pen,
          actionLabel: DashL10n.string("Edit charts"),
          action: beginCustomization
        )
        .transition(.opacity)
      }
      WatchtowerTrafficView(
        state: trafficState,
        customization: customization,
        isEditing: customization.isEditing,
        editorInteractionsReady: editorInteractionsReady,
        usesPlaceholderCharts: customization.isEditing
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
    withAnimation(
      reduceMotion ? nil : DashTheme.Motion.morph,
      completionCriteria: .removed
    ) {
      customization.beginEditing()
    } completion: {
      guard
        generation == editorTransitionGeneration,
        customization.isEditing
      else { return }
      editorInteractionsReady = true
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
    editorInteractionsReady = false
    withAnimation(reduceMotion ? nil : DashTheme.Motion.morphExit) {
      if commit {
        customization.commitEditing()
      } else {
        customization.cancelEditing()
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
