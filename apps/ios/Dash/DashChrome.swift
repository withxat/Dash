import Combine
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
      DashTrayModifier<EmptyView, Content>(
        isPresented: isPresented, title: title, sizing: sizing,
        showsMenuButtons: showsMenuButtons, hero: nil, trayContent: content))
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
      DashTrayModifier(
        isPresented: isPresented, title: title, sizing: .content,
        showsMenuButtons: showsMenuButtons, hero: hero, trayContent: content))
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
}

private struct DashTrayTitleKey: PreferenceKey {
  static var defaultValue: String? { nil }
  static func reduce(value: inout String?, nextValue: () -> String?) {
    value = nextValue() ?? value
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
  /// Content tray: a deliberate pull can dismiss on distance, while a fling
  /// must first travel far enough to establish downward intent. This keeps a
  /// tiny, fast wobble from being amplified into a dismissal by SwiftUI's
  /// projected endpoint.
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

/// Tray motion, split by job: presentation arrives with only a whisper of
/// settle, a finger-driven release gets a little elasticity, and dismissal
/// leaves fast with no bounce. The values live once in `DashTheme.Motion`
/// (shared with the toast host); this is the tray-named handle for them.
private enum DashTrayMotion {
  static let present = DashTheme.Motion.present
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
    }
    .disabled(isDisabled)
    .opacity(isDisabled ? 0.45 : 1)
  }
}

/// Shared header (title + menu buttons, optional grab bar) for both tray styles.
private struct DashSheetHeader: View {
  let title: String
  var showsGrabBar = false
  var showsMenuButtons = true
  var trailingAction: DashSheetHeaderAction? = nil
  var menuButtonsDisabled = false
  let dismiss: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @AccessibilityFocusState private var titleFocused: Bool

  private var displayedTitle: String { DashL10n.ui(title) }

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
            reduceMotion ? DashTheme.Motion.reduced : DashTheme.Motion.morph, value: displayedTitle
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
      .padding(.leading, DashTheme.Sheet.content)
      // The close circle is 32pt inside a centered 44pt hit target. Let the
      // invisible 6pt trailing half extend into the inset so the visible circle
      // aligns with the title's 28pt leading edge.
      .padding(.trailing, showsMenuButtons ? DashTheme.Sheet.content - 6 : DashTheme.Sheet.content)
      .padding(.top, showsGrabBar ? 12 : DashTheme.Sheet.headerTop)
      .padding(.bottom, DashTheme.Sheet.headerBottom)

      Rectangle()
        .fill(DashTheme.Sheet.headerBorder)
        .frame(height: 1)
        .padding(.horizontal, DashTheme.Sheet.content)
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
  var trailingAction: DashSheetHeaderAction? = nil
  var menuButtonsDisabled = false
  let dismiss: () -> Void
  @ViewBuilder var hero: () -> Hero

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
          .padding(.top, DashTheme.Sheet.headerTop)
          .padding(.trailing, DashTheme.Sheet.content - 6)
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
/// bottom-pinned card. The card springs its own height (DashSheetCard) so
/// content morphs resize smoothly — there's no native detent to clip or snap.
/// The dim fades and the card slides up from the bottom (and dismisses the
/// same way), independently of the cover (see DashTrayModifier).
private struct DashCustomSheet<Hero: View, Content: View>: View {
  let title: String
  var showsMenuButtons = true
  /// Full-bleed view replacing the title header; nil keeps the standard header.
  var hero: (() -> Hero)?
  /// Removes the cover once the exit animation has finished.
  let onDismiss: () -> Void
  @ViewBuilder var content: () -> Content
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var progress: CGFloat = 0
  @State private var drag: CGFloat = 0
  @State private var cardHeight: CGFloat = 0
  @State private var keyboardHeight: CGFloat = 0
  @State private var headerAction: DashSheetHeaderAction?
  @State private var contentTitle: String?
  @State private var dismissDisabled = false

  private var resolvedTitle: String { contentTitle ?? title }

