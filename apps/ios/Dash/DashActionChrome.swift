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

struct DashPillButton: View {
  let title: String
  /// Optional leading asset-catalog icon.
  var icon: String?
  var isLoading = false
  /// Disabled state with the shared 0.45 dim; loading disables without dimming.
  var isEnabled = true
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
      .frame(maxWidth: .infinity, minHeight: 52)
      .overlay(alignment: .trailing) {
        if isLoading {
          DashLoadingRing()
            .padding(.trailing, 18)
        }
      }
      .background(DashTheme.strong, in: DashTheme.pillShape)
    }
    .buttonStyle(DashPressButtonStyle())
    .disabled(isLoading || !isEnabled)
    .opacity(isEnabled ? 1 : 0.45)
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
      .frame(maxWidth: .infinity, minHeight: 52)
      .background(DashTheme.recessed, in: DashTheme.pillShape)
      .dashShadow(.border, in: DashTheme.pillShape)
  }
}

// MARK: - Danger confirmation morph

private struct DashBlurModifier: ViewModifier {
  let radius: CGFloat
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
/// destructive action needs a hold-to-confirm (purge, delete). Confirmation is
/// always Cancel + a named hold button — never a type-the-name field. Sign out
/// stays a plain tap — hold is reserved for delete-class business actions.
struct DashDangerAction: Identifiable {
  /// Stable across re-renders — it drives the matchedGeometryEffect morph, so it
  /// must NOT be a fresh UUID per render. Defaults to `title`.
  let id: String
  let title: String
  let icon: String
  let message: String
  /// Hold-confirm footer label. Delete-class actions keep the default; non-delete
  /// verbs (purge) pass their own.
  let confirmTitle: String
  /// A thrown error keeps the confirmation open and surfaces the message
  /// inline; only a clean return dismisses the tray.
  let perform: () async throws -> Void

  init(
    id: String? = nil,
    title: String,
    icon: String = SolarAsset.trash,
    message: String,
    confirmTitle: String = "Delete",
    perform: @escaping () async throws -> Void
  ) {
    self.id = id ?? title
    self.title = title
    self.icon = icon
    self.message = message
    self.confirmTitle = confirmTitle
    self.perform = perform
  }
}

/// Tray content that lists destructive actions as menu rows and morphs a tapped
/// one — via matchedGeometryEffect — into a confirm step (message, Cancel, and
/// a red hold-to-confirm Delete that the row grows into). No type-the-name
/// field. Horizontal insets come from the tray card, never from here.
struct DashConfirmableActions: View {
  let actions: [DashDangerAction]
  @Namespace private var morph
  @State private var pending: DashDangerAction?
  @State private var working = false
  @State private var errorMessage: String?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dashTrayDismiss) private var dismiss

  var body: some View {
    ZStack {
      if let pending {
        confirmation(pending)
          .transition(reduceMotion ? .opacity : .dashMorph)
      } else {
        menu
          .transition(reduceMotion ? .opacity : .dashMorph)
      }
    }
  }

  private var menu: some View {
    VStack(spacing: 10) {
      ForEach(actions) { action in
        Button {
          errorMessage = nil
          withAnimation(DashTheme.Motion.morph) { pending = action }
        } label: {
          dangerRow(action)
        }
        .buttonStyle(DashSurfaceButtonStyle())
      }
    }
  }

  // List-item styled as a compact tray row, with an outline icon.
  private func dangerRow(_ action: DashDangerAction) -> some View {
    HStack(spacing: 12) {
      SolarIcon(asset: action.icon, size: 22, color: DashTheme.danger)
      Text(DashL10n.ui(action.title))
        .dashTextStyle(.bodyMedium)
        .foregroundStyle(DashTheme.danger)
        .lineLimit(1)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      dangerBackground(action)
    }
  }

