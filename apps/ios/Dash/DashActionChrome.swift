import CloudflareAPI
import SwiftUI
import UIKit

/// Twotone ring spinner (after iconify's line-md:loading-twotone-loop): a
/// faint full circle under a quarter arc looping a 1.5s rotation. Sits at a
/// pill's trailing edge so the centered label never shifts while loading.
struct DashLoadingRing: View {
  var color: Color = DashTheme.inverse
  var size: CGFloat = 20
  var lineWidth: CGFloat = 3
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var spinning = false

  var body: some View {
    ZStack {
      Circle()
        .stroke(color.opacity(0.3), lineWidth: lineWidth)
      Circle()
        .trim(from: 0, to: 0.25)
        .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        .rotationEffect(.degrees(reduceMotion ? -90 : (spinning ? 360 : 0)))
    }
    .frame(width: size, height: size)
    .padding(lineWidth / 2)
    .onAppear {
      guard !reduceMotion else { return }
      withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
        spinning = true
      }
    }
    .accessibilityLabel("Loading")
  }
}

enum DashActionPhase: Equatable, Sendable {
  case idle
  case loading
  case succeeded

  var isActive: Bool { self != .idle }

  var accessibilityValue: String {
    switch self {
    case .idle: ""
    case .loading: DashL10n.string("Loading")
    case .succeeded: DashL10n.string("Success")
    }
  }
}

/// Fixed trailing slot shared by every action pill. The ring and Solar's
/// `ui/Bold/CheckCircle` stay mounted in the same ZStack while opacity, blur,
/// and scale swap their visibility.
struct DashActionStatusIcon: View {
  let phase: DashActionPhase
  var loadingColor: Color = DashTheme.inverse
  var successColor: Color? = nil
  var size: CGFloat = 20
  var lineWidth: CGFloat = 3
  var onSuccessPresentationCompleted: (@MainActor () -> Void)?

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var displayedPhase: DashActionPhase = .idle
  @State private var rendersLayers = false
  @State private var completionArmed = false
  @State private var transitionGeneration = 0

  /// The ring's stroke straddles a `size`-wide path, so the spinner reads
  /// `size + lineWidth` across, while Solar's `ui/Bold/CheckCircle` only fills
  /// 20 of its 24pt canvas. A glyph drawn at `size` therefore landed a quarter
  /// narrower than the ring it replaces. Scale its frame so the two circles
  /// share an outer edge, trimmed 4% because a solid disc carries more weight
  /// than an outline of the same width. Only the transparent margin exceeds the
  /// slot; the ink stays inside it.
  private var successSize: CGFloat { (size + lineWidth) * 0.96 * (24.0 / 20.0) }

  var body: some View {
    ZStack {
      if rendersLayers {
        statusLayer(isVisible: displayedPhase == .loading) {
          DashLoadingRing(color: loadingColor, size: size, lineWidth: lineWidth)
        }
        statusLayer(isVisible: displayedPhase == .succeeded) {
          SolarIcon(
            asset: SolarAsset.checkCircleFill,
            size: successSize,
            color: successColor ?? loadingColor
          )
        }
      }
    }
    .frame(width: size + 4, height: size + 4)
    .accessibilityHidden(true)
    .onChange(of: phase, initial: true) { _, newPhase in
      transition(to: newPhase)
    }
  }

  private func statusLayer<Content: View>(
    isVisible: Bool,
    @ViewBuilder content: () -> Content
  ) -> some View {
    content()
      .opacity(isVisible ? 1 : 0)
      .blur(radius: reduceMotion || isVisible ? 0 : 2)
      .scaleEffect(reduceMotion || isVisible ? 1 : 0.25)
  }

  private func transition(to newPhase: DashActionPhase) {
    transitionGeneration &+= 1
    let generation = transitionGeneration
    completionArmed = newPhase == .succeeded
    if newPhase != .idle, !rendersLayers {
      var mountTransaction = Transaction()
      mountTransaction.disablesAnimations = true
      withTransaction(mountTransaction) {
        rendersLayers = true
      }
    }
    if reduceMotion {
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        displayedPhase = newPhase
        if newPhase == .idle {
          rendersLayers = false
        }
      }
      completeSuccessIfNeeded()
      return
    }