  var body: some View {
    ZStack(alignment: .bottom) {
      Color.black.opacity(progress * DashTheme.Sheet.scrimOpacity)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { requestClose() }
        .accessibilityLabel("Dismiss")
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
          maxCardHeight: proxy.size.height - bottomLift(proxy) - 24
        ) {
          // Drag-to-dismiss lives on the header (or hero) only, so the
          // scrollable body keeps its own vertical scroll.
          trayHeader
            .contentShape(Rectangle())
            .gesture(dragGesture, including: dismissDisabled ? .none : .all)
        } content: {
          content()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DashTheme.Sheet.floatingMargin)
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
    .environment(\.dashTrayDismiss, close)
    .onPreferenceChange(DashSheetFittedHeightKey.self) { cardHeight = $0 }
    .onPreferenceChange(DashSheetHeaderActionKey.self) { headerAction = $0 }
    .onPreferenceChange(DashTrayTitleKey.self) { contentTitle = $0 }
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

  @ViewBuilder private var trayHeader: some View {
    if let hero {
      DashSheetHeroHeader(
        title: resolvedTitle, showsMenuButtons: showsMenuButtons,
        trailingAction: headerAction, menuButtonsDisabled: dismissDisabled,
        dismiss: requestClose, hero: hero)
    } else {
      DashSheetHeader(
        title: resolvedTitle, showsMenuButtons: showsMenuButtons,
        trailingAction: headerAction, menuButtonsDisabled: dismissDisabled,
        dismiss: requestClose)
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
        case .settle, .settleExpanded:
          if reduceMotion {
            drag = 0
          } else {
            withAnimation(DashTrayMotion.release) { drag = 0 }
          }
        }
      }
  }
}

/// Slide reveal for the `.content` card: a bounded rise with fade, blur, and
/// a whisper of bottom-anchored scale, driven by one continuous progress.
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

/// `.large` trays: a custom two-detent sheet. It presents expanded — full
/// width, edge-to-edge at the bottom, native-sheet top corners — and the grab
/// bar or header drags it down to a floating detent styled exactly like a
/// `.content` tray (screen-edge margins, concentric all-corner radius).
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
    .environment(\.dashTrayDismiss, close)
    .onPreferenceChange(DashTrayTitleKey.self) { contentTitle = $0 }
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
        title: resolvedTitle, showsGrabBar: true, showsMenuButtons: showsMenuButtons,
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
    let floatingBottomMargin = max(
      safeBottom - DashTheme.Sheet.floatingBottomTuck,
      DashTheme.Sheet.floatingMargin)
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
      horizontalMargin: lerp(0, DashTheme.Sheet.floatingMargin),
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

/// Physical display metrics so floating trays run concentric with the
/// hardware corners.
@MainActor
enum DashDisplayChrome {
  /// The display's corner radius; 0 on square-cornered devices.
  static let cornerRadius: CGFloat = {
    let key = ["_display", "Corner", "Radius"].joined()
    let screen = UIApplication.shared.connectedScenes
      .compactMap { ($0 as? UIWindowScene)?.screen }.first
    return (screen?.value(forKey: key) as? CGFloat) ?? 0
  }()

  /// All-corner radius for a floating tray inset by `floatingMargin`:
  /// concentric with the display when its radius is known, the sheet token
  /// otherwise.
  static var floatingRadius: CGFloat {
    cornerRadius > 0
      ? max(cornerRadius - DashTheme.Sheet.floatingMargin, DashTheme.Radius.card)
      : DashTheme.Radius.sheet
  }
}

/// The visible card of a `.content` tray, at the bottom of a full-screen
/// transparent cover: a fixed header over a body that springs its height to fit
/// its content — so a morph resizes smoothly with no detent to clip or snap —
/// but caps at the available height (`maxCardHeight`, which shrinks with the
/// keyboard) and scrolls beyond it, so a form never squeezes or overflows.
/// Paints its own canvas fill, top corners, and safe-area extension.
private struct DashSheetCard<Header: View, Body: View>: View {
  let maxCardHeight: CGFloat
  @ViewBuilder let header: () -> Header
  @ViewBuilder let content: () -> Body
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var headerHeight: CGFloat = 0
  @State private var bodyIdeal: CGFloat = 0
  @State private var bodyDisplay: CGFloat = 0

  private var maxBodyHeight: CGFloat { max(80, maxCardHeight - headerHeight) }

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
          .padding(.bottom, DashTheme.Sheet.bodyBottom)
          .background {
            GeometryReader { proxy in
              Color.clear.preference(key: DashSheetBodyIdealKey.self, value: proxy.size.height)
            }
          }
      }
      .frame(height: bodyDisplay > 0 ? bodyDisplay : nil)
    }
    .frame(maxWidth: .infinity)
    // A floating card: every corner rounded, concentric with the display, and
    // nothing extends past the card — the gaps around it are the design.
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
      withAnimation(DashTheme.Motion.morph) { bodyDisplay = target }
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

private struct DashTrayModifier<Hero: View, TrayContent: View>: ViewModifier {
  @Binding var isPresented: Bool
  let title: String
  var sizing: DashSheetSizing = .content
  var showsMenuButtons = true
  var hero: (() -> Hero)?
  @ViewBuilder var trayContent: () -> TrayContent
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
            onDismiss: { isPresented = false }, content: trayContent)
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
          DashCustomSheet(
            title: title(value), showsMenuButtons: showsMenuButtons,
            hero: hero.map { hero in { hero(value) } },
            onDismiss: { item = nil }, content: { trayContent(value) })
        } else {
          DashExpandableSheet(
            title: title(value), showsMenuButtons: showsMenuButtons,
            onDismiss: { item = nil }, content: { trayContent(value) })
        }
      }
  }
}
