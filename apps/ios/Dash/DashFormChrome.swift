import SwiftUI
import UIKit

// MARK: - Tray content helpers

enum DashFormDeletionPresentation: Equatable, Sendable {
  /// Sensitive or irreversible actions keep the shared confirmation morph and
  /// a second-tap destructive control.
  case confirmThenExecute
  /// Reversible ordinary deletion schedules immediately; the global Toast is
  /// the single confirmation/Undo surface.
  case deferToGlobalUndo
}

/// A form tray with one primary action and, when needed, one reversible text
/// action immediately above it. When a delete is supplied, a circular header
/// button morphs the form — in place — into a confirmation whose Save button
/// becomes Confirm rather than a second primary button appearing. This is the
/// canonical editor tray.
struct DashFormSheet<Content: View>: View {
  var saveTitle = "Save"
  var actionPhase: DashActionPhase = .idle
  var onSuccessPresentationCompleted: (@MainActor () -> Void)? = nil
  var canSave = true
  var deleteMessage: String? = nil
  /// Failure of the last delete attempt, shown inline while confirming so the
  /// morph stays open instead of pretending success.
  var deleteError: String? = nil
  var onDelete: (() -> Void)? = nil
  var deletionPresentation: DashFormDeletionPresentation = .confirmThenExecute
  var secondaryActionTitle: String? = nil
  var secondaryActionEnabled = true
  var onSecondaryAction: (() -> Void)? = nil
  let onSave: () -> Void
  @ViewBuilder let content: Content
  @State private var confirmingDelete = false

  private var hasDelete: Bool {
    guard onDelete != nil else { return false }
    return deletionPresentation == .deferToGlobalUndo || deleteMessage != nil
  }

  var body: some View {
    DashConfirmMorph(
      confirming: $confirmingDelete,
      message: deleteMessage,
      actionPhase: actionPhase,
      onSuccessPresentationCompleted: onSuccessPresentationCompleted,
      actionTitle: saveTitle,
      confirmingActionTitle: "Delete",
      actionRole: nil,
      confirmingActionRole: .destructive,
      actionEnabled: confirmingDelete || canSave,
      secondaryActionTitle: secondaryActionTitle,
      secondaryActionEnabled: secondaryActionEnabled,
      secondaryAction: onSecondaryAction,
      errorMessage: confirmingDelete ? deleteError : nil,
      action: { confirmingDelete ? onDelete?() : onSave() },
      headerDelete: hasDelete,
      headerDeleteAction: deletionPresentation == .deferToGlobalUndo ? onDelete : nil,
      content: { content }
    )
    .dashKeyboardDismissal()
  }
}

/// The shared body/confirm morph: a body that swaps to a centered message, a
/// Cancel that joins while confirming, and a primary `DashActionButton` that
/// follows the same route-driven replacement as the body (idle Save/Make active
/// ↔ Delete). A header trash button flips `confirming`. Reused by editor and
/// detail trays so the whole app shares one "primary action + optional
/// sub-actions" interaction.
struct DashConfirmMorph<Content: View>: View {
  @Binding var confirming: Bool
  var message: String?
  var actionPhase: DashActionPhase = .idle
  var onSuccessPresentationCompleted: (@MainActor () -> Void)? = nil
  /// Idle primary action title. `nil` hides the footer button until confirming
  /// (detail trays that only offer header delete).
  var actionTitle: String?
  var confirmingActionTitle: String = "Delete"
  var actionRole: ButtonRole? = nil
  var confirmingActionRole: ButtonRole? = .destructive
  var actionEnabled: Bool = true
  /// Optional reversible action paired with the idle primary action.
  var secondaryActionTitle: String? = nil
  var secondaryActionEnabled = true
  var secondaryAction: (() -> Void)? = nil
  var errorMessage: String? = nil
  var action: () -> Void
  var headerDelete = false
  var headerDeleteAction: (() -> Void)? = nil
  @ViewBuilder var content: () -> Content

  private var stepRole: DashTrayStepRole { confirming ? .destructive : .root }

