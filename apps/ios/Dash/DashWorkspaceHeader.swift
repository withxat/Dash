import SwiftUI

// MARK: - Slot model

/// The leading slot's one occupant. Avatar, Back, Close and a page's own
/// leading action are the SAME seat — that is the whole point of the shared
/// header: they trade places inside one control-sized slot instead of each
/// page shipping its own bar that slides in with the page.
enum DashWorkspaceHeaderLeading: Equatable {
  case empty
  case profile
  case dismissal(DashNavigationDismissal)
  case action(DashPageActionDescriptor)
  case watchtowerEditorCancel
}

/// The trailing slot's occupant. Root controls and page actions are branches of
/// one slot for the same reason.
enum DashWorkspaceHeaderTrailing: Equatable {
  case empty
  case watchtowerInbox
  case watchtowerEditor
  case actions([DashPageActionDescriptor])
}

struct DashWorkspaceHeaderState: Equatable {
  /// The page these slots belong to; nil on a tab root. Part of the state's
  /// equality on purpose: a page change whose title / trailing actually differ
  /// must still animate those seats even when the leading control looks the
  /// same (Back → Back on a card expand).
  var entryID: DashNavigationEntry.ID?
  var leading: DashWorkspaceHeaderLeading = .empty
  var title: DashPageHeaderDescriptor?
  var trailing: DashWorkspaceHeaderTrailing = .empty
}

/// A slot's occupant identity — the page it belongs to plus which kind of
/// occupant it is. Trailing uses this so a page change cross-fades actions
/// while an in-page change (a Save becoming enabled) updates in place.
struct DashWorkspaceHeaderSlotID: Hashable {
  let entryID: DashNavigationEntry.ID?
  let kind: Int
}

extension DashWorkspaceHeaderLeading {
  /// Visual seat identity for the leading control. Back and Close are
  /// different seats (glyph change); Back on page A and Back on page B are
  /// the SAME seat — keying those apart forced a glass morph between two
  /// identical chevrons on every card expand / drill.
  var slotKind: Int {
    switch self {
    case .empty: 0
    case .profile: 1
    case .dismissal(.back): 2
    case .dismissal(.closeToWorkspaceRoot): 3
    case .action: 4
    case .watchtowerEditorCancel: 5
    }
  }
}

extension DashWorkspaceHeaderTrailing {
  var slotKind: Int {
    switch self {
    case .empty: 0
    case .watchtowerInbox: 1
    case .watchtowerEditor: 2
    case .actions: 3
    }
  }
}

enum DashWorkspaceHeaderRules {
  /// One resolution for every page in the workspace. A tab root shows the
  /// account identity and whatever that root floats; a pushed page shows its
  /// own dismissal, title and actions. A page's leading action replaces the
  /// dismissal outright — the same override the page-local bar always applied,
  /// and the same one VoiceOver Escape mirrors.
  static func state(
    entry: DashNavigationEntry?,
    chrome: DashPageChromePreference?,
    holdoverTitle: DashPageHeaderDescriptor?,
    showsProfileControl: Bool,
    showsWatchtowerInbox: Bool,
    isEditingWatchtower: Bool
  ) -> DashWorkspaceHeaderState {
    guard let entry else {
      if isEditingWatchtower {
        return DashWorkspaceHeaderState(
          entryID: nil,
          leading: .watchtowerEditorCancel,
          title: nil,
          trailing: .watchtowerEditor)
      }
      // Tab roots keep an empty title slot on purpose: a drill-down is the
      // moment a title exists at all, so the slot has something to say.
      return DashWorkspaceHeaderState(
        entryID: nil,
        leading: showsProfileControl ? .profile : .empty,
        title: nil,
        trailing: showsWatchtowerInbox ? .watchtowerInbox : .empty)
    }

    let trailingActions = chrome?.trailingActions ?? []
    let leading: DashWorkspaceHeaderLeading =
      if let leadingAction = chrome?.leadingActions.first {
        .action(leadingAction)
      } else {
        .dismissal(entry.dismissal)
      }
    return DashWorkspaceHeaderState(
      entryID: entry.id,
      leading: leading,
      // A page that has not published yet holds the last title on screen
      // rather than blanking the slot. `chrome == nil` is "has not spoken",
      // NOT "has no title" — a screen that genuinely wants no title publishes
      // a preference whose header is nil, and that clears the slot properly.
      // Without this every drill was remove → one-frame gap → insert, so the
      // two parts never had a counterpart to morph against and the swap read
      // as an instant cut.
      title: chrome == nil ? holdoverTitle : chrome?.header,
      // Actions do NOT hold over: the previous page's Delete must never sit
      // over the page that replaced it.
      trailing: trailingActions.isEmpty ? .empty : .actions(trailingActions))
  }

