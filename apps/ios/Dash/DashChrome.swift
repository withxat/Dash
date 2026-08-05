import Combine
import SwiftUI
import UIKit

// MARK: - Sheet presentation

/// Whether a subtree currently presents the app's single compact tray, bubbled
/// to `MainTabView` so root chrome can hide the dock and header avatar.
struct DashTrayPresentation: Equatable {
  var presented = false
}

/// Cross-host bridge for page-owned trays. Preferences cannot cross from a
/// cached `UIHostingController` into `MainTabView`, so each tray also reports
/// its stable modifier instance here while the custom page stack is active.
@MainActor
@Observable
final class DashWorkspacePresentationState {
  private struct Reporter {
    let entryID: UUID?
    var presented: Bool
  }

  private var trayPresentations: [UUID: Reporter] = [:]
  private var coverPresentations: [UUID: Reporter] = [:]

  var trayPresented: Bool {
    trayPresentations.values.contains { $0.presented }
  }

  var coverPresented: Bool {
    coverPresentations.values.contains { $0.presented }
  }

  func setTrayPresented(_ presented: Bool, reporterID: UUID, entryID: UUID?) {
    trayPresentations[reporterID] = Reporter(entryID: entryID, presented: presented)
  }

  func setCoverPresented(_ presented: Bool, reporterID: UUID, entryID: UUID?) {
    coverPresentations[reporterID] = Reporter(entryID: entryID, presented: presented)
  }

  func removePresentationReporters(forEntryID entryID: UUID) {
    trayPresentations = trayPresentations.filter { $0.value.entryID != entryID }
    coverPresentations = coverPresentations.filter { $0.value.entryID != entryID }
  }
}

private struct DashWorkspacePresentationStateKey: EnvironmentKey {
  static let defaultValue: DashWorkspacePresentationState? = nil
}

extension EnvironmentValues {
  var dashWorkspacePresentationState: DashWorkspacePresentationState? {
    get { self[DashWorkspacePresentationStateKey.self] }
    set { self[DashWorkspacePresentationStateKey.self] = newValue }
  }
}

struct TrayPresentedPreferenceKey: PreferenceKey {
  static let defaultValue = DashTrayPresentation()
  static func reduce(value: inout DashTrayPresentation, nextValue: () -> DashTrayPresentation) {
    let next = nextValue()
    value.presented = value.presented || next.presented
  }
}

/// Layout constants for the floating dock capsule (`DashFloatingTabBar`).
enum DashDockMetrics {
  /// Width of one tab cell; the bar is `cell × tab count` wide.
  static let cell: CGFloat = 80
  static let height: CGFloat = 64
  /// How far `MainTabView` sinks the bar into the home-indicator inset.
  static let bottomSink: CGFloat = 10
}

private struct DashTrayDismissKey: EnvironmentKey {
  nonisolated(unsafe) static let defaultValue: () -> Void = {}
}

private struct DashTrayDismissAfterKey: EnvironmentKey {
  nonisolated(unsafe) static let defaultValue: (@escaping () -> Void) -> Void = {
    completion in completion()
  }
}

struct DashTrayDismissDisabledPreferenceKey: PreferenceKey {
  static let defaultValue = false

  static func reduce(value: inout Bool, nextValue: () -> Bool) {
    value = value || nextValue()
  }
}

private struct DashTrayToneKey: EnvironmentKey {
  static let defaultValue: FeatureVisualTone? = nil
}

private struct DashTrayBodyMaxHeightKey: EnvironmentKey {
  static let defaultValue: CGFloat? = nil
}

#if DEBUG
  private struct DashTrayReduceMotionOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
  }
#endif

extension EnvironmentValues {
  var dashTrayDismiss: () -> Void {
    get { self[DashTrayDismissKey.self] }
    set { self[DashTrayDismissKey.self] = newValue }
  }

  /// Closes through the tray's complete keyboard/exit choreography, then runs
  /// work that would otherwise tear down or navigate away from its presenter.
  var dashTrayDismissAfter: (@escaping () -> Void) -> Void {
    get { self[DashTrayDismissAfterKey.self] }
    set { self[DashTrayDismissAfterKey.self] = newValue }
  }

  /// Contextual tone of the presenting flow — Family's "the tray dresses for
  /// the room it walks into". `nil` (the default) is the neutral tray. Set via
  /// `dashTray(tone:)`; feature-launched trays pass
  /// `FeatureVisualIdentity.tone(for:)`, Profile/Settings trays stay neutral.
  /// Applied sparingly: the footer submit pill, a non-destructive header
  /// action circle, and a whisper of wash at the card top. The tray background
  /// token itself never changes.
  var dashTrayTone: FeatureVisualTone? {
    get { self[DashTrayToneKey.self] }
    set { self[DashTrayToneKey.self] = newValue }
  }

  /// How tall the tray's content may grow before the card runs out of room —
  /// published by `DashSheetCard`, spent by `DashTrayScrollBoundary`, which
  /// hands what is left after its action band to the scrolling body. `nil`
  /// outside a tray (and on the first frame, before the header is measured):
  /// no budget, so the boundary lays out at natural height and never scrolls.
  var dashTrayBodyMaxHeight: CGFloat? {
    get { self[DashTrayBodyMaxHeightKey.self] }
    set { self[DashTrayBodyMaxHeightKey.self] = newValue }
  }

  #if DEBUG
    fileprivate var dashTrayReduceMotionOverride: Bool? {
      get { self[DashTrayReduceMotionOverrideKey.self] }
      set { self[DashTrayReduceMotionOverrideKey.self] = newValue }
    }
  #endif
}

#if DEBUG
  extension View {
    func dashTrayTestReduceMotionOverride(_ value: Bool?) -> some View {
      environment(\.dashTrayReduceMotionOverride, value)
    }
  }

  extension Notification.Name {
    static let dashTraySuccessFlightDidBegin = Notification.Name(
      "dash.tray.success-flight.did-begin")
  }
#endif

// MARK: - Paired tray action presentation

/// The one source transition Dash supports: the same primary action persists
/// from the presenting screen into the tray. A launcher tile is not a shared
/// action and must use the standard bottom reveal.
struct DashTraySharedAction: Equatable, Sendable {
  let id: String
  let title: String
  var icon: String? = nil
}

/// Global-frame registry for the presenting endpoint. The claim reserves one
/// source while the transparent cover mounts, but the source stays visible
/// until the tray has laid out the matching destination. Activation and the
/// native-size proxy then exchange ownership in one rendered frame.
@MainActor
@Observable
final class DashTraySourceRegistry {
  static let shared = DashTraySourceRegistry()

  /// The source currently represented by the host-owned action proxy.
  private(set) var occupiedID: AnyHashable?
  @ObservationIgnored private var claimedID: AnyHashable?
  @ObservationIgnored private var frames: [AnyHashable: CGRect] = [:]

  func record(_ frame: CGRect, for id: AnyHashable) {
    frames[id] = frame
  }

  func removeFrame(for id: AnyHashable) {
    frames.removeValue(forKey: id)
  }

  /// The frame a tray may anchor to, or nil — off-screen, collapsed, or
  /// unregistered sources fall back to the standard bottom reveal.
  func presentationFrame(for id: AnyHashable, in bounds: CGRect) -> CGRect? {
    guard let frame = frames[id], Self.isPresentableSource(frame, in: bounds) else {
      return nil
    }
    return frame
  }

  /// Reserves the one source slot. Reservation does not hide the source; the
  /// paired destination must exist before `activate` transfers visual ownership.
  @discardableResult
  func claim(_ id: AnyHashable) -> Bool {
    guard claimedID == nil || claimedID == id else { return false }
    claimedID = id
    return true
  }

  @discardableResult
  func activate(_ id: AnyHashable) -> Bool {
    guard claimedID == id else { return false }
    occupiedID = id
    return true
  }

  func release(_ id: AnyHashable) {
    if claimedID == id { claimedID = nil }
    if occupiedID == id { occupiedID = nil }
  }

  /// A source is anchorable when it has real size and is at least partly on
  /// screen. Oversized rects (a scroll container, a full-screen cover) would
  /// make the "grow" read as a zoom glitch, so they fall back too.
  static func isPresentableSource(_ frame: CGRect, in bounds: CGRect) -> Bool {
    guard !bounds.isEmpty, frame.width > 1, frame.height > 1 else { return false }
    guard frame.intersects(bounds) else { return false }
    return frame.width <= bounds.width && frame.height <= bounds.height * 0.6
  }
}

private struct DashTraySourceModifier: ViewModifier {
  let id: AnyHashable
  @Bindable private var registry = DashTraySourceRegistry.shared

  func body(content: Content) -> some View {
    let occupied = registry.occupiedID == id
    content
      .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
        registry.record(frame, for: id)
      }
      .onDisappear { registry.removeFrame(for: id) }
      // Instant, not faded: while occupied the tray card occupies (or is
      // travelling to) this exact rect, so any crossfade would double-expose.
      .opacity(occupied ? 0 : 1)
      .allowsHitTesting(!occupied)
      .accessibilityHidden(occupied)
  }
}

/// The presented endpoint reports its live global frame to the tray host. The
/// host freezes the opening frame, while continuing to retain the live value
/// for an accurate close after keyboard or content-height changes.
@MainActor
@Observable
private final class DashTraySharedActionCoordinator {
  @ObservationIgnored private var destinationToken: UUID?
  private(set) var destinationAction: DashTraySharedAction?
  private(set) var destinationFrame: CGRect?

  func update(_ action: DashTraySharedAction, frame: CGRect, token: UUID) {
    destinationToken = token
    destinationAction = action
    destinationFrame = frame
  }

  func clear(token: UUID) {
    guard destinationToken == token else { return }
    destinationToken = nil
    destinationAction = nil
    destinationFrame = nil
  }
}

private struct DashTraySharedGeometrySnapshot: Equatable {
  let action: DashTraySharedAction
  let destination: CGRect
  let card: CGRect
}

private struct DashTraySharedActionCoordinatorKey: EnvironmentKey {
  static let defaultValue: DashTraySharedActionCoordinator? = nil
}

private struct DashTrayProxyOwnedActionIDKey: EnvironmentKey {
  static let defaultValue: String? = nil
}

extension EnvironmentValues {
  fileprivate var dashTraySharedActionCoordinator: DashTraySharedActionCoordinator? {
    get { self[DashTraySharedActionCoordinatorKey.self] }
    set { self[DashTraySharedActionCoordinatorKey.self] = newValue }
  }

  fileprivate var dashTrayProxyOwnedActionID: String? {
    get { self[DashTrayProxyOwnedActionIDKey.self] }
    set { self[DashTrayProxyOwnedActionIDKey.self] = newValue }
  }
}

private struct DashTraySharedDestinationModifier: ViewModifier {
  let action: DashTraySharedAction
  @Environment(\.dashTraySharedActionCoordinator) private var coordinator
  @Environment(\.dashTrayProxyOwnedActionID) private var proxyOwnedActionID
  @State private var token = UUID()

  private var proxyOwnsAction: Bool { proxyOwnedActionID == action.id }

  func body(content: Content) -> some View {
    content
      .background {
        GeometryReader { proxy in
          let frame = proxy.frame(in: .global)
          Color.clear
            .onAppear { coordinator?.update(action, frame: frame, token: token) }
            .onChange(of: frame) { _, newFrame in
              coordinator?.update(action, frame: newFrame, token: token)
            }
        }
      }
      .onDisappear { coordinator?.clear(token: token) }
      .opacity(proxyOwnsAction ? 0 : 1)
      .allowsHitTesting(!proxyOwnsAction)
      .accessibilityHidden(proxyOwnsAction)
  }
}

/// The window bounds anchored presentations validate source frames against.
@MainActor private func dashTrayWindowBounds() -> CGRect {
  let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
  if let bounds = scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.bounds {
    return bounds
  }
  return scenes.first?.screen.bounds ?? UIScreen.main.bounds
}

extension View {
  /// Compatibility-only geometry reporter for old debug hosts. A one-ended
  /// source no longer changes presentation; production source transitions use
  /// `dashTraySharedSource` plus a matching destination.
  func dashTraySource(id: AnyHashable) -> some View {
    modifier(DashTraySourceModifier(id: id))
  }

  /// Marks the presenting endpoint of one persistent tray action.
  func dashTraySharedSource(_ action: DashTraySharedAction) -> some View {
    modifier(DashTraySourceModifier(id: action.id))
  }

  /// Marks the matching endpoint inside the tray. Without this endpoint the
  /// host releases the source and falls back to the standard bottom reveal.
  func dashTraySharedDestination(_ action: DashTraySharedAction) -> some View {
    modifier(DashTraySharedDestinationModifier(action: action))
  }
}