    withAnimation(
      DashTheme.Motion.iconSwap,
      completionCriteria: .logicallyComplete
    ) {
      displayedPhase = newPhase
    } completion: {
      guard transitionGeneration == generation else { return }
      if newPhase == .idle {
        rendersLayers = false
      }
      completeSuccessIfNeeded()
    }
  }

  private func completeSuccessIfNeeded() {
    guard completionArmed, phase == .succeeded, displayedPhase == .succeeded else { return }
    completionArmed = false
    onSuccessPresentationCompleted?()
  }
}

struct DashPillButton: View {
  let title: String
  /// Optional leading asset-catalog icon.
  var icon: String?
  var phase: DashActionPhase = .idle
  /// Disabled state with the shared 0.45 dim; active phases disable without dimming.
  var isEnabled = true
  var onSuccessPresentationCompleted: (@MainActor () -> Void)?
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        if let icon {
          SolarIcon(asset: icon, size: 20, color: DashTheme.inverse)
            .transition(.opacity)
        }
        Text(DashL10n.ui(title))
          .dashTextStyle(.button)
          .contentTransition(.opacity)
      }
      .foregroundStyle(DashTheme.inverse)
      .frame(maxWidth: .infinity)
      .frame(height: DashTheme.Layout.actionPillHeight)
      .overlay(alignment: .trailing) {
        DashActionStatusIcon(
          phase: phase,
          onSuccessPresentationCompleted: onSuccessPresentationCompleted
        )
        .padding(.trailing, 18)
      }
      .background(DashTheme.strong, in: DashTheme.pillShape)
    }
    .buttonStyle(DashPressButtonStyle())
    .disabled(phase.isActive || !isEnabled)
    .opacity(isEnabled ? 1 : 0.45)
    .accessibilityValue(phase.accessibilityValue)
    .dashTrayDismissDisabled(phase.isActive)
  }
}

struct DashSecondaryPillButton: View {
  let title: String
  var action: (() -> Void)?

  var body: some View {
    Group {
      if let action {
        Button(action: action) { label }
          .buttonStyle(DashPressButtonStyle())
      } else {
        label
      }
    }
  }

  private var label: some View {
    Text(DashL10n.ui(title))
      .dashTextStyle(.buttonBold)
      .foregroundStyle(DashTheme.strong)
      .lineLimit(1)
      .minimumScaleFactor(0.8)
      .frame(maxWidth: .infinity)
      .frame(height: DashTheme.Layout.actionPillHeight)
      .background(DashTheme.recessed, in: DashTheme.pillShape)
      .dashShadow(.border, in: DashTheme.pillShape)
  }
}

/// The way out of a confirm step: a recessed pill that shares the footer row
/// with the primary action, never a text link under it. Cancel and confirm are
/// one decision — they read as one control pair, and the tray's footer keeps
/// the same height whichever step it is on.
///
/// Titles are catalog keys (`DashSecondaryPillButton` localizes), so pass
/// `"Cancel"`, not `DashL10n.string("Cancel")`.
struct DashTrayCancelButton: View {
  var title = "Cancel"
  let action: () -> Void

  var body: some View {
    DashSecondaryPillButton(title: title, action: action)
      .accessibilityIdentifier("dash.tray.cancel")
  }
}

/// The full-width text-only secondary action stacked above a tray's primary
/// pill, for a secondary that is an *alternative* rather than a way out
/// (onboarding's "Explore the demo"). A cancel is `DashTrayCancelButton`.
struct DashTrayTextButton: View {
  let title: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title)
        .dashTextStyle(.buttonMedium)
        .foregroundStyle(DashTheme.subtle)
        .frame(maxWidth: .infinity, minHeight: 44)
    }
    .buttonStyle(DashPressButtonStyle())
  }
}