  /// Which way the slots travel. Read from the navigator's own last mutation
  /// rather than tracked in view state: the reason lands in the SAME update as
  /// the entry, so the inserted content already carries the right transition
  /// instead of picking one up a frame later.
  static func direction(
    for reason: DashNavigationMutationReason?
  ) -> DashTabTransitionDirection {
    switch reason {
    case .push:
      .forward
    case .back, .popToRoot, .closeToWorkspaceRoot, .resourcePruned:
      .backward
    case .reset, .accountScopeChanged, .none:
      .stationary
    }
  }

  /// The header speaks the page compositor's three languages, resolved through
  /// the SAME `DashPageTransitionRules.role` the compositor uses, so the bar
  /// can never disagree with the page about which step is happening.
  static func role(for mutation: DashNavigationMutation?) -> DashPageTransitionRole? {
    guard let entry = mutation?.entry else { return nil }
    return DashPageTransitionRules.role(
      presentation: entry.presentation,
      hasHero: entry.origin?.hero != nil)
  }

  /// One step of the shared header: how far its slots travel, and how long
  /// they take.
  struct Step: Equatable {
    var travel: CGSize
    var duration: TimeInterval
    var dampingRatio: CGFloat
  }

  static func step(
    for mutation: DashNavigationMutation?,
    reduceMotion: Bool
  ) -> Step {
    let role = role(for: mutation) ?? .flow
    let direction = direction(for: mutation?.reason)
    let isPush = direction != .backward
    return Step(
      travel: travel(role: role, direction: direction, reduceMotion: reduceMotion),
      duration: DashPageTransitionRules.duration(for: role, isPush: isPush),
      dampingRatio: DashPageTransitionRules.dampingRatio(for: role, isPush: isPush))
  }

  /// Header slots never travel. A vertical ride used to carry Close / title
  /// with the Settings page, but the leading seat now morphs in place, the
  /// title swaps instantly, and the leftover Y offset was inherited by the
  /// Watchtower inbox whenever Settings left `lastMutation` on that tab —
  /// a root button sliding for a page it does not belong to. Role still
  /// decides *pace* via `step`; distance is always zero.
  static func travel(
    role _: DashPageTransitionRole,
    direction _: DashTabTransitionDirection,
    reduceMotion _: Bool
  ) -> CGSize {
    .zero
  }
}

// MARK: - Shared glass identities

enum WorkspaceHeaderGlassID: Hashable, Sendable {
  case leading
  case trailingPrimary
  case trailingSecondary
}

extension View {
  /// Stable Liquid Glass identities for the controls that trade places inside
  /// the shared header. Earlier systems keep the same aligned opacity handoff
  /// without adopting iOS 26-only material APIs.
  @MainActor
  @ViewBuilder
  func workspaceHeaderGlassID(
    _ id: WorkspaceHeaderGlassID,
    in namespace: Namespace.ID
  ) -> some View {
    if #available(iOS 26.0, *) {
      glassEffectID(id, in: namespace)
        .glassEffectTransition(.matchedGeometry)
    } else {
      self
    }
  }
}

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

// MARK: - The one header