extension View {
  func dashTrayDismissDisabled(_ disabled: Bool) -> some View {
    preference(key: DashTrayDismissDisabledPreferenceKey.self, value: disabled)
  }

  /// Presents a tray. Attach after `.refreshable` in the modifier chain: a tray
  /// attached before it sits inside the refreshable subtree and inherits the
  /// screen's pull-to-refresh into the tray's own scroll view.
  /// `showsMenuButtons` toggles the corner controls (trailing action + close);
  /// with them off, scrim tap and header drag still dismiss.
  /// `sharedAction` opts into the paired-action reveal. The same descriptor
  /// must mark one source and one destination; otherwise the tray uses the
  /// standard bottom reveal.
  func dashTray<Content: View>(
    isPresented: Binding<Bool>,
    title: String,
    showsMenuButtons: Bool = true,
    tone: FeatureVisualTone? = nil,
    sharedAction: DashTraySharedAction? = nil,
    @ViewBuilder content: @escaping () -> Content
  ) -> some View {
    modifier(
      DashTrayModifier<EmptyView, Content, EmptyView>(
        isPresented: isPresented, title: title,
        showsMenuButtons: showsMenuButtons, tone: tone, sharedAction: sharedAction, hero: nil,
        trayContent: content, footer: { EmptyView() }, hasFooter: false))
  }

  /// Source-only compatibility for debug hosts. It deliberately presents with
  /// the standard reveal; a frame without a destination is not a shared action.
  func dashTray<Content: View>(
    isPresented: Binding<Bool>,
    title: String,
    showsMenuButtons: Bool = true,
    tone: FeatureVisualTone? = nil,
    sourceID _: AnyHashable,
    @ViewBuilder content: @escaping () -> Content
  ) -> some View {
    dashTray(
      isPresented: isPresented, title: title,
      showsMenuButtons: showsMenuButtons, tone: tone,
      sharedAction: nil, content: content)
  }

  /// A floating content tray with three stable chrome regions: fixed header,
  /// independently scrolling body, and fixed action footer. Use this when a
  /// multi-step body morphs above controls that must retain one screen position.
  func dashTray<Content: View, Footer: View>(
    isPresented: Binding<Bool>,
    title: String,
    showsMenuButtons: Bool = true,
    tone: FeatureVisualTone? = nil,
    sharedAction: DashTraySharedAction? = nil,
    @ViewBuilder content: @escaping () -> Content,
    @ViewBuilder footer: @escaping () -> Footer
  ) -> some View {
    modifier(
      DashTrayModifier<EmptyView, Content, Footer>(
        isPresented: isPresented, title: title,
        showsMenuButtons: showsMenuButtons, tone: tone, sharedAction: sharedAction, hero: nil,
        trayContent: content, footer: footer, hasFooter: true))
  }

  /// A compact tray whose top is a full-bleed hero — an image spanning the
  /// card edge to edge with no insets — instead of the title row. The hero
  /// sizes itself (fixed height or aspect ratio); the card clips its top
  /// corners. Menu buttons, when on, float over the hero in the standard
  /// corner position. `title` still names the tray for accessibility.
  func dashTray<Hero: View, Content: View>(
    isPresented: Binding<Bool>,
    title: String,
    showsMenuButtons: Bool = true,
    tone: FeatureVisualTone? = nil,
    sharedAction: DashTraySharedAction? = nil,
    @ViewBuilder hero: @escaping () -> Hero,
    @ViewBuilder content: @escaping () -> Content
  ) -> some View {
    modifier(
      DashTrayModifier<Hero, Content, EmptyView>(
        isPresented: isPresented, title: title,
        showsMenuButtons: showsMenuButtons, tone: tone, sharedAction: sharedAction, hero: hero,
        trayContent: content, footer: { EmptyView() }, hasFooter: false))
  }

  func dashTray<Item: Identifiable & Equatable, Content: View>(
    item: Binding<Item?>,
    title: @escaping (Item) -> String,
    showsMenuButtons: Bool = true,
    tone: FeatureVisualTone? = nil,
    sharedAction: DashTraySharedAction? = nil,
    @ViewBuilder content: @escaping (Item) -> Content
  ) -> some View {
    modifier(
      DashTrayItemModifier<Item, EmptyView, Content>(
        item: item, title: title,
        showsMenuButtons: showsMenuButtons, tone: tone, sharedAction: sharedAction, hero: nil,
        trayContent: content)
    )
  }

  /// Item-driven variant of the hero tray; see the `isPresented` overload.
  func dashTray<Item: Identifiable & Equatable, Hero: View, Content: View>(
    item: Binding<Item?>,
    title: @escaping (Item) -> String,
    showsMenuButtons: Bool = true,
    tone: FeatureVisualTone? = nil,
    sharedAction: DashTraySharedAction? = nil,
    @ViewBuilder hero: @escaping (Item) -> Hero,
    @ViewBuilder content: @escaping (Item) -> Content
  ) -> some View {
    modifier(
      DashTrayItemModifier(
        item: item, title: title,
        showsMenuButtons: showsMenuButtons, tone: tone, sharedAction: sharedAction, hero: hero,
        trayContent: content)
    )
  }
}

private struct DashSheetFittedHeightKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

private struct DashSheetHeaderHeightKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

private struct DashSheetBodyIdealKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

private struct DashSheetFooterHeightKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

/// A compact circular action rendered left of the tray's close button
/// (e.g. delete). Tray content publishes it with `dashTrayHeaderAction`.
struct DashSheetHeaderAction: Equatable {
  let id: String
  let icon: String
  var accessibilityLabel: String
  /// Destructive actions keep the fixed danger circle whatever the tray's
  /// contextual tone; only non-destructive actions pick up `\.dashTrayTone`.
  var role: ButtonRole? = .destructive
  let perform: () -> Void

  static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

private struct DashSheetHeaderActionKey: PreferenceKey {
  static var defaultValue: DashSheetHeaderAction? { nil }
  static func reduce(value: inout DashSheetHeaderAction?, nextValue: () -> DashSheetHeaderAction?) {
    value = nextValue() ?? value
  }
}

extension View {
  /// Publishes a circular header action (left of close) for the enclosing tray.
  func dashTrayHeaderAction(_ action: DashSheetHeaderAction?) -> some View {
    preference(key: DashSheetHeaderActionKey.self, value: action)
  }

  /// Overrides the tray chrome title for the current step of a multi-step flow.
  func dashTrayTitle(_ title: String?) -> some View {
    preference(key: DashTrayTitleKey.self, value: title)
  }

  /// Publishes the tray's description — the sentence that says what this tray
  /// does — so the chrome seats it under the title instead of the content
  /// stacking it above the first control or stranding it under the last one.
  /// A tray that has one loses the header separator (see `DashSheetHeader`).
  ///
  /// It lives with the content, not at the `dashTray` call site, because most
  /// tray bodies are reusable views presented from several screens and because
  /// the copy is usually conditional on the step the body is showing — pass
  /// `nil` for the steps that have nothing to say.
  func dashTrayDescription(_ description: String?) -> some View {
    preference(key: DashTrayDescriptionKey.self, value: description)
  }
}

private struct DashTrayTitleKey: PreferenceKey {
  static var defaultValue: String? { nil }
  static func reduce(value: inout String?, nextValue: () -> String?) {
    value = nextValue() ?? value
  }
}

private struct DashTrayDescriptionKey: PreferenceKey {
  static var defaultValue: String? { nil }
  static func reduce(value: inout String?, nextValue: () -> String?) {
    value = nextValue() ?? value
  }
}

/// Back navigation for a stack-driven multi-step tray: published by
/// `DashTrayFlow`'s `root:path:` form whenever the path is non-empty, consumed
/// by the tray header, whose ✕ circle then pops one step instead of dismissing
/// (same glyph, different job). Equality is depth-only, matching
/// `DashSheetHeaderAction`'s id-only pattern: the pop closure is semantically
/// identical at any given depth, so preference plumbing never churns on
/// closure identity.
struct DashTrayBackAction: Equatable {
  let depth: Int
  let perform: () -> Void

  static func == (lhs: Self, rhs: Self) -> Bool { lhs.depth == rhs.depth }
}

private struct DashTrayBackActionKey: PreferenceKey {
  static var defaultValue: DashTrayBackAction? { nil }
  static func reduce(value: inout DashTrayBackAction?, nextValue: () -> DashTrayBackAction?) {
    value = nextValue() ?? value
  }
}

/// Semantic position inside a multi-step Tray. Callers describe where the
/// current route sits; the Tray owns timing, chrome insets, and target-height
/// measurement.
enum DashTrayStepRole: Int, Equatable, Sendable {
  case root
  case detail
  case destructive

  fileprivate var isDetail: Bool { self != .root }

  fileprivate var transitionAnimation: Animation {
    switch self {
    case .root: DashTheme.Motion.trayStepReturn
    case .detail: DashTheme.Motion.trayStep
    case .destructive: DashTheme.Motion.trayStepDestructive
    }
  }
}

private struct DashTrayStepRoleKey: PreferenceKey {
  static let defaultValue = DashTrayStepRole.root

  static func reduce(value: inout DashTrayStepRole, nextValue: () -> DashTrayStepRole) {
    let next = nextValue()
    if next.rawValue > value.rawValue { value = next }
  }
}

private struct DashTrayRouteLayoutKey<Route: Hashable & Sendable>: LayoutValueKey {
  static var defaultValue: Route? { nil }
}

/// SwiftUI counterpart to a pop-layout presence transition: outgoing and
/// incoming routes remain visual siblings, but only the active route contributes
/// the layout size. The enclosing card can therefore begin moving to the target
/// height on the first frame instead of waiting for the old route to disappear.
private struct DashTrayPopLayout<Route: Hashable & Sendable>: Layout {
  let activeRoute: Route

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) -> CGSize {
    guard let active = activeSubview(in: subviews) else { return .zero }
    return active.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) {
    let childProposal = ProposedViewSize(width: bounds.width, height: nil)
    for subview in subviews {
      subview.place(
        at: CGPoint(x: bounds.midX, y: bounds.minY),
        anchor: .top,
        proposal: childProposal
      )
    }
  }

  private func activeSubview(in subviews: Subviews) -> LayoutSubview? {
    subviews.first { $0[DashTrayRouteLayoutKey<Route>.self] == activeRoute } ?? subviews.last
  }
}

/// Mutable direction shared between a stack flow and its step transitions.
/// A removal transition is captured with the outgoing view's *last rendered*
/// modifiers, so a value stored there would still carry the direction of the
/// push that inserted it; routing every read through one reference lets the
/// flow flip the sign at pop time and have the already-scheduled exit follow.
private final class DashTrayFlowDirection {
  var lastDepth = 0
  /// +1 while stepping forward (deeper), -1 while popping back.
  var sign: CGFloat = 1
}

/// Directional travel for one stack-driven step. Forward: the incoming route
/// settles in from the trailing edge while the outgoing route exits leading —
/// fly instead of teleport. A pop mirrors both. Combined with the flow's
/// shared opacity + 0.96-scale transition; this modifier only owns the offset.
private struct DashTrayStepSlide: ViewModifier, Animatable {
  enum Phase {
    case insertion
    case removal
  }

  var progress: CGFloat
  let direction: DashTrayFlowDirection
  let phase: Phase
  /// -1 flips travel for right-to-left layouts.
  let layoutSign: CGFloat

  // Nonisolated for the same SE-0434 reason as DashTrayCardReveal: the
  // accessor only touches a Sendable stored property.
  nonisolated var animatableData: CGFloat {
    get { progress }
    set { progress = newValue }
  }

  func body(content: Content) -> some View {
    let side: CGFloat = phase == .insertion ? 1 : -1
    content.offset(
      x: progress * DashTheme.Motion.trayStepSlide * side * direction.sign * layoutSign)
  }
}

