import SwiftUI
import UIKit

/// Feature drill-down shell: fixed chrome above scrollable content.
struct DashFeatureScreen<Chrome: View, Content: View>: View {
  @ViewBuilder var chrome: () -> Chrome
  @ViewBuilder var content: () -> Content

  init(
    @ViewBuilder chrome: @escaping () -> Chrome,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.chrome = chrome
    self.content = content
  }

  var body: some View {
    // `DashPageChromeHost` keeps fixed chrome (text tabs) above the header
    // frost — same stacking as the nav title — and sizes the scroll slot to
    // the remaining height so the list scrolls instead of clipping.
    DashPageChromeHost(chrome: chrome) {
      content()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(DashTheme.canvas)
  }
}

extension DashFeatureScreen where Chrome == EmptyView {
  init(@ViewBuilder content: @escaping () -> Content) {
    self.init(chrome: { EmptyView() }, content: content)
  }
}

/// What a feature list should render for a given load/error/content state.
///
/// Loading contract (lists):
/// - **Cold** (`loading`): no cached primary payload → one feature body in
///   `DashBodyMode.placeholder` (same structure as live; redacted / geometric
///   stand-ins). Never paint an empty shell with “Updating…”.
/// - **Warm** (`content` + `refreshing`): body stays in `.live` with the inline
///   “Updating…” strip (and optional error banner). Refresh never remounts
///   placeholder mode.
/// - **Empty settled** (`empty`): zero items after a successful load → the same
///   placeholder body stays mounted and empty copy lands on the cold wash
///   (same mount as failure — never swap in a bare `DashEmptyState` that tears
///   the bars down). Nested empties inside an already-loaded detail stay in
///   live content.
/// - **Handoff**: the first cold → live transition animates with
///   `DashBodyTransition` — surplus placeholder slots recede (scale 0.97 +
///   blur + fade), extra live slots insert; index-aligned slots replace in
///   place. Navigation push and warm refresh must not add a second reveal.
/// - **Section cold** (not this enum): secondary fetches inside an already-loaded
///   detail (build log, traffic chart, preview) may use a local ring + short copy.
///
/// Cache-first: when `hasContent` is true, refresh never returns to Cold.
enum DashListPhase: Equatable {
  case loading
  case fullScreenError(String)
  case empty
  case content(banner: String?, refreshing: Bool)

  static func resolve(isLoading: Bool, error: String?, hasContent: Bool) -> DashListPhase {
    if hasContent {
      return .content(banner: error, refreshing: isLoading)
    }
    if isLoading { return .loading }
    if let error { return .fullScreenError(error) }
    // Settled with nothing to show. Call sites that always paint chrome
    // (chart detail snapshots, settings screens with alerts,
    // dual-fetch pages where one half can be empty) must pass
    // `hasContent: true` / `hasPresentedContent` after settle — the default
    // `false` leaves the skeleton up forever, with or without `empty:`.
    return .empty
  }

  /// Placeholder body for cold / empty / failure; live body once `hasContent`.
  var bodyMode: DashBodyMode {
    switch self {
    case .loading, .fullScreenError, .empty: return .placeholder
    case .content: return .live
    }
  }
}

/// Paint mode for a feature body's single structure tree.
enum DashBodyMode: Equatable, Sendable {
  /// Cold / empty / failure — same layout as live, non-interactive stand-ins.
  case placeholder
  /// Settled primary payload — real values and controls.
  case live

  var isPlaceholder: Bool { self == .placeholder }
}

/// Soft blur stand-in for body-slot removal (same device as tray `.dashMorph`).
private struct DashBodyBlurModifier: ViewModifier, Animatable {
  var radius: CGFloat

  nonisolated var animatableData: CGFloat {
    get { radius }
    set { radius = newValue }
  }

