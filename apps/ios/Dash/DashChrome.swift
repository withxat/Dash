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
    showsMenuButtons: Bool = true,
    @ViewBuilder content: @escaping () -> Content
  ) -> some View {
    modifier(
      DashTrayModifier<EmptyView, Content, EmptyView>(
        isPresented: isPresented, title: title,
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
        isPresented: isPresented, title: title,
        showsMenuButtons: showsMenuButtons, hero: nil,
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
    @ViewBuilder hero: @escaping () -> Hero,
    @ViewBuilder content: @escaping () -> Content
  ) -> some View {
    modifier(
      DashTrayModifier<Hero, Content, EmptyView>(
        isPresented: isPresented, title: title,
        showsMenuButtons: showsMenuButtons, hero: hero,
        trayContent: content, footer: { EmptyView() }, hasFooter: false))
  }

  func dashTray<Item: Identifiable & Equatable, Content: View>(
    item: Binding<Item?>,
    title: @escaping (Item) -> String,
    showsMenuButtons: Bool = true,
    @ViewBuilder content: @escaping (Item) -> Content
  ) -> some View {
    modifier(
      DashTrayItemModifier<Item, EmptyView, Content>(
        item: item, title: title,
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
        item: item, title: title,
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

/// A compact circular action rendered left of the tray's close button
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

/// Compact trays use a full-screen transparent cover with our own dim and a
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
  @State private var keyboardHeight: CGFloat = 0
  @State private var headerAction: DashSheetHeaderAction?
  @State private var contentTitle: String?
  @State private var contentDescription: String?
  @State private var stepRole = DashTrayStepRole.root
  @State private var dismissDisabled = false

  private var resolvedTitle: String { contentTitle ?? title }

  var body: some View {
    ZStack(alignment: .bottom) {
      Color.black.opacity(progress * DashTheme.Sheet.scrimOpacity)
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
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DashTheme.Sheet.floatingMargin)
        .accessibilityIdentifier("dash.tray.card")
        .padding(.bottom, bottomLift(proxy))
        // Bottom-pinned slide: a bounded fraction of the card height plus
        // opacity, blur, and scale — tall trays never shoot in from far away.
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
    .onPreferenceChange(DashSheetFittedHeightKey.self) { cardHeight = $0 }
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
    .onAppear {
      withAnimation(reduceMotion ? DashTheme.Motion.reduced : DashTrayMotion.present) {
        progress = 1
      }
    }
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

  private func close() {
    withAnimation(reduceMotion ? DashTheme.Motion.reduced : DashTrayMotion.dismiss) {
      progress = 0
    } completion: {
      drag = 0
      onDismiss()
    }
  }

  private func requestClose() {
    guard !dismissDisabled else { return }
    close()
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
          requestClose()
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

/// The established compact-tray reveal: a bounded rise with fade, blur, and a
/// whisper of bottom-anchored scale, driven by presentation progress.
private struct DashTrayCardReveal: ViewModifier, Animatable {
  var progress: CGFloat
  var drag: CGFloat
  var revealOffset: CGFloat
  var reduceMotion: Bool

  // Nonisolated: `Animatable` is a nonisolated protocol while `ViewModifier`
  // infers main-actor isolation onto the type; the accessors only touch
  // Sendable stored properties, which SE-0434 leaves nonisolated.
  nonisolated var animatableData: CGFloat {
    get { progress }
    set { progress = newValue }
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
        .scaleEffect(0.985 + 0.015 * progress, anchor: .bottom)
        .opacity(progress)
        .blur(radius: 4 * (1 - progress))
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
        value: DashTrayPresentation(presented: isPresented)
      )
      .onChange(of: isPresented, initial: true) { _, present in
        dashPresentWithoutAnimation { covered = present }
      }
      .fullScreenCover(isPresented: $covered) {
        DashCustomSheet(
          title: title, showsMenuButtons: showsMenuButtons, hero: hero,
          onDismiss: { isPresented = false }, content: trayContent,
          footer: footer, hasFooter: hasFooter)
      }
  }
}

private struct DashTrayItemModifier<Item: Identifiable & Equatable, Hero: View, TrayContent: View>:
  ViewModifier
{
  @Binding var item: Item?
  let title: (Item) -> String
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
        value: DashTrayPresentation(presented: isPresented)
      )
      .onChange(of: item, initial: true) { _, newItem in
        dashPresentWithoutAnimation { coveredItem = newItem }
      }
      .fullScreenCover(item: $coveredItem) { value in
        DashCustomSheet<Hero, TrayContent, EmptyView>(
          title: title(value), showsMenuButtons: showsMenuButtons,
          hero: hero.map { hero in { hero(value) } },
          onDismiss: { item = nil }, content: { trayContent(value) },
          footer: { EmptyView() }, hasFooter: false)
      }
  }
}