/// Canonical multi-step Tray content. Business views provide a stable route and
/// its semantic role; this view keeps the outgoing route alive for its visual
/// exit while handing layout ownership to the target route immediately.
///
/// Two forms:
/// - `route:role:` — one stable route value, symmetric fade/0.96-scale
///   replacement. For two-state morphs (confirm affordances) and terminal
///   replacements where "back" would reopen a committed step.
/// - `root:path:role:` — a route stack. Forward is `path.append`, and the flow
///   publishes the header back control: at any depth the tray's ✕ pops one step
///   instead of dismissing (the glyph stays ✕ — see `DashTrayDismissButton`).
///   Steps gain a directional slide (`trayStepSlide`) so progression and return
///   read as travel, not teleport. Terminal success steps must *replace* the
///   stack (`path = [.done]`), never push — a back control over a committed
///   action would reopen its form.
struct DashTrayFlow<Route: Hashable & Sendable, Content: View>: View {
  let route: Route
  let role: DashTrayStepRole
  private let path: Binding<[Route]>?
  @ViewBuilder let content: (Route) -> Content
  @State private var direction = DashTrayFlowDirection()
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.layoutDirection) private var layoutDirection

  init(
    route: Route,
    role: DashTrayStepRole,
    @ViewBuilder content: @escaping (Route) -> Content
  ) {
    self.route = route
    self.role = role
    self.path = nil
    self.content = content
  }

  init(
    root: Route,
    path: Binding<[Route]>,
    role: (Route) -> DashTrayStepRole,
    @ViewBuilder content: @escaping (Route) -> Content
  ) {
    let active = path.wrappedValue.last ?? root
    self.route = active
    self.role = role(active)
    self.path = path
    self.content = content
  }

  var body: some View {
    if let path {
      // Recorded during body on purpose: `onChange` lands after this render,
      // but the insertion transition for the arriving route is captured now.
      let depth = path.wrappedValue.count
      if depth != direction.lastDepth {
        direction.sign = depth > direction.lastDepth ? 1 : -1
        direction.lastDepth = depth
      }
    }
    return DashTrayPopLayout(activeRoute: route) {
      content(route)
        .frame(maxWidth: .infinity, alignment: .top)
        .layoutValue(key: DashTrayRouteLayoutKey<Route>.self, value: route)
        .id(route)
        .transition(stepTransition)
    }
    .frame(maxWidth: .infinity, alignment: .top)
    .animation(
      reduceMotion ? DashTheme.Motion.reduced : role.transitionAnimation,
      value: route
    )
    .preference(key: DashTrayStepRoleKey.self, value: role)
    .preference(key: DashTrayBackActionKey.self, value: backAction)
  }

  private var stepTransition: AnyTransition {
    if reduceMotion { return .opacity }
    let base = AnyTransition.opacity.combined(with: .scale(scale: 0.96, anchor: .center))
    guard path != nil else { return base }
    let layoutSign: CGFloat = layoutDirection == .rightToLeft ? -1 : 1
    return .asymmetric(
      insertion: .modifier(
        active: DashTrayStepSlide(
          progress: 1, direction: direction, phase: .insertion, layoutSign: layoutSign),
        identity: DashTrayStepSlide(
          progress: 0, direction: direction, phase: .insertion, layoutSign: layoutSign)
      ),
      removal: .modifier(
        active: DashTrayStepSlide(
          progress: 1, direction: direction, phase: .removal, layoutSign: layoutSign),
        identity: DashTrayStepSlide(
          progress: 0, direction: direction, phase: .removal, layoutSign: layoutSign)
      )
    )
    .combined(with: base)
  }

  private var backAction: DashTrayBackAction? {
    guard let path, !path.wrappedValue.isEmpty else { return nil }
    return DashTrayBackAction(depth: path.wrappedValue.count) {
      var stack = path.wrappedValue
      _ = stack.popLast()
      path.wrappedValue = stack
    }
  }
}

/// Pure dismiss / settle decisions for the compact tray drag gesture.
enum TrayDragOutcome: Equatable, Sendable {
  case dismiss
  case settle
}

enum TrayDragDecision {
  /// A deliberate pull can dismiss on distance, while a fling must first travel
  /// far enough to establish downward intent. This is Dash's established tray
  /// gesture rather than the height-relative Family drawer gesture.
  static func content(
    translation: CGFloat,
    predictedEndTranslation: CGFloat,
    distanceThreshold: CGFloat = 120,
    projectedThreshold: CGFloat = 160,
    minimumFlingDistance: CGFloat = 32
  ) -> TrayDragOutcome {
    let hasDownwardMomentum = predictedEndTranslation > translation
    let isDeliberateFling =
      translation >= minimumFlingDistance
      && predictedEndTranslation > projectedThreshold
      && hasDownwardMomentum
    if translation > distanceThreshold || isDeliberateFling {
      return .dismiss
    }
    return .settle
  }

  /// Original fixed-friction rubber band for upward tray travel.
  static func rubberBand(cardTop: CGFloat, expandedTop: CGFloat, factor: CGFloat = 0.15)
    -> CGFloat
  {
    guard cardTop < expandedTop else { return cardTop }
    return expandedTop - (expandedTop - cardTop) * factor
  }
}

/// The established Dash shell motion. Route replacement keeps its separate
/// timing vocabulary inside `DashTrayFlow`.
private enum DashTrayMotion {
  static let present = DashTheme.Motion.present
  static let scrimPresent = DashTheme.Motion.scrimPresent
  static let scrimDismiss = DashTheme.Motion.scrimDismiss
  static let resize = DashTheme.Motion.trayResize
  static let release = DashTheme.Motion.release
  static let dismiss = DashTheme.Motion.dismiss
}

/// The trailing button cluster — optional action circle plus close — shared by
/// the standard and hero headers so both variants keep identical geometry.
private struct DashSheetMenuButtons: View {
  var trailingAction: DashSheetHeaderAction? = nil
  var backAction: DashTrayBackAction? = nil
  var isDisabled = false
  let dismiss: () -> Void
  @Environment(\.dashTrayTone) private var tone

  /// Destructive stays the fixed danger pair; a non-destructive action wears
  /// the tray's contextual tone (falling back to the neutral close-circle
  /// treatment when the tray has none). No production call site uses the toned
  /// branch yet — before one does, device-check glyph contrast on the 12% tint
  /// (mid-luminance vivids like `.accent` sit near 2.3:1 in light mode).
  private func circleColors(for action: DashSheetHeaderAction) -> (icon: Color, fill: Color) {
    if action.role == .destructive { return (DashTheme.danger, DashTheme.dangerTint) }
    if let tone { return (tone.vivid, tone.vivid.opacity(0.12)) }
    return (DashTheme.strong, DashTheme.recessed)
  }

  var body: some View {
    // Both circular controls already carry independent 44pt hit targets.
    // Zero stack spacing keeps those targets adjacent (never overlapping)
    // and reduces the visible action-to-close gap from 20pt to 12pt.
    HStack(alignment: .center, spacing: 0) {
      if let trailingAction {
        let colors = circleColors(for: trailingAction)
        Button(action: trailingAction.perform) {
          // The glyph sits smaller than the close X, whose larger mark is what
          // keeps the two circles visually balanced.
          SolarIcon(asset: trailingAction.icon, size: 18, color: colors.icon)
            .frame(width: 32, height: 32)
            .background(colors.fill, in: Circle())
            .dashCompactHitTarget()
        }
        .buttonStyle(DashPressButtonStyle())
        .accessibilityLabel(trailingAction.accessibilityLabel)
        .accessibilityIdentifier("dash-tray-header-\(trailingAction.id)")
      }
      DashTrayDismissButton(backAction: backAction, dismiss: dismiss)
    }
    .disabled(isDisabled)
    .opacity(isDisabled ? 0.45 : 1)
  }
}

/// The tray's one dismissal circle. Its glyph is always ✕ — deliberately, at
/// every depth: a tray is one modal surface, and the mark in that corner is
/// the mark that takes you out of the step you are in. Swapping it for a ←
/// made the corner a control the eye has to re-read on every push, so only the
/// button's *job* changes with depth — a stack flow's back action pops one
/// step instead of dismissing, and the accessibility label and identifier are
/// what report that (`dash.tray.back` / `dash.tray.close`). Do not reintroduce
/// a glyph morph here. Drag and scrim are unaffected: they always dismiss the
/// whole tray.
private struct DashTrayDismissButton: View {
  let backAction: DashTrayBackAction?
  let dismiss: () -> Void

  private var isBack: Bool { backAction != nil }

  var body: some View {
    Button {
      if let backAction {
        backAction.perform()
      } else {
        dismiss()
      }
    } label: {
      SolarIcon(asset: SolarAsset.close, size: 22, color: DashTheme.Sheet.closeIcon)
        .frame(width: 32, height: 32)
        .background(DashTheme.recessed, in: Circle())
        .dashCompactHitTarget()
    }
    .buttonStyle(DashPressButtonStyle())
    .accessibilityLabel(isBack ? DashL10n.string("Back") : DashL10n.string("Close"))
    .accessibilityIdentifier(isBack ? "dash.tray.back" : "dash.tray.close")
  }
}

/// Shared header (title + menu buttons) for the compact tray.
///
/// Two variants, one rule: a bare title is closed by the hairline separator,
/// and a title with a description under it is not. The description is the
/// tray's own explanation of what it does, and it reads as one block with the
/// title — a line drawn between them would cut that block in half, and a line
/// drawn under both would fence off a header taller than the body it
/// introduces. So the description *is* the separator. Never render both.
///
/// Content publishes it with `dashTrayDescription`; anything that arrives that
/// way stops being body copy, which is the point — this used to be a paragraph
/// stacked above the first control on some trays and stranded under the last
/// one on others.
private struct DashSheetHeader: View {
  let title: String
  var description: String? = nil
  var showsMenuButtons = true
  var stepRole = DashTrayStepRole.root
  var trailingAction: DashSheetHeaderAction? = nil
  var backAction: DashTrayBackAction? = nil
  var menuButtonsDisabled = false
  let dismiss: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @AccessibilityFocusState private var titleFocused: Bool

  /// Air between the title and its description — tight enough that the two
  /// read as one block, which is what lets the separator go.
  private static let descriptionGap: CGFloat = 6

  private var displayedTitle: String { DashL10n.ui(title) }

  /// Empty is absent, not a blank line: a conditional caller that computes its
  /// way to `""` must still get the separator, never a hairline-less header
  /// with nothing under the title.
  private var displayedDescription: String? {
    guard let description, !description.isEmpty else { return nil }
    return DashL10n.ui(description)
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .center, spacing: 0) {
        Text(displayedTitle)
          .dashTextStyle(.trayTitle)
          .foregroundStyle(DashTheme.strong)
          .lineLimit(1)
          .minimumScaleFactor(0.85)
          .contentTransition(reduceMotion ? .identity : .opacity)
          .animation(
            reduceMotion ? DashTheme.Motion.reduced : stepRole.transitionAnimation,
            value: displayedTitle
          )
          .id(displayedTitle)
          .accessibilityAddTraits(.isHeader)
          .accessibilityFocused($titleFocused)
        Spacer(minLength: 12)
        if showsMenuButtons {
          DashSheetMenuButtons(
            trailingAction: trailingAction,
            backAction: backAction,
            isDisabled: menuButtonsDisabled,
            dismiss: dismiss
          )
        }
      }
      .padding(.leading, DashTheme.Sheet.headerHorizontal)
      // The close circle is 32pt inside a centered 44pt hit target. Let the
      // invisible 6pt trailing half extend into the inset so the visible face
      // animates from 28pt on a root step to 32pt on a detail step.
      .padding(
        .trailing,
        showsMenuButtons
          ? (stepRole.isDetail ? 32 : DashTheme.Sheet.headerHorizontal) - 6
          : DashTheme.Sheet.headerHorizontal
      )
      .padding(
        .top,
        stepRole.isDetail ? DashTheme.Sheet.detailHeaderTop : DashTheme.Sheet.headerTop
      )
      .padding(
        .bottom,
        displayedDescription == nil ? DashTheme.Sheet.headerBottom : Self.descriptionGap
      )
      .animation(
        reduceMotion ? nil : DashTrayMotion.resize,
        value: stepRole
      )

      if let displayedDescription {
        // Full width: the menu buttons are on the row above, not beside this.
        //
        // No `.id(…)` here, unlike the title. A description wraps, so swapping
        // identity on every edit would hard-cut a height change; keeping one
        // Text lets the crossfade and the reflow run as one animation.
        Text(displayedDescription)
          .dashTextStyle(.supporting)
          .foregroundStyle(DashTheme.subtle)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentTransition(reduceMotion ? .identity : .opacity)
          .animation(
            reduceMotion ? DashTheme.Motion.reduced : stepRole.transitionAnimation,
            value: displayedDescription
          )
          .padding(.horizontal, DashTheme.Sheet.content)
          // Leaves the same gap to the body the separator did.
          .padding(.bottom, DashTheme.Sheet.descriptionBottom)
      } else {
        Rectangle()
          .fill(DashTheme.separator)
          .frame(height: 1)
          .padding(.horizontal, DashTheme.Sheet.content)
      }
    }
    .onAppear {
      titleFocused = true
      UIAccessibility.post(notification: .screenChanged, argument: displayedTitle)
    }
    .onChange(of: displayedTitle) { _, newTitle in
      titleFocused = true
      UIAccessibility.post(notification: .screenChanged, argument: newTitle)
    }
  }
}