/// The canonical relationship between a tray's secondary action and its
/// primary pill.
///
/// A cancel and a confirm are one decision, so they share one row at the
/// action-button position — cancel leading, confirm trailing, equal halves —
/// and the tray's footer stays a single band whichever step it is on. Reach
/// for `.vertical` only when the secondary is *not* a way out of the primary
/// (onboarding's "Explore the demo" beside Sign in): stacking states that the
/// two are alternatives rather than a choice about the same action.
struct DashTrayActionPair<Secondary: View, Primary: View>: View {
  var axis: Axis = .horizontal
  private let secondary: Secondary
  private let primary: Primary

  init(
    axis: Axis = .horizontal,
    @ViewBuilder secondary: () -> Secondary,
    @ViewBuilder primary: () -> Primary
  ) {
    self.axis = axis
    self.secondary = secondary()
    self.primary = primary()
  }

  var body: some View {
    switch axis {
    case .horizontal:
      HStack(spacing: DashTheme.Sheet.actionGap) {
        secondary
        primary
      }
    case .vertical:
      VStack(spacing: 4) {
        secondary
        primary
      }
    }
  }
}

// MARK: - Danger confirmation morph

private struct DashBlurModifier: ViewModifier, Animatable {
  var radius: CGFloat

  nonisolated var animatableData: CGFloat {
    get { radius }
    set { radius = newValue }
  }

  func body(content: Content) -> some View {
    content.blur(radius: radius)
  }
}

extension AnyTransition {
  /// Softer cross-fade for morphing tray content: fades *and* blurs, so the
  /// before/after content dissolves rather than hard-swapping under the
  /// matchedGeometryEffect hero. The outgoing side also contracts slightly —
  /// the old content recedes while the new one dissolves in at full size.
  @MainActor static var dashMorph: AnyTransition {
    if UIAccessibility.isReduceMotionEnabled { return .opacity }
    let dissolve = AnyTransition.opacity.combined(
      with: .modifier(
        active: DashBlurModifier(radius: 3),
        identity: DashBlurModifier(radius: 0)))
    return .asymmetric(
      insertion: dissolve,
      removal: dissolve.combined(with: .scale(scale: 0.95))
    )
  }

}

/// A single high-risk action presented inside a tray. Tapping its row morphs —
/// via matchedGeometryEffect — into an inline confirmation step before `perform`
/// runs. This is the canonical tray danger pattern; reuse it everywhere a
/// destructive action needs a second tap (purge, delete). Confirmation is
/// always Cancel + a named tap button — never a type-the-name field or hold.
struct DashDangerAction: Identifiable {
  /// Stable across re-renders — it drives the matchedGeometryEffect morph, so it
  /// must NOT be a fresh UUID per render. Defaults to `title`.
  let id: String
  let title: String
  let icon: String
  let message: String
  /// Confirm footer label. Delete-class actions keep the default; non-delete
  /// verbs (purge) pass their own.
  let confirmTitle: String
  /// A thrown error keeps the confirmation open and surfaces the message
  /// inline; only a clean return dismisses the tray.
  let perform: () async throws -> Void
  /// Presentation changes that would unmount the confirmation run only after
  /// the shared loading-to-success swap finishes.
  let onSuccessPresentationCompleted: @MainActor () -> Void

  init(
    id: String? = nil,
    title: String,
    icon: String = SolarAsset.trash,
    message: String,
    confirmTitle: String = "Delete",
    onSuccessPresentationCompleted: @escaping @MainActor () -> Void = {},
    perform: @escaping () async throws -> Void
  ) {
    self.id = id ?? title
    self.title = title
    self.icon = icon
    self.message = message
    self.confirmTitle = confirmTitle
    self.onSuccessPresentationCompleted = onSuccessPresentationCompleted
    self.perform = perform
  }
}

/// One destructive choice as a tray menu row: outline glyph, danger ink, and
/// the tinted surface a confirm pill grows out of. The row's text layer takes
/// its own matched-geometry id, so the title glides into the pill instead of
/// only the red surface making the trip (the text morph the surface morph
/// always implied). Nil ids drop both effects without changing the look, which
/// is how Reduce Motion renders it.
///
/// One definition for every tray that asks for the first of two taps —
/// `DashConfirmableActions` and Settings' sign-out tray, which cannot use that
/// component because its confirm pill runs on `AppModel`'s sign-out phase.
struct DashDangerMenuRow: View {
  let title: String
  var icon = SolarAsset.trash
  var morphID: String?
  var labelMorphID: String?
  var morphNamespace: Namespace.ID?

