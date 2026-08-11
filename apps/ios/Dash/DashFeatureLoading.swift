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
/// - **Warm** (`content` + `refreshing`): body stays in `.live` while automatic
///   refresh is visually quiet; pull-to-refresh owns its native indicator and
///   an optional error still lands as a shared banner. Refresh never remounts
///   placeholder mode.
/// - **Empty settled** (`empty`): zero items after a successful load → the same
///   placeholder body stays mounted and empty copy lands on the cold wash
///   (same mount as failure — never swap in a bare `DashEmptyState` that tears
///   the bars down). Nested empties inside an already-loaded detail stay in
///   live content.
/// - **Handoff**: the first cold → live transition animates with
///   `DashBodyTransition` — surplus placeholder slots recede (scale 0.97 +
///   blur + fade), overlapping slots cross-fade in place, and live rows keep
///   their entity identity through later inserts/reorders. Navigation push and
///   warm refresh must not add a second reveal.
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

/// Whether the settled cold body owns a prompt. Keeping this rule separate
/// from copy construction makes the loading-first contract explicit: a retry
/// with an old error still shows only the breathing placeholder until it ends.
enum DashColdOverlayIntent: Equatable {
  case failure(String)
  case empty
}

enum DashColdOverlayRules {
  static func intent(
    phase: DashListPhase,
    hasEmptyCopy: Bool
  ) -> DashColdOverlayIntent? {
    switch phase {
    case .loading, .content:
      return nil
    case .fullScreenError(let message):
      return .failure(message)
    case .empty:
      return hasEmptyCopy ? .empty : nil
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

struct DashBodyHandoffUpdate: Equatable {
  let mode: DashBodyMode
  let animates: Bool
}

/// Keeps the first frame honest while reserving motion for the one transition
/// that explains a load completing. A reverse live → placeholder reset is
/// immediate; Reduce Motion also switches without animating layout. A later
/// cold → live handoff may animate again for a new load.
enum DashBodyHandoffRules {
  static func update(
    displayed: DashBodyMode?,
    target: DashBodyMode,
    reduceMotion: Bool = false
  ) -> DashBodyHandoffUpdate? {
    guard displayed != target else { return nil }
    return DashBodyHandoffUpdate(
      mode: target,
      animates: !reduceMotion && displayed == .placeholder && target == .live)
  }
}

enum DashBodyListSlotRules {
  static func placeholderRecedes(index: Int, liveItemCount: Int) -> Bool {
    index >= max(liveItemCount, 0)
  }
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
  /// Write-site mirror: page-local tray modifiers disable descendant implicit
  /// animations, so the cold → live handoff must own its transaction here.
  @State private var displayedBodyMode: DashBodyMode?

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
        // Pad the shared error banner explicitly instead.
        LazyVStack(spacing: 0) {
          if case .content(let banner, _) = phase, let banner {
            failureBanner(banner)
              .padding(.bottom, DashTheme.Spacing.itemGap)
          }

          // One body identity across loading → failure/empty → live. Mode flips
          // drive slot replace / recede / append; the wash only veils
          // placeholder. Warm refresh never remounts `.placeholder`.
          content(displayedBodyMode ?? bodyMode)
            .dashColdOverlay(copy: coldOverlayCopy, extent: .scrollViewport)
            .dashFailureRemovalTransition()
        }
        .padding(.horizontal, DashTheme.Spacing.screen)
        // This gap belongs to the scroll content. Putting it on
        // DashFeatureScreen turns it into fixed header chrome.
        .padding(.top, DashTheme.Spacing.section)
        .padding(.bottom, DashTheme.Spacing.scrollBottomInset)
      }
      .scrollDismissesKeyboard(.interactively)
      .modifier(DashScrollEdgeEffectsHidden())
    }
    .onChange(of: bodyMode, initial: true) { _, next in
      updateDisplayedBodyMode(to: next)
    }
  }

  private func updateDisplayedBodyMode(to target: DashBodyMode) {
    guard
      let update = DashBodyHandoffRules.update(
        displayed: displayedBodyMode,
        target: target,
        reduceMotion: reduceMotion)
    else { return }

    if update.animates {
      withAnimation(DashBodyTransition.handoff) {
        displayedBodyMode = update.mode
      }
    } else {
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        displayedBodyMode = update.mode
      }
    }
  }

  private var coldOverlayCopy: DashColdOverlayCopy? {
    guard
      let intent = DashColdOverlayRules.intent(
        phase: phase,
        hasEmptyCopy: empty != nil)
    else { return nil }

    switch intent {
    case .failure(let message):
      let presentation = DashFailurePresentation.from(message: message)
      return DashColdOverlayCopy(
        icon: SolarAsset.Content.danger,
        title: "Couldn’t load",
        message: coldFailureMessage(for: presentation),
        actionTitle: presentation.action.title,
        action: { performColdFailureAction(presentation.action) }
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
    }
  }

  private func coldFailureMessage(for presentation: DashFailurePresentation) -> String {
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

  private func performColdFailureAction(_ action: DashFailureAction) {
    switch action {
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

private enum DashModeListSlotID<ItemID: Hashable>: Hashable {
  case placeholder(Int)
  case live(ItemID)
}

private enum DashModeListSlot<Item: Identifiable>: Identifiable {
  case placeholder(Int)
  case live(Item)

  var id: DashModeListSlotID<Item.ID> {
    switch self {
    case .placeholder(let index): .placeholder(index)
    case .live(let item): .live(item.id)
    }
  }
}

/// The one mode-aware list primitive. Cold placeholders own independent
/// positional slots; overlap cross-fades in place while only surplus
/// placeholders recede. Live rows keep `Item.ID`, so later inserts, removals,
/// filtering, and reordering never make surviving rows change identity. Live
/// rows deliberately get no helper-owned transition: the animated cold handoff
/// gives an inserted row SwiftUI's default fade, while a later live diff keeps
/// any transition the row itself declares (DNS / Pages use `.dashMorph`).
///
/// Keep this as a free `@ViewBuilder` function: wrapping the emitted `ForEach` in
/// an opaque `View` or eager stack would defeat `DashFeatureList`'s lazy rows.
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
  let slots: [DashModeListSlot<Item>] =
    mode.isPlaceholder
    ? (0..<max(placeholderRows, 1)).map { .placeholder($0) }
    : items.map { .live($0) }
  ForEach(slots) { slot in
    switch slot {
    case .placeholder(let index):
      let transition =
        DashBodyListSlotRules.placeholderRecedes(index: index, liveItemCount: items.count)
        ? DashBodyTransition.content(reduceMotion) : AnyTransition.opacity
      DashListRowPlaceholder()
        .modifier(DashListCardInsetModifier(enabled: inset))
        .transition(transition)
    case .live(let item):
      row(item)
        .modifier(DashListCardInsetModifier(enabled: inset))
    }
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