/// Hero-topped header for compact trays: the hero fills the card edge to
/// edge with no insets (the card's clip rounds its top corners) and the menu
/// buttons, when on, float over it in the standard corner position. There is
/// no title row or separator — `title` still names the tray for accessibility.
/// The hero decides its own height (fixed frame or aspect ratio); anything a
/// `scaledToFill` overflows is clipped so it never bleeds into the body.
private struct DashSheetHeroHeader<Hero: View>: View {
  let title: String
  var showsMenuButtons = true
  var stepRole = DashTrayStepRole.root
  var trailingAction: DashSheetHeaderAction? = nil
  var backAction: DashTrayBackAction? = nil
  var menuButtonsDisabled = false
  let dismiss: () -> Void
  @ViewBuilder var hero: () -> Hero
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var displayedTitle: String { DashL10n.ui(title) }

  var body: some View {
    hero()
      .frame(maxWidth: .infinity)
      .clipped()
      .overlay(alignment: .topTrailing) {
        if showsMenuButtons {
          DashSheetMenuButtons(
            trailingAction: trailingAction,
            backAction: backAction,
            isDisabled: menuButtonsDisabled,
            dismiss: dismiss
          )
          .padding(
            .top,
            stepRole.isDetail ? DashTheme.Sheet.detailHeaderTop : DashTheme.Sheet.headerTop
          )
          .padding(
            .trailing,
            (stepRole.isDetail ? 32 : DashTheme.Sheet.headerHorizontal) - 6
          )
          .animation(
            reduceMotion ? nil : DashTrayMotion.resize,
            value: stepRole
          )
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel(displayedTitle)
      .onAppear {
        UIAccessibility.post(notification: .screenChanged, argument: displayedTitle)
      }
  }
}

/// Compact trays use a full-screen transparent cover with our own dim and a
/// bottom-pinned card. The card animates its own target height (DashSheetCard) so
/// content morphs resize smoothly — there's no native detent to clip or snap.
/// Card and scrim share the cover but not the motion: the card springs up from
/// the bottom, while the dim fades in place over the page behind.
private struct DashCustomSheet<Hero: View, Content: View, Footer: View>: View {
  let title: String
  var showsMenuButtons = true
  /// Contextual tone; nil keeps the neutral tray. See `\.dashTrayTone`.
  var tone: FeatureVisualTone? = nil
  /// Paired action plus its frozen presenting frame. Nil keeps the standard
  /// bottom reveal; the destination must still report the matching identity.
  var sharedAction: DashTraySharedAction? = nil
  var sourceFrame: CGRect? = nil
  /// Full-bleed view replacing the title header; nil keeps the standard header.
  var hero: (() -> Hero)?
  /// Removes the cover once the exit animation has finished.
  let onDismiss: (@escaping () -> Void) -> Void
  @ViewBuilder var content: () -> Content
  @ViewBuilder var footer: () -> Footer
  let hasFooter: Bool
  @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  #if DEBUG
    @Environment(\.dashTrayReduceMotionOverride) private var reduceMotionOverride
  #endif
  /// Card / paired-shell reveal. Springs with the bottom train — not the dim.
  @State private var progress: CGFloat = 0
  /// Full-screen page dim. Opacity only; never shares the card's offset spring.
  @State private var scrimProgress: CGFloat = 0
  @State private var drag: CGFloat = 0
  @State private var cardHeight: CGFloat = 0
  @State private var keyboardHeight: CGFloat = 0
  @State private var keyboardIsPresented = false
  /// Closing or popping while a software keyboard owns the layout would make
  /// the card animate from a moving bottom edge. Hold the requested action
  /// until UIKit has finished hiding the keyboard, then run one stable tray
  /// transition.
  @State private var keyboardAction: DashTrayKeyboardAction?
  @State private var headerAction: DashSheetHeaderAction?
  @State private var backAction: DashTrayBackAction?
  @State private var contentTitle: String?
  @State private var contentDescription: String?
  @State private var stepRole = DashTrayStepRole.root
  @State private var dismissDisabled = false
  @State private var sharedActionCoordinator = DashTraySharedActionCoordinator()
  /// The destination is live-reported, but the opening endpoint freezes before
  /// animation so layout feedback cannot steer an in-flight action.
  @State private var openingDestinationFrame: CGRect?
  @State private var openingCardFrame: CGRect?
  @State private var closeDestinationFrame: CGRect?
  @State private var closeSourceFrame: CGRect?
  @State private var closeCardFrame: CGRect?
  @State private var liveCardFrame: CGRect = .zero
  @State private var presentationStarted = false
  @State private var sharedProxyOwnsAction = false
  /// A settled drag/scrim/programmatic exit hands the paired reveal to the
  /// established downward slide at their shared identity pose.
  @State private var sharedRevealReleased = false
  /// True once the present animation has visually finished — progress rests
  /// at 1, where both reveal modifiers render identity. The only moment an
  /// exit may hand off between them or retarget the anchor rect.
  @State private var presentationSettled = false
  @State private var isClosing = false
  /// Result-destination flight: liftoff (the submit pill's success check) and
  /// landing (the toast's leading mark), held only while eligible. The mark
  /// carries its toast identity so the check can never fly into an unrelated
  /// success toast that happens to hold the slot.
  @State private var successFlightCoordinator = DashTraySuccessFlightCoordinator()
  @State private var toastMark: DashToastLeadingMark?
  @State private var flight: DashTrayCheckFlight?
  @State private var flightProgress: CGFloat = 0
  @State private var remainingExitStages = 0
  @State private var flightExitStagePending = false
  @State private var pendingDismissCompletion: (() -> Void)?

  private var resolvedTitle: String { contentTitle ?? title }
  private var reduceMotion: Bool {
    #if DEBUG
      reduceMotionOverride ?? accessibilityReduceMotion
    #else
      accessibilityReduceMotion
    #endif
  }

  /// Initial Reduce Motion never resolves a shared action. A mid-presentation
  /// toggle releases this path only at the card's identity pose.
  private var sharedRevealActive: Bool {
    sharedAction != nil && sourceFrame != nil && !sharedRevealReleased
  }

  private var sharedGeometrySnapshot: DashTraySharedGeometrySnapshot? {
    guard sharedRevealActive,
      let sharedAction,
      sharedActionCoordinator.destinationAction == sharedAction,
      let destination = sharedActionCoordinator.destinationFrame,
      destination.width > 1, destination.height > 1,
      liveCardFrame.width > 1, liveCardFrame.height > 1
    else { return nil }
    return DashTraySharedGeometrySnapshot(
      action: sharedAction, destination: destination, card: liveCardFrame)
  }

  private var presentedCardFrame: CGRect {
    if let closeCardFrame { return closeCardFrame }
    if presentationSettled, !liveCardFrame.isEmpty { return liveCardFrame }
    return openingCardFrame ?? liveCardFrame
  }

  private var presentedDestinationFrame: CGRect {
    if let closeDestinationFrame { return closeDestinationFrame }
    if presentationSettled, let live = sharedActionCoordinator.destinationFrame { return live }
    return openingDestinationFrame ?? sharedActionCoordinator.destinationFrame ?? .zero
  }

  var body: some View {
    ZStack(alignment: .bottom) {
      trayScrim
        .opacity(scrimProgress)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { requestClose(reason: .gesture) }
        .accessibilityLabel("Dismiss")
        .accessibilityIdentifier("dash.tray.scrim")
        .accessibilityAddTraits(.isButton)
        .accessibilityHidden(trayInteractionDisabled)

      // We position the card above the keyboard ourselves (padding + an observed
      // height) rather than let SwiftUI's automatic avoidance also push it, which
      // over-lifts it and leaves a dim gap. The card caps its body at the space
      // left above the keyboard and scrolls the rest. As a floating card the
      // lift is plain outer padding — there's no longer an edge-to-edge fill
      // that has to run under the keyboard.
      //
      // The reader extends under the home indicator so bottom tuck is positive
      // padding from the screen edge — negative padding inside a safe-area
      // clipped host was cutting the card's bottom corners off.
      GeometryReader { proxy in
        ZStack {
          if sharedRevealActive, let sharedAction, let sourceFrame {
            DashTraySharedReveal(
              layer: .shell,
              action: sharedAction,
              progress: progress,
              source: closeSourceFrame ?? sourceFrame,
              destination: presentedDestinationFrame,
              card: presentedCardFrame,
              containerOrigin: proxy.frame(in: .global).origin,
              proxyOwnsAction: sharedProxyOwnsAction
            )
          }

          DashSheetCard(
            maxCardHeight: Self.resolvedMaxCardHeight(
              containerHeight: proxy.size.height,
              bottomLift: bottomLift(proxy)),
            hasFooter: hasFooter,
            drawsSurface: !sharedRevealActive,
            sharedRevealProgress: sharedRevealActive ? progress : nil
          ) {
            // Drag-to-dismiss lives on the header (or hero) only, so the
            // scrollable body keeps its own vertical scroll.
            trayHeader
              .contentShape(Rectangle())
              .gesture(dragGesture, including: trayInteractionDisabled ? .none : .all)
          } content: {
            content()
              .allowsHitTesting(presentationSettled && keyboardAction == nil && !isClosing)
          } footer: {
            footer()
              .allowsHitTesting(presentationSettled && keyboardAction == nil && !isClosing)
          }
          .frame(maxWidth: .infinity)
          .fixedSize(horizontal: false, vertical: true)
          .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
            liveCardFrame = frame
          }
          // Rise only the card — never the GeometryReader host. Transforming
          // the full host would slide empty transparent space and read like
          // the page dim is traveling with the tray.
          .modifier(
            DashTrayCardReveal(
              progress: progress, drag: drag, revealOffset: revealOffset,
              reduceMotion: reduceMotion, active: !sharedRevealActive)
          )
          .offset(y: drag)
          .padding(.horizontal, DashTheme.Sheet.floatingMargin)
          .padding(.bottom, bottomLift(proxy))
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
          .allowsHitTesting(keyboardAction == nil && !isClosing)
          #if DEBUG
            .overlay(alignment: .topLeading) {
              Color.clear
              .frame(width: 1, height: 1)
              .accessibilityElement()
              .accessibilityIdentifier("dash.tray.card")
              .accessibilityValue(sharedRevealActive ? "paired" : "standard")
            }
          #endif
          .mask {
            if sharedRevealActive, let sourceFrame {
              DashTraySharedContentMask(
                progress: progress,
                source: closeSourceFrame ?? sourceFrame,
                card: presentedCardFrame,
                containerOrigin: proxy.frame(in: .global).origin
              )
            } else {
              Rectangle()
            }
          }

          if sharedRevealActive, let sharedAction, let sourceFrame {
            DashTraySharedReveal(
              layer: .action,
              action: sharedAction,
              progress: progress,
              source: closeSourceFrame ?? sourceFrame,
              destination: presentedDestinationFrame,
              card: presentedCardFrame,
              containerOrigin: proxy.frame(in: .global).origin,
              proxyOwnsAction: sharedProxyOwnsAction
            )
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.dashTraySharedActionCoordinator, sharedActionCoordinator)
        .environment(
          \.dashTrayProxyOwnedActionID,
          sharedProxyOwnsAction ? sharedAction?.id : nil
        )
      }
      .ignoresSafeArea(.container, edges: .bottom)
      .ignoresSafeArea(.keyboard)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityAddTraits(.isModal)
    .environment(\.dashTrayDismiss, { requestProgrammaticClose() })
    .environment(
      \.dashTrayDismissAfter,
      { completion in
        requestProgrammaticClose(completion: completion)
      }
    )
    .environment(\.dashTrayTone, tone)
    .environment(\.dashTraySuccessFlightCoordinator, successFlightCoordinator)
    .environment(\.dashTraySuccessFlightInProgress, flight != nil)
    .onPreferenceChange(DashSheetFittedHeightKey.self) { cardHeight = $0 }
    .onPreferenceChange(DashSheetHeaderActionKey.self) { headerAction = $0 }
    .onPreferenceChange(DashTrayBackActionKey.self) { backAction = $0 }
    .onPreferenceChange(DashTrayTitleKey.self) { contentTitle = $0 }
    .onPreferenceChange(DashTrayDescriptionKey.self) { contentDescription = $0 }
    .onPreferenceChange(DashTrayStepRoleKey.self) { stepRole = $0 }
    .onPreferenceChange(DashTrayDismissDisabledPreferenceKey.self) { dismissDisabled = $0 }
    .task(id: sharedGeometrySnapshot) {
      guard let snapshot = sharedGeometrySnapshot, !presentationStarted, !isClosing else { return }
      // One rendered-frame stability barrier: if either endpoint changes, the
      // task is cancelled and restarted with the new snapshot.
      try? await Task.sleep(for: .milliseconds(16))
      guard !Task.isCancelled, !presentationStarted, !isClosing,
        sharedGeometrySnapshot == snapshot
      else {
        return
      }
      openingDestinationFrame = snapshot.destination
      openingCardFrame = snapshot.card
      startPresentation()
    }
    .onReceive(
      NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)
    ) { note in
      guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
        let window = UIApplication.shared.connectedScenes
          .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first
      else { return }
      // How far the keyboard covers the window from the bottom (0 when hidden).
      let covered = max(0, window.bounds.height - frame.minY)
      if covered > 0 { keyboardIsPresented = true }
      if reduceMotion {
        keyboardHeight = covered
      } else {
        withAnimation(DashTheme.Motion.settle) { keyboardHeight = covered }
      }
    }
    .onReceive(
      NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)
    ) { _ in
      keyboardHeight = 0
      keyboardIsPresented = false
      guard let keyboardAction else { return }
      self.keyboardAction = nil
      perform(keyboardAction)
    }
    .presentationBackground(.clear)
    .dashToastHost(successFlightInProgress: flight != nil)
    // Above the toast: the check lands *on* the toast's leading mark.
    .overlay { flightOverlay }
    .onPreferenceChange(DashToastLeadingMarkPreferenceKey.self) { mark in
      if mark != nil || !isClosing { toastMark = mark }
    }
    .onChange(of: reduceMotion, initial: true) { previous, reduced in
      guard reduced else { return }
      // The initial callback reports the same value twice; `onAppear` owns the
      // normal reduced-opacity entrance regardless of callback ordering.
      guard previous != reduced else { return }
      if !presentationStarted {
        if sharedRevealActive {
          var transaction = Transaction()
          transaction.disablesAnimations = true
          withTransaction(transaction) {
            sharedProxyOwnsAction = false
            sharedRevealReleased = true
          }
          releaseSharedSource()
        }
        // Preserve the established short reduced-motion opacity transition on
        // an initially reduced presentation.
        startPresentation()
        return
      }

      // A live setting change interrupts spatial motion at the identity pose.
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        if !isClosing { presentationSettled = true }
        presentationStarted = true
        progress = isClosing ? 0 : 1
        scrimProgress = isClosing ? 0 : 1
        sharedProxyOwnsAction = false
        sharedRevealReleased = true
        if isClosing {
          flightProgress = 1
          flight = nil
        }
      }
      releaseSharedSource()
      if isClosing { finishFlightExitStage() }
    }
    .onAppear {
      if !sharedRevealActive { startPresentation() }
    }
    .task {
      // A malformed/conditional destination must not leave a transparent cover
      // parked at progress zero. Give normal layout a short bounded window,
      // then release the reservation and use the standard reveal.
      guard sharedRevealActive, !isClosing else { return }
      try? await Task.sleep(for: .milliseconds(180))
      guard !Task.isCancelled, !presentationStarted, !isClosing else { return }
      fallbackToStandardPresentation()
    }
  }

