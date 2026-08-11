import CloudflareAPI
import Observation
import SwiftDitherKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct WatchtowerTrafficView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Bindable var state: WatchtowerTrafficState
  let customization: WatchtowerChartCustomizationState
  let dragVisual: WatchtowerMetricDragVisualState
  let isEditing: Bool
  let editorControlsVisible: Bool
  let usesPlaceholderCharts: Bool
  @State private var removalSequence = WatchtowerMetricRemovalSequence()
  @State private var layoutMorphingMetric: WatchtowerAnalyticsMetric?

  /// Cold / access / error without overview — same flow layout as live, with
  /// `WatchtowerMetricSkeletonCard` as the placeholder face.
  private var paintsPlaceholderCharts: Bool {
    state.overview == nil
      && (state.needsAnalyticsAccess || state.isLoadingCurrent || state.currentError != nil)
  }

  var body: some View {
    ZStack(alignment: .topLeading) {
      VStack(alignment: .leading, spacing: DashTheme.Spacing.section) {
        if customization.visibleMetrics.isEmpty {
          statusCard {
            emptyContent(
              title: DashL10n.string("No charts"),
              message: DashL10n.string("Add a chart to rebuild this view.")
            )
          }
        } else if paintsPlaceholderCharts
          || (state.overview != nil && state.snapshot != nil)
        {
          // One continuous flow across load → access/error → live. A 403 used
          // to swap the cards for a status panel; now the saved layout stays
          // and the failure wash lands on top.
          WatchtowerMetricCardFlowLayout(spacing: DashTheme.Spacing.itemGap) {
            ForEach(customization.visibleMetrics) { metric in
              let expanded = isExpanded(metric)
              Group {
                if paintsPlaceholderCharts {
                  WatchtowerMetricSkeletonCard(metric: metric, isExpanded: expanded)
                } else if let overview = state.overview, let snapshot = state.snapshot {
                  reorderableMetricCard(
                    metric,
                    overview: overview,
                    snapshot: snapshot,
                    expanded: expanded
                  )
                }
              }
              .layoutValue(
                key: WatchtowerMetricExpandedLayoutKey.self,
                value: expanded
              )
              .dashBodySlot(reduceMotion: reduceMotion)
            }
            if !paintsPlaceholderCharts, let error = state.currentError {
              DashNotice(kind: .warning, message: error)
                .layoutValue(
                  key: WatchtowerMetricExpandedLayoutKey.self,
                  value: true
                )
                .dashBodySlot(reduceMotion: reduceMotion)
            }
          }
          .animation(
            reduceMotion ? DashTheme.Motion.reduced : DashBodyTransition.handoff,
            value: paintsPlaceholderCharts
          )
          .dashColdFailure(
            title: coldFailureTitle,
            message: paintsPlaceholderCharts ? coldFailureMessage : nil,
            actionTitle: coldFailureActionTitle,
            action: performColdFailureAction
          )
          .dashFailureRemovalTransition()
        }
      }

      if let overview = state.overview {
        WatchtowerMetricDragOverlay(
          state: dragVisual,
          overview: overview,
          range: state.range
        )
      }
    }
    .coordinateSpace(name: WatchtowerMetricDragLayout.coordinateSpace)
    .onPreferenceChange(WatchtowerMetricFramePreferenceKey.self) { frames in
      dragVisual.updateLayoutFrames(frames)
    }
    // Every lift resolves its coordinates against this view, so it is mounted
    // unconditionally: anything that appears or disappears on `isEditing` gets
    // built during the editor morph, and a `UIViewRepresentable` inserted on
    // that frame both eats the transition and leaves a window where a lift can
    // find no reference — which `itemsForBeginning` cancels silently.
    // `topLeading` anchors its origin to the stack's, so the ghost's
    // coordinates hold even if the view resolves to a smaller size.
    .background(alignment: .topLeading) {
      WatchtowerMetricDragCoordinateView(state: dragVisual)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
    .accessibilityIdentifier(isEditing ? "watchtower-chart-editor" : "watchtower-charts")
    .modifier(
      WatchtowerMetricRootDropModifier(
        isEnabled: isEditing,
        customization: customization)
    )
    .onChange(of: isEditing) {
      if !isEditing {
        removalSequence.cancel()
        layoutMorphingMetric = nil
        dragVisual.finish()
      }
    }
  }

  private func isExpanded(_ metric: WatchtowerAnalyticsMetric) -> Bool {
    if dynamicTypeSize.isAccessibilitySize { return true }
    return customization.isExpanded(metric)
  }

  @ViewBuilder
  private func reorderableMetricCard(
    _ metric: WatchtowerAnalyticsMetric,
    overview: AccountAnalyticsOverview,
    snapshot: WatchtowerAnalyticsChartModel.Snapshot,
    expanded: Bool
  ) -> some View {
    let isDeparting = removalSequence.departingMetric == metric
    let isPressed = isEditing && dragVisual.pressedMetric == metric
    let card = metricCard(
      metric, overview: overview, snapshot: snapshot, expanded: expanded)
    card
      .background {
        GeometryReader { geometry in
          Color.clear.preference(
            key: WatchtowerMetricFramePreferenceKey.self,
            value: [
              metric: geometry.frame(
                in: .named(WatchtowerMetricDragLayout.coordinateSpace))
            ]
          )
        }
      }
      // Reordering is the one card interaction that intentionally borrows the
      // button press pose: the held object itself is the direct manipulation.
      .scaleEffect(isPressed && !reduceMotion ? DashTheme.Motion.pressScale : 1)
      .opacity(isPressed && reduceMotion ? 0.88 : 1)
      .animation(
        reduceMotion ? DashTheme.Motion.reduced : DashTheme.Motion.press,
        value: isPressed
      )
      .opacity(
        isDeparting || (isEditing && customization.draggedMetric == metric)
          ? 0
          : 1
      )
      .blur(radius: reduceMotion || !isDeparting ? 0 : 3)
      .overlay {
        if isEditing, customization.draggedMetric == metric {
          WatchtowerMetricDropPlaceholder()
        }
      }
      .scaleEffect(
        isDeparting
          ? (reduceMotion ? 1 : 0.95)
          : (isEditing && customization.dropTargetMetric == metric ? 1.015 : 1)
      )
      .contentShape(
        RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous)
      )
      .overlay {
        WatchtowerNativeMetricDragSource(
          metric: metric,
          isExpanded: expanded,
          isEnabled: isEditing,
          customization: customization,
          visualState: dragVisual
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
      }
      .accessibilityHint(
        isEditing ? DashL10n.string("Touch and hold, then drag to reorder") : ""
      )
      .accessibilityHidden(isDeparting)
      // Only the card that is leaving stops taking touches. `removalSequence`
      // is one shared value, so gating every card on it meant a removal whose
      // two-stage completion never landed took the whole editor's gestures
      // with it. Re-entrancy is already guarded inside the handlers.
      .allowsHitTesting(!isDeparting)
      .zIndex(
        isDeparting
          ? 2
          : (layoutMorphingMetric == metric ? 1 : 0)
      )
      .accessibilityActions {
        if isEditing {
          Button(DashL10n.string("Move up")) {
            withAnimation(reduceMotion ? nil : DashTheme.Motion.morph) {
              customization.moveVisible(metric, offset: -1)
            }
          }
          Button(DashL10n.string("Move down")) {
            withAnimation(reduceMotion ? nil : DashTheme.Motion.morph) {
              customization.moveVisible(metric, offset: 1)
            }
          }
        }
      }
  }

  private func metricCard(
    _ metric: WatchtowerAnalyticsMetric,
    overview: AccountAnalyticsOverview,
    snapshot: WatchtowerAnalyticsChartModel.Snapshot,
    expanded: Bool
  ) -> some View {
    WatchtowerMetricChartCard(
      metric: metric,
      overview: overview,
      previousOverview: snapshot.previousOverview,
      // The card retains this value through its two-stage visual handoff, then
      // unmounts the live chart while editing. Arrays remain copy-on-write.
      chart: snapshot.charts[metric] ?? .empty,
      range: state.range,
      snapshotsByRange: state.snapshots,
      loadingRanges: state.loadingRanges,
      isExpanded: expanded,
      showsEditingControls: editorControlsVisible,
      renderingMode: WatchtowerMetricChartRenderingMode.resolved(
        isEditing: usesPlaceholderCharts),
      onToggleExpanded: {
        toggleMetric(metric)
      },
      onRemove: {
        removeMetric(metric)
      },
      onScrubChange: { scrubbing in
        customization.setScrubbing(scrubbing, for: metric)
      }
    )
  }

  private func toggleMetric(_ metric: WatchtowerAnalyticsMetric) {
    guard
      removalSequence.isIdle,
      layoutMorphingMetric == nil
    else { return }

    guard !reduceMotion else {
      customization.toggleExpanded(metric)
      return
    }

    layoutMorphingMetric = metric
    withAnimation(
      DashTheme.Motion.morph.logicallyComplete(after: 0.28),
      completionCriteria: .logicallyComplete
    ) {
      customization.toggleExpanded(metric)
    } completion: {
      if layoutMorphingMetric == metric {
        layoutMorphingMetric = nil
      }
    }
  }

  private func removeMetric(_ metric: WatchtowerAnalyticsMetric) {
    guard
      customization.isEditing,
      removalSequence.isIdle,
      layoutMorphingMetric == nil
    else { return }
    DashDelight.selectionChanged()

    withAnimation(
      (reduceMotion ? DashTheme.Motion.reduced : DashTheme.Motion.morphExit)
        .logicallyComplete(after: reduceMotion ? 0.12 : 0.22),
      completionCriteria: .logicallyComplete
    ) {
      _ = removalSequence.begin(metric)
    } completion: {
      guard
        customization.isEditing,
        removalSequence.finishExit(metric)
      else {
        removalSequence.cancel()
        return
      }

      withAnimation(
        (reduceMotion ? DashTheme.Motion.reduced : DashTheme.Motion.morph)
          .logicallyComplete(after: reduceMotion ? 0.12 : 0.28),
        completionCriteria: .logicallyComplete
      ) {
        customization.remove(metric)
      } completion: {
        removalSequence.finishReflow(metric)
      }
    }
  }

  private func statusCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous)
    return content()
      .padding(DashTheme.Spacing.card)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(DashTheme.homeCardSurface, in: shape)
      .dashEmbossChrome(shape: shape)
  }

  private var coldFailureTitle: String {
    state.needsAnalyticsAccess
      ? DashL10n.string("Analytics access needed")
      : DashL10n.string("Traffic unavailable")
  }

  private var coldFailureMessage: String? {
    if state.needsAnalyticsAccess {
      return [
        DashL10n.string("Allow Account Analytics: Read to load account traffic."),
        DashL10n.string(
          "Dash requests all permissions used by its current features in one authorization."
        ),
      ].joined(separator: " ")
    }
    return state.currentError
  }

  private var coldFailureActionTitle: String {
    state.needsAnalyticsAccess
      ? DashL10n.string("Grant access")
      : DashL10n.string("Try again")
  }

  private func performColdFailureAction() {
    if state.needsAnalyticsAccess {
      model.requestAccess(to: DashAuthorizationScopes.accountAnalytics)
    } else {
      Task { await state.retry(model: model) }
    }
  }

  private func emptyContent(
    title: String,
    message: String,
    buttonTitle: String? = nil,
    action: (() -> Void)? = nil
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .dashTextStyle(.supportingMedium)
        .foregroundStyle(DashTheme.text)
      Text(message)
        .dashTextStyle(.footnote)
        .foregroundStyle(DashTheme.rowSubtitle)
        .fixedSize(horizontal: false, vertical: true)
      if let buttonTitle, let action {
        Button(buttonTitle, action: action)
          .dashTextStyle(.supportingMedium)
          .foregroundStyle(DashTheme.brand)
          .frame(minHeight: DashTheme.Layout.minimumHitTarget)
          .buttonStyle(DashPressButtonStyle())
      }
    }
    .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
  }
}