  var body: some View {
    VStack(spacing: 0) {
      bodyContent

      // Keep the route host alive even when a detail tray has no idle footer.
      // Its root route is zero-height, but retaining it lets Delete animate in
      // and back out instead of mounting the flow after the route already won.
      actionContent
        .padding(.top, confirming || actionTitle != nil ? 16 : 0)
    }
    .frame(maxWidth: .infinity, alignment: .top)
    .dashTrayHeaderAction(
      headerDelete && !confirming && !actionPhase.isActive
        ? DashSheetHeaderAction(
          id: "delete", icon: SolarAsset.trash,
          accessibilityLabel: DashL10n.string("Delete")
        ) {
          if let headerDeleteAction {
            headerDeleteAction()
          } else {
            confirming = true
          }
        }
        : nil
    )
  }

  private var actionContent: some View {
    DashTrayFlow(route: confirming, role: stepRole) { isConfirming in
      if isConfirming {
        DashTrayActionPair {
          DashTrayCancelButton { confirming = false }
            .disabled(actionPhase.isActive)
        } primary: {
          DashActionButton(
            title: confirmingActionTitle,
            role: confirmingActionRole,
            phase: actionPhase,
            onSuccessPresentationCompleted: onSuccessPresentationCompleted,
            action: action
          )
          .disabled(!actionEnabled)
          .opacity(actionEnabled ? 1 : 0.45)
        }
      } else if let actionTitle {
        if let secondaryActionTitle, let secondaryAction {
          // Not a way out of the primary — an alternative beside it, so it
          // keeps the stacked relationship rather than sharing the row.
          DashTrayActionPair(axis: .vertical) {
            DashTrayTextButton(title: secondaryActionTitle, action: secondaryAction)
              .disabled(!secondaryActionEnabled || actionPhase.isActive)
          } primary: {
            DashActionButton(
              title: actionTitle,
              role: actionRole,
              phase: actionPhase,
              onSuccessPresentationCompleted: onSuccessPresentationCompleted,
              action: action
            )
            .disabled(!actionEnabled)
            .opacity(actionEnabled ? 1 : 0.45)
          }
        } else {
          DashActionButton(
            title: actionTitle,
            role: actionRole,
            phase: actionPhase,
            onSuccessPresentationCompleted: onSuccessPresentationCompleted,
            action: action
          )
          .disabled(!actionEnabled)
          .opacity(actionEnabled ? 1 : 0.45)
        }
      }
    }
  }

  private var bodyContent: some View {
    DashTrayFlow(route: confirming, role: stepRole) { isConfirming in
      if isConfirming, let message {
        VStack(spacing: 12) {
          Text(DashL10n.ui(message))
            .dashTextStyle(.supporting)
            .foregroundStyle(DashTheme.subtle)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
          if let errorMessage {
            DashNotice(kind: .error, message: errorMessage)
          }
        }
      } else {
        content()
      }
    }
  }
}

private struct DashKeyboardDismissalModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
      .scrollDismissesKeyboard(.immediately)
      .contentShape(Rectangle())
      .onTapGesture(perform: dismissKeyboard)
  }

  private func dismissKeyboard() {
    UIApplication.shared.sendAction(
      #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
  }
}

extension View {
  func dashKeyboardDismissal() -> some View {
    modifier(DashKeyboardDismissalModifier())
  }
}

struct DashFormField: View {
  let label: String
  @Binding var text: String
  var keyboard: UIKeyboardType = .default
  var contentType: UITextContentType? = nil
  @FocusState private var isFocused: Bool

  private var displayedLabel: String { DashL10n.ui(label) }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(displayedLabel)
        .dashTextStyle(.footnoteSemibold)
        .foregroundStyle(DashTheme.subtle)
      TextField(displayedLabel, text: $text)
        .dashTextStyle(.bodyMedium)
        .foregroundStyle(DashTheme.text)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .keyboardType(keyboard)
        .textContentType(contentType)
        .focused($isFocused)
        .submitLabel(.done)
        .onSubmit { isFocused = false }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(DashTheme.recessed)
        .clipShape(RoundedRectangle(cornerRadius: DashTheme.Radius.medium, style: .continuous))
    }
  }
}