  private func startPresentation() {
    guard !presentationStarted, !isClosing else { return }

    if sharedRevealActive {
      guard let sharedAction, openingDestinationFrame != nil, openingCardFrame != nil else {
        return
      }
      var activated = false
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        activated = DashTraySourceRegistry.shared.activate(sharedAction.id)
        if activated { sharedProxyOwnsAction = true }
      }
      guard activated else {
        fallbackToStandardPresentation()
        return
      }
    }

    presentationStarted = true
    // Scrim fades in place over the page; the card keeps its own bottom spring.
    withAnimation(reduceMotion ? DashTheme.Motion.reduced : DashTrayMotion.scrimPresent) {
      scrimProgress = 1
    }
    // `.removed`, not `.logicallyComplete`: endpoint ownership changes only
    // once the rendered spring is actually at rest.
    withAnimation(
      reduceMotion ? DashTheme.Motion.reduced : DashTrayMotion.present,
      completionCriteria: .removed
    ) {
      progress = 1
    } completion: {
      guard !isClosing else { return }
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        presentationSettled = true
        sharedProxyOwnsAction = false
      }
    }
  }

  private func fallbackToStandardPresentation() {
    guard !presentationStarted, !isClosing else { return }
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      sharedProxyOwnsAction = false
      sharedRevealReleased = true
      openingDestinationFrame = nil
      openingCardFrame = nil
    }
    releaseSharedSource()
    startPresentation()
  }

  private func releaseSharedSource() {
    guard let sharedAction else { return }
    DashTraySourceRegistry.shared.release(sharedAction.id)
  }

  /// One-shot overlay for the success-check flight. Mounted at progress 0 and
  /// animated from its own `onAppear` so the insertion is committed before the
  /// travel starts (an implicit animation on a freshly inserted view would
  /// render straight at the target). Two same-silhouette glyphs crossfade
  /// along the arc — the check lifts off in the pill's ink and lands in the
  /// toast's green, so neither endpoint pops a foreign color.
  @ViewBuilder private var flightOverlay: some View {
    if let flight {
      GeometryReader { proxy in
        let origin = proxy.frame(in: .global).origin
        ZStack {
          Color.clear
            .contentShape(Rectangle())
          flightCheck(
            flight, in: origin, color: tone?.vividLabel ?? DashTheme.inverse, role: .liftoff)
          flightCheck(flight, in: origin, color: DashTheme.success, role: .landing)
        }
        .onAppear {
          withAnimation(DashTheme.Motion.settle) {
            flightProgress = 1
          } completion: {
            finishFlightExitStage()
          }
        }
      }
      .ignoresSafeArea()
      // The terminal flight owns this brief handoff. Blocking touches keeps
      // the destination toast from being dismissed before the check lands.
      .allowsHitTesting(true)
      .accessibilityHidden(true)
    }
  }

  private func flightCheck(
    _ flight: DashTrayCheckFlight, in origin: CGPoint,
    color: Color, role: DashTrayCheckFlightEffect.ColorRole
  ) -> some View {
    SolarIcon(
      asset: SolarAsset.checkCircleFill,
      size: max(flight.start.height, 1),
      color: color
    )
    .modifier(
      DashTrayCheckFlightEffect(
        progress: flightProgress,
        start: flight.start, end: flight.end,
        containerOrigin: origin, colorRole: role))
  }

  /// A hero replaces the title row outright, so it has nowhere to seat a
  /// description — `dashTrayDescription` is inert under one, by design.
  @ViewBuilder private var trayHeader: some View {
    if let hero {
      DashSheetHeroHeader(
        title: resolvedTitle, showsMenuButtons: showsMenuButtons,
        stepRole: stepRole,
        trailingAction: headerAction, backAction: keyboardAwareBackAction,
        menuButtonsDisabled: trayInteractionDisabled,
        dismiss: { requestClose(reason: .control) }, hero: hero)
    } else {
      DashSheetHeader(
        title: resolvedTitle, description: contentDescription,
        showsMenuButtons: showsMenuButtons, stepRole: stepRole,
        trailingAction: headerAction, backAction: keyboardAwareBackAction,
        menuButtonsDisabled: trayInteractionDisabled,
        dismiss: { requestClose(reason: .control) })
    }
  }

  /// A bounded travel distance keeps tall trays from shooting through hundreds
  /// of points. Fade, blur, and a tiny bottom-anchored scale carry the rest.
  private var revealOffset: CGFloat {
    min(max((cardHeight > 0 ? cardHeight : 400) * 0.28, 80), 160)
  }

  /// Page dim: material blur under a light black veil. Reduce Transparency
  /// keeps the solid veil only so the entrance never depends on a filter.
  @ViewBuilder private var trayScrim: some View {
    ZStack {
      if !reduceTransparency {
        Rectangle().fill(.ultraThinMaterial)
      }
      Color.black.opacity(DashTheme.Sheet.scrimOpacity)
    }
  }

  /// How far to lift the card above the keyboard, in the GeometryReader's space.
  /// The reader extends under the home indicator; `keyboardHeight` is from the
  /// window bottom, so subtract the safe-area inset or the card over-lifts.
  private func keyboardInset(_ proxy: GeometryProxy) -> CGFloat {
    max(0, keyboardHeight - proxy.safeAreaInsets.bottom)
  }

  /// Bottom gap under the floating card from the screen edge (always ≥ 0).
  /// With a home indicator the gap is `safeArea - tuck` so the card sits
  /// slightly into that region without negative padding (which clipped).
  private func bottomLift(_ proxy: GeometryProxy) -> CGFloat {
    let keyboard = keyboardInset(proxy)
    if keyboard > 0 { return keyboard + DashTheme.Sheet.floatingMargin }
    let safe = proxy.safeAreaInsets.bottom
    if safe > 0 {
      return max(0, safe - DashTheme.Sheet.floatingBottomTuck)
    }
    return DashTheme.Sheet.floatingMargin
  }

  /// Geometry can report 0 / non-finite sizes on the first cover layout pass;
  /// never hand `DashSheetCard` a negative max height (SwiftUI then logs
  /// "Invalid frame dimension").
  private static func resolvedMaxCardHeight(
    containerHeight: CGFloat,
    bottomLift: CGFloat
  ) -> CGFloat {
    guard containerHeight.isFinite, bottomLift.isFinite else { return 120 }
    return max(120, containerHeight - bottomLift - 24)
  }

  /// Only ✕ retraces a settled paired action. Drag, scrim, and programmatic
  /// dismissal keep the established downward exit. An interrupted paired
  /// entrance reverses continuously from its current shell/action pose.
  private func close(reason: DashTrayCloseReason = .programmatic) {
    guard !isClosing else { return }
    isClosing = true
    let reversesUnsettledSharedReveal = sharedRevealActive && !presentationSettled
    if sharedRevealActive, presentationSettled {
      if reason == .control {
        // Retarget both endpoints only at settled progress 1, where every
        // possible rect produces the same final card/action pose.
        if let sharedAction,
          let fresh = DashTraySourceRegistry.shared.presentationFrame(
            for: sharedAction.id, in: dashTrayWindowBounds()),
          sharedActionCoordinator.destinationAction == sharedAction,
          let destination = sharedActionCoordinator.destinationFrame
        {
          closeSourceFrame = fresh
          closeDestinationFrame = destination
          closeCardFrame = liveCardFrame
          sharedProxyOwnsAction = true
        } else {
          sharedRevealReleased = true
          sharedProxyOwnsAction = false
        }
      } else {
        sharedRevealReleased = true
        sharedProxyOwnsAction = false
      }
    }
    let flies = beginSuccessFlightIfEligible(reason: reason)
    remainingExitStages = flies ? 2 : 1
    flightExitStagePending = flies
    withAnimation(reduceMotion ? DashTheme.Motion.reduced : DashTrayMotion.scrimDismiss) {
      scrimProgress = 0
    }
    withAnimation(reduceMotion ? DashTheme.Motion.reduced : DashTrayMotion.dismiss) {
      progress = 0
      if reversesUnsettledSharedReveal { drag = 0 }
    } completion: {
      finishExitStage()
    }
  }

  /// The check leaves the pill only on a programmatic (submit-success)
  /// dismissal while the succeeded check and a success toast are both on
  /// screen — failure paths never produced either frame, and ✕ / drag / scrim
  /// carry their own exit semantics. The flight view animates itself from its
  /// `onAppear`; see `flightOverlay`.
  private func beginSuccessFlightIfEligible(reason: DashTrayCloseReason) -> Bool {
    guard reason == .programmatic, !reduceMotion,
      let start = successFlightCoordinator.sourceFrame,
      let mark = toastMark,
      let target = successFlightCoordinator.targetToastID,
      mark.id == target
    else { return false }
    flight = DashTrayCheckFlight(start: start, end: mark.frame)
    #if DEBUG
      NotificationCenter.default.post(name: .dashTraySuccessFlightDidBegin, object: nil)
    #endif
    return true
  }

  private func finishFlightExitStage() {
    guard flightExitStagePending else { return }
    flightExitStagePending = false
    finishExitStage()
  }

  /// The cover unmounts only after every exit animation — card slide/shrink
  /// and, when scheduled, the check flight — has finished.
  private func finishExitStage() {
    remainingExitStages -= 1
    guard remainingExitStages <= 0 else { return }
    drag = 0
    flight = nil
    let completion = pendingDismissCompletion ?? {}
    pendingDismissCompletion = nil
    onDismiss(completion)
  }

  private var trayInteractionDisabled: Bool {
    dismissDisabled || keyboardAction != nil
  }

  private var keyboardAwareBackAction: DashTrayBackAction? {
    guard let backAction else { return nil }
    return DashTrayBackAction(depth: backAction.depth) {
      requestBack(backAction)
    }
  }

  private func requestClose(reason: DashTrayCloseReason) {
    guard !trayInteractionDisabled else { return }
    requestAfterKeyboardDismissal(.close(reason))
  }

  private func requestBack(_ action: DashTrayBackAction) {
    guard !trayInteractionDisabled else { return }
    requestAfterKeyboardDismissal(.back(action))
  }

  /// Content owns the moment a submitted flow is complete. Preserve the
  /// historical ability for that explicit dismissal to close even if the
  /// dismiss-disabled preference has not yet caught up with a same-transaction
  /// `.succeeded → .idle` phase change, while still stabilizing the keyboard.
  private func requestProgrammaticClose(
    completion: @escaping () -> Void = {}
  ) {
    guard keyboardAction == nil else { return }
    pendingDismissCompletion = completion
    requestAfterKeyboardDismissal(.close(.programmatic))
  }

  private func requestAfterKeyboardDismissal(_ action: DashTrayKeyboardAction) {
    guard keyboardIsPresented else {
      perform(action)
      return
    }
    keyboardAction = action
    let requested = UIApplication.shared.sendAction(
      #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    if !requested {
      keyboardAction = nil
      perform(action)
    }
  }

  private func perform(_ action: DashTrayKeyboardAction) {
    switch action {
    case .close(let reason):
      close(reason: reason)
    case .back(let action):
      action.perform()
    }
  }

  private var dragGesture: some Gesture {
    // Global space: measuring in the header's own (moving) coordinates feeds the
    // offset back into the translation and makes the drag flicker.
    DragGesture(coordinateSpace: .global)
      .onChanged { value in
        let raw = value.translation.height
        // Upward overshoot rubber-bands; downward follows 1:1 for dismiss.
        drag = raw < 0 ? TrayDragDecision.rubberBand(cardTop: raw, expandedTop: 0) : raw
      }
      .onEnded { value in
        switch TrayDragDecision.content(
          translation: value.translation.height,
          predictedEndTranslation: value.predictedEndTranslation.height
        ) {
        case .dismiss:
          requestClose(reason: .gesture)
        case .settle:
          if reduceMotion {
            drag = 0
          } else {
            withAnimation(DashTrayMotion.release) { drag = 0 }
          }
        }
      }
  }
}