  func body(content: Content) -> some View {
    content.blur(radius: radius)
  }
}

/// Slot insert/remove transitions for placeholder ↔ live count deltas.
enum DashBodyTransition {
  /// Surplus placeholders recede in place (scale to 0.97 + blur + fade); new
  /// live slots fade in. No slide — that fought the navigation push and read
  /// as an upward exit. Isolation-free so `dashModeListRows` can apply it from
  /// a `@ViewBuilder` free function.
  nonisolated static func content(_ reduceMotion: Bool) -> AnyTransition {
    if reduceMotion { return .opacity }
    let dissolve = AnyTransition.opacity.combined(
      with: .modifier(
        active: DashBodyBlurModifier(radius: 3),
        identity: DashBodyBlurModifier(radius: 0)))
    return .asymmetric(
      insertion: .opacity,
      removal: dissolve.combined(with: .scale(scale: 0.97))
    )
  }

  /// Animation applied when `DashBodyMode` flips cold → live once. Slower than
  /// `Motion.morph` so the scale/blur/fade on surplus slots can read.
  @MainActor
  static var handoff: Animation {
    UIAccessibility.isReduceMotionEnabled
      ? DashTheme.Motion.reduced
      : DashTheme.Motion.softLanding(duration: 0.48)
  }
}

/// Reserved placeholder counts for fuller cold paint (over-reserve; extras exit).
enum DashBodyPlaceholderDepth {
  static let listRows = 4
  static let domainCards = 6
  static let infoRows = 4
}

/// Settled-empty copy for a `DashFeatureList` — lands on the same placeholder
/// body + wash as a cold failure, with the call site's mark and an optional CTA.
struct DashFeatureEmpty {
  var icon: String
  var title: String
  var message: String
  var actionTitle: String? = nil
  var action: (() -> Void)? = nil
}

/// Shared feature list: loading/error/empty slots, grouped list chrome.
///
/// One `@ViewBuilder` body receives `DashBodyMode` so cold and live share
/// structure. Settled empty and cold failure keep that same body in
/// `.placeholder` under the wash. The first flip to `.live` uses
/// `DashBodyTransition.handoff`; warm refresh stays on `.live`.
struct DashFeatureList<Header: View, Content: View>: View {
  var isLoading: Bool = false
  var error: String?
  /// Whether the content phase may paint. Defaults to `false` for cold lists;
  /// snapshot screens and details whose body mounts chrome independent of the
  /// primary rows must set this once settled (`true` or `hasPresentedContent`),
  /// never derive it only from a subset of optional rows.
  var hasContent: Bool = false
  /// Primary-list empty (zero items after a successful load). Detail screens
  /// that never settle empty may omit it; the empty phase then shows the
  /// placeholder body alone until a call site supplies copy — and forever if
  /// `hasContent` was left false by mistake.
  var empty: DashFeatureEmpty? = nil
  var retry: () -> Void
  @ViewBuilder var header: () -> Header
  @ViewBuilder var content: (DashBodyMode) -> Content
  @Environment(AppModel.self) private var model
  @Environment(\.featureRequiredScopes) private var featureRequiredScopes
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(
    isLoading: Bool = false,
    error: String? = nil,
    hasContent: Bool = false,
    empty: DashFeatureEmpty? = nil,
    retry: @escaping () -> Void = {},
    @ViewBuilder header: @escaping () -> Header,
    @ViewBuilder content: @escaping (DashBodyMode) -> Content
  ) {
    self.isLoading = isLoading
    self.error = error
    self.hasContent = hasContent
    self.empty = empty
    self.retry = retry
    self.header = header
    self.content = content
  }

  private var phase: DashListPhase {
    DashListPhase.resolve(isLoading: isLoading, error: error, hasContent: hasContent)
  }

  private var bodyMode: DashBodyMode { phase.bodyMode }