/// Menu-backed form field (a dropdown) styled to match `DashFormField` — for
/// choosing among many options where a segmented control would cramp and can't
/// grow. One row, constant footprint, scales to any number of options.
struct DashFormMenuField: View {
  let label: String
  @Binding var selection: String
  let options: [String]

  private var displayedLabel: String { DashL10n.ui(label) }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(displayedLabel)
        .dashTextStyle(.footnoteSemibold)
        .foregroundStyle(DashTheme.subtle)
      Menu {
        Picker(displayedLabel, selection: $selection) {
          ForEach(options, id: \.self) { Text(DashL10n.ui($0)) }
        }
      } label: {
        HStack(spacing: 8) {
          Text(DashL10n.ui(selection))
            .dashTextStyle(.bodyMedium)
            .foregroundStyle(DashTheme.text)
          Spacer(minLength: 0)
          SolarIcon(
            asset: SolarAsset.chevronRight, size: DashTheme.Chevron.compact,
            color: DashTheme.placeholder
          )
          .rotationEffect(.degrees(90))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DashTheme.recessed)
        .clipShape(RoundedRectangle(cornerRadius: DashTheme.Radius.medium, style: .continuous))
      }
    }
  }
}

/// Multiline code variant of DashFormField for tray forms.
struct DashFormCodeField: View {
  let label: String
  @Binding var text: String
  var minHeight: CGFloat = 220

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(label)
        .dashTextStyle(.footnoteSemibold)
        .foregroundStyle(DashTheme.subtle)
      TextEditor(text: $text)
        .dashTextStyle(.code)
        .foregroundStyle(DashTheme.text)
        .scrollContentBackground(.hidden)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .frame(minHeight: minHeight)
        .padding(12)
        .background(DashTheme.recessed)
        .clipShape(RoundedRectangle(cornerRadius: DashTheme.Radius.medium, style: .continuous))
    }
  }
}

/// Circular close control shared by tray headers and the R2 image viewer.
struct DashCloseButton: View {
  var accessibilityLabel = "Close"
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      SolarIcon(asset: SolarAsset.close, size: 22, color: DashTheme.Sheet.closeIcon)
        .frame(width: 32, height: 32)
        .background(DashTheme.recessed, in: Circle())
        .dashCompactHitTarget()
    }
    .buttonStyle(DashPressButtonStyle())
    .accessibilityLabel(accessibilityLabel)
  }
}

// MARK: - Staggered reveal

private struct DashSplashLiftedKey: EnvironmentKey {
  static let defaultValue = true
}

private struct DashSectionsRevealedKey: EnvironmentKey {
  static let defaultValue = true
}

private struct DashLoginIconCloakedKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  /// False while the launch splash still covers the window. Entrance reveals
  /// wait on it so they play in view, not underneath the splash.
  var dashSplashLifted: Bool {
    get { self[DashSplashLiftedKey.self] }
    set { self[DashSplashLiftedKey.self] = newValue }
  }

  /// Shared entrance phase for the semantic sections on a catalog screen.
  fileprivate var dashSectionsRevealed: Bool {
    get { self[DashSectionsRevealedKey.self] }
    set { self[DashSectionsRevealedKey.self] = newValue }
  }

  /// True while the splash overlay's morphing lockup stands in for the
  /// welcome brand lockup; onboarding keeps its own copy invisible (but laid
  /// out) so the hand-off is a seamless same-frame swap.
  var dashLoginIconCloaked: Bool {
    get { self[DashLoginIconCloakedKey.self] }
    set { self[DashLoginIconCloakedKey.self] = newValue }
  }
}

/// Bubbles the welcome lockup icon's bounds up to the splash overlay, which
/// glides and scales the launch logo onto it on first launch.
struct DashLoginIconAnchorKey: PreferenceKey {
  static var defaultValue: Anchor<CGRect>? { nil }
  static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
    value = nextValue() ?? value
  }
}

/// Entrance reveal (after Transitions.dev "Texts reveal"): rises 12pt out of
/// a 3pt blur on a 0.5s deceleration curve. Elements stagger by 40ms and
/// semantic sections by 100ms so siblings land top to bottom. Works on any
/// view, not just text. Exits stay a plain short fade — never replay the
/// stagger in reverse.
private enum DashRevealCadence {
  static let element = 0.04
  static let section = 0.1
}