/// Who asked the tray to leave — decides which exit animation runs.
private enum DashTrayCloseReason {
  /// The header's ✕ circle.
  case control
  /// Header drag or scrim tap.
  case gesture
  /// `\.dashTrayDismiss` from content (submit success, Cancel, Done).
  case programmatic
}

private enum DashTrayKeyboardAction {
  case close(DashTrayCloseReason)
  case back(DashTrayBackAction)
}

// MARK: - Success-check flight (result destination indicator)

/// Direct registration shared down the tray environment. SwiftUI preferences
/// from scroll content can arrive after a same-turn success completion asks the
/// tray to close; this coordinator keeps the current source geometry and toast
/// identity synchronously available through keyboard settlement.
@MainActor
final class DashTraySuccessFlightCoordinator {
  private var sourceToken: UUID?
  private var targetToken: UUID?
  private(set) var sourceFrame: CGRect?
  private(set) var targetToastID: DashToast.ID?

  func updateSource(_ frame: CGRect, token: UUID) {
    sourceToken = token
    sourceFrame = frame
  }

  func clearSource(token: UUID) {
    guard sourceToken == token else { return }
    sourceToken = nil
    sourceFrame = nil
  }

  func updateTarget(_ id: DashToast.ID?, token: UUID) {
    targetToken = token
    targetToastID = id
  }

  func clearTarget(token: UUID) {
    guard targetToken == token else { return }
    targetToken = nil
    targetToastID = nil
  }
}

private struct DashTraySuccessFlightCoordinatorKey: EnvironmentKey {
  static let defaultValue: DashTraySuccessFlightCoordinator? = nil
}

/// The visible success toast's leading mark: its toast identity plus global
/// frame — the flight's landing point. Published by `DashToastCard`;
/// unobserved outside tray hosts. Carrying the identity lets the host refuse
/// to land on an unrelated success toast that happens to hold the slot.
struct DashToastLeadingMark: Equatable {
  let id: DashToast.ID
  let frame: CGRect
}

struct DashToastLeadingMarkPreferenceKey: PreferenceKey {
  static var defaultValue: DashToastLeadingMark? { nil }
  static func reduce(value: inout DashToastLeadingMark?, nextValue: () -> DashToastLeadingMark?) {
    value = nextValue() ?? value
  }
}

private struct DashTraySuccessFlightEnabledKey: EnvironmentKey {
  static let defaultValue = false
}

private struct DashTraySuccessFlightInProgressKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  fileprivate var dashTraySuccessFlightCoordinator: DashTraySuccessFlightCoordinator? {
    get { self[DashTraySuccessFlightCoordinatorKey.self] }
    set { self[DashTraySuccessFlightCoordinatorKey.self] = newValue }
  }

  /// Whether this tray's submit pill reports its success check for the
  /// check-flies-into-the-toast dismissal. Off by default; a deliberately
  /// single-instance exploration (R2 Create bucket), not a general system.
  var dashTraySuccessFlightEnabled: Bool {
    get { self[DashTraySuccessFlightEnabledKey.self] }
    set { self[DashTraySuccessFlightEnabledKey.self] = newValue }
  }

  /// True only while the host-owned glyph is travelling. Source and landing
  /// views keep reporting geometry but hide their own ink so one check owns
  /// every frame of the handoff.
  var dashTraySuccessFlightInProgress: Bool {
    get { self[DashTraySuccessFlightInProgressKey.self] }
    set { self[DashTraySuccessFlightInProgressKey.self] = newValue }
  }
}

extension View {
  /// Opts a tray's submit pill into the one-shot "success check flies into
  /// the toast" exit: on a programmatic dismissal while the pill shows its
  /// success check and a success toast is visible, the check leaves the pill
  /// along a short arc and dissolves into the toast's leading mark. Failure
  /// paths, ✕ / drag / scrim exits, and Reduce Motion are untouched.
  func dashTraySuccessFlight(_ enabled: Bool = true) -> some View {
    environment(\.dashTraySuccessFlightEnabled, enabled)
  }

  /// Names the toast the flight may land on — the ID returned when the
  /// content enqueued its success toast. Without a matching visible toast the
  /// tray keeps its normal programmatic slide.
  func dashTraySuccessFlightTarget(_ id: DashToast.ID?) -> some View {
    modifier(DashTraySuccessFlightTargetModifier(id: id))
  }
}

private struct DashTraySuccessFlightTargetModifier: ViewModifier {
  let id: DashToast.ID?
  @Environment(\.dashTraySuccessFlightCoordinator) private var coordinator
  @State private var token = UUID()

  func body(content: Content) -> some View {
    content
      .onAppear {
        coordinator?.updateTarget(id, token: token)
      }
      .onChange(of: id) { _, newID in
        coordinator?.updateTarget(newID, token: token)
      }
      .onDisappear { coordinator?.clearTarget(token: token) }
  }
}

/// Tracks the succeeded glyph's global frame directly in the tray host's
/// coordinator, including the card's movement while a keyboard settles.
struct DashTraySuccessFlightSourceReporter: View {
  @Environment(\.dashTraySuccessFlightCoordinator) private var coordinator
  @State private var token = UUID()

  var body: some View {
    GeometryReader { proxy in
      let frame = proxy.frame(in: .global)
      Color.clear
        .onAppear {
          coordinator?.updateSource(frame, token: token)
        }
        .onChange(of: frame) { _, newFrame in
          coordinator?.updateSource(newFrame, token: token)
        }
    }
    .onDisappear { coordinator?.clearSource(token: token) }
  }
}

/// Pure geometry for the flight: a quadratic bezier whose apex sits above
/// both endpoints, a start-to-landing size interpolation, and a dissolve over
/// the final quarter of the travel.
enum DashTrayFlightMath {
  /// How far the arc's control point rises above the higher endpoint.
  static let apexLift: CGFloat = 72

  static func point(from: CGPoint, to: CGPoint, progress: CGFloat) -> CGPoint {
    let t = min(max(progress, 0), 1)
    let control = CGPoint(x: (from.x + to.x) / 2, y: min(from.y, to.y) - apexLift)
    let inverse = 1 - t
    return CGPoint(
      x: inverse * inverse * from.x + 2 * inverse * t * control.x + t * t * to.x,
      y: inverse * inverse * from.y + 2 * inverse * t * control.y + t * t * to.y
    )
  }

  static func scale(from start: CGFloat, to end: CGFloat, progress: CGFloat) -> CGFloat {
    guard start > 0 else { return 1 }
    return 1 + (end / start - 1) * min(max(progress, 0), 1)
  }

  /// Fully visible for the first three quarters, then dissolving into the
  /// toast mark it lands on.
  static func opacity(_ progress: CGFloat) -> CGFloat {
    let t = min(max(progress, 0), 1)
    return t < 0.75 ? 1 : max(0, 1 - (t - 0.75) / 0.25)
  }

  /// Liftoff-ink → landing-green crossfade weight: 0 leaving the pill, 1 well
  /// before touchdown, ramping through the middle of the travel.
  static func colorBlend(_ progress: CGFloat) -> CGFloat {
    if progress <= 0.3 { return 0 }
    if progress >= 0.7 { return 1 }
    return (progress - 0.3) / 0.4
  }
}

/// One scheduled flight: where the check lifts off and where it lands.
private struct DashTrayCheckFlight: Equatable {
  let start: CGRect
  let end: CGRect
}

private struct DashTrayCheckFlightEffect: ViewModifier, Animatable {
  /// Which side of the ink → green crossfade this glyph carries. The two
  /// same-silhouette layers ride identical arcs; only their opacity ramps
  /// mirror each other.
  enum ColorRole {
    case liftoff
    case landing
  }

  var progress: CGFloat
  let start: CGRect
  let end: CGRect
  /// The overlay container's global origin, subtracted so global endpoint
  /// frames position correctly inside it.
  let containerOrigin: CGPoint
  var colorRole = ColorRole.landing

  // Nonisolated for the same SE-0434 reason as DashTrayCardReveal.
  nonisolated var animatableData: CGFloat {
    get { progress }
    set { progress = newValue }
  }

  func body(content: Content) -> some View {
    let center = DashTrayFlightMath.point(
      from: CGPoint(x: start.midX, y: start.midY),
      to: CGPoint(x: end.midX, y: end.midY),
      progress: progress
    )
    let blend = DashTrayFlightMath.colorBlend(progress)
    content
      .scaleEffect(
        DashTrayFlightMath.scale(from: start.height, to: end.height, progress: progress)
      )
      .position(x: center.x - containerOrigin.x, y: center.y - containerOrigin.y)
      .opacity(
        DashTrayFlightMath.opacity(progress) * (colorRole == .landing ? blend : 1 - blend))
  }
}

/// The established compact-tray reveal: a bounded rise with fade, blur, and a
/// whisper of bottom-anchored scale, driven by presentation progress.
private struct DashTrayCardReveal: ViewModifier, Animatable {
  var progress: CGFloat
  var drag: CGFloat
  var revealOffset: CGFloat
  var reduceMotion: Bool
  /// False hands presentation to the paired shell/action reveal; the flip only
  /// happens at progress 1, where both paths render the final card pose.
  var active = true

  // Nonisolated: `Animatable` is a nonisolated protocol while `ViewModifier`
  // infers main-actor isolation onto the type; the accessors only touch
  // Sendable stored properties, which SE-0434 leaves nonisolated.
  nonisolated var animatableData: CGFloat {
    get { progress }
    set { progress = newValue }
  }

  @ViewBuilder
  func body(content: Content) -> some View {
    if !active {
      content
    } else if reduceMotion {
      content
        .opacity(progress)
    } else {
      // Card-only fade (the modifier sits on the card, not the full-screen host).
      // Opacity still covers the bounded travel's peek; the page dim is a
      // separate `scrimProgress` and must never ride this spring.
      content
        .offset(y: (1 - progress) * (max(revealOffset, drag + 48) - drag))
        .scaleEffect(0.985 + 0.015 * progress, anchor: .bottom)
        .opacity(min(1, progress * 2))
    }
  }
}

/// Pure geometry for a paired tray reveal. Only rectangles and section alpha
/// interpolate; text, icons, controls, and the final card layout retain native
/// geometry throughout.
enum DashTraySharedRevealMath {
  static func shellProgress(_ progress: CGFloat) -> CGFloat {
    stage(progress, from: 0, to: 0.55)
  }

  static func actionProgress(_ progress: CGFloat) -> CGFloat {
    stage(progress, from: 0, to: 0.48)
  }