  var body: some View {
    DashFeatureScreen(chrome: header) {
      ScrollView {
        // Spacing must stay 0: `dashListCardRows` flattens its ForEach into this
        // stack so rows stay lazy. Section spacing here would gap every row
        // (Workers/Pages looked sparse vs Resources' DashListGroup VStack(0)).
        // Pad chrome blocks (Updating… / error banner) explicitly instead.
        LazyVStack(spacing: 0) {
          if case .content(let banner, let refreshing) = phase {
            if refreshing {
              HStack(spacing: DashTheme.Spacing.compact) {
                DashLoadingRing(color: DashTheme.brand, size: 16, lineWidth: 2.5)
                Text("Updating…")
                  .dashTextStyle(.footnote)
                  .foregroundStyle(DashTheme.subtle)
                Spacer(minLength: 0)
              }
              .accessibilityElement(children: .combine)
              .accessibilityLabel("Updating")
              .padding(.bottom, DashTheme.Spacing.itemGap)
            }
            if let banner {
              failureBanner(banner)
                .padding(.bottom, DashTheme.Spacing.itemGap)
            }
          }

          // One body identity across loading → failure/empty → live. Mode flips
          // drive slot replace / recede / append; the wash only veils
          // placeholder. Warm refresh never remounts `.placeholder`.
          content(bodyMode)
            .dashColdOverlay(copy: coldOverlayCopy, extent: .scrollViewport)
            .dashFailureRemovalTransition()
        }
        .animation(
          reduceMotion ? DashTheme.Motion.reduced : DashBodyTransition.handoff,
          value: bodyMode
        )
        .padding(.horizontal, DashTheme.Spacing.screen)
        // This gap belongs to the scroll content. Putting it on
        // DashFeatureScreen turns it into fixed header chrome.
        .padding(.top, DashTheme.Spacing.section)
        .padding(.bottom, DashTheme.Spacing.scrollBottomInset)
      }
      .scrollDismissesKeyboard(.interactively)
      .modifier(DashScrollEdgeEffectsHidden())
    }
  }

  private var coldOverlayCopy: DashColdOverlayCopy? {
    switch phase {
    case .loading:
      return nil
    case .fullScreenError:
      guard let message = coldFailureMessage else { return nil }
      return DashColdOverlayCopy(
        icon: SolarAsset.Content.danger,
        title: "Couldn’t load",
        message: message,
        actionTitle: coldFailureActionTitle,
        action: coldFailureAction
      )
    case .empty:
      guard let empty else { return nil }
      return DashColdOverlayCopy(
        icon: empty.icon,
        title: empty.title,
        message: empty.message,
        actionTitle: empty.actionTitle,
        action: empty.action
      )
    case .content:
      return nil
    }
  }

  private var coldFailurePresentation: DashFailurePresentation? {
    error.map(DashFailurePresentation.from(message:))
  }

  private var coldFailureActionTitle: String {
    coldFailurePresentation?.action.title ?? "Try again"
  }

  private var coldFailureMessage: String? {
    guard let presentation = coldFailurePresentation else { return nil }
    if presentation.action == .grantAccess, !model.isDemoSession {
      return [
        presentation.message,
        DashL10n.string(
          "Dash requests all permissions used by its current features in one authorization."
        ),
      ].joined(separator: " ")
    }
    return presentation.message
  }

  private func coldFailureAction() {
    switch coldFailurePresentation?.action {
    case .signInAgain:
      Task { await model.signOut() }
    case .grantAccess:
      model.requestAccess(
        to: featureRequiredScopes.isEmpty
          ? DashAuthorizationScopes.initialReadOnly : featureRequiredScopes)
    case .tryAgain, .none:
      retry()
    }
  }

  @ViewBuilder
  private func failureBanner(_ message: String) -> some View {
    let presentation = DashFailurePresentation.from(message: message)
    VStack(alignment: .leading, spacing: DashTheme.Spacing.compact) {
      DashNotice(kind: .error, message: presentation.message)
      if presentation.action == .grantAccess {
        DashAuthorizationDisclosure()
      }
      DashSecondaryPillButton(title: presentation.action.title) {
        switch presentation.action {
        case .signInAgain:
          Task { await model.signOut() }
        case .grantAccess:
          model.requestAccess(
            to: featureRequiredScopes.isEmpty
              ? DashAuthorizationScopes.initialReadOnly : featureRequiredScopes)
        case .tryAgain:
          retry()
        }
      }
    }
  }
}

extension DashFeatureList where Header == EmptyView {
  init(
    isLoading: Bool = false,
    error: String? = nil,
    hasContent: Bool = false,
    empty: DashFeatureEmpty? = nil,
    retry: @escaping () -> Void = {},
    @ViewBuilder content: @escaping (DashBodyMode) -> Content
  ) {
    self.init(
      isLoading: isLoading,
      error: error,
      hasContent: hasContent,
      empty: empty,
      retry: retry,
      header: { EmptyView() },
      content: content
    )
  }
}

/// Redact + pulse + freeze interaction while a shared body is in placeholder mode.
extension View {
  @ViewBuilder
  func dashBodyPlaceholder(_ active: Bool) -> some View {
    if active {
      self
        .redacted(reason: .placeholder)
        .dashSkeletonPulse()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    } else {
      self
    }
  }

