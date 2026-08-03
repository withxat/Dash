import Combine
import Foundation
import SwiftUI
import UIKit

// MARK: - Sheet presentation

enum DashSheetSizing: Equatable {
  /// A floating card whose height hugs its content (Profile, forms).
  case content
  /// Presents expanded to a full-height sheet; the grab bar drags it down to
  /// a floating detent styled like `.content` (small forms and menus).
  case large
}

/// Which tray styles a subtree currently presents, bubbled to `MainTabView` so
/// root chrome can hide the floating dock and header avatar for any open tray
/// (and for pushed routes).
struct DashTrayPresentation: Equatable {
  var content = false
  var large = false

  init(content: Bool = false, large: Bool = false) {
    self.content = content
    self.large = large
  }

  init(sizing: DashSheetSizing, isPresented: Bool) {
    self.init(
      content: isPresented && sizing == .content,
      large: isPresented && sizing == .large)
  }

  var presented: Bool { content || large }
}

struct TrayPresentedPreferenceKey: PreferenceKey {
  static let defaultValue = DashTrayPresentation()
  static func reduce(value: inout DashTrayPresentation, nextValue: () -> DashTrayPresentation) {
    let next = nextValue()
    value = DashTrayPresentation(
      content: value.content || next.content,
      large: value.large || next.large)
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

/// When true (`.large` trays), `DashConfirmMorph` scrolls the body and pins
/// the footer action — matching `.content` horizontal/bottom insets without
/// letting Done sit flush on the home indicator.
private struct DashTrayPinsFooterKey: EnvironmentKey {
  static let defaultValue = false
}

struct DashTrayDismissDisabledPreferenceKey: PreferenceKey {
  static let defaultValue = false

  static func reduce(value: inout Bool, nextValue: () -> Bool) {
    value = value || nextValue()
  }
}

extension EnvironmentValues {
  var dashTrayDismiss: () -> Void {
    get { self[DashTrayDismissKey.self] }
    set { self[DashTrayDismissKey.self] = newValue }
  }

  var dashTrayPinsFooter: Bool {
    get { self[DashTrayPinsFooterKey.self] }
    set { self[DashTrayPinsFooterKey.self] = newValue }
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
  func dashTray<Content: View>(
    isPresented: Binding<Bool>,
    title: String,
    sizing: DashSheetSizing = .content,
    showsMenuButtons: Bool = true,
    @ViewBuilder content: @escaping () -> Content
  ) -> some View {
    modifier(
      DashTrayModifier<EmptyView, Content, EmptyView>(
        isPresented: isPresented, title: title, sizing: sizing,
        showsMenuButtons: showsMenuButtons, hero: nil,
        trayContent: content, footer: { EmptyView() }, hasFooter: false))
  }

  /// A floating content tray with three stable chrome regions: fixed header,
  /// independently scrolling body, and fixed action footer. Use this when a
  /// multi-step body morphs above controls that must retain one screen position.
  func dashTray<Content: View, Footer: View>(
    isPresented: Binding<Bool>,
    title: String,
    showsMenuButtons: Bool = true,
    @ViewBuilder content: @escaping () -> Content,
    @ViewBuilder footer: @escaping () -> Footer
  ) -> some View {
    modifier(
      DashTrayModifier<EmptyView, Content, Footer>(
        isPresented: isPresented, title: title, sizing: .content,
        showsMenuButtons: showsMenuButtons, hero: nil,
        trayContent: content, footer: footer, hasFooter: true))
  }

  /// A `.content` tray whose top is a full-bleed hero — an image spanning the
  /// card edge to edge with no insets — instead of the title row. The hero
  /// sizes itself (fixed height or aspect ratio); the card clips its top
  /// corners. Menu buttons, when on, float over the hero in the standard
  /// corner position. `title` still names the tray for accessibility.
  func dashTray<Hero: View, Content: View>(
    isPresented: Binding<Bool>,
    title: String,
    showsMenuButtons: Bool = true,
    @ViewBuilder hero: @escaping () -> Hero,
    @ViewBuilder content: @escaping () -> Content
  ) -> some View {
    modifier(
      DashTrayModifier<Hero, Content, EmptyView>(
        isPresented: isPresented, title: title, sizing: .content,
        showsMenuButtons: showsMenuButtons, hero: hero,
        trayContent: content, footer: { EmptyView() }, hasFooter: false))
  }

  func dashTray<Item: Identifiable & Equatable, Content: View>(
    item: Binding<Item?>,
    title: @escaping (Item) -> String,
    sizing: DashSheetSizing = .content,
    showsMenuButtons: Bool = true,
    @ViewBuilder content: @escaping (Item) -> Content
  ) -> some View {
    modifier(
      DashTrayItemModifier<Item, EmptyView, Content>(
        item: item, title: title, sizing: sizing,
        showsMenuButtons: showsMenuButtons, hero: nil, trayContent: content)
    )
  }

  /// Item-driven variant of the hero tray; see the `isPresented` overload.
  func dashTray<Item: Identifiable & Equatable, Hero: View, Content: View>(
    item: Binding<Item?>,
    title: @escaping (Item) -> String,
    showsMenuButtons: Bool = true,
    @ViewBuilder hero: @escaping (Item) -> Hero,
    @ViewBuilder content: @escaping (Item) -> Content
  ) -> some View {
    modifier(
      DashTrayItemModifier(
        item: item, title: title, sizing: .content,
        showsMenuButtons: showsMenuButtons, hero: hero, trayContent: content)
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

/// A compact circular action rendered left of a `.content` tray's close button
/// (e.g. delete). Tray content publishes it with `dashTrayHeaderAction`.
struct DashSheetHeaderAction: Equatable {
  let id: String
  let icon: String
  var accessibilityLabel: String
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

/// Canonical multi-step Tray content. Business views provide a stable route and
/// its semantic role; this view keeps the outgoing route alive for its visual
/// exit while handing layout ownership to the target route immediately.
struct DashTrayFlow<Route: Hashable & Sendable, Content: View>: View {
  let route: Route
  let role: DashTrayStepRole
  @ViewBuilder let content: (Route) -> Content
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    DashTrayPopLayout(activeRoute: route) {
      content(route)
        .frame(maxWidth: .infinity, alignment: .top)
        .layoutValue(key: DashTrayRouteLayoutKey<Route>.self, value: route)
        .id(route)
        .transition(
          reduceMotion
            ? .opacity
            : .opacity.combined(with: .scale(scale: 0.96, anchor: .center))
        )
    }
    .frame(maxWidth: .infinity, alignment: .top)
    .animation(
      reduceMotion ? DashTheme.Motion.reduced : role.transitionAnimation,
      value: route
    )
    .preference(key: DashTrayStepRoleKey.self, value: role)
  }
}

/// Pure dismiss / settle decisions for tray drag gestures — shared by content and
/// expandable trays so velocity thresholds stay testable.
enum TrayDragOutcome: Equatable, Sendable {
  case dismiss
  case settle
  case settleExpanded(Bool)
}

enum TrayDragStartDetent: Equatable, Sendable {
  case expanded
  case floating
}

enum TrayDragDecision {
  /// Content tray: the physical card size sets the distance threshold, while a
  /// downward flick may dismiss early. A small intent floor keeps a stray touch
  /// from turning a noisy velocity sample into data loss on a form.
  static func content(
    translation: CGFloat,
    predictedEndTranslation: CGFloat,
    velocity: CGFloat,
    trayHeight: CGFloat,
    distanceFraction: CGFloat = 0.25,
    velocityThreshold: CGFloat = 400,
    minimumFlingDistance: CGFloat = 8
  ) -> TrayDragOutcome {
    let distanceThreshold = max(0, trayHeight) * distanceFraction
    let crossedDistance = trayHeight > 0 && translation >= distanceThreshold
    let hasDownwardMomentum = predictedEndTranslation > translation
    let isDeliberateFling =
      translation >= minimumFlingDistance
      && velocity >= velocityThreshold
      && hasDownwardMomentum
    if crossedDistance || isDeliberateFling {
      return .dismiss
    }
    return .settle
  }

  /// Downward movement tracks the finger exactly. Upward movement remains
  /// continuous but becomes progressively more resistant instead of hitting a
  /// hard clamp or following a fixed fraction forever.
  static func contentOffset(translation: CGFloat, resistance: CGFloat = 8) -> CGFloat {
    guard translation < 0, resistance > 0 else { return translation }
    return -resistance * CGFloat(log1p(Double(-translation / resistance)))
  }

  /// The backdrop and card share one dismissal progress. The dim therefore
  /// follows a downward drag frame-for-frame instead of staying fully opaque
  /// until release.
  static func scrimProgress(
    presentation: CGFloat,
    drag: CGFloat,
    trayHeight: CGFloat
  ) -> CGFloat {
    let presented = min(max(presentation, 0), 1)
    guard trayHeight > 0 else { return presented }
    let dismissed = min(max(drag / trayHeight, 0), 1)
    return presented * (1 - dismissed)
  }

  /// SwiftUI spring velocity is relative to the animated [from, to] range,
  /// not raw points per second. A negative result means the gesture is moving
  /// away from its target; zero distance cannot carry meaningful momentum.
  static func normalizedSpringVelocity(
    pointsPerSecond: CGFloat,
    from: CGFloat,
    to: CGFloat
  ) -> Double {
    let distance = to - from
    guard abs(distance) > .ulpOfOne else { return 0 }
    return Double(pointsPerSecond / distance)
  }

  /// Expandable tray: projection chooses a detent, while dismissal requires
  /// either a deliberate pull or a downward flick with enough real travel.
  /// A gesture that starts expanded must cross the floating detent before its
  /// dismissal thresholds begin, so a short flick advances only one detent.
  static func expandable(
    startDetent: TrayDragStartDetent,
    translation: CGFloat,
    predictedEndTranslation: CGFloat,
    velocity: CGFloat,
    expandedTop: CGFloat,
    floatingTop: CGFloat,
    dismissDistance: CGFloat = 120,
    minimumFlingDistance: CGFloat = 32,
    velocityThreshold: CGFloat = 900
  ) -> TrayDragOutcome {
    let baseTop = startDetent == .expanded ? expandedTop : floatingTop
    let predictedTop = baseTop + predictedEndTranslation
    let distanceToFloating =
      startDetent == .expanded ? max(0, floatingTop - expandedTop) : 0
    let travelPastFloating = translation - distanceToFloating
    let isDeliberatePull = travelPastFloating > dismissDistance
    let isDeliberateFling =
      travelPastFloating >= minimumFlingDistance
      && velocity > velocityThreshold
    if isDeliberatePull || isDeliberateFling {
      return .dismiss
    }
    let snapExpanded = abs(predictedTop - expandedTop) < abs(predictedTop - floatingTop)
    return .settleExpanded(snapExpanded)
  }

  /// Rubber-band offset when dragging past the expanded top detent.
  static func rubberBand(cardTop: CGFloat, expandedTop: CGFloat, factor: CGFloat = 0.15)
    -> CGFloat
  {
    guard cardTop < expandedTop else { return cardTop }
    return expandedTop - (expandedTop - cardTop) * factor
  }
}

/// Tray motion, split by job. Only a finger-driven release is a spring; drawer
/// presentation, target-height changes, and dismissal use the timing curves in
/// the Tray-specific theme vocabulary.
private enum DashTrayMotion {
  static let present = DashTheme.Motion.trayPresent
  static let resize = DashTheme.Motion.trayResize
  static let release = DashTheme.Motion.trayRelease
  static let dismiss = DashTheme.Motion.trayDismiss

  /// A cancelled dismissal keeps the gesture's point velocity, so the card
  /// first follows the release direction and then settles instead of starting
  /// a disconnected zero-velocity spring.
  static func release(initialVelocity: Double) -> Animation {
    .interpolatingSpring(
      mass: 1,
      stiffness: 340,
      damping: 30,
      initialVelocity: initialVelocity
    )
  }

  /// A completed drag hands its downward velocity to presentation progress.
  /// Programmatic closes retain the reference drawer curve above; this physical
  /// path is only for a surface already under the user's finger.
  static func gestureDismiss(initialVelocity: Double) -> Animation {
    .interpolatingSpring(
      mass: 1,
      stiffness: 100,
      damping: 20,
      initialVelocity: initialVelocity
    )
  }
}

/// The trailing button cluster — optional action circle plus close — shared by
/// the standard and hero headers so both variants keep identical geometry.
private struct DashSheetMenuButtons: View {
  var trailingAction: DashSheetHeaderAction? = nil
  var isDisabled = false
  let dismiss: () -> Void

  var body: some View {
    // Both circular controls already carry independent 44pt hit targets.
    // Zero stack spacing keeps those targets adjacent (never overlapping)
    // and reduces the visible action-to-close gap from 20pt to 12pt.
    HStack(alignment: .center, spacing: 0) {
      if let trailingAction {
        Button(action: trailingAction.perform) {
          // The glyph sits smaller than the close X, whose larger mark is what
          // keeps the two circles visually balanced.
          SolarIcon(asset: trailingAction.icon, size: 18, color: DashTheme.danger)
            .frame(width: 32, height: 32)
            .background(DashTheme.dangerTint, in: Circle())
            .dashCompactHitTarget()
        }
        .buttonStyle(DashPressButtonStyle())
        .accessibilityLabel(trailingAction.accessibilityLabel)
        .accessibilityIdentifier("dash-tray-header-\(trailingAction.id)")
      }
      DashCloseButton { dismiss() }
        .accessibilityIdentifier("dash.tray.close")
    }
    .disabled(isDisabled)
    .opacity(isDisabled ? 0.45 : 1)
  }
}

/// Shared header (title + menu buttons, optional grab bar) for both tray styles.
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
  var showsGrabBar = false
  var showsMenuButtons = true
  var stepRole = DashTrayStepRole.root
  var trailingAction: DashSheetHeaderAction? = nil
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
      if showsGrabBar { DashSheetGrabBar() }

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
        showsGrabBar
          ? 12
          : (stepRole.isDetail ? DashTheme.Sheet.detailHeaderTop : DashTheme.Sheet.headerTop)
      )
      .padding(
        .bottom,
        displayedDescription == nil ? DashTheme.Sheet.headerBottom : Self.descriptionGap
      )
      .animation(
        reduceMotion ? DashTheme.Motion.reduced : DashTrayMotion.resize,
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

/// Hero-topped header for `.content` trays: the hero fills the card edge to
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
            reduceMotion ? DashTheme.Motion.reduced : DashTrayMotion.resize,
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

/// `.content` trays: a full-screen transparent cover with our own dim and a
/// bottom-pinned card. The card animates its own target height (DashSheetCard) so
/// content morphs resize smoothly — there's no native detent to clip or snap.
/// The dim fades and the card slides up from the bottom (and dismisses the
/// same way), independently of the cover (see DashTrayModifier).
private struct DashCustomSheet<Hero: View, Content: View, Footer: View>: View {
  let title: String
  var showsMenuButtons = true
  /// Full-bleed view replacing the title header; nil keeps the standard header.
  var hero: (() -> Hero)?
  /// Removes the cover once the exit animation has finished.
  let onDismiss: () -> Void
  @ViewBuilder var content: () -> Content
  @ViewBuilder var footer: () -> Footer
  let hasFooter: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var progress: CGFloat = 0
  @State private var drag: CGFloat = 0
  @State private var cardHeight: CGFloat = 0
  @State private var revealOffset: CGFloat = 0
  @State private var presentationStarted = false
  @State private var presentationCompleted = false
  @State private var keyboardHeight: CGFloat = 0
  @State private var headerAction: DashSheetHeaderAction?
  @State private var contentTitle: String?
  @State private var contentDescription: String?
  @State private var stepRole = DashTrayStepRole.root
  @State private var dismissDisabled = false

  private var resolvedTitle: String { contentTitle ?? title }

  var body: some View {
    ZStack(alignment: .bottom) {
      Color.black.opacity(scrimProgress * DashTheme.Sheet.scrimOpacity)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { requestClose() }
        .accessibilityLabel("Dismiss")
        .accessibilityIdentifier("dash.tray.scrim")
        .accessibilityAddTraits(.isButton)
        .accessibilityHidden(dismissDisabled)

      // We position the card above the keyboard ourselves (padding + an observed
      // height) rather than let SwiftUI's automatic avoidance also push it, which
      // over-lifts it and leaves a dim gap. The card caps its body at the space
      // left above the keyboard and scrolls the rest. As a floating card the
      // lift is plain outer padding — there's no longer an edge-to-edge fill
      // that has to run under the keyboard.
      GeometryReader { proxy in
        let cardWidth = DashTrayGeometry.floatingWidth(containerWidth: proxy.size.width)
        DashSheetCard(
          maxCardHeight: proxy.size.height - bottomLift(proxy) - 24,
          hasFooter: hasFooter
        ) {
          // Drag-to-dismiss lives on the header (or hero) only, so the
          // scrollable body keeps its own vertical scroll.
          trayHeader
            .contentShape(Rectangle())
            .gesture(dragGesture, including: dismissDisabled ? .none : .all)
        } content: {
          content()
        } footer: {
          footer()
        }
        .frame(width: cardWidth)
        .accessibilityIdentifier("dash.tray.card")
        .padding(.bottom, bottomLift(proxy))
        // The card is independently sized, then centered in the modal host.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .modifier(
          DashTrayCardReveal(
            progress: progress, drag: drag, revealOffset: revealOffset,
            reduceMotion: reduceMotion))
      }
      .ignoresSafeArea(.keyboard)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityAddTraits(.isModal)
    .environment(\.dashTrayDismiss, { close() })
    .onPreferenceChange(DashSheetFittedHeightKey.self, perform: updateCardHeight)
    .onPreferenceChange(DashSheetHeaderActionKey.self) { headerAction = $0 }
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
      if reduceMotion {
        keyboardHeight = covered
      } else {
        withAnimation(DashTheme.Motion.settle) { keyboardHeight = covered }
      }
    }
    .presentationBackground(.clear)
    .dashToastHost()
  }

  /// A hero replaces the title row outright, so it has nowhere to seat a
  /// description — `dashTrayDescription` is inert under one, by design.
  @ViewBuilder private var trayHeader: some View {
    if let hero {
      DashSheetHeroHeader(
        title: resolvedTitle, showsMenuButtons: showsMenuButtons,
        stepRole: stepRole,
        trailingAction: headerAction, menuButtonsDisabled: dismissDisabled,
        dismiss: { requestClose() }, hero: hero)
    } else {
      DashSheetHeader(
        title: resolvedTitle, description: contentDescription,
        showsMenuButtons: showsMenuButtons, stepRole: stepRole,
        trailingAction: headerAction, menuButtonsDisabled: dismissDisabled,
        dismiss: { requestClose() })
    }
  }

  /// Presentation begins only after the real card exists. The hidden endpoint
  /// is captured for the whole entrance, then may follow later route heights
  /// while fully shown; changing it mid-flight would bend the arrival path.
  private func updateCardHeight(_ height: CGFloat) {
    guard height > 0 else { return }
    cardHeight = height

    if !presentationStarted {
      presentationStarted = true
      revealOffset = height * 1.1
      withAnimation(reduceMotion ? DashTheme.Motion.reduced : DashTrayMotion.present) {
        progress = 1
      } completion: {
        guard progress == 1 else { return }
        presentationCompleted = true
        revealOffset = cardHeight * 1.1
      }
    } else if presentationCompleted, progress == 1 {
      revealOffset = height * 1.1
    }
  }

  private var scrimProgress: CGFloat {
    TrayDragDecision.scrimProgress(
      presentation: progress,
      drag: drag,
      trayHeight: cardHeight
    )
  }

  /// How far to lift the card above the keyboard, in the GeometryReader's space.
  /// `keyboardHeight` is measured from the window bottom (home indicator
  /// included), but the reader already sits above the home indicator, so subtract
  /// that inset or the card over-lifts and leaves a dim gap.
  private func keyboardInset(_ proxy: GeometryProxy) -> CGFloat {
    max(0, keyboardHeight - proxy.safeAreaInsets.bottom)
  }

  /// Bottom gap under the floating card: the keyboard plus a margin while
  /// typing. At rest, move into the home-indicator safe area just enough to keep
  /// the same physical screen-edge gap as square-bottom devices.
  private func bottomLift(_ proxy: GeometryProxy) -> CGFloat {
    let keyboard = keyboardInset(proxy)
    if keyboard > 0 { return keyboard + DashTheme.Sheet.floatingMargin }
    return DashTrayGeometry.bottomLift(safeAreaBottom: proxy.safeAreaInsets.bottom)
  }

  private func close(releaseVelocity: CGFloat? = nil) {
    let animation: Animation
    if reduceMotion {
      animation = DashTheme.Motion.reduced
    } else if let releaseVelocity {
      animation = DashTrayMotion.gestureDismiss(
        initialVelocity: TrayDragDecision.normalizedSpringVelocity(
          pointsPerSecond: max(0, releaseVelocity),
          from: drag,
          // The reveal modifier guarantees at least 48pt of remaining travel
          // even after a pull beyond the nominal hidden endpoint.
          to: max(revealOffset, drag + 48)
        )
      )
    } else {
      animation = DashTrayMotion.dismiss
    }
    withAnimation(animation) {
      progress = 0
    } completion: {
      drag = 0
      onDismiss()
    }
  }

  private func requestClose(releaseVelocity: CGFloat? = nil) {
    guard !dismissDisabled else { return }
    close(releaseVelocity: releaseVelocity)
  }

  private var dragGesture: some Gesture {
    // Global space: measuring in the header's own (moving) coordinates feeds the
    // offset back into the translation and makes the drag flicker.
    DragGesture(coordinateSpace: .global)
      .onChanged { value in
        let raw = value.translation.height
        // Upward overshoot rubber-bands; downward follows 1:1 for dismiss.
        drag = TrayDragDecision.contentOffset(translation: raw)
      }
      .onEnded { value in
        switch TrayDragDecision.content(
          translation: value.translation.height,
          predictedEndTranslation: value.predictedEndTranslation.height,
          velocity: value.velocity.height,
          trayHeight: cardHeight
        ) {
        case .dismiss:
          requestClose(releaseVelocity: value.velocity.height)
        case .settle, .settleExpanded:
          if reduceMotion {
            drag = 0
          } else {
            withAnimation(
              DashTrayMotion.release(
                initialVelocity: TrayDragDecision.normalizedSpringVelocity(
                  pointsPerSecond: value.velocity.height,
                  from: drag,
                  to: 0
                )
              )
            ) { drag = 0 }
          }
        }
      }
  }
}

/// Slide reveal for the `.content` card. Presentation progress and direct drag
/// share one animatable vector so releases and retargeting keep the card and
/// scrim coherent instead of letting one dimension snap independently.
private struct DashTrayCardReveal: ViewModifier, Animatable {
  var progress: CGFloat
  var drag: CGFloat
  var revealOffset: CGFloat
  var reduceMotion: Bool

  // Nonisolated: `Animatable` is a nonisolated protocol while `ViewModifier`
  // infers main-actor isolation onto the type; the accessors only touch
  // Sendable stored properties, which SE-0434 leaves nonisolated.
  nonisolated var animatableData: AnimatablePair<CGFloat, CGFloat> {
    get { AnimatablePair(progress, drag) }
    set {
      progress = newValue.first
      drag = newValue.second
    }
  }

  @ViewBuilder
  func body(content: Content) -> some View {
    if reduceMotion {
      content
        .offset(y: drag)
        .opacity(progress)
    } else {
      content
        .offset(y: drag + (1 - progress) * (max(revealOffset, drag + 48) - drag))
        .opacity(progress)
    }
  }
}

/// `.large` trays: a custom two-detent sheet. It presents expanded — full
/// width, edge-to-edge at the bottom, native-sheet top corners — and the grab
/// bar or header drags it down to a floating detent styled exactly like a
/// `.content` tray (screen-edge margins and the shared all-corner radius).
/// Margins and radii interpolate continuously with the drag; past the floating
/// detent it dismisses. Native sheet behavior, our chrome.
private struct DashExpandableSheet<Content: View>: View {
  let title: String
  var showsMenuButtons = true
  /// Removes the cover once the exit animation has finished.
  let onDismiss: () -> Void
  @ViewBuilder var content: () -> Content
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var shown = false
  @State private var expanded = true
  @State private var drag: CGFloat = 0
  @State private var contentTitle: String?
  @State private var contentDescription: String?
  @State private var stepRole = DashTrayStepRole.root
  @State private var dismissDisabled = false

  private var resolvedTitle: String { contentTitle ?? title }

  private struct Metrics {
    let cardTop: CGFloat
    let height: CGFloat
    let horizontalMargin: CGFloat
    let bottomMargin: CGFloat
    let topRadius: CGFloat
    let bottomRadius: CGFloat
    let contentBottomInset: CGFloat
    let expandedTop: CGFloat
    let floatingTop: CGFloat
  }

  var body: some View {
    ZStack(alignment: .bottom) {
      Color.black.opacity(shown ? DashTheme.Sheet.scrimOpacity : 0)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { requestClose() }
        .accessibilityLabel("Dismiss")
        .accessibilityAddTraits(.isButton)
        .accessibilityHidden(dismissDisabled)

      GeometryReader { proxy in
        let metrics = metrics(in: proxy)
        card(metrics)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
          .offset(y: reduceMotion ? 0 : (shown ? 0 : revealOffset(for: metrics)))
          .scaleEffect(reduceMotion || shown ? 1 : 0.985, anchor: .bottom)
          .opacity(shown ? 1 : 0)
          .blur(radius: reduceMotion ? 0 : (shown ? 0 : 4))
      }
      .ignoresSafeArea(edges: .bottom)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityAddTraits(.isModal)
    .environment(\.dashTrayDismiss, close)
    .onPreferenceChange(DashTrayTitleKey.self) { contentTitle = $0 }
    .onPreferenceChange(DashTrayDescriptionKey.self) { contentDescription = $0 }
    .onPreferenceChange(DashTrayStepRoleKey.self) { stepRole = $0 }
    .onPreferenceChange(DashTrayDismissDisabledPreferenceKey.self) { dismissDisabled = $0 }
    .presentationBackground(.clear)
    .dashToastHost()
    .onAppear {
      withAnimation(reduceMotion ? DashTheme.Motion.reduced : DashTrayMotion.present) {
        shown = true
      }
    }
  }

  private func revealOffset(for metrics: Metrics) -> CGFloat {
    min(max((metrics.height - metrics.cardTop) * 0.22, 96), 180)
  }

  private func card(_ metrics: Metrics) -> some View {
    let shape = UnevenRoundedRectangle(
      topLeadingRadius: metrics.topRadius,
      bottomLeadingRadius: metrics.bottomRadius,
      bottomTrailingRadius: metrics.bottomRadius,
      topTrailingRadius: metrics.topRadius,
      style: .continuous
    )
    return VStack(spacing: 0) {
      DashSheetHeader(
        title: resolvedTitle, description: contentDescription, showsGrabBar: true,
        showsMenuButtons: showsMenuButtons, stepRole: stepRole,
        menuButtonsDisabled: dismissDisabled,
        dismiss: requestClose
      )
      .contentShape(Rectangle())
      .gesture(detentGesture(metrics), including: dismissDisabled ? .none : .all)
      // Same body insets as `DashSheetCard` so `.large` edit trays match
      // `.content` Edit shortcuts: horizontal padding, top breath, bottom gap
      // under Done. Card margin still lerps 0→floating on collapse so row
      // width tracks the detent.
      content()
        .environment(\.dashTrayPinsFooter, true)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, DashTheme.Sheet.content)
        .padding(.top, DashTheme.Sheet.bodyVertical)
        .padding(.bottom, DashTheme.Sheet.bodyBottom)
        .safeAreaPadding(.bottom, metrics.contentBottomInset)
    }
    .frame(height: metrics.height)
    .frame(maxWidth: .infinity)
    .background { shape.fill(DashTheme.Sheet.background) }
    .clipShape(shape)
    .padding(.horizontal, metrics.horizontalMargin)
    .padding(.bottom, metrics.bottomMargin)
  }

  /// Detent geometry for the current drag, interpolating chrome between the
  /// expanded sheet and the floating card.
  private func metrics(in proxy: GeometryProxy) -> Metrics {
    let safeBottom = proxy.safeAreaInsets.bottom
    let expandedTop = DashTheme.Sheet.expandedTopGap
    let floatingBottomMargin = DashTheme.Sheet.floatingMargin
    let floatingHorizontalMargin = DashTrayGeometry.floatingHorizontalMargin(
      containerWidth: proxy.size.width)
    let floatingHeight = proxy.size.height * DashTheme.Sheet.floatingDetentFraction
    let floatingTop = proxy.size.height - floatingBottomMargin - floatingHeight

    let baseTop = expanded ? expandedTop : floatingTop
    let cardTop = TrayDragDecision.rubberBand(
      cardTop: baseTop + drag, expandedTop: expandedTop)
    let progress = min(max((cardTop - expandedTop) / (floatingTop - expandedTop), 0), 1)

    func lerp(_ from: CGFloat, _ to: CGFloat) -> CGFloat { from + (to - from) * progress }
    let bottomMargin = lerp(0, floatingBottomMargin)
    return Metrics(
      cardTop: cardTop,
      height: max(120, proxy.size.height - cardTop - bottomMargin),
      horizontalMargin: lerp(0, floatingHorizontalMargin),
      bottomMargin: bottomMargin,
      topRadius: lerp(DashTheme.Sheet.expandedTopRadius, DashDisplayChrome.floatingRadius),
      bottomRadius: lerp(DashDisplayChrome.cornerRadius, DashDisplayChrome.floatingRadius),
      contentBottomInset: (1 - progress) * safeBottom,
      expandedTop: expandedTop,
      floatingTop: floatingTop
    )
  }

  private func detentGesture(_ metrics: Metrics) -> some Gesture {
    DragGesture(coordinateSpace: .global)
      .onChanged { value in drag = value.translation.height }
      .onEnded { value in
        switch TrayDragDecision.expandable(
          startDetent: expanded ? .expanded : .floating,
          translation: value.translation.height,
          predictedEndTranslation: value.predictedEndTranslation.height,
          velocity: value.velocity.height,
          expandedTop: metrics.expandedTop,
          floatingTop: metrics.floatingTop
        ) {
        case .dismiss:
          requestClose()
        case .settleExpanded(let snapExpanded):
          if reduceMotion {
            expanded = snapExpanded
            drag = 0
          } else {
            withAnimation(DashTrayMotion.release) {
              expanded = snapExpanded
              drag = 0
            }
          }
        case .settle:
          if reduceMotion {
            drag = 0
          } else {
            withAnimation(DashTrayMotion.release) { drag = 0 }
          }
        }
      }
  }

  private func close() {
    if reduceMotion {
      withAnimation(DashTheme.Motion.reduced) {
        shown = false
      } completion: {
        drag = 0
        onDismiss()
      }
    } else {
      withAnimation(DashTrayMotion.dismiss) {
        shown = false
      } completion: {
        drag = 0
        onDismiss()
      }
    }
  }

  private func requestClose() {
    guard !dismissDisabled else { return }
    close()
  }
}

private struct DashSheetGrabBar: View {
  var body: some View {
    Capsule()
      .fill(DashTheme.fill)
      .frame(width: DashTheme.Sheet.grabBarWidth, height: DashTheme.Sheet.grabBarHeight)
      .frame(maxWidth: .infinity)
      .padding(.top, DashTheme.Sheet.grabBarTop)
      .padding(.bottom, DashTheme.Sheet.grabBarBottom)
      .accessibilityHidden(true)
  }
}

/// Pure floating-card geometry shared by content trays, collapsed large trays,
/// and unit tests.
enum DashTrayGeometry {
  static func floatingWidth(containerWidth: CGFloat) -> CGFloat {
    min(
      DashTheme.Sheet.floatingMaxWidth,
      max(0, containerWidth - DashTheme.Sheet.floatingMargin * 2)
    )
  }

  static func floatingHorizontalMargin(containerWidth: CGFloat) -> CGFloat {
    max(
      DashTheme.Sheet.floatingMargin,
      (containerWidth - DashTheme.Sheet.floatingMaxWidth) / 2
    )
  }

  /// The content GeometryReader ends above the home-indicator safe area. Move
  /// the card into that inset just far enough to preserve a physical 16pt gap
  /// from the display edge; square-bottom devices simply use 16pt padding.
  static func bottomLift(safeAreaBottom: CGFloat) -> CGFloat {
    guard safeAreaBottom > 0 else { return DashTheme.Sheet.floatingMargin }
    return DashTheme.Sheet.floatingMargin - safeAreaBottom
  }
}

/// Physical display metrics retained for the edge-to-edge bottom corners of an
/// expanded `.large` tray.
@MainActor
enum DashDisplayChrome {
  /// The display's corner radius; 0 on square-cornered devices.
  static let cornerRadius: CGFloat = {
    let key = ["_display", "Corner", "Radius"].joined()
    let screen = UIApplication.shared.connectedScenes
      .compactMap { ($0 as? UIWindowScene)?.screen }.first
    return (screen?.value(forKey: key) as? CGFloat) ?? 0
  }()

  /// Floating trays share one product radius across devices. This also makes a
  /// collapsed `.large` tray geometrically identical to a `.content` tray.
  static var floatingRadius: CGFloat {
    DashTheme.Radius.sheet
  }
}

/// The visible card of a `.content` tray, at the bottom of a full-screen
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
      RoundedRectangle(cornerRadius: DashDisplayChrome.floatingRadius, style: .continuous)
        .fill(DashTheme.Sheet.background)
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

private struct DashTrayModifier<Hero: View, TrayContent: View, Footer: View>: ViewModifier {
  @Binding var isPresented: Bool
  let title: String
  var sizing: DashSheetSizing = .content
  var showsMenuButtons = true
  var hero: (() -> Hero)?
  @ViewBuilder var trayContent: () -> TrayContent
  @ViewBuilder var footer: () -> Footer
  let hasFooter: Bool
  @State private var covered = false

  @ViewBuilder
  func body(content: Content) -> some View {
    content
      .preference(
        key: TrayPresentedPreferenceKey.self,
        value: DashTrayPresentation(sizing: sizing, isPresented: isPresented)
      )
      .onChange(of: isPresented, initial: true) { _, present in
        dashPresentWithoutAnimation { covered = present }
      }
      .fullScreenCover(isPresented: $covered) {
        if sizing == .content {
          DashCustomSheet(
            title: title, showsMenuButtons: showsMenuButtons, hero: hero,
            onDismiss: { isPresented = false }, content: trayContent,
            footer: footer, hasFooter: hasFooter)
        } else {
          DashExpandableSheet(
            title: title, showsMenuButtons: showsMenuButtons,
            onDismiss: { isPresented = false }, content: trayContent)
        }
      }
  }
}

private struct DashTrayItemModifier<Item: Identifiable & Equatable, Hero: View, TrayContent: View>:
  ViewModifier
{
  @Binding var item: Item?
  let title: (Item) -> String
  var sizing: DashSheetSizing = .content
  var showsMenuButtons = true
  var hero: ((Item) -> Hero)?
  @ViewBuilder var trayContent: (Item) -> TrayContent
  @State private var coveredItem: Item?

  private var isPresented: Bool { item != nil }

  @ViewBuilder
  func body(content: Content) -> some View {
    content
      .preference(
        key: TrayPresentedPreferenceKey.self,
        value: DashTrayPresentation(sizing: sizing, isPresented: isPresented)
      )
      .onChange(of: item, initial: true) { _, newItem in
        dashPresentWithoutAnimation { coveredItem = newItem }
      }
      .fullScreenCover(item: $coveredItem) { value in
        if sizing == .content {
          DashCustomSheet<Hero, TrayContent, EmptyView>(
            title: title(value), showsMenuButtons: showsMenuButtons,
            hero: hero.map { hero in { hero(value) } },
            onDismiss: { item = nil }, content: { trayContent(value) },
            footer: { EmptyView() }, hasFooter: false)
        } else {
          DashExpandableSheet(
            title: title(value), showsMenuButtons: showsMenuButtons,
            onDismiss: { item = nil }, content: { trayContent(value) })
        }
      }
  }
}