  static func stage(_ progress: CGFloat, from start: CGFloat, to end: CGFloat) -> CGFloat {
    guard end > start else { return progress >= end ? 1 : 0 }
    return min(1, max(0, (progress - start) / (end - start)))
  }

  static func rect(from start: CGRect, to end: CGRect, progress: CGFloat) -> CGRect {
    let t = min(1, max(0, progress))
    return CGRect(
      x: start.origin.x + (end.origin.x - start.origin.x) * t,
      y: start.origin.y + (end.origin.y - start.origin.y) * t,
      width: start.width + (end.width - start.width) * t,
      height: start.height + (end.height - start.height) * t
    )
  }

  static func cornerRadius(
    source: CGRect, destination: CGFloat, progress: CGFloat
  ) -> CGFloat {
    let start = source.height / 2
    let t = min(1, max(0, progress))
    return start + (destination - start) * t
  }
}

/// Family-style paired reveal: the surface expands around a native-size action
/// proxy while the laid-out card content appears in staged sections behind it.
/// This sibling layer never transforms `DashSheetCard` itself.
private enum DashTraySharedRevealLayer {
  case shell
  case action
}

private struct DashTraySharedReveal: View, Animatable {
  let layer: DashTraySharedRevealLayer
  let action: DashTraySharedAction
  var progress: CGFloat
  var source: CGRect
  var destination: CGRect
  var card: CGRect
  var containerOrigin: CGPoint
  var proxyOwnsAction: Bool

  nonisolated var animatableData: CGFloat {
    get { progress }
    set { progress = newValue }
  }