  @ViewBuilder
  private func dangerBackground(_ action: DashDangerAction) -> some View {
    let shape = RoundedRectangle(cornerRadius: DashTheme.Radius.button, style: .continuous)
    if reduceMotion {
      shape.fill(DashTheme.dangerTint)
    } else {
      shape
        .fill(DashTheme.dangerTint)
        .matchedGeometryEffect(id: action.id, in: morph)
    }
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

      VStack(spacing: 4) {
        Button {
          errorMessage = nil
          withAnimation(DashTheme.Motion.morphExit) { pending = nil }
        } label: {
          Text(DashL10n.string("Cancel"))
            .dashTextStyle(.buttonMedium)
            .foregroundStyle(DashTheme.subtle)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(DashPressButtonStyle())
        .disabled(working)

        DashActionButton(
          title: DashL10n.ui(action.confirmTitle),
          role: .destructive,
          isLoading: working,
          holdToConfirm: true,
          morphID: reduceMotion ? nil : action.id,
          morphNamespace: reduceMotion ? nil : morph,
          action: {
            Task {
              working = true
              errorMessage = nil
              do {
                try await action.perform()
                dismiss()
              } catch {
                withAnimation(DashTheme.Motion.morph) { errorMessage = error.dashActionableMessage }
                DashDelight.failError()
                working = false
              }
            }
          }
        )
        .disabled(working)
      }
    }
  }
}

/// The primary filled pill a tray should use when it has any footer actions —
/// at least one of these, with reversible extras as `DashTrayPillButton`. Idle
/// and confirming titles are separate views that cross-dissolve via
/// `.dashMorph` inside `DashConfirmMorph`.
///
/// Pass `holdToConfirm: true` for Confirm / final destructive steps: the pill
/// keeps its enamel face, and a hard path-cut of primary ink (`#0A0A0A`) wipes
/// left→right. The action fires only on finger-up after the wipe completes;
/// dragging past the cancel slop flips the label to “Release to cancel”.
struct DashActionButton: View {
  let title: String
  /// Optional leading asset-catalog icon (e.g. Cloudflare brand mark).
  var icon: String? = nil
  var role: ButtonRole? = nil
  var isLoading = false
  /// Sustained press with a left-to-right black path-cut; confirms on release.
  var holdToConfirm = false
  /// Optional matched-geometry id so a danger row can morph into this pill.
  var morphID: String? = nil
  var morphNamespace: Namespace.ID? = nil
  let action: () -> Void

