import Combine
import SwiftUI
import UIKit

// MARK: - Sheet presentation

/// Whether a subtree currently presents the app's single compact tray, bubbled
/// to `MainTabView` so root chrome can hide the dock and header avatar.
struct DashTrayPresentation: Equatable {
  var presented = false
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

// MARK: - Anchored tray presentation (Family's "the tray grows out of the button")

/// Global-frame registry connecting a tray's trigger control to its
/// presentation. `.dashTraySource(id:)` keeps a control's global frame current
/// here; `dashTray(sourceID:)` reads it once at present time and freezes it, so
/// scrolling under the scrim never drags the reveal target around. Frames are
/// plain (untracked) storage — only `occupiedID`, which hides the source while
/// its tray is up (a component may never duplicate itself mid-animation), is
/// observable.
@MainActor
@Observable
final class DashTraySourceRegistry {
  static let shared = DashTraySourceRegistry()

  /// The source currently replaced by a presented tray; that control renders
  /// at opacity 0 until the tray fully leaves.
  private(set) var occupiedID: AnyHashable?
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

  /// Claims the one source slot. A second presentation must fall back to the
  /// unanchored reveal instead of making the first tray's source reappear.
  @discardableResult
  func claim(_ id: AnyHashable) -> Bool {
    guard occupiedID == nil || occupiedID == id else { return false }
    occupiedID = id
    return true
  }