  var body: some View {
    HStack(spacing: 12) {
      SolarIcon(asset: icon, size: 22, color: DashTheme.danger)
      label
        .dashTextStyle(.bodyMedium)
        .foregroundStyle(DashTheme.danger)
        .lineLimit(1)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      background
    }
  }

  @ViewBuilder
  private var label: some View {
    let text = Text(DashL10n.ui(title))
    if let labelMorphID, let morphNamespace {
      text.matchedGeometryEffect(id: labelMorphID, in: morphNamespace)
    } else {
      text
    }
  }

  @ViewBuilder
  private var background: some View {
    let shape = RoundedRectangle(cornerRadius: DashTheme.Radius.button, style: .continuous)
    if let morphID, let morphNamespace {
      shape
        .fill(DashTheme.dangerTint)
        .matchedGeometryEffect(id: morphID, in: morphNamespace)
    } else {
      shape.fill(DashTheme.dangerTint)
    }
  }
}

/// Tray content that lists destructive actions as menu rows and morphs a tapped
/// one — via matchedGeometryEffect — into a confirm step (message, Cancel, and
/// a red Delete that the row grows into). No type-the-name field and no hold.
/// Horizontal insets come from the tray card, never from here.
struct DashConfirmableActions: View {
  private enum Route: Hashable, Sendable {
    case menu
    case confirmation(String)
  }

  let actions: [DashDangerAction]
  @Namespace private var morph
  @State private var pending: DashDangerAction?
  @State private var actionPhase: DashActionPhase = .idle
  @State private var errorMessage: String?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dashTrayDismissAfter) private var dismissAfter

  private var route: Route {
    pending.map { .confirmation($0.id) } ?? .menu
  }

  var body: some View {
    DashTrayFlow(
      route: route,
      role: pending == nil ? .root : .destructive
    ) { _ in
      if let pending {
        confirmation(pending)
      } else {
        menu
      }
    }
  }

  private var menu: some View {
    VStack(spacing: 10) {
      ForEach(actions) { action in
        Button {
          errorMessage = nil
          pending = action
        } label: {
          DashDangerMenuRow(
            title: action.title,
            icon: action.icon,
            morphID: reduceMotion ? nil : action.id,
            labelMorphID: reduceMotion ? nil : labelMorphID(action),
            morphNamespace: reduceMotion ? nil : morph
          )
        }
        .buttonStyle(DashSurfaceButtonStyle())
      }
    }
  }

  /// Companion id to the surface morph id (`action.id`); shared by
  /// the row's label and the confirm `DashActionButton`'s title run.
  private func labelMorphID(_ action: DashDangerAction) -> String {
    "\(action.id).label"
  }

  private func confirmation(_ action: DashDangerAction) -> some View {
    VStack(spacing: 16) {
      Text(DashL10n.ui(action.message))
        .dashTextStyle(.supporting)
        .foregroundStyle(DashTheme.subtle)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 4)
        .padding(.top, 4)

      if let errorMessage {
        DashNotice(kind: .error, message: errorMessage)
      }

      DashTrayActionPair {
        DashTrayCancelButton {
          errorMessage = nil
          pending = nil
        }
        .disabled(actionPhase.isActive)
      } primary: {
        DashActionButton(
          title: DashL10n.ui(action.confirmTitle),
          role: .destructive,
          phase: actionPhase,
          morphID: reduceMotion ? nil : action.id,
          labelMorphID: reduceMotion ? nil : labelMorphID(action),
          morphNamespace: reduceMotion ? nil : morph,
          onSuccessPresentationCompleted: {
            guard actionPhase == .succeeded, pending?.id == action.id else { return }
            dismissAfter(action.onSuccessPresentationCompleted)
          },
          action: {
            Task {
              actionPhase = .loading
              errorMessage = nil
              do {
                try await action.perform()
                actionPhase = .succeeded
              } catch {
                actionPhase = .idle
                // Undo during an optimistic grace window cancels the write —
                // not a failure toast inside the confirm tray.
                guard !error.dashIsCancellation else { return }
                withAnimation(DashTheme.Motion.morph) { errorMessage = error.dashActionableMessage }
                DashDelight.failError()
              }
            }
          }
        )
        .disabled(actionPhase.isActive)
      }
    }
  }
}