  nonisolated func dashBodySlot(reduceMotion: Bool) -> some View {
    transition(DashBodyTransition.content(reduceMotion))
  }
}

/// Index-stable catalog rows: placeholder count → live count with receding
/// surplus slots (scale + blur + fade) and in-place replace for overlap.
@MainActor
@ViewBuilder
func dashModeListRows<Item: Identifiable, Row: View>(
  mode: DashBodyMode,
  items: [Item],
  placeholderRows: Int = DashBodyPlaceholderDepth.listRows,
  reduceMotion: Bool,
  inset: Bool = true,
  @ViewBuilder row: @escaping (Item) -> Row
) -> some View {
  let count = mode.isPlaceholder ? max(placeholderRows, 1) : items.count
  ForEach(0..<count, id: \.self) { index in
    Group {
      if mode.isPlaceholder {
        DashListRowPlaceholder()
      } else {
        row(items[index])
      }
    }
    .modifier(DashListCardInsetModifier(enabled: inset))
    .dashBodySlot(reduceMotion: reduceMotion)
  }
}

private struct DashListCardInsetModifier: ViewModifier {
  var enabled: Bool

  func body(content: Content) -> some View {
    if enabled {
      content.dashListCardInset()
    } else {
      content
    }
  }
}

/// Cold-load failure for a feature list: the same placeholder body the loading
/// phase painted stays on screen and the failure lands on a wash over it
/// (`dashColdFailure`). Prefer keeping that body mounted in the caller
/// (see `DashFeatureList`) so loading → error never remounts the bars; this
/// type remains for one-off call sites that already own a discrete failure view.
struct ErrorStateView<Skeleton: View>: View {
  let message: String
  let retry: () -> Void
  @ViewBuilder var skeleton: () -> Skeleton
  @Environment(AppModel.self) private var model
  @Environment(\.featureRequiredScopes) private var featureRequiredScopes

  private var presentation: DashFailurePresentation {
    DashFailurePresentation.from(message: message)
  }

  var body: some View {
    skeleton()
      .dashColdFailure(
        message:
          presentation.action == .grantAccess && !model.isDemoSession
          ? [
            presentation.message,
            DashL10n.string(
              "Dash requests all permissions used by its current features in one authorization."
            ),
          ].joined(separator: " ")
          : presentation.message,
        actionTitle: presentation.action.title,
        extent: .scrollViewport,
        action: recover)
  }

  private func recover() {
    switch presentation.action {
    case .signInAgain:
      Task { await model.signOut() }
    case .grantAccess:
      model.requestAccess(
        to: featureRequiredScopes.isEmpty
          ? DashAuthorizationScopes.initialReadOnly : featureRequiredScopes)
    case .tryAgain:
      retry()
    }
  }
}

/// Explains the real OAuth boundary before any access-recovery control opens
/// Cloudflare. Dash currently upgrades real accounts to the complete reviewed
/// scope set, even when the missing permission belongs to one feature.
struct DashAuthorizationDisclosure: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    if !model.isDemoSession {
      Text(
        DashL10n.string(
          "Dash requests all permissions used by its current features in one authorization."
        )
      )
      .dashTextStyle(.caption)
      .foregroundStyle(DashTheme.subtle)
      .fixedSize(horizontal: false, vertical: true)
    }
  }
}