  func release(_ id: AnyHashable) {
    guard occupiedID == id else { return }
    occupiedID = nil
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

/// Rect-to-rect mapping for the anchored reveal: at progress 0 the full card
/// renders scaled and translated onto the source rect; at 1 it is untouched.
/// One transform of the whole card — never per-property layout animation.
enum DashTrayAnchorMath {
  struct Transform: Equatable {
    var scaleX: CGFloat
    var scaleY: CGFloat
    var offsetX: CGFloat
    var offsetY: CGFloat
  }

  static func transform(source: CGRect, card: CGRect, progress: CGFloat) -> Transform {
    guard card.width > 0, card.height > 0 else {
      return Transform(scaleX: 1, scaleY: 1, offsetX: 0, offsetY: 0)
    }
    let remaining = 1 - progress
    let scaleX = 1 + (source.width / card.width - 1) * remaining
    let scaleY = 1 + (source.height / card.height - 1) * remaining
    return Transform(
      scaleX: scaleX,
      scaleY: scaleY,
      offsetX: (source.midX - card.midX) * remaining,
      offsetY: (source.midY - card.midY) * remaining
    )
  }

  /// The growing card turns opaque in the first third of the travel so the
  /// hidden source never leaves a hole, without popping in full-strength at
  /// frame zero.
  static func opacity(progress: CGFloat) -> CGFloat {
    min(1, max(0, progress * 3))
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
  /// Marks this control as a tray anchor: a `dashTray(sourceID:)` matching
  /// `id` presents by growing out of this control's frame and, on ✕, shrinks
  /// back into it. The control hides while its tray is up. IDs must be unique
  /// among simultaneously visible sources; reuse the control's accessibility
  /// identifier.
  func dashTraySource(id: AnyHashable) -> some View {
    modifier(DashTraySourceModifier(id: id))
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
  /// `sourceID` names a `.dashTraySource(id:)` control: when its frame is
  /// available the tray grows out of it and ✕ shrinks back into it; drag and
  /// scrim keep the downward exit, and without a resolvable source the
  /// presentation is byte-identical to the plain bottom reveal.
  func dashTray<Content: View>(
    isPresented: Binding<Bool>,
    title: String,
    showsMenuButtons: Bool = true,
    tone: FeatureVisualTone? = nil,
    sourceID: AnyHashable? = nil,
    @ViewBuilder content: @escaping () -> Content
  ) -> some View {
    modifier(
      DashTrayModifier<EmptyView, Content, EmptyView>(
        isPresented: isPresented, title: title,
        showsMenuButtons: showsMenuButtons, tone: tone, sourceID: sourceID, hero: nil,
        trayContent: content, footer: { EmptyView() }, hasFooter: false))
  }

  /// A floating content tray with three stable chrome regions: fixed header,
  /// independently scrolling body, and fixed action footer. Use this when a
  /// multi-step body morphs above controls that must retain one screen position.
  func dashTray<Content: View, Footer: View>(
    isPresented: Binding<Bool>,
    title: String,
    showsMenuButtons: Bool = true,
    tone: FeatureVisualTone? = nil,
    sourceID: AnyHashable? = nil,
    @ViewBuilder content: @escaping () -> Content,
    @ViewBuilder footer: @escaping () -> Footer
  ) -> some View {
    modifier(
      DashTrayModifier<EmptyView, Content, Footer>(
        isPresented: isPresented, title: title,
        showsMenuButtons: showsMenuButtons, tone: tone, sourceID: sourceID, hero: nil,
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
    sourceID: AnyHashable? = nil,
    @ViewBuilder hero: @escaping () -> Hero,
    @ViewBuilder content: @escaping () -> Content
  ) -> some View {
    modifier(
      DashTrayModifier<Hero, Content, EmptyView>(
        isPresented: isPresented, title: title,
        showsMenuButtons: showsMenuButtons, tone: tone, sourceID: sourceID, hero: hero,
        trayContent: content, footer: { EmptyView() }, hasFooter: false))
  }

  func dashTray<Item: Identifiable & Equatable, Content: View>(
    item: Binding<Item?>,
    title: @escaping (Item) -> String,
    showsMenuButtons: Bool = true,
    tone: FeatureVisualTone? = nil,
    sourceID: AnyHashable? = nil,
    @ViewBuilder content: @escaping (Item) -> Content
  ) -> some View {
    modifier(
      DashTrayItemModifier<Item, EmptyView, Content>(
        item: item, title: title,
        showsMenuButtons: showsMenuButtons, tone: tone, sourceID: sourceID, hero: nil,
        trayContent: content)
    )
  }

  /// Item-driven variant of the hero tray; see the `isPresented` overload.
  func dashTray<Item: Identifiable & Equatable, Hero: View, Content: View>(
    item: Binding<Item?>,
    title: @escaping (Item) -> String,
    showsMenuButtons: Bool = true,
    tone: FeatureVisualTone? = nil,
    sourceID: AnyHashable? = nil,
    @ViewBuilder hero: @escaping (Item) -> Hero,
    @ViewBuilder content: @escaping (Item) -> Content
  ) -> some View {
    modifier(
      DashTrayItemModifier(
        item: item, title: title,
        showsMenuButtons: showsMenuButtons, tone: tone, sourceID: sourceID, hero: hero,
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
/// by the tray header, which morphs its close circle from ✕ into ← and pops one
/// step instead of dismissing. Equality is depth-only, matching
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
///   publishes the header back control: at any depth the tray's ✕ morphs into ←
///   and pops one step. Steps gain a directional slide (`trayStepSlide`) so
///   progression and return read as travel, not teleport. Terminal success
///   steps must *replace* the stack (`path = [.done]`), never push — a back
///   control over a committed action would reopen its form.
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

/// The tray's one dismissal circle, in two poses: ✕ closes the tray on a root
/// step; when a stack flow publishes a back action, the same circle morphs
/// into ← and pops one step instead. One control, two meanings — the morph is
/// what tells the user the button's job changed (Family's chevron rule).
/// Drag and scrim are unaffected: they always dismiss the whole tray.
private struct DashTrayDismissButton: View {
  let backAction: DashTrayBackAction?
  let dismiss: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.layoutDirection) private var layoutDirection

  private var isBack: Bool { backAction != nil }
  private var backAsset: String {
    layoutDirection == .rightToLeft ? SolarAsset.chevronRight : SolarAsset.chevronLeft
  }
  private var morphDirection: Double { layoutDirection == .rightToLeft ? 1 : -1 }

  var body: some View {
    Button {
      if let backAction {
        backAction.perform()
      } else {
        dismiss()
      }
    } label: {
      ZStack {
        SolarIcon(asset: SolarAsset.close, size: 22, color: DashTheme.Sheet.closeIcon)
          .opacity(isBack ? 0 : 1)
          .rotationEffect(.degrees(reduceMotion ? 0 : (isBack ? 90 * morphDirection : 0)))
        SolarIcon(asset: backAsset, size: 22, color: DashTheme.Sheet.closeIcon)
          .opacity(isBack ? 1 : 0)
          .rotationEffect(.degrees(reduceMotion ? 0 : (isBack ? 0 : -90 * morphDirection)))
      }
      .frame(width: 32, height: 32)
      .background(DashTheme.recessed, in: Circle())
      .dashCompactHitTarget()
      .animation(
        reduceMotion ? DashTheme.Motion.reduced : DashTheme.Motion.iconSwap,
        value: isBack
      )
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
/// The dim fades and the card slides up from the bottom (and dismisses the
/// same way), independently of the cover (see DashTrayModifier).
private struct DashCustomSheet<Hero: View, Content: View, Footer: View>: View {
  let title: String
  var showsMenuButtons = true
  /// Contextual tone; nil keeps the neutral tray. See `\.dashTrayTone`.
  var tone: FeatureVisualTone? = nil
  /// Anchor pair, resolved by the presenting modifier: the source control's
  /// registry id plus its frozen global frame at present time. Nil keeps the
  /// plain bottom reveal.
  var sourceID: AnyHashable? = nil
  var sourceFrame: CGRect? = nil
  /// Full-bleed view replacing the title header; nil keeps the standard header.
  var hero: (() -> Hero)?
  /// Removes the cover once the exit animation has finished.
  let onDismiss: (@escaping () -> Void) -> Void
  @ViewBuilder var content: () -> Content
  @ViewBuilder var footer: () -> Footer
  let hasFooter: Bool
  @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
  #if DEBUG
    @Environment(\.dashTrayReduceMotionOverride) private var reduceMotionOverride
  #endif
  @State private var progress: CGFloat = 0
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
  /// Set when a settled drag/scrim/programmatic exit hands the card from the
  /// anchored reveal to the downward slide — the flip only happens where both
  /// modifiers render identity. Never set mid-animation.
  @State private var anchorReleased = false
  /// The rect the ✕ retract returns into: the source's *current* frame read
  /// at close time. Nil (entrance and fallback) keeps the frozen present-time
  /// `sourceFrame`.
  @State private var closeAnchorRect: CGRect?
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

  /// Whether the anchored reveal drives the card. Derived, never armed by a
  /// lifecycle callback: an anchored tray is anchored from its very first
  /// frame, so there is no pre-`onAppear` window rendering under the slide
  /// modifier. Deliberately independent of the *live* Reduce Motion value —
  /// initial Reduce Motion never resolves a `sourceFrame` at all, and a
  /// mid-presentation toggle must not swap modifiers away from identity, so
  /// ownership flips off only via `anchorReleased`, at settled identity.
  private var anchorActive: Bool {
    sourceFrame != nil && !anchorReleased
  }

  var body: some View {
    ZStack(alignment: .bottom) {
      Color.black.opacity(progress * DashTheme.Sheet.scrimOpacity)
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
      GeometryReader { proxy in
        DashSheetCard(
          maxCardHeight: proxy.size.height - bottomLift(proxy) - 24,
          hasFooter: hasFooter
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
        .padding(.horizontal, DashTheme.Sheet.floatingMargin)
        .allowsHitTesting(keyboardAction == nil && !isClosing)
        #if DEBUG
          .overlay(alignment: .topLeading) {
            Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityIdentifier("dash.tray.card")
            .accessibilityValue(anchorActive ? "anchored" : "unanchored")
          }
        #endif
        // Anchored reveal: one whole-card transform mapping its laid-out rect
        // onto the source control's rect — never per-property layout
        // animation. Inert whenever this tray has no anchor. The card rect is
        // *derived* from layout inputs (see `anchoredCardRect`), never
        // measured through the reveal transforms, so the mapping cannot feed
        // back into its own input regardless of callback timing.
        .modifier(
          DashTrayAnchorReveal(
            progress: progress, active: anchorActive,
            source: closeAnchorRect ?? sourceFrame ?? .zero,
            card: anchoredCardRect(proxy))
        )
        .padding(.bottom, bottomLift(proxy))
        // Bottom-pinned slide: a bounded fraction of the card height plus
        // opacity, blur, and scale — tall trays never shoot in from far away.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .modifier(
          DashTrayCardReveal(
            progress: progress, drag: drag, revealOffset: revealOffset,
            reduceMotion: reduceMotion, active: !anchorActive)
        )
        // Gesture travel is its own animatable layer. Keeping it outside the
        // progress-driven reveal prevents a drag update from retargeting an
        // in-flight presentation spring's progress.
        .offset(y: drag)
      }
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
    .onChange(of: reduceMotion, initial: true) { _, reduced in
      // Enabling Reduce Motion is the one legal interruption of an unsettled
      // anchored reveal: swap directly to the identity pose without another
      // spatial animation, then keep the reduced fade path for dismissal.
      // `progress` already holds its model-space target of 1 while SwiftUI is
      // rendering the spring, so replacing the modifier is what cancels the
      // presentation-layer transform.
      guard reduced else { return }
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        if !isClosing { presentationSettled = true }
        anchorReleased = true
        if isClosing {
          flightProgress = 1
          flight = nil
        }
      }
      if isClosing { finishFlightExitStage() }
    }
    .onAppear {
      // `.removed`, not `.logicallyComplete`: the present spring has a long
      // tail, and `presentationSettled` gates handoffs and anchor-rect
      // retargeting that are only legal once the rendered pose actually
      // rests at identity. An early exit retargets progress before removal,
      // so the completion then fires with `isClosing` already guarding
      // every settled-only path.
      withAnimation(
        reduceMotion ? DashTheme.Motion.reduced : DashTrayMotion.present,
        completionCriteria: .removed
      ) {
        progress = 1
      } completion: {
        presentationSettled = true
      }
    }
  }

  /// The card's final laid-out global rect, derived purely from layout
  /// inputs: the container's global frame (the GeometryReader sits above
  /// every reveal transform), the card's fitted-height preference (a layout
  /// size — render transforms never touch it), and the same horizontal
  /// margin and bottom lift the layout applies below. Because nothing here
  /// is measured through the transforms, the anchored mapping cannot feed
  /// back into itself and no assumption about geometry-callback ordering is
  /// needed. Zero until the fitted height lands (a frame or two after
  /// insertion), where the anchor modifier draws its no-scale fallback at
  /// near-zero progress opacity.
  private func anchoredCardRect(_ proxy: GeometryProxy) -> CGRect {
    guard anchorActive, cardHeight > 0 else { return .zero }
    let container = proxy.frame(in: .global)
    let margin = DashTheme.Sheet.floatingMargin
    let lift = bottomLift(proxy)
    return CGRect(
      x: container.minX + margin,
      y: container.maxY - lift - cardHeight,
      width: container.width - margin * 2,
      height: cardHeight)
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

  /// How far to lift the card above the keyboard, in the GeometryReader's space.
  /// `keyboardHeight` is measured from the window bottom (home indicator
  /// included), but the reader already sits above the home indicator, so subtract
  /// that inset or the card over-lifts and leaves a dim gap.
  private func keyboardInset(_ proxy: GeometryProxy) -> CGFloat {
    max(0, keyboardHeight - proxy.safeAreaInsets.bottom)
  }

  /// Bottom gap under the floating card: the keyboard plus a margin while
  /// typing. At rest, tuck the card slightly into the home-indicator safe area
  /// so it does not appear to float too high above the screen edge.
  private func bottomLift(_ proxy: GeometryProxy) -> CGFloat {
    let keyboard = keyboardInset(proxy)
    if keyboard > 0 { return keyboard + DashTheme.Sheet.floatingMargin }
    return proxy.safeAreaInsets.bottom > 0
      ? -DashTheme.Sheet.floatingBottomTuck : DashTheme.Sheet.floatingMargin
  }

  /// Exit routing, Family's rule set: only the ✕ control retraces the anchored
  /// reveal back into its source; a drag or scrim tap is a physical downward
  /// gesture and keeps the downward slide; programmatic dismissals (submit
  /// success, Cancel) slide too. An exit that interrupts the anchored
  /// entrance is the one exception: the two reveal modifiers only render the
  /// same pose at settled progress 1, so before the presentation settles
  /// *every* reason keeps the anchor and reverses the grow continuously from
  /// its current partial pose back into the frozen source rect.
  private func close(reason: DashTrayCloseReason = .programmatic) {
    guard !isClosing else { return }
    isClosing = true
    let reversesUnsettledAnchor = anchorActive && !presentationSettled
    if anchorActive, presentationSettled {
      if reason == .control {
        // Return into the source's *current* frame — layout may have shifted
        // since present (keyboard, rotation); the frozen rect is the
        // fallback. Retargeting is only legal here: the rect is not
        // animatable state, so at any progress other than a settled 1
        // (where the transform is identity for every rect) swapping it
        // would snap the pose.
        if let sourceID,
          let fresh = DashTraySourceRegistry.shared.presentationFrame(
            for: sourceID, in: dashTrayWindowBounds())
        {
          closeAnchorRect = fresh
        } else {
          // The trigger can scroll away or disappear while the tray is open.
          // At settled identity it is safe to hand off to the standard exit;
          // shrinking into the frozen old rect would point at empty space.
          anchorReleased = true
        }
      } else {
        // At settled progress 1 both reveal modifiers render identity (the
        // live drag offset included), so handing the exit to the downward
        // slide cannot jump.
        anchorReleased = true
      }
    }
    let flies = beginSuccessFlightIfEligible(reason: reason)
    remainingExitStages = flies ? 2 : 1
    flightExitStagePending = flies
    withAnimation(reduceMotion ? DashTheme.Motion.reduced : DashTrayMotion.dismiss) {
      progress = 0
      // A drag that interrupts the entrance must return to the source itself,
      // not to `source + drag` before the hidden source reappears.
      if reversesUnsettledAnchor { drag = 0 }
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
  /// False hands the card to `DashTrayAnchorReveal` (anchored presentations);
  /// the flip only ever happens at progress 1, where both render identity.
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
      content
        .offset(y: (1 - progress) * (max(revealOffset, drag + 48) - drag))
        .scaleEffect(0.985 + 0.015 * progress, anchor: .bottom)
        .opacity(progress)
        .blur(radius: 4 * (1 - progress))
    }
  }
}

/// The anchored reveal: the whole card, scaled and translated so that at
/// progress 0 it occupies the source control's rect and at 1 it sits exactly
/// where layout put it. Drag rides on top so header pulls stay physical. If
/// the card has not been measured yet (first frame), it falls back to a plain
/// progress fade, which at progress ≈ 0 is invisible anyway.
private struct DashTrayAnchorReveal: ViewModifier, Animatable {
  var progress: CGFloat
  var active: Bool
  var source: CGRect
  var card: CGRect

  // Nonisolated for the same SE-0434 reason as DashTrayCardReveal.
  nonisolated var animatableData: CGFloat {
    get { progress }
    set { progress = newValue }
  }

  @ViewBuilder
  func body(content: Content) -> some View {
    if !active {
      content
    } else if card.width > 0, card.height > 0 {
      let transform = DashTrayAnchorMath.transform(
        source: source, card: card, progress: progress)
      content
        .scaleEffect(x: transform.scaleX, y: transform.scaleY, anchor: .center)
        .offset(x: transform.offsetX, y: transform.offsetY)
        .opacity(DashTrayAnchorMath.opacity(progress: progress))
    } else {
      content
        .opacity(DashTrayAnchorMath.opacity(progress: progress))
    }
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

/// The visible compact tray card, at the bottom of a full-screen
/// transparent cover: a fixed header over a body that animates its height to fit
/// its content — so a morph resizes smoothly with no detent to clip or snap —
/// but caps at the available height (`maxCardHeight`, which shrinks with the
/// keyboard) and scrolls beyond it, so a form never squeezes or overflows.
/// Paints its own canvas fill, top corners, and safe-area extension.
private struct DashSheetCard<Header: View, Body: View, Footer: View>: View {
  let maxCardHeight: CGFloat
  let hasFooter: Bool
  @ViewBuilder let header: () -> Header
  @ViewBuilder let content: () -> Body
  @ViewBuilder let footer: () -> Footer
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dashTrayTone) private var tone
  @Environment(\.colorScheme) private var colorScheme
  @State private var headerHeight: CGFloat = 0
  @State private var footerHeight: CGFloat = 0
  @State private var bodyIdeal: CGFloat = 0
  @State private var bodyDisplay: CGFloat = 0

  private var maxBodyHeight: CGFloat {
    max(80, maxCardHeight - headerHeight - footerHeight)
  }

  var body: some View {
    VStack(spacing: 0) {
      header()
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
          .frame(maxWidth: .infinity, alignment: .top)
          .padding(.horizontal, DashTheme.Sheet.content)
          .padding(.top, DashTheme.Sheet.bodyVertical)
          .padding(
            .bottom,
            hasFooter ? DashTheme.Sheet.bodyVertical : DashTheme.Sheet.bodyBottom
          )
          .background {
            GeometryReader { proxy in
              Color.clear.preference(key: DashSheetBodyIdealKey.self, value: proxy.size.height)
            }
          }
      }
      .frame(height: bodyDisplay > 0 ? bodyDisplay : nil)

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
      }
    }
    .frame(maxWidth: .infinity)
    // A floating card: one stable all-corner radius, and nothing extends past
    // the card — the gaps around it are the design.
    .background {
      ZStack {
        RoundedRectangle(cornerRadius: DashDisplayChrome.floatingRadius, style: .continuous)
          .fill(DashTheme.Sheet.background)
        // A contextual whisper of the presenting feature's tone at the card
        // top — Family's tray-dresses-for-the-room, at an opacity that can
        // never move text contrast. The background token above stays the one
        // true card color; this layer is absent entirely on neutral trays.
        if let tone {
          LinearGradient(
            colors: [tone.vivid.opacity(colorScheme == .dark ? 0.03 : 0.06), .clear],
            startPoint: .top, endPoint: .center
          )
        }
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
    .onPreferenceChange(DashSheetHeaderHeightKey.self) { headerHeight = $0 }
    .onPreferenceChange(DashSheetFooterHeightKey.self) { footerHeight = $0 }
    .onPreferenceChange(DashSheetBodyIdealKey.self) { ideal in
      bodyIdeal = ideal
      applyBody(animated: bodyDisplay != 0)
    }
    .onChange(of: maxBodyHeight) { _, _ in applyBody(animated: true) }
  }

  private func applyBody(animated: Bool) {
    let target = min(bodyIdeal, maxBodyHeight)
    guard target > 0 else { return }
    if animated, !reduceMotion {
      withAnimation(DashTrayMotion.resize) { bodyDisplay = target }
    } else {
      var transaction = Transaction()
      transaction.disablesAnimations = reduceMotion
      withTransaction(transaction) { bodyDisplay = target }
    }
  }
}

// The full-screen cover is toggled without animation (`covered`, driven off the
// caller's binding through a disabled-animation transaction) so its own present
// transition never fires — DashCustomSheet owns the fade/slide and the exit
// finishes before the caller's binding clears.
private func dashPresentWithoutAnimation(_ apply: () -> Void) {
  var transaction = Transaction()
  transaction.disablesAnimations = true
  withTransaction(transaction, apply)
}

/// Resolves and claims an anchor at present time; releases it when the
/// caller's binding clears (which happens only after the exit animation, so
/// the hidden source never reappears under a still-visible card). Reduce
/// Motion never anchors — the standard fade reveal is already low-motion.
struct DashTrayAnchorClaim {
  let sourceID: AnyHashable
  let frame: CGRect
}

/// Owns a registry claim for exactly as long as its presenter modifier lives.
/// A session/auth transition can tear that subtree down while its binding is
/// still true, so relying only on the binding's `false` edge would leave the
/// singleton registry occupied and the matching Home tile hidden forever.
@MainActor
final class DashTrayAnchorLease {
  private let registry: DashTraySourceRegistry
  private var sourceID: AnyHashable?

  init(registry: DashTraySourceRegistry = .shared) {
    self.registry = registry
  }

  func adopt(_ claim: DashTrayAnchorClaim?) {
    guard sourceID != claim?.sourceID else { return }
    release()
    sourceID = claim?.sourceID
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

@MainActor private func dashTrayResolveAnchor(
  sourceID: AnyHashable?, reduceMotion: Bool
) -> DashTrayAnchorClaim? {
  guard let sourceID, !reduceMotion else { return nil }
  guard
    let frame = DashTraySourceRegistry.shared.presentationFrame(
      for: sourceID, in: dashTrayWindowBounds()),
    DashTraySourceRegistry.shared.claim(sourceID)
  else { return nil }
  return DashTrayAnchorClaim(sourceID: sourceID, frame: frame)
}

/// Carries the trigger geometry and presented value through one state write.
/// A separate `covered = true` write can make `fullScreenCover` capture the
/// previous frame on Xcode 26, leaving the source claimed while the card takes
/// the unanchored path.
private struct DashTrayCoverPresentation<Value>: Identifiable {
  let id = UUID()
  let value: Value
  let sourceID: AnyHashable?
  let sourceFrame: CGRect?
}

private struct DashTrayModifier<Hero: View, TrayContent: View, Footer: View>: ViewModifier {
  @Binding var isPresented: Bool
  let title: String
  var showsMenuButtons = true
  var tone: FeatureVisualTone? = nil
  var sourceID: AnyHashable? = nil
  var hero: (() -> Hero)?
  @ViewBuilder var trayContent: () -> TrayContent
  @ViewBuilder var footer: () -> Footer
  let hasFooter: Bool
  @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
  #if DEBUG
    @Environment(\.dashTrayReduceMotionOverride) private var reduceMotionOverride
  #endif
  @State private var coverPresentation: DashTrayCoverPresentation<Bool>?
  @State private var anchorLease = DashTrayAnchorLease()
  @State private var dismissCompletion: (() -> Void)?

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
        if present {
          let claim = dashTrayResolveAnchor(sourceID: sourceID, reduceMotion: reduceMotion)
          anchorLease.adopt(claim)
          let presentation = DashTrayCoverPresentation(
            value: true, sourceID: claim?.sourceID, sourceFrame: claim?.frame)
          dashPresentWithoutAnimation { coverPresentation = presentation }
        } else {
          anchorLease.release()
          dashPresentWithoutAnimation { coverPresentation = nil }
        }
      }
      .fullScreenCover(
        item: $coverPresentation,
        onDismiss: {
          anchorLease.release()
          isPresented = false
          let completion = dismissCompletion
          dismissCompletion = nil
          completion?()
        },
        content: { presentation in
          DashCustomSheet(
            title: title, showsMenuButtons: showsMenuButtons, tone: tone,
            sourceID: presentation.sourceID, sourceFrame: presentation.sourceFrame,
            hero: hero,
            onDismiss: { completion in
              dismissCompletion = completion
              // Keep the external presentation state alive until UIKit has
              // actually removed the cover. Callers use that state to gate
              // competing presentations such as pending Home deep links.
              dashPresentWithoutAnimation { coverPresentation = nil }
            }, content: trayContent,
            footer: footer, hasFooter: hasFooter)
        })
  }
}

private struct DashTrayItemModifier<Item: Identifiable & Equatable, Hero: View, TrayContent: View>:
  ViewModifier
{
  @Binding var item: Item?
  let title: (Item) -> String
  var showsMenuButtons = true
  var tone: FeatureVisualTone? = nil
  var sourceID: AnyHashable? = nil
  var hero: ((Item) -> Hero)?
  @ViewBuilder var trayContent: (Item) -> TrayContent
  @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
  #if DEBUG
    @Environment(\.dashTrayReduceMotionOverride) private var reduceMotionOverride
  #endif
  @State private var coverPresentation: DashTrayCoverPresentation<Item>?
  @State private var anchorLease = DashTrayAnchorLease()
  @State private var dismissCompletion: (() -> Void)?

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
        if let newItem {
          let claim = dashTrayResolveAnchor(sourceID: sourceID, reduceMotion: reduceMotion)
          anchorLease.adopt(claim)
          let presentation = DashTrayCoverPresentation(
            value: newItem, sourceID: claim?.sourceID, sourceFrame: claim?.frame)
          dashPresentWithoutAnimation { coverPresentation = presentation }
        } else {
          anchorLease.release()
          dashPresentWithoutAnimation { coverPresentation = nil }
        }
      }
      .fullScreenCover(
        item: $coverPresentation,
        onDismiss: {
          anchorLease.release()
          item = nil
          let completion = dismissCompletion
          dismissCompletion = nil
          completion?()
        },
        content: { presentation in
          DashCustomSheet<Hero, TrayContent, EmptyView>(
            title: title(presentation.value), showsMenuButtons: showsMenuButtons, tone: tone,
            sourceID: presentation.sourceID, sourceFrame: presentation.sourceFrame,
            hero: hero.map { hero in { hero(presentation.value) } },
            onDismiss: { completion in
              dismissCompletion = completion
              // Match the Bool-backed modifier: the item remains presented
              // through the native dismissal so another cover cannot race it.
              dashPresentWithoutAnimation { coverPresentation = nil }
            }, content: { trayContent(presentation.value) },
            footer: { EmptyView() }, hasFooter: false)
        })
  }
}