/// The primary filled pill a tray should use when it has any footer actions —
/// at least one of these, with reversible extras as `DashTrayPillButton`. Idle
/// and confirming titles are separate views replaced by `DashTrayFlow` inside
/// `DashConfirmMorph`. Destructive confirms are a second tap after Cancel joins
/// the row — never a sustained hold.
struct DashActionButton: View {
  let title: String
  /// Optional leading asset-catalog icon (e.g. Cloudflare brand mark).
  var icon: String? = nil
  var role: ButtonRole? = nil
  var phase: DashActionPhase = .idle
  /// Optional matched-geometry id so a full-width pill (or danger row fill)
  /// can shrink into this confirm pill when Cancel joins the row.
  var morphID: String? = nil
  /// Optional companion id for the title run, so the originating row's label
  /// glides into this pill's label alongside the surface morph.
  var labelMorphID: String? = nil
  var morphNamespace: Namespace.ID? = nil
  var onSuccessPresentationCompleted: (@MainActor () -> Void)? = nil
  let action: () -> Void
  @Environment(\.dashTrayTone) private var trayTone
  @Environment(\.dashTraySuccessFlightEnabled) private var successFlightEnabled
  @Environment(\.dashTraySuccessFlightInProgress) private var successFlightInProgress

  /// Destructive keeps danger red whatever the tray's context. Otherwise a
  /// toned tray colors its submit pill (Family's contextual tray) with the
  /// tone's vivid stop; the label comes from `vividLabel`, which flips to
  /// near-black ink for mid-luminance fills like brand orange.
  private var fill: Color {
    if role == .destructive { return DashTheme.danger }
    return trayTone?.vivid ?? DashTheme.strong
  }
  /// Danger pills stay white in both schemes — adaptive `inverse` goes dark in
  /// Dark Mode and washes out on red. Non-destructive pills pair the tone's
  /// `vividLabel` with its vivid fill, or keep `inverse` on neutral `strong`.
  private var labelForeground: Color {
    if role == .destructive { return Color(hex: 0xF5F5F5) }
    return trayTone?.vividLabel ?? DashTheme.inverse
  }

  var body: some View {
    Button(action: action) {
      label
    }
    .buttonStyle(DashPressButtonStyle())
    .disabled(phase.isActive)
    // Explicit: the title now renders as segmented runs inside
    // `DashMorphingLabel`, so the button names itself instead of relying on
    // label aggregation across the segments.
    .accessibilityLabel(DashL10n.ui(title))
    .accessibilityValue(phase.accessibilityValue)
    .dashTrayDismissDisabled(phase.isActive)
  }

  private var label: some View {
    // Fixed height — not `minHeight` — so the primary action never stretches
    // when its content sits inside a bounded, scrolling compact tray.
    let face =
      enamelFace
      .frame(maxWidth: .infinity)
      .frame(height: DashTheme.Layout.actionPillHeight)
      .clipShape(DashTheme.pillShape)
      .overlay(alignment: .trailing) {
        DashActionStatusIcon(
          phase: phase,
          loadingColor: labelForeground,
          onSuccessPresentationCompleted: onSuccessPresentationCompleted
        )
        // Liftoff slot for the tray host's success-check flight. The R2
        // create flow keeps `.succeeded` mounted until the cover unmounts, so
        // a keyboard can settle the card before dismissal without losing the
        // current start point.
        .background {
          if successFlightEnabled, phase == .succeeded {
            DashTraySuccessFlightSourceReporter()
          }
        }
        .opacity(successFlightInProgress ? 0 : 1)
        .padding(.trailing, 18)
      }

    // Chrome-only emboss so matchedGeometryEffect stays single-instance
    // (full `dashEmbossed` duplicates its content for the press sink).
    return Group {
      if let morphID, let morphNamespace {
        face.matchedGeometryEffect(id: morphID, in: morphNamespace)
      } else {
        face
      }
    }
    .dashEmbossChrome(.pigmented, shape: DashTheme.pillShape)
  }

