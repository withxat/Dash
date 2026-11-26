import SwiftUI

struct WatchtowerAddChartToolbarLabel: View {
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

/// Native navigation-bar chrome for the three tab roots (Home, Resources,
/// Watchtower). Pushed destinations provide their own `.toolbar` via
/// `detailHeader` and `dashPageActions`, so UIKit animates every bar
/// transition and interactive swipe-back natively.
struct DashRootNavigationToolbarModifier: ViewModifier {
  let isWatchtowerTab: Bool
  let watchtowerCustomization: WatchtowerChartCustomizationState?
  @Binding var editorInteractionsReady: Bool
  let onPrepareNavigation: () -> Void
  let onProfileLongPress: () -> Void
  let onInboxLongPress: () -> Void
  let onCancelEditing: () -> Void
  let onCommitEditing: () -> Void

  @Environment(AppModel.self) private var model
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var isEditingWatchtower: Bool {
    isWatchtowerTab && (watchtowerCustomization?.isEditing ?? false)
  }

  private var showsWatchtowerInbox: Bool {
    isWatchtowerTab && model.activeAccountID != nil
  }

  func body(content: Content) -> some View {
    content.toolbar {
      ToolbarItem(placement: .topBarLeading) {
        if isEditingWatchtower {
          DashToolbarIconButton(
            asset: SolarAsset.editClose,
            accessibilityLabel: DashL10n.string("Cancel"),
            action: onCancelEditing
          )
          .accessibilityIdentifier("watchtower-customize-cancel")
        } else {
          DashNavigationSource(
            destination: .settings,
            onNavigate: onPrepareNavigation
          ) { navigate in
            HeaderProfileButton(
              action: { navigate() },
              onLongPress: onProfileLongPress)
          }
        }
      }
      .dashSeparateToolbarBackground()

      if isEditingWatchtower, let watchtowerCustomization {
        ToolbarItem(placement: .topBarTrailing) {
          HStack(spacing: DashPageChromeMetrics.actionSpacing) {
            addChartMenu(watchtowerCustomization)
            DashToolbarIconButton(
              asset: SolarAsset.unread,
              accessibilityLabel: DashL10n.string("Done"),
              variant: .confirmation,
              action: onCommitEditing
            )
            .accessibilityIdentifier("watchtower-customize-done")
          }
        }
        .dashSeparateToolbarBackground()
      } else if showsWatchtowerInbox {
        ToolbarItem(placement: .topBarTrailing) {
          DashNavigationSource(destination: .watchtowerInbox) { navigate in
            HeaderInboxButton(
              count: model.watchtowerUnreadAlertCount ?? 0,
              action: { navigate() },
              onLongPress: onInboxLongPress)
          }
        }
        .dashSeparateToolbarBackground()
      }
    }
  }

  private func addChartMenu(_ customization: WatchtowerChartCustomizationState) -> some View {
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
}

extension View {
  func dashRootNavigationToolbar(
    isWatchtowerTab: Bool = false,
    watchtowerCustomization: WatchtowerChartCustomizationState? = nil,
    editorInteractionsReady: Binding<Bool> = .constant(false),
    onPrepareNavigation: @escaping () -> Void,
    onProfileLongPress: @escaping () -> Void,
    onInboxLongPress: @escaping () -> Void = {},
    onCancelEditing: @escaping () -> Void = {},
    onCommitEditing: @escaping () -> Void = {}
  ) -> some View {
    modifier(
      DashRootNavigationToolbarModifier(
        isWatchtowerTab: isWatchtowerTab,
        watchtowerCustomization: watchtowerCustomization,
        editorInteractionsReady: editorInteractionsReady,
        onPrepareNavigation: onPrepareNavigation,
        onProfileLongPress: onProfileLongPress,
        onInboxLongPress: onInboxLongPress,
        onCancelEditing: onCancelEditing,
        onCommitEditing: onCommitEditing))
  }
}