/// ONE header for the whole workspace: leading control, centred title, trailing
/// controls. It is shared chrome of the same kind as `DashWorkspaceTopWash` —
/// floated by `MainTabView` above the pager, never seated in a page — so it
/// holds still while pages slide across it, and a page change is a change of
/// slot *content*, not a second bar arriving with the page.
///
/// Pages never draw these slots. They publish `detailHeader` / `dashPageActions`
/// into their navigator's `DashPageChromeStore`, and this view is that store's
/// ONE reader: a per-page action change must not refresh `MainTabView`'s body
/// while a transition is settling. `DashRoutePageChromeHost` still reserves the
/// same fixed height inside every page, so the content rest line never moves.
struct DashWorkspaceHeaderBar: View {
  let navigator: DestinationNavigator
  let glassNamespace: Namespace.ID
  let showsProfileControl: Bool
  let showsWatchtowerInbox: Bool
  let watchtowerUnreadCount: Int
  let watchtowerCustomization: WatchtowerChartCustomizationState
  let isEditingWatchtower: Bool
  let editorInteractionsReady: Bool
  let onPrepareNavigation: () -> Void
  let onProfileLongPress: () -> Void
  let onInboxLongPress: () -> Void
  let onCancelEditing: () -> Void
  let onCommitEditing: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.layoutDirection) private var layoutDirection

  /// What the bar is currently SHOWING — written only inside an explicit
  /// `withAnimation`, so every slot swap, title morph and reveal runs in a
  /// transaction this view owns. The live resolution arrives through chains
  /// the header does not control (a page host's preference relay, navigator
  /// mutations from arbitrary call sites), and an ambient transaction is a
  /// promise nobody made; the frost band animates its own mount for the same
  /// reason. Rendering a mirror is safe under `DashPageActionDescriptor`'s
  /// documented equality: action closures are excluded from `==` because they
  /// read live state through captured references — the store's own `publish`
  /// dedup already relies on exactly that.
  @State private var displayed: DashWorkspaceHeaderState?

  private var entry: DashNavigationEntry? { navigator.topEntry }

  private var state: DashWorkspaceHeaderState {
    DashWorkspaceHeaderRules.state(
      entry: entry,
      chrome: navigator.pageChrome.chrome(for: entry?.id),
      holdoverTitle: holdoverTitle,
      showsProfileControl: showsProfileControl,
      showsWatchtowerInbox: showsWatchtowerInbox,
      isEditingWatchtower: isEditingWatchtower)
  }

  /// The nearest title still standing behind an arriving page — the deepest
  /// page that HAS published. Stateless on purpose: no `@State` mirror to fall
  /// out of step with the stack, and a pop finds its answer in the same update
  /// the entry disappears in.
  private var holdoverTitle: DashPageHeaderDescriptor? {
    for entry in navigator.entries.reversed() {
      if let chrome = navigator.pageChrome.chrome(for: entry.id) {
        return chrome.header
      }
    }
    return nil
  }

  private var step: DashWorkspaceHeaderRules.Step {
    DashWorkspaceHeaderRules.step(
      for: navigator.lastMutation,
      reduceMotion: reduceMotion)
  }

  var body: some View {
    // Evaluated in body so Observation still registers the navigator and the
    // chrome store as dependencies — `displayed` is a mirror, not the reader.
    let live = state
    bar(displayed ?? live)
      .environment(\.destinationNavigator, navigator)
      .onChange(of: live, initial: true) { _, next in
        guard displayed != nil else {
          // First frame: show, don't animate an arrival that never happened.
          displayed = next
          return
        }
        guard displayed != next else { return }
        withAnimation(headerAnimation) { displayed = next }
      }
  }

  /// Deliberately the same geometry as the page-local fallback bar, not a
  /// second hand-tuned placement: the avatar has to land exactly where a
  /// pushed page's Back control does, or the leading morph would jump.
  ///
  /// The title lives OUTSIDE the Liquid Glass container on purpose: it is not
  /// glass, and the container's compositing exists for the shapes that are —
  /// the original shared overlay only ever wrapped the controls, and the title
  /// keeps that arrangement now that it shares the bar.
  private func bar(_ shown: DashWorkspaceHeaderState) -> some View {
    ZStack {
      titleSlot(shown)
      controlsLayer(shown)
    }
    .frame(height: DashPageChromeMetrics.controlSize)
    .padding(.horizontal, DashPageChromeMetrics.horizontalInset)
    .padding(.top, DashPageChromeMetrics.topInset)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }

  @ViewBuilder
  private func controlsLayer(_ shown: DashWorkspaceHeaderState) -> some View {
    let controls = HStack(spacing: DashPageChromeMetrics.actionSpacing) {
      leadingSlot(shown)
      Spacer(minLength: 0)
      trailingSlot(shown)
    }
    if #available(iOS 26.0, *) {
      GlassEffectContainer(spacing: DashPageChromeMetrics.actionSpacing) {
        controls
      }
    } else {
      controls
    }
  }

  /// The bar settles on the page's own timeline, not a generic one: the
  /// workspace train leaves in 0.22s and a Close still easing out after it
  /// reads as chrome that did not belong to the page it left with.
  private var headerAnimation: Animation {
    guard !reduceMotion else {
      return .easeOut(duration: DashTheme.Motion.Page.reducedDuration)
    }
    let step = step
    return .spring(response: step.duration, dampingFraction: step.dampingRatio)
  }

  /// Seats change hands in place. Controls cross-fade rather than blur — the
  /// blur dissolve is the title's language, and a glass circle mid-shape-morph
  /// does not want a second filter on top of it. No spatial travel: a leftover
  /// Y ride from the Settings train was sliding the Watchtower inbox in.
  private var controlTransition: AnyTransition { .opacity }

  // MARK: Leading

  /// The swap happens INSIDE this ZStack, never in the surrounding HStack: a
  /// removing view still takes part in layout, so an outgoing control seated
  /// next to its replacement would shove the arriving one sideways for the
  /// length of the cross-fade. Overlaid on a reserved slot they change in place.
  private func leadingSlot(_ shown: DashWorkspaceHeaderState) -> some View {
    ZStack(alignment: .leading) {
      slotReservation
      leadingControl(shown)
        // One glass identity for the whole slot: the avatar, Back, Close and a
        // page's own leading action are the same circle changing job, so iOS
        // 26 morphs the shape instead of compositing two controls.
        .workspaceHeaderGlassID(.leading, in: glassNamespace)
        // Key the *visual* occupant only — not the page. Dismiss still hits
        // `navigator.topEntry`, so a stable Back across Domains → zone (card)
        // or a plain drill keeps one circle; avatar → Close and Back → Close
        // still remount because their `slotKind` differs.
        .id(shown.leading.slotKind)
    }
  }

  /// Keeps both slots at control width whatever they hold, so the centred
  /// title never shifts because a page arrived without actions.
  private var slotReservation: some View {
    Color.clear
      .frame(
        width: DashPageChromeMetrics.controlSize,
        height: DashPageChromeMetrics.controlSize)
  }

  /// Every occupant crossfades in the same seat. The avatar used to leave
  /// instantly instead, because a workspace present flew a live copy of it
  /// onto a seat in the Settings page and a component must not duplicate
  /// itself mid-flight. That flight is gone, so the exception went with it.
  @ViewBuilder
  private func leadingControl(_ shown: DashWorkspaceHeaderState) -> some View {
    switch shown.leading {
    case .empty:
      EmptyView()
    case .profile:
      profileControl
        .transition(leadingTransition)
    case .dismissal(let dismissal):
      dismissalControl(dismissal)
        .transition(leadingTransition)
    case .action(let descriptor):
      DashPageActionControl(descriptor: descriptor)
        .transition(leadingTransition)
    case .watchtowerEditorCancel:
      DashToolbarIconButton(
        asset: SolarAsset.editClose,
        accessibilityLabel: DashL10n.string("Cancel"),
        action: onCancelEditing
      )
      .accessibilityIdentifier("watchtower-customize-cancel")
      .transition(.opacity)
    }
  }

  /// The leading seat is always one control changing job — avatar, Back, Close
  /// and a page's own leading action trade the same circle — so it morphs in
  /// place on every role.
  private var leadingTransition: AnyTransition { .opacity }

  private var profileControl: some View {
    DashNavigationSource(
      destination: .settings,
      presentation: .workspaceOverlay,
      onNavigate: onPrepareNavigation
    ) { navigate in
      HeaderProfileButton(
        action: { navigate() },
        onLongPress: { onProfileLongPress() })
    }
  }

  private func dismissalControl(_ dismissal: DashNavigationDismissal) -> some View {
    let isBack = dismissal == .back
    return DashToolbarIconButton(
      asset: DashPageChromeAssetRules.leadingAsset(
        for: dismissal,
        rightToLeft: layoutDirection == .rightToLeft),
      accessibilityLabel: DashL10n.string(isBack ? "Back" : "Close"),
      action: dismissTopPage
    )
    .accessibilityIdentifier(isBack ? "dash.navigation.back" : "dash.navigation.close")
  }

  private func dismissTopPage() {
    guard let entry else { return }
    navigator.dismiss(entryID: entry.id)
  }

  // MARK: Title

  /// The title swaps instantly — a decision, not an omission. Its blur morph
  /// cost per-frame main-thread work beside the page transition and dropped
  /// frames, so the whole subtree opts out of the seats' animated write: no
  /// reveal fade, no content morph, and no width interpolation (a half-slid
  /// title width against an instant string is worse than neither). The
  /// stripped transaction is the ONE hook to remove if the morph ever comes
  /// back on a better frame budget.
  @ViewBuilder
  private func titleSlot(_ shown: DashWorkspaceHeaderState) -> some View {
    if let header = shown.title {
      DashPageChromeTitleView(header: header)
        .transition(.identity)
        .transaction { $0.animation = nil }
    }
  }

  // MARK: Trailing

  private func trailingSlot(_ shown: DashWorkspaceHeaderState) -> some View {
    ZStack(alignment: .trailing) {
      slotReservation
      trailingControls(shown)
        // Page actions change inside a page too (a selection, a Save becoming
        // enabled). Keying the group to the page keeps those per-button, and
        // reserves the cross-fade for an actual page change.
        .id(
          DashWorkspaceHeaderSlotID(
            entryID: shown.entryID,
            kind: shown.trailing.slotKind)
        )
        .transition(controlTransition)
    }
  }

  @ViewBuilder
  private func trailingControls(_ shown: DashWorkspaceHeaderState) -> some View {
    switch shown.trailing {
    case .empty:
      EmptyView()
    case .watchtowerInbox:
      inboxControl
        .workspaceHeaderGlassID(.trailingPrimary, in: glassNamespace)
    case .watchtowerEditor:
      editorControls
    case .actions(let descriptors):
      DashPageActionGroupView(actions: descriptors)
        .workspaceHeaderGlassID(.trailingPrimary, in: glassNamespace)
    }
  }

  private var inboxControl: some View {
    DashNavigationSource(destination: .watchtowerInbox) { navigate in
      HeaderInboxButton(
        count: watchtowerUnreadCount,
        action: { navigate() },
        onLongPress: { onInboxLongPress() })
    }
  }

  private var editorControls: some View {
    HStack(spacing: DashPageChromeMetrics.actionSpacing) {
      addChartMenu
        .workspaceHeaderGlassID(.trailingSecondary, in: glassNamespace)
      DashToolbarIconButton(
        asset: SolarAsset.unread,
        accessibilityLabel: DashL10n.string("Done"),
        variant: .confirmation,
        action: onCommitEditing
      )
      // Done occupies the inbox's former rightmost slot, so its glass shape
      // has a stable source while Add separates to the left.
      .workspaceHeaderGlassID(.trailingPrimary, in: glassNamespace)
      .accessibilityIdentifier("watchtower-customize-done")
    }
  }

  private var addChartMenu: some View {
    Menu {
      if watchtowerCustomization.addableMetrics.isEmpty {
        Button(DashL10n.string("All charts are shown")) {}
          .disabled(true)
      } else {
        ForEach(watchtowerCustomization.addableMetrics) { metric in
          Button(DashL10n.ui(metric.title)) {
            withAnimation(reduceMotion ? nil : DashTheme.Motion.morph) {
              watchtowerCustomization.add(metric)
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