  /// The title as a character-run morphing label; a `labelMorphID` also pins
  /// it into the shared matched-geometry space so the text layer travels with
  /// the surface during row → confirm-pill morphs.
  @ViewBuilder private var titleLabel: some View {
    let label = DashMorphingLabel(text: DashL10n.ui(title))
    if let labelMorphID, let morphNamespace {
      label.matchedGeometryEffect(id: labelMorphID, in: morphNamespace)
    } else {
      label
    }
  }

  private var enamelFace: some View {
    ZStack {
      DashGrainSurface(color: fill, shape: .capsule, intensity: 0.055)

      HStack(spacing: 8) {
        if let icon {
          SolarIcon(asset: icon, size: 20, color: labelForeground)
        }
        // Status-y title swaps morph per character run instead of hard
        // cross-fading; static titles render identically to a plain `Text`.
        titleLabel
          .dashTextStyle(.button)
          .foregroundStyle(labelForeground)
          // Half a row wide when a cancel shares it: a long confirm verb
          // tightens rather than wrapping inside the fixed pill height.
          .lineLimit(1)
          .minimumScaleFactor(0.8)
      }
    }
  }
}

/// Sub-action pill for tray accessories under a primary `DashActionButton` —
/// reversible writes (copy, mute, rename, enable/disable). Never the sole
/// footer control when the tray offers a clear primary verb.
struct DashTrayPillButton: View {
  let title: String
  var phase: DashActionPhase = .idle
  var onSuccessPresentationCompleted: (@MainActor () -> Void)? = nil
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(DashL10n.ui(title))
        .dashTextStyle(.buttonBold)
        .foregroundStyle(DashTheme.strong)
        .frame(maxWidth: .infinity)
        .frame(height: DashTheme.Layout.actionPillHeight)
        .overlay(alignment: .trailing) {
          DashActionStatusIcon(
            phase: phase,
            loadingColor: DashTheme.strong,
            onSuccessPresentationCompleted: onSuccessPresentationCompleted
          )
          .padding(.trailing, 18)
        }
        .background(DashTheme.recessed, in: DashTheme.pillShape)
        .dashShadow(.border, in: DashTheme.pillShape)
    }
    .buttonStyle(DashPressButtonStyle())
    .disabled(phase.isActive)
    .accessibilityValue(phase.accessibilityValue)
    .dashTrayDismissDisabled(phase.isActive)
  }
}

// MARK: - Header more menu

/// Trailing toolbar button that opens a `dashMoreMenu` tray of danger actions.
struct DashMoreButton: View {
  @Binding var isPresented: Bool
  var accessibilityLabel = "More actions"

  var body: some View {
    DashToolbarIconButton(
      asset: SolarAsset.menuDots,
      accessibilityLabel: accessibilityLabel
    ) {
      isPresented = true
    }
  }
}

extension View {
  /// Attaches a tray of high-risk actions, each morphing to a confirmation step.
  func dashMoreMenu(
    isPresented: Binding<Bool>,
    title: String = "Actions",
    actions: [DashDangerAction]
  ) -> some View {
    dashTray(isPresented: isPresented, title: title) {
      DashConfirmableActions(actions: actions)
    }
  }
}

extension Error {
  var dashActionableMessage: String {
    DashFailurePresentation.from(error: self).message
  }

  /// Task / URLSession cancellations from `.task` identity changes — not user-facing failures.
  var dashIsCancellation: Bool {
    self is CancellationError || (self as? URLError)?.code == .cancelled
  }

