import SwiftUI

/// The visual language for a route replacement inside one Tray.
///
/// `step` is the standard directional drill. `heroMorph` removes that competing
/// horizontal travel and keeps the root route mounted so a caller-owned
/// matched-geometry surface can remain one live object between routes.
enum DashTrayFlowTransitionStyle: Equatable, Sendable {
  case step
  case heroMorph
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
///   read as travel, not teleport. A caller with a real matched-geometry hero
///   opts into `heroMorph`, which removes that competing slide. Terminal
///   success steps must *replace* the stack (`path = [.done]`), never push — a
///   back control over a committed action would reopen its form.
struct DashTrayFlow<Route: Hashable & Sendable, Content: View>: View {
  let route: Route
  let role: DashTrayStepRole
  let transitionStyle: DashTrayFlowTransitionStyle
  private let rootRoute: Route?
  private let path: Binding<[Route]>?
  @ViewBuilder let content: (Route) -> Content
  @State private var direction = DashTrayFlowDirection()
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.layoutDirection) private var layoutDirection

  init(
    route: Route,
    role: DashTrayStepRole,
    transitionStyle: DashTrayFlowTransitionStyle = .step,
    @ViewBuilder content: @escaping (Route) -> Content
  ) {
    self.route = route
    self.role = role
    self.transitionStyle = transitionStyle
    self.rootRoute = nil
    self.path = nil
    self.content = content
  }

  init(
    root: Route,
    path: Binding<[Route]>,
    role: (Route) -> DashTrayStepRole,
    transitionStyle: DashTrayFlowTransitionStyle = .step,
    @ViewBuilder content: @escaping (Route) -> Content
  ) {
    let active = path.wrappedValue.last ?? root
    self.route = active
    self.role = role(active)
    self.transitionStyle = transitionStyle
    self.rootRoute = root
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
      if transitionStyle == .heroMorph, let rootRoute {
        persistentRoot(rootRoute)
        if route != rootRoute {
          transientStep(route)
        }
      } else {
        transientStep(route)
      }
    }
    .frame(maxWidth: .infinity, alignment: .top)
    .animation(
      reduceMotion ? DashTheme.Motion.reduced : transitionAnimation,
      value: route
    )
    .preference(key: DashTrayStepRoleKey.self, value: role)
    .preference(key: DashTrayBackActionKey.self, value: backAction)
  }

  private func persistentRoot(_ root: Route) -> some View {
    let isActive = route == root
    return content(root)
      .frame(maxWidth: .infinity, alignment: .top)
      .layoutValue(key: DashTrayRouteLayoutKey<Route>.self, value: root)
      .opacity(isActive ? 1 : 0)
      .allowsHitTesting(isActive)
      .accessibilityHidden(!isActive)
      .zIndex(0)
      .id(root)
  }

  private func transientStep(_ step: Route) -> some View {
    content(step)
      .frame(maxWidth: .infinity, alignment: .top)
      .layoutValue(key: DashTrayRouteLayoutKey<Route>.self, value: step)
      .zIndex(1)
      .id(step)
      .transition(stepTransition)
  }

  private var stepTransition: AnyTransition {
    if reduceMotion { return .opacity }
    if transitionStyle == .heroMorph { return .opacity }
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

  private var transitionAnimation: Animation {
    switch transitionStyle {
    case .step:
      role.transitionAnimation
    case .heroMorph:
      role == .root ? DashTheme.Motion.morphExit : DashTheme.Motion.morph
    }
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