private struct DashRevealModifier: ViewModifier {
  let index: Int
  let shown: Bool
  let stagger: Double
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    let visible = shown || reduceMotion
    content
      .opacity(visible ? 1 : 0)
      .offset(y: visible ? 0 : 12)
      .blur(radius: visible ? 0 : 3)
      .animation(
        reduceMotion
          ? nil
          : DashTheme.Motion.textReveal
            .delay(Double(max(index, 0)) * stagger),
        value: shown
      )
  }
}

extension View {
  /// Staggered entrance; drive `shown` from state flipped on appear (waiting
  /// for `dashSplashLifted` when the view can sit under the launch splash).
  func dashReveal(_ index: Int = 0, shown: Bool) -> some View {
    modifier(
      DashRevealModifier(index: index, shown: shown, stagger: DashRevealCadence.element)
    )
  }

  /// Self-driving entrance for loaded content: plays once when the view first
  /// appears with `ready` true (and the splash lifted), then latches — pull
  /// refreshes and scroll-backs never replay it. Applied to a `@ViewBuilder`
  /// product it distributes per element, so lazy stacks stay lazy.
  func dashContentReveal(_ index: Int = 0, ready: Bool = true) -> some View {
    modifier(
      DashContentRevealModifier(
        index: index, ready: ready, stagger: DashRevealCadence.element)
    )
  }

  /// Marks a semantic screen section for the shared top-to-bottom entrance.
  func dashSectionReveal(_ index: Int = 0) -> some View {
    modifier(DashSectionRevealModifier(index: index))
  }

  /// Coordinates all `dashSectionReveal` descendants from one screen-level
  /// phase. Lazy sections created after the entrance are immediately visible.
  func dashSectionEntrance() -> some View {
    modifier(DashSectionEntranceModifier())
  }

  /// Self-driving reveal for sections inserted after async content loads.
  func dashSectionContentReveal(_ index: Int = 0, ready: Bool = true) -> some View {
    modifier(
      DashContentRevealModifier(
        index: index, ready: ready, stagger: DashRevealCadence.section)
    )
  }

  /// Leaves a staggered reveal as one quiet 200ms fade. The outgoing view
  /// keeps its resting geometry and sharpness, so removal never reads as the
  /// entrance playing backwards. Reduced Motion removes the transition.
  func dashFailureRemovalTransition() -> some View {
    modifier(DashFailureRemovalTransitionModifier())
  }
}

private struct DashFailureRemovalTransitionModifier: ViewModifier {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content.transition(
      reduceMotion
        ? .identity
        : .asymmetric(
          insertion: .identity,
          removal: .opacity.animation(DashTheme.Motion.failureDismiss)
        )
    )
  }
}

private struct DashContentRevealModifier: ViewModifier {
  let index: Int
  let ready: Bool
  let stagger: Double
  @Environment(\.dashSplashLifted) private var splashLifted
  @State private var revealed = false

  @ViewBuilder
  func body(content: Content) -> some View {
    content
      .modifier(DashRevealModifier(index: index, shown: revealed, stagger: stagger))
      .onAppear { maybeReveal() }
      .onChange(of: ready) { _, _ in maybeReveal() }
      .onChange(of: splashLifted) { _, _ in maybeReveal() }
  }

  private func maybeReveal() {
    if ready && splashLifted { revealed = true }
  }
}

private struct DashSectionRevealModifier: ViewModifier {
  let index: Int
  @Environment(\.dashSectionsRevealed) private var revealed

  func body(content: Content) -> some View {
    content.modifier(
      DashRevealModifier(
        index: index, shown: revealed, stagger: DashRevealCadence.section)
    )
  }
}

private struct DashSectionEntranceModifier: ViewModifier {
  @Environment(\.dashSplashLifted) private var splashLifted
  @State private var revealed = false

  func body(content: Content) -> some View {
    content
      .environment(\.dashSectionsRevealed, revealed)
      .onAppear { maybeReveal() }
      .onChange(of: splashLifted) { _, _ in maybeReveal() }
  }

  private func maybeReveal() {
    if splashLifted { revealed = true }
  }
}