  @ViewBuilder var body: some View {
    let shellProgress = DashTraySharedRevealMath.shellProgress(progress)
    let actionProgress = DashTraySharedRevealMath.actionProgress(progress)
    let shell = local(
      DashTraySharedRevealMath.rect(from: source, to: card, progress: shellProgress))
    let proxy = local(
      DashTraySharedRevealMath.rect(from: source, to: destination, progress: actionProgress))
    let corner = DashTraySharedRevealMath.cornerRadius(
      source: source, destination: DashDisplayChrome.floatingRadius, progress: shellProgress)

    ZStack(alignment: .topLeading) {
      Group {
        switch layer {
        case .shell:
          if shell.width > 0, shell.height > 0 {
            DashTrayCardSurface(cornerRadius: corner)
              .frame(width: shell.width, height: shell.height)
              .position(x: shell.midX, y: shell.midY)
              // While layout is finding the destination, the real source still
              // owns the pixels behind this transparent cover. Mount the shell
              // only in the same frame the native-size proxy takes ownership.
              .opacity(proxyOwnsAction || progress > 0 ? 1 : 0)
          }
        case .action:
          if proxy.width > 0, proxy.height > 0 {
            DashActionButton(title: action.title, icon: action.icon, action: {})
              .frame(width: proxy.width, height: proxy.height)
              .position(x: proxy.midX, y: proxy.midY)
              .opacity(proxyOwnsAction ? 1 : 0)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private func local(_ rect: CGRect) -> CGRect {
    rect.offsetBy(dx: -containerOrigin.x, dy: -containerOrigin.y)
  }
}

/// Clips final-layout card content to the same expanding shell rect. The mask
/// changes only rendered visibility; it never proposes a smaller layout to the
/// header, body, footer, or destination reporter.
private struct DashTraySharedContentMask: View, Animatable {
  var progress: CGFloat
  var source: CGRect
  var card: CGRect
  var containerOrigin: CGPoint

  nonisolated var animatableData: CGFloat {
    get { progress }
    set { progress = newValue }
  }

  var body: some View {
    let shellProgress = DashTraySharedRevealMath.shellProgress(progress)
    let global = DashTraySharedRevealMath.rect(
      from: source, to: card, progress: shellProgress)
    let rect = global.offsetBy(dx: -containerOrigin.x, dy: -containerOrigin.y)
    let corner = DashTraySharedRevealMath.cornerRadius(
      source: source, destination: DashDisplayChrome.floatingRadius, progress: shellProgress)

    ZStack(alignment: .topLeading) {
      RoundedRectangle(cornerRadius: corner, style: .continuous)
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

/// Physical display metrics keep the compact tray concentric with the device.
@MainActor
enum DashDisplayChrome {
  /// The display's corner radius; 0 on square-cornered devices.
  static let cornerRadius: CGFloat = {
    let key = ["_display", "Corner", "Radius"].joined()
    let screen = UIApplication.shared.connectedScenes
      .compactMap { ($0 as? UIWindowScene)?.screen }.first
    return (screen?.value(forKey: key) as? CGFloat) ?? 0
  }()

  /// The floating radius follows the hardware inset by the tray's edge margin.
  /// Square-cornered or unavailable displays retain the shared sheet fallback.
  static var floatingRadius: CGFloat {
    cornerRadius > 0
      ? max(cornerRadius - DashTheme.Sheet.floatingMargin, DashTheme.Radius.card)
      : DashTheme.Radius.sheet
  }
}

/// One visual definition for both the resting tray card and the independently
/// expanding paired shell. Sharing it prevents a fill/gradient handoff at the
/// end of the source transition.
private struct DashTrayCardSurface: View {
  let cornerRadius: CGFloat
  @Environment(\.dashTrayTone) private var tone
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .fill(DashTheme.Sheet.background)
      if let tone {
        LinearGradient(
          colors: [tone.vivid.opacity(colorScheme == .dark ? 0.03 : 0.06), .clear],
          startPoint: .top, endPoint: .center
        )
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
  }
}

/// The visible compact tray card, at the bottom of a full-screen
/// transparent cover: a fixed header over a body that animates its height to fit
/// its content — so a morph resizes smoothly with no detent to clip or snap —
/// but caps at the available height (`maxCardHeight`, which shrinks with the
/// keyboard) and scrolls beyond it, so a form never squeezes or overflows.
/// Paints its own canvas fill, top corners, and safe-area extension.
private struct DashSheetCard<Header: View, Body: View, Footer: View>: View {
  let maxCardHeight: CGFloat
  let hasFooter: Bool
  let drawsSurface: Bool
  let sharedRevealProgress: CGFloat?
  @ViewBuilder let header: () -> Header
  @ViewBuilder let content: () -> Body
  @ViewBuilder let footer: () -> Footer
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var headerHeight: CGFloat = 0
  @State private var footerHeight: CGFloat = 0
  @State private var bodyIdeal: CGFloat = 0
  @State private var bodyDisplay: CGFloat = 0

  private var maxBodyHeight: CGFloat {
    guard maxCardHeight.isFinite, headerHeight.isFinite, footerHeight.isFinite else {
      return 80
    }
    return max(80, maxCardHeight - headerHeight - footerHeight)
  }

  /// A tray with its own fixed footer keeps the body's bottom inset symmetric
  /// with its top; without one, the last thing in the body is also the last
  /// thing on the card and takes the home-indicator tuck.
  private var bodyBottomInset: CGFloat {
    hasFooter ? DashTheme.Sheet.bodyVertical : DashTheme.Sheet.bodyBottom
  }

  /// The height budget handed to `content()`: what the body region can show
  /// minus its own insets. Withheld until the header has been measured —
  /// until then `maxBodyHeight` is the whole card and a boundary that trusted
  /// it would size its scroll region to a region that does not exist yet.
  private var contentMaxHeight: CGFloat? {
    guard headerHeight > 0 else { return nil }
    let budget = maxBodyHeight - DashTheme.Sheet.bodyVertical - bodyBottomInset
    guard budget.isFinite else { return nil }
    return max(0, budget)
  }

  private var headerReveal: CGFloat {
    guard let sharedRevealProgress else { return 1 }
    // The shell reaches its final rect at 0.55; no final-position header ink
    // appears before there is surface behind it.
    return DashTraySharedRevealMath.stage(sharedRevealProgress, from: 0.55, to: 0.78)
  }

  private var bodyReveal: CGFloat {
    guard let sharedRevealProgress else { return 1 }
    return DashTraySharedRevealMath.stage(sharedRevealProgress, from: 0.60, to: 0.88)
  }

  private var footerReveal: CGFloat {
    guard let sharedRevealProgress else { return 1 }
    return DashTraySharedRevealMath.stage(sharedRevealProgress, from: 0.44, to: 0.72)
  }

  /// Explicit body viewport once measured. `nil` only on the first pass so the
  /// scroll child can hug content and publish `bodyIdeal` — a `0` height would
  /// never measure. After that, always pin so the white surface cannot stretch.
  private var resolvedBodyHeight: CGFloat? {
    let candidate: CGFloat
    if bodyDisplay > 0 {
      candidate = bodyDisplay
    } else if bodyIdeal > 0 {
      candidate = min(bodyIdeal, maxBodyHeight)
    } else {
      return nil
    }
    guard candidate.isFinite, candidate >= 0 else { return nil }
    return candidate
  }

  var body: some View {
    VStack(spacing: 0) {
      header()
        .opacity(headerReveal)
        .offset(y: 8 * (1 - headerReveal))
        .background {
          GeometryReader { proxy in
            Color.clear.preference(key: DashSheetHeaderHeightKey.self, value: proxy.size.height)
          }
        }

      DashFadedScrollView(
        surface: DashTheme.Sheet.background,
        bounceBasedOnSize: true,
        dismissesKeyboardInteractively: true
      ) {
        // The body owns its margins so every tray breathes the same: content
        // pieces must not add their own horizontal or bottom padding.
        content()
          .environment(\.dashTrayBodyMaxHeight, contentMaxHeight)
          .frame(maxWidth: .infinity, alignment: .top)
          .padding(.horizontal, DashTheme.Sheet.content)
          .padding(.top, DashTheme.Sheet.bodyVertical)
          .padding(.bottom, bodyBottomInset)
          .fixedSize(horizontal: false, vertical: true)
          .background {
            GeometryReader { proxy in
              Color.clear.preference(key: DashSheetBodyIdealKey.self, value: proxy.size.height)
            }
          }
      }
      .frame(height: resolvedBodyHeight, alignment: .top)
      .fixedSize(horizontal: false, vertical: resolvedBodyHeight == nil)
      .opacity(bodyReveal)
      .offset(y: 10 * (1 - bodyReveal))

      if hasFooter {
        footer()
          .frame(maxWidth: .infinity)
          .padding(.horizontal, DashTheme.Sheet.content)
          .padding(.bottom, DashTheme.Sheet.bodyBottom)
          .background {
            GeometryReader { proxy in
              Color.clear.preference(
                key: DashSheetFooterHeightKey.self,
                value: proxy.size.height
              )
            }
          }
          .opacity(footerReveal)
      }
    }
    .frame(maxWidth: .infinity)
    // Hug header + fitted body + footer. Do not apply a tall `maxHeight` frame
    // after this — that expands the white surface past the content.
    .fixedSize(horizontal: false, vertical: true)
    // A floating card: one stable all-corner radius, and nothing extends past
    // the card — the gaps around it are the design.
    .background {
      if drawsSurface {
        DashTrayCardSurface(cornerRadius: DashDisplayChrome.floatingRadius)
      }
    }
    .clipShape(
      RoundedRectangle(cornerRadius: DashDisplayChrome.floatingRadius, style: .continuous)
    )
    .background {
      GeometryReader { proxy in
        Color.clear.preference(key: DashSheetFittedHeightKey.self, value: proxy.size.height)
      }
    }
    .onPreferenceChange(DashSheetHeaderHeightKey.self) { height in
      guard height.isFinite, height >= 0 else { return }
      headerHeight = height
    }
    .onPreferenceChange(DashSheetFooterHeightKey.self) { height in
      guard height.isFinite, height >= 0 else { return }
      footerHeight = height
    }
    .onPreferenceChange(DashSheetBodyIdealKey.self) { ideal in
      guard ideal.isFinite, ideal >= 0 else { return }
      bodyIdeal = ideal
      applyBody(animated: bodyDisplay != 0)
    }
    .onChange(of: maxBodyHeight) { _, _ in applyBody(animated: true) }
  }

  private func applyBody(animated: Bool) {
    let target = min(bodyIdeal, maxBodyHeight)
    guard target.isFinite, target > 0 else { return }
    if animated, !reduceMotion {
      withAnimation(DashTrayMotion.resize) { bodyDisplay = target }
    } else {
      var transaction = Transaction()
      transaction.disablesAnimations = reduceMotion
      withTransaction(transaction) { bodyDisplay = target }
    }
  }
}

/// Height arithmetic for the tray's scroll boundary, kept out of the view so
/// the one rule that decides what scrolls is testable.
enum DashTrayScrollBoundaryRules {
  /// The floor the scrolling body keeps whatever the action band costs. Below
  /// it the boundary stops shrinking and the card's own body scroll takes the
  /// overflow — a squeezed tray (a tall band under a raised keyboard) scrolls
  /// as a whole rather than showing a body region too short to read.
  static let minimumBody: CGFloat = 80

  /// The height of the scrolling region, or `nil` for "lay out naturally".
  ///
  /// - `available`: the content budget from `\.dashTrayBodyMaxHeight`; `nil`
  ///   outside a tray, where nothing constrains the card.
  /// - `action`: the measured action band, which never scrolls and is paid
  ///   for first.
  /// - `ideal`: the body's own measured height; 0 before it is measured.
  static func bodyHeight(ideal: CGFloat, action: CGFloat, available: CGFloat?) -> CGFloat? {
    guard let available, ideal > 0 else { return nil }
    return min(ideal, max(minimumBody, available - action))
  }
}

private struct DashTrayBoundaryBodyIdealKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

/// The tray's scroll boundary: the body scrolls, the action band under it does
/// not. Every tray's title sits in the fixed header and its submit pill sits on
/// the fixed floor of the card — reaching a form's action must never mean
/// scrolling to find it, and a long list must never push it off the card.
///
/// The card publishes what room it has (`\.dashTrayBodyMaxHeight`); the band is
/// measured and paid for first, and the body takes what is left, scrolling
/// inside it. With no budget — outside a tray, or on the first frame before the
/// header is measured — both regions lay out at natural height and the scroll
/// view never scrolls, which is exactly what the card's own body scroll used to
/// do on its own.
///
/// It nests inside the card's body scroll on purpose: sized this way the
/// content always fits that scroll exactly, so the outer one stays inert (no
/// bounce, no edge fade, no gesture) while this one owns the finger. Do not
/// hoist it into `DashSheetCard`'s footer slot — body and band share the state
/// that morphs them together (`DashConfirmMorph`'s `confirming`, its matched
/// geometry), and a slot in the card is a different view tree.
struct DashTrayScrollBoundary<Content: View, Action: View>: View {
  @ViewBuilder let content: () -> Content
  @ViewBuilder let action: () -> Action
  @Environment(\.dashTrayBodyMaxHeight) private var available
  @State private var bodyIdeal: CGFloat = 0
  @State private var actionHeight: CGFloat = 0

  private var bodyHeight: CGFloat? {
    DashTrayScrollBoundaryRules.bodyHeight(
      ideal: bodyIdeal, action: actionHeight, available: available)
  }

  var body: some View {
    VStack(spacing: 0) {
      DashFadedScrollView(
        surface: DashTheme.Sheet.background,
        bounceBasedOnSize: true,
        dismissesKeyboardInteractively: true
      ) {
        content()
          .frame(maxWidth: .infinity, alignment: .top)
          .background {
            GeometryReader { proxy in
              Color.clear.preference(
                key: DashTrayBoundaryBodyIdealKey.self, value: proxy.size.height)
            }
          }
      }
      // An exact height, not a cap: inside the card's scroll the incoming
      // proposal carries no useful height, and a `maxHeight` would leave a
      // greedy scroll view to resolve against whatever it was handed.
      .frame(height: bodyHeight)

      action()
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { actionHeight = $0 }
    }
    .onPreferenceChange(DashTrayBoundaryBodyIdealKey.self) { bodyIdeal = $0 }
  }
}

// The full-screen cover must mount and unmount with *no* system slide — that
// transition would translate the scrim and card together from the bottom, which
// makes an opacity-only dim look like it rises with the tray. UIKit's modal
// animation is not always suppressed by a SwiftUI transaction alone on recent
// OS releases, so briefly disable UIView animations around the binding write.
// Re-enable synchronously afterward so `DashCustomSheet`'s entrance springs
// (started from `onAppear`) are not swallowed.
private func dashPresentWithoutAnimation(_ apply: () -> Void) {
  // SwiftUI view-update callbacks always run on the main thread, so assume the
  // main actor synchronously for the UIKit calls rather than hop: the whole
  // point is that animations are disabled for the duration of `apply`. Only the
  // two `UIView` calls are isolated here so the non-`Sendable` `apply` closure
  // is never captured into a sendable `@MainActor` context.
  var transaction = Transaction()
  transaction.disablesAnimations = true
  MainActor.assumeIsolated {
    UIView.setAnimationsEnabled(false)
  }
  withTransaction(transaction, apply)
  MainActor.assumeIsolated {
    UIView.setAnimationsEnabled(true)
  }
}

/// Resolves and reserves a paired source at present time. Reduce Motion never
/// takes the spatial path; the standard fade is already the correct answer.
struct DashTraySharedActionClaim {
  let action: DashTraySharedAction
  let frame: CGRect
}

/// Owns a registry claim for exactly as long as its presenter modifier lives.
/// A session/auth transition can tear that subtree down while its binding is
/// still true, so relying only on the binding's `false` edge would leave the
/// singleton registry occupied and the matching Home tile hidden forever.
@MainActor
final class DashTraySharedActionLease {
  private let registry: DashTraySourceRegistry
  private var sourceID: String?

  init(registry: DashTraySourceRegistry = .shared) {
    self.registry = registry
  }

  func adopt(_ claim: DashTraySharedActionClaim?) {
    guard sourceID != claim?.action.id else { return }
    release()
    sourceID = claim?.action.id
  }

  func release() {
    guard let sourceID else { return }
    registry.release(sourceID)
    self.sourceID = nil
  }

  isolated deinit {
    release()
  }
}

@MainActor private func dashTrayResolveSharedAction(
  _ action: DashTraySharedAction?, reduceMotion: Bool
) -> DashTraySharedActionClaim? {
  guard let action, !reduceMotion else { return nil }
  guard
    let frame = DashTraySourceRegistry.shared.presentationFrame(
      for: action.id, in: dashTrayWindowBounds()),
    DashTraySourceRegistry.shared.claim(action.id)
  else { return nil }
  return DashTraySharedActionClaim(action: action, frame: frame)
}

/// Carries the trigger geometry and presented value through one state write.
/// A separate `covered = true` write can make `fullScreenCover` capture the
/// previous frame on Xcode 26, leaving the source claimed while the card takes
/// the unanchored path.
private struct DashTrayCoverPresentation<Value>: Identifiable {
  let id = UUID()
  let value: Value
  let sharedAction: DashTraySharedAction?
  let sourceFrame: CGRect?
}

private struct DashTrayModifier<Hero: View, TrayContent: View, Footer: View>: ViewModifier {
  @Binding var isPresented: Bool
  let title: String
  var showsMenuButtons = true
  var tone: FeatureVisualTone? = nil
  var sharedAction: DashTraySharedAction? = nil
  var hero: (() -> Hero)?
  @ViewBuilder var trayContent: () -> TrayContent
  @ViewBuilder var footer: () -> Footer
  let hasFooter: Bool
  @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
  #if DEBUG
    @Environment(\.dashTrayReduceMotionOverride) private var reduceMotionOverride
  #endif
  @State private var coverPresentation: DashTrayCoverPresentation<Bool>?
  @State private var sharedActionLease = DashTraySharedActionLease()
  @State private var dismissCompletion: (() -> Void)?
  @State private var presentationReporterID = UUID()
  @Environment(\.dashWorkspacePresentationState) private var workspacePresentationState
  @Environment(\.dashNavigationEntryID) private var navigationEntryID

  private var reduceMotion: Bool {
    #if DEBUG
      reduceMotionOverride ?? accessibilityReduceMotion
    #else
      accessibilityReduceMotion
    #endif
  }

  @ViewBuilder
  func body(content: Content) -> some View {
    content
      .preference(
        key: TrayPresentedPreferenceKey.self,
        value: DashTrayPresentation(presented: isPresented)
      )
      .onChange(of: isPresented, initial: true) { _, present in
        workspacePresentationState?.setTrayPresented(
          present,
          reporterID: presentationReporterID,
          entryID: navigationEntryID)
        if present {
          let claim = dashTrayResolveSharedAction(sharedAction, reduceMotion: reduceMotion)
          sharedActionLease.adopt(claim)
          let presentation = DashTrayCoverPresentation(
            value: true, sharedAction: claim?.action, sourceFrame: claim?.frame)
          dashPresentWithoutAnimation { coverPresentation = presentation }
        } else {
          sharedActionLease.release()
          dashPresentWithoutAnimation { coverPresentation = nil }
        }
      }
      .onAppear {
        workspacePresentationState?.setTrayPresented(
          isPresented,
          reporterID: presentationReporterID,
          entryID: navigationEntryID)
      }
      .fullScreenCover(
        item: $coverPresentation,
        onDismiss: {
          sharedActionLease.release()
          isPresented = false
          let completion = dismissCompletion
          dismissCompletion = nil
          completion?()
        },
        content: { presentation in
          DashCustomSheet(
            title: title, showsMenuButtons: showsMenuButtons, tone: tone,
            sharedAction: presentation.sharedAction, sourceFrame: presentation.sourceFrame,
            hero: hero,
            onDismiss: { completion in
              dismissCompletion = completion
              // Keep the external presentation state alive until UIKit has
              // actually removed the cover. Callers use that state to gate
              // competing presentations such as pending Home deep links.
              dashPresentWithoutAnimation { coverPresentation = nil }
            }, content: trayContent,
            footer: footer, hasFooter: hasFooter)
        }
      )
      // Belt with the binding transaction: keep the cover's own present/dismiss
      // transition from sliding the whole host (scrim included).
      .transaction { $0.disablesAnimations = true }
  }
}

private struct DashTrayItemModifier<Item: Identifiable & Equatable, Hero: View, TrayContent: View>:
  ViewModifier
{
  @Binding var item: Item?
  let title: (Item) -> String
  var showsMenuButtons = true
  var tone: FeatureVisualTone? = nil
  var sharedAction: DashTraySharedAction? = nil
  var hero: ((Item) -> Hero)?
  @ViewBuilder var trayContent: (Item) -> TrayContent
  @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
  #if DEBUG
    @Environment(\.dashTrayReduceMotionOverride) private var reduceMotionOverride
  #endif
  @State private var coverPresentation: DashTrayCoverPresentation<Item>?
  @State private var sharedActionLease = DashTraySharedActionLease()
  @State private var dismissCompletion: (() -> Void)?
  @State private var presentationReporterID = UUID()
  @Environment(\.dashWorkspacePresentationState) private var workspacePresentationState
  @Environment(\.dashNavigationEntryID) private var navigationEntryID

  private var isPresented: Bool { item != nil }
  private var reduceMotion: Bool {
    #if DEBUG
      reduceMotionOverride ?? accessibilityReduceMotion
    #else
      accessibilityReduceMotion
    #endif
  }

  @ViewBuilder
  func body(content: Content) -> some View {
    content
      .preference(
        key: TrayPresentedPreferenceKey.self,
        value: DashTrayPresentation(presented: isPresented)
      )
      .onChange(of: item, initial: true) { _, newItem in
        workspacePresentationState?.setTrayPresented(
          newItem != nil,
          reporterID: presentationReporterID,
          entryID: navigationEntryID)
        if let newItem {
          let claim = dashTrayResolveSharedAction(sharedAction, reduceMotion: reduceMotion)
          sharedActionLease.adopt(claim)
          let presentation = DashTrayCoverPresentation(
            value: newItem, sharedAction: claim?.action, sourceFrame: claim?.frame)
          dashPresentWithoutAnimation { coverPresentation = presentation }
        } else {
          sharedActionLease.release()
          dashPresentWithoutAnimation { coverPresentation = nil }
        }
      }
      .onAppear {
        workspacePresentationState?.setTrayPresented(
          isPresented,
          reporterID: presentationReporterID,
          entryID: navigationEntryID)
      }
      .fullScreenCover(
        item: $coverPresentation,
        onDismiss: {
          sharedActionLease.release()
          item = nil
          let completion = dismissCompletion
          dismissCompletion = nil
          completion?()
        },
        content: { presentation in
          DashCustomSheet<Hero, TrayContent, EmptyView>(
            title: title(presentation.value), showsMenuButtons: showsMenuButtons, tone: tone,
            sharedAction: presentation.sharedAction, sourceFrame: presentation.sourceFrame,
            hero: hero.map { hero in { hero(presentation.value) } },
            onDismiss: { completion in
              dismissCompletion = completion
              // Match the Bool-backed modifier: the item remains presented
              // through the native dismissal so another cover cannot race it.
              dashPresentWithoutAnimation { coverPresentation = nil }
            }, content: { trayContent(presentation.value) },
            footer: { EmptyView() }, hasFooter: false)
        }
      )
      .transaction { $0.disablesAnimations = true }
  }
}