  /// Structural absence for optional Cloudflare surfaces. Keep this exact:
  /// transport and server failures must remain visible, while a 403/404 may
  /// mean the account has not provisioned that resource.
  var dashIsResourceAbsent: Bool {
    guard
      let apiError = self as? CloudflareAPIError,
      case .request(let status, _) = apiError
    else { return false }
    return status == 403 || status == 404
  }
}

/// Maps Cloudflare / transport failures to a primary recovery action.
enum DashFailureAction: Equatable, Sendable {
  case signInAgain
  case grantAccess
  case tryAgain

  var title: String {
    switch self {
    case .signInAgain: "Sign in again"
    case .grantAccess: "Grant access"
    case .tryAgain: "Try again"
    }
  }
}

struct DashFailurePresentation: Equatable, Sendable {
  let message: String
  let action: DashFailureAction

  static func from(error: Error) -> DashFailurePresentation {
    if let apiError = error as? CloudflareAPIError, apiError.isUnauthorized {
      return DashFailurePresentation(
        message: "Your Cloudflare session is no longer valid. Sign in again.",
        action: .signInAgain)
    }
    if let apiError = error as? CloudflareAPIError, apiError.isForbidden {
      return DashFailurePresentation(
        message:
          "Dash doesn’t have access to this resource. Grant access, or confirm the active account includes it.",
        action: .grantAccess)
    }
    if let apiError = error as? CloudflareAPIError, apiError.isRateLimited {
      return DashFailurePresentation(
        message: "Rate limited by Cloudflare — wait a moment and try again.",
        action: .tryAgain)
    }
    if let apiError = error as? CloudflareAPIError {
      switch apiError {
      case .transport:
        return DashFailurePresentation(
          message: "Dash couldn’t reach Cloudflare. Check your connection and try again.",
          action: .tryAgain)
      case .invalidResponse:
        return DashFailurePresentation(
          message: "Cloudflare returned a response Dash couldn’t read. Try again.",
          action: .tryAgain)
      case .oauth:
        return DashFailurePresentation(
          message: "Cloudflare couldn’t complete sign-in. Try again.",
          action: .tryAgain)
      case .request(let status, let errors):
        if status == 404 {
          return DashFailurePresentation(
            message:
              "Cloudflare couldn’t find this resource. It may have been removed or belong to another account.",
            action: .tryAgain)
        }
        if status == 400 || status == 422 {
          return DashFailurePresentation(
            message: Self.cloudflareRequestDetail(from: errors)
              ?? "Cloudflare couldn’t process this request. Check the resource and try again.",
            action: .tryAgain)
        }
        if status >= 500 {
          return DashFailurePresentation(
            message: "Cloudflare is temporarily unavailable. Try again in a moment.",
            action: .tryAgain)
        }
        return DashFailurePresentation(
          message: Self.cloudflareRequestDetail(from: errors)
            ?? "Cloudflare couldn’t complete this request. Try again.",
          action: .tryAgain)
      }
    }
    if error is URLError {
      return DashFailurePresentation(
        message: "Dash couldn’t reach Cloudflare. Check your connection and try again.",
        action: .tryAgain)
    }
    return DashFailurePresentation(
      message: error.localizedDescription,
      action: .tryAgain)
  }

  static func from(message: String) -> DashFailurePresentation {
    let lower = message.lowercased()
    if lower.contains("sign in again") || lower.contains("session is no longer valid") {
      return DashFailurePresentation(message: message, action: .signInAgain)
    }
    if lower.contains("permission denied") || lower.contains("grant access")
      || lower.contains("forbidden") || lower.contains("granted scopes")
      || lower.contains("may not include this product")
    {
      return DashFailurePresentation(message: message, action: .grantAccess)
    }
    return DashFailurePresentation(message: message, action: .tryAgain)
  }

  /// Prefer Cloudflare's envelope messages (e.g. "Record already exists") over a
  /// status-only fallback so write forms can show something actionable.
  private static func cloudflareRequestDetail(from errors: [APIErrorItem]) -> String? {
    let messages =
      errors
      .map { $0.message.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard !messages.isEmpty else { return nil }
    return messages.joined(separator: "\n")
  }
}