  @Environment(AppModel.self) private var model
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.isEnabled) private var isEnabled
  @AppStorage(DashInteractionPreferences.holdToConfirmKey) private var holdToConfirmEnabled =
    true
  @State private var holdProgress: CGFloat = 0
  @State private var isHolding = false
  /// Wipe finished while the finger is still down — waiting for release.
  @State private var holdArmed = false
  /// Finger dragged past `holdCancelSlop`; release will abort instead of confirm.
  @State private var holdWillCancel = false
  @State private var holdTask: Task<Void, Never>?
  @State private var holdStartedAt: Date?

  private var fill: Color { role == .destructive ? DashTheme.danger : DashTheme.strong }
  /// Fixed primary ink for the hold path-cut — not adaptive, so the wipe stays
  /// black in both schemes (same stop as light-mode `DashTheme.strong`).
  private var holdCutFill: Color { Color(hex: 0x0A0A0A) }
  /// Forced light ink on the cut face — pairs with `holdCutFill` regardless of
  /// scheme (adaptive `inverse` goes dark in Dark Mode and would vanish).
  private var holdCutForeground: Color { Color(hex: 0xF5F5F5) }
  /// Danger pills stay white in both schemes — adaptive `inverse` goes dark in
  /// Dark Mode and washes out on red. Non-destructive pills keep `inverse`.
  private var labelForeground: Color {
    role == .destructive ? holdCutForeground : DashTheme.inverse
  }
  private var holdDuration: TimeInterval { reduceMotion ? 0.7 : 1.2 }
  /// Finger travel (pt) that switches the hold into cancel-on-release.
  private var holdCancelSlop: CGFloat { 36 }
  /// Early release past this fraction of the hold earns the “keep holding” toast.
  private var holdCancelHintThreshold: TimeInterval { holdDuration * 0.2 }
  private var usesHoldConfirm: Bool { holdToConfirm && holdToConfirmEnabled }
  /// Generic Confirm / Hold to confirm pills follow the Settings toggle; named
  /// verbs (Sign out, Ignore all, …) keep their title and use the a11y hint.
  private var displayTitle: String {
    let isGenericConfirm = title == "Confirm" || title == "Hold to confirm"
    guard holdToConfirm, isGenericConfirm else { return title }
    return usesHoldConfirm ? "Hold to confirm" : "Confirm"
  }
  private var visibleHoldTitle: String {
    holdWillCancel ? DashL10n.string("Release to cancel") : displayTitle
  }

  var body: some View {
    Group {
      if usesHoldConfirm {
        holdButton
      } else {
        tapButton
      }
    }
    .disabled(isLoading)
    .onDisappear { resetHold(animated: false) }
  }

  private var tapButton: some View {
    Button(action: action) {
      label(progress: 0)
    }
    .buttonStyle(DashPressButtonStyle())
  }

  @ViewBuilder
  private var holdButton: some View {
    let labeled = label(progress: holdProgress)
      .scaleEffect(isHolding && !reduceMotion ? 0.97 : 1)
      .animation(reduceMotion ? nil : DashTheme.Motion.press, value: isHolding)
      .contentShape(DashTheme.pillShape)
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            beginHoldIfNeeded()
            updateHoldDrag(value)
          }
          .onEnded { _ in endHoldGesture() }
      )
      .accessibilityAddTraits(.isButton)
      .accessibilityLabel(DashL10n.ui(displayTitle))
      .accessibilityAction(.default) {
        guard isEnabled, !isLoading else { return }
        DashDelight.warnImpact()
        action()
      }
    // Named hold verbs keep an explicit hint; the generic label already says it.
    if displayTitle == "Hold to confirm" {
      labeled
    } else {
      labeled.accessibilityHint(DashL10n.string("Hold to confirm"))
    }
  }

  private func label(progress: CGFloat) -> some View {
    // Dual enamel faces share one silhouette. The cut layer is always mounted
    // and cropped by width so the hold animates as a hard left→right wipe:
    // black + white ink over the idle danger/strong face.
    let face = GeometryReader { geo in
      let cutWidth = max(0, geo.size.width * progress)
      ZStack(alignment: .leading) {
        enamelFace(fill: fill, foreground: labelForeground)
          .frame(width: geo.size.width, height: geo.size.height)

        enamelFace(fill: holdCutFill, foreground: holdCutForeground)
          .frame(width: geo.size.width, height: geo.size.height)
          .frame(width: cutWidth, alignment: .leading)
          .clipped()
          .allowsHitTesting(false)
      }
    }
    .frame(maxWidth: .infinity, minHeight: 52)
    .clipShape(DashTheme.pillShape)
    .overlay(alignment: .trailing) {
      if isLoading {
        DashLoadingRing()
          .padding(.trailing, 18)
      }
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

  /// Metal-grain pill face — fill + caption/icon painted as one unit so a
  /// progress crop cuts background and type on the same edge.
  private func enamelFace(fill: Color, foreground: Color) -> some View {
    ZStack {
      DashGrainSurface(color: fill, shape: .capsule, intensity: 0.055)

      HStack(spacing: 8) {
        if let icon {
          SolarIcon(asset: icon, size: 20, color: foreground)
        }
        Text(DashL10n.ui(visibleHoldTitle))
          .dashTextStyle(.button)
          .foregroundStyle(foreground)
      }
      .id(visibleHoldTitle)
      .transition(reduceMotion ? .opacity : .dashMorph)
    }
  }

  private func beginHoldIfNeeded() {
    guard holdToConfirm, isEnabled, !isLoading, !isHolding else { return }
    isHolding = true
    holdArmed = false
    holdWillCancel = false
    holdStartedAt = Date()
    holdProgress = 0
    withAnimation(.linear(duration: holdDuration)) {
      holdProgress = 1
    }
    holdTask?.cancel()
    holdTask = Task { @MainActor in
      // Soft ticks that ease louder toward the end, then a distinct medium hit
      // when the wipe arms — action still waits for finger-up.
      let tickCount = reduceMotion ? 4 : 7
      let tickNanos = UInt64((holdDuration / Double(tickCount)) * 1_000_000_000)
      let ramp = DashDelight.makeHoldRampGenerator()
      for tick in 1..<tickCount {
        // Ease-in so the ramp feels quiet at first, then builds.
        let t = CGFloat(tick) / CGFloat(tickCount)
        DashDelight.holdRampImpact(ramp, intensity: 0.18 + 0.72 * (t * t))
        try? await Task.sleep(nanoseconds: tickNanos)
        guard !Task.isCancelled else { return }
      }
      try? await Task.sleep(nanoseconds: tickNanos)
      guard !Task.isCancelled else { return }
      holdArmed = true
      holdTask = nil
      DashDelight.warnImpact()
    }
  }

  private func updateHoldDrag(_ value: DragGesture.Value) {
    guard isHolding else { return }
    let distance = hypot(value.translation.width, value.translation.height)
    let cancelling = distance >= holdCancelSlop
    guard cancelling != holdWillCancel else { return }
    holdWillCancel = cancelling
    if cancelling {
      DashDelight.lightImpact()
    }
  }

  private func endHoldGesture() {
    let shouldConfirm = holdArmed && !holdWillCancel
    let shouldHintKeepHolding =
      !shouldConfirm && !holdWillCancel && shouldShowHoldCancelHint()
    if shouldConfirm {
      DashDelight.warnImpact()
      action()
    }
    resetHold(animated: true)
    if shouldHintKeepHolding {
      model.toasts.warning(
        DashL10n.string("Keep holding to confirm delete."),
        title: DashL10n.string("Hold to confirm")
      )
    }
  }

  private func shouldShowHoldCancelHint() -> Bool {
    guard let holdStartedAt else { return false }
    return Date().timeIntervalSince(holdStartedAt) >= holdCancelHintThreshold
  }

  private func resetHold(animated: Bool) {
    holdTask?.cancel()
    holdTask = nil
    holdArmed = false
    holdWillCancel = false
    holdStartedAt = nil
    guard isHolding || holdProgress > 0 else { return }
    if animated {
      withAnimation(reduceMotion ? DashTheme.Motion.reduced : DashTheme.Motion.quick) {
        holdProgress = 0
        isHolding = false
      }
    } else {
      holdProgress = 0
      isHolding = false
    }
  }
}

/// Sub-action pill for tray accessories under a primary `DashActionButton` —
/// reversible writes (copy, mute, rename, enable/disable). Never the sole
/// footer control when the tray offers a clear primary verb.
struct DashTrayPillButton: View {
  let title: String
  var isLoading = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(DashL10n.ui(title))
        .dashTextStyle(.buttonBold)
        .foregroundStyle(DashTheme.strong)
        .frame(maxWidth: .infinity, minHeight: 52)
        .overlay(alignment: .trailing) {
          if isLoading {
            DashLoadingRing(color: DashTheme.strong)
              .padding(.trailing, 18)
          }
        }
        .background(DashTheme.recessed, in: DashTheme.pillShape)
        .dashShadow(.border, in: DashTheme.pillShape)
    }
    .buttonStyle(DashPressButtonStyle())
    .disabled(isLoading)
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
