import CloudflareAPI
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

  /// Overrides the tray chrome title for the current step (e.g. Profile → Sign out).
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

/// Tray motion is intentionally split by job: presentation arrives quick with
/// only a whisper of settle, a finger-driven release gets a little elasticity,
/// and dismissal leaves fast with no bounce. Keeping the three separate avoids
/// making programmatic opens feel toy-like.
private enum DashTrayMotion {
  static let present = Animation.spring(response: 0.35, dampingFraction: 0.88, blendDuration: 0.12)
  static let release = Animation.spring(response: 0.34, dampingFraction: 0.82, blendDuration: 0.14)
  static let dismiss = Animation.spring(response: 0.28, dampingFraction: 0.94, blendDuration: 0.08)
}

/// The trailing button cluster — optional action circle plus close — shared by
/// the standard and hero headers so both variants keep identical geometry.
private struct DashSheetMenuButtons: View {
  var trailingAction: DashSheetHeaderAction? = nil
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
      }
      DashCloseButton { dismiss() }
    }
  }
}

/// Shared header (title + menu buttons, optional grab bar) for both tray styles.
private struct DashSheetHeader: View {
  let title: String
  var showsGrabBar = false
  var showsMenuButtons = true
  var trailingAction: DashSheetHeaderAction? = nil
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
          DashSheetMenuButtons(trailingAction: trailingAction, dismiss: dismiss)
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
  let dismiss: () -> Void
  @ViewBuilder var hero: () -> Hero

  private var displayedTitle: String { DashL10n.ui(title) }

  var body: some View {
    hero()
      .frame(maxWidth: .infinity)
      .clipped()
      .overlay(alignment: .topTrailing) {
        if showsMenuButtons {
          DashSheetMenuButtons(trailingAction: trailingAction, dismiss: dismiss)
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

  private var resolvedTitle: String { contentTitle ?? title }

  var body: some View {
    ZStack(alignment: .bottom) {
      Color.black.opacity(progress * DashTheme.Sheet.scrimOpacity)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { close() }
        .accessibilityLabel("Dismiss")
        .accessibilityAddTraits(.isButton)

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
            .gesture(dragGesture)
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
        withAnimation(DashTheme.Motion.sheet) { keyboardHeight = covered }
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
        trailingAction: headerAction, dismiss: close, hero: hero)
    } else {
      DashSheetHeader(
        title: resolvedTitle, showsMenuButtons: showsMenuButtons,
        trailingAction: headerAction, dismiss: close)
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
          close()
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
        .onTapGesture { close() }
        .accessibilityLabel("Dismiss")
        .accessibilityAddTraits(.isButton)

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
        dismiss: close
      )
      .contentShape(Rectangle())
      .gesture(detentGesture(metrics))
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
          close()
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

// MARK: - Root chrome

/// Shared profile avatar control: ONE instance, floated by `MainTabView`
/// above the pager so it doesn't ride along on tab swipes (and doesn't get
/// squashed by the nav bar's item-height clamp). It is positioned over the
/// leading slot of the roots' titleless nav bars, so on push it fades out
/// exactly where the system back control fades in — same spot, same glass
/// circle — reading as one control trading places.
struct HeaderProfileButton: View {
  @Environment(AppModel.self) private var model
  let action: @MainActor () -> Void

  private var accountLabel: String {
    model.activeAccount?.name ?? model.profileTitle
  }

  /// Circular glass matching the system back control. Without
  /// `buttonBorderShape(.circle)`, iOS 26 paints a square glass plate around
  /// the 44×44 avatar bounds and flashes its white corner during push morph.
  /// The negative padding pulls the glass in so the ring hugs the avatar
  /// instead of leaving a gap around it.
  var body: some View {
    let email = model.user?.email ?? ""
    if #available(iOS 26.0, *) {
      Button {
        DashDelight.lightImpact()
        action()
      } label: {
        HeaderProfileAvatar(email: email)
          .frame(width: AvatarHeaderMetrics.barSize, height: AvatarHeaderMetrics.barSize)
          .padding(-7)
      }
      .buttonStyle(.glass)
      .buttonBorderShape(.circle)
      .accessibilityLabel("Profile, \(accountLabel)")
    } else {
      Button(action: action) {
        HeaderProfileAvatar(email: email)
      }
      .buttonStyle(DashPressButtonStyle())
      .accessibilityLabel("Profile, \(accountLabel)")
    }
  }
}

/// Watchtower root action that enters chart customization. It uses the same
/// floated 44pt circle as the profile and inbox controls so adding a second
/// trailing action does not let the navigation bar clamp either button.
struct HeaderWatchtowerCustomizeButton: View {
  let action: @MainActor () -> Void

  var body: some View {
    Group {
      if #available(iOS 26.0, *) {
        Button {
          DashDelight.lightImpact()
          action()
        } label: {
          SolarIcon(asset: SolarAsset.slider, size: 24, color: DashTheme.strong)
            .frame(width: AvatarHeaderMetrics.barSize, height: AvatarHeaderMetrics.barSize)
            .padding(-7)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
      } else {
        Button {
          DashDelight.lightImpact()
          action()
        } label: {
          SolarIcon(asset: SolarAsset.slider, size: 24, color: DashTheme.strong)
            .frame(width: AvatarHeaderMetrics.barSize, height: AvatarHeaderMetrics.barSize)
            .background(DashTheme.elevated, in: Circle())
            .overlay { Circle().stroke(DashTheme.line, lineWidth: 0.5) }
        }
        .buttonStyle(DashPressButtonStyle())
      }
    }
    .frame(width: AvatarHeaderMetrics.barSize, height: AvatarHeaderMetrics.barSize)
    .accessibilityLabel(DashL10n.string("Adjust view"))
    .accessibilityIdentifier("watchtower-customize-button")
  }
}

/// Trailing Watchtower inbox control — same 44pt glass circle as the leading
/// profile avatar. Floated by `MainTabView` (not a toolbar item) so the nav
/// bar's item-height clamp cannot squash it into a capsule. The count badge
/// overlays the glass corner (not a sibling ZStack that floats away).
struct HeaderInboxButton: View {
  let count: Int
  let action: @MainActor () -> Void
  /// Long-press opens the shared Ignore-all confirmation when there are actives.
  var onLongPress: (@MainActor () -> Void)? = nil

  private var accessibilityLabel: String {
    count > 0
      ? DashL10n.string("Alerts, \(count) pending")
      : DashL10n.string("Alerts")
  }

  var body: some View {
    circleButton
      // Lock the layout to the avatar's 44pt slot so the badge anchors to
      // the same circle the glass paints, not an inflated button bounds.
      .frame(width: AvatarHeaderMetrics.barSize, height: AvatarHeaderMetrics.barSize)
      .overlay(alignment: .topTrailing) { countBadge }
      .simultaneousGesture(
        LongPressGesture(minimumDuration: 0.35).onEnded { _ in
          guard count > 0, let onLongPress else { return }
          DashDelight.lightImpact()
          onLongPress()
        }
      )
      .accessibilityIdentifier("watchtower-inbox-button")
      .accessibilityHint(
        count > 0 && onLongPress != nil
          ? DashL10n.string("Long press to ignore all alerts") : ""
      )
      .accessibilityAction(named: DashL10n.string("Ignore all alerts")) {
        guard count > 0 else { return }
        onLongPress?()
      }
  }

  @ViewBuilder
  private var countBadge: some View {
    if count > 0 {
      Text(count > 9 ? "9+" : "\(count)")
        .font(.system(size: 11, weight: .bold))
        .monospacedDigit()
        .foregroundStyle(.white)
        .padding(.horizontal, count > 9 ? 5 : 0)
        .frame(minWidth: 18, minHeight: 18)
        .background(DashTheme.danger, in: Capsule(style: .continuous))
        .offset(x: 4, y: -4)
        .accessibilityHidden(true)
    }
  }

  @ViewBuilder
  private var circleButton: some View {
    if #available(iOS 26.0, *) {
      Button {
        DashDelight.lightImpact()
        action()
      } label: {
        SolarIcon(asset: SolarAsset.inbox, size: 24, color: DashTheme.strong)
          .frame(width: AvatarHeaderMetrics.barSize, height: AvatarHeaderMetrics.barSize)
          .padding(-7)
      }
      .buttonStyle(.glass)
      .buttonBorderShape(.circle)
      .accessibilityLabel(accessibilityLabel)
    } else {
      Button(action: action) {
        SolarIcon(asset: SolarAsset.inbox, size: 24, color: DashTheme.strong)
          .frame(width: AvatarHeaderMetrics.barSize, height: AvatarHeaderMetrics.barSize)
          .background(DashTheme.elevated, in: Circle())
          .overlay { Circle().stroke(DashTheme.line, lineWidth: 0.5) }
      }
      .buttonStyle(DashPressButtonStyle())
      .accessibilityLabel(accessibilityLabel)
    }
  }
}

extension View {
  /// Canvas chrome for a tab-root screen: canvas background and every fix
  /// needed to keep the system's white slabs from painting over it (UIKit
  /// scroll fill, iOS 26 edge pockets, nav-bar background).
  ///
  /// The root shows a REAL navigation bar — no title, no items. Keeping the
  /// bar mounted is what makes a push seamless: the bar's height never
  /// changes (no content shift), and the back control lands in the leading
  /// slot where the shared floating avatar sits (`MainTabView` renders that
  /// avatar once, above the pager, so it doesn't ride along on tab swipes;
  /// seating it as a toolbar item would also squash it against the bar's
  /// item-height clamp). `topBand` is a zero-height hook at the content's
  /// rest line — Home hangs its scroll probe there.
  ///
  /// `scrollFill: .clear` is for Home: its in-page canvas + top wash must
  /// show through the content scroll. Other roots keep `.canvas` so the
  /// system white slab stays dead.
  func dashCatalogScreen(
    @ViewBuilder background: () -> some View = { DashTheme.canvas.ignoresSafeArea() },
    scrollFill: DashScrollViewConfigurator.Fill = .canvas,
    @ViewBuilder topBand: () -> some View = { Color.clear }
  ) -> some View {
    navigationTitle("")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        // Invisible prop: a titleless bar with no items collapses to zero
        // inset. A clear principal keeps the root bar at standard height —
        // principal items carry no glass plate, so nothing shows — and the
        // content rest line lands exactly where pushed screens put it.
        ToolbarItem(placement: .principal) {
          Color.clear.frame(width: 1, height: 1)
        }
      }
      // The bar itself stays fully transparent so the canvas (and Home's
      // wash) shows through; scrolled content frosts under the status bar
      // only via the shared appearance, never a slab.
      .toolbarBackground(.hidden, for: .navigationBar)
      .safeAreaInset(edge: .top, spacing: 0) {
        Color.clear
          .frame(height: 0)
          .background { topBand() }
      }
      .scrollContentBackground(.hidden)
      .modifier(DashScrollEdgeEffectsHidden())
      // UIKit scroll/hosting chrome → canvas grey (kills the system white slab),
      // or clear on Home so the page's own canvas + wash show through.
      .background { DashScrollViewConfigurator(fill: scrollFill) }
      .background { background() }
  }

  /// Canvas scroll chrome for pushed feature/detail screens. Tab roots use
  /// `dashCatalogScreen`; destinations need the same edge-pocket kill so iOS
  /// 26 doesn't leave a white slab under the (now hidden) dock.
  func dashDetailCanvasChrome() -> some View {
    modifier(DashScrollEdgeEffectsHidden())
      .background { DashScrollViewConfigurator(fill: .canvas) }
  }

}

/// iOS 26 paints a white “scroll edge pocket” above floating chrome; kill it
/// on canvas screens so the warm canvas shows through under the custom tab bar.
struct DashScrollEdgeEffectsHidden: ViewModifier {
  func body(content: Content) -> some View {
    if #available(iOS 26.0, *) {
      content.scrollEdgeEffectHidden(true, for: .all)
    } else {
      content
    }
  }
}

// MARK: - Scroll edge fades

/// Vertical `ScrollView` with soft top/bottom surface fades for nested or
/// height-capped regions where overflow is easy to miss (Domains viewport,
/// build log, tray bodies). Full-page canvas scrolls stay plain `ScrollView`.
///
/// Pass the fill *behind* the scroll content as `surface` so the fade matches
/// (sheet, card, domains tint, …). Nested instances are safe: each keeps its
/// own probe id so preferences do not collide.
///
/// Opacity ramps over the first ~36pt past an edge (tracks the finger); large
/// layout jumps ease over 0.22s so the fade never pops.
struct DashFadedScrollView<Content: View>: View {
  var surface: Color
  var maxHeight: CGFloat? = nil
  var showsIndicators: Bool = false
  var bounceBasedOnSize: Bool = false
  var dismissesKeyboardInteractively: Bool = false
  @ViewBuilder var content: () -> Content

  @State private var spaceID = UUID()
  /// 0…1 strength; ramps with distance past the edge so show/hide is not a pop.
  @State private var topOpacity: CGFloat = 0
  @State private var bottomOpacity: CGFloat = 0
  /// Mutable sample so mid-scroll offset chatter does not re-render the list
  /// except when a quantized opacity step changes.
  @State private var sample = ScrollEdgeSample()

  private var spaceName: String { "dashFadedScroll.\(spaceID.uuidString)" }
  /// Distance (pt) over which the edge fade eases from 0 → 1.
  private let softRange: CGFloat = 36
  private let fadeHeight: CGFloat = 32

  var body: some View {
    ScrollView(showsIndicators: showsIndicators) {
      content()
        .background {
          GeometryReader { geo in
            let frame = geo.frame(in: .named(spaceName))
            Color.clear.preference(
              key: DashScrollEdgeProbeKey.self,
              value: [
                spaceID: DashScrollEdgeProbe(
                  offset: -frame.minY,
                  contentHeight: geo.size.height,
                  viewportHeight: nil
                )
              ]
            )
          }
        }
    }
    .coordinateSpace(name: spaceName)
    .background {
      GeometryReader { geo in
        Color.clear.preference(
          key: DashScrollEdgeProbeKey.self,
          value: [
            spaceID: DashScrollEdgeProbe(
              offset: nil,
              contentHeight: nil,
              viewportHeight: geo.size.height
            )
          ]
        )
      }
    }
    .onPreferenceChange(DashScrollEdgeProbeKey.self) { probes in
      guard let probe = probes[spaceID] else { return }
      ingest(probe)
    }
    .modifier(DashScrollBounceBasedOnSize(enabled: bounceBasedOnSize))
    .modifier(DashScrollDismissesKeyboard(enabled: dismissesKeyboardInteractively))
    .frame(maxHeight: maxHeight)
    .overlay(alignment: .top) {
      edgeFade(leadingFromTop: true)
        .opacity(topOpacity)
    }
    .overlay(alignment: .bottom) {
      edgeFade(leadingFromTop: false)
        .opacity(bottomOpacity)
    }
  }

  /// Soft ease for layout jumps (content size change); continuous scroll already
  /// ramps via `softRange` so it tracks the finger without lag.
  /// Computed: generic types cannot hold static stored properties.
  private static var edgeAnimation: Animation {
    .easeInOut(duration: 0.22)
  }

  private func ingest(_ probe: DashScrollEdgeProbe) {
    if let offset = probe.offset {
      sample.offset = offset
    }
    if let contentHeight = probe.contentHeight, contentHeight > 0 {
      sample.contentHeight = contentHeight
    }
    if let viewportHeight = probe.viewportHeight, viewportHeight > 0 {
      sample.viewportHeight = viewportHeight
    }
    recomputeEdges()
  }

  private func recomputeEdges() {
    let viewport = sample.viewportHeight
    let content = sample.contentHeight
    guard viewport > 0, content > 0 else { return }
    let remaining = content - viewport - sample.offset
    let nextTop = Self.softOpacity(distance: sample.offset, range: softRange)
    let nextBottom = Self.softOpacity(distance: remaining, range: softRange)
    setEdgeOpacity(nextTop, current: topOpacity) { topOpacity = $0 }
    setEdgeOpacity(nextBottom, current: bottomOpacity) { bottomOpacity = $0 }
  }

  /// Finger-tracking steps update immediately; large jumps (layout / content
  /// size) ease so the fade never pops.
  private func setEdgeOpacity(
    _ next: CGFloat, current: CGFloat, set: (CGFloat) -> Void
  ) {
    guard next != current else { return }
    if abs(next - current) > 0.35 {
      withAnimation(Self.edgeAnimation) { set(next) }
    } else {
      set(next)
    }
  }

  /// Maps overflow distance into a stepped 0…1 opacity so the fade eases in
  /// over `range` points instead of flipping on a 1pt threshold.
  private static func softOpacity(distance: CGFloat, range: CGFloat) -> CGFloat {
    guard range > 0 else { return distance > 0 ? 1 : 0 }
    let raw = min(1, max(0, distance / range))
    // ~20 steps: smooth enough to read, sparse enough to avoid per-frame churn.
    return (raw * 20).rounded() / 20
  }

  private func edgeFade(leadingFromTop: Bool) -> some View {
    LinearGradient(
      colors: leadingFromTop
        ? [surface, surface.opacity(0)]
        : [surface.opacity(0), surface],
      startPoint: .top,
      endPoint: .bottom
    )
    .frame(height: fadeHeight)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

/// Reference-type sample so preference updates can mutate without `@State` churn.
private final class ScrollEdgeSample {
  var offset: CGFloat = 0
  var contentHeight: CGFloat = 0
  var viewportHeight: CGFloat = 0
}

private struct DashScrollEdgeProbe: Equatable {
  var offset: CGFloat?
  var contentHeight: CGFloat?
  var viewportHeight: CGFloat?

  func merging(_ other: DashScrollEdgeProbe) -> DashScrollEdgeProbe {
    DashScrollEdgeProbe(
      offset: other.offset ?? offset,
      contentHeight: other.contentHeight ?? contentHeight,
      viewportHeight: other.viewportHeight ?? viewportHeight
    )
  }
}

private enum DashScrollEdgeProbeKey: PreferenceKey {
  static let defaultValue: [UUID: DashScrollEdgeProbe] = [:]

  static func reduce(
    value: inout [UUID: DashScrollEdgeProbe],
    nextValue: () -> [UUID: DashScrollEdgeProbe]
  ) {
    value.merge(nextValue()) { $0.merging($1) }
  }
}

private struct DashScrollBounceBasedOnSize: ViewModifier {
  var enabled: Bool

  func body(content: Content) -> some View {
    if enabled {
      content.scrollBounceBehavior(.basedOnSize)
    } else {
      content
    }
  }
}

private struct DashScrollDismissesKeyboard: ViewModifier {
  var enabled: Bool

  func body(content: Content) -> some View {
    if enabled {
      content.scrollDismissesKeyboard(.interactively)
    } else {
      content
    }
  }
}

/// Clears UIScrollView's opaque fill and hides iOS 26 edge pockets. SwiftUI's
/// `scrollEdgeEffectHidden` alone was still leaving a fixed white slab that
/// content scrolled underneath.
///
/// Note: a `.background` representable is a *sibling* of the UIScrollView, not
/// a descendant — walk up, then search the subtree for scroll views.
struct DashScrollViewConfigurator: UIViewRepresentable {
  enum Fill {
    /// Matches `DashTheme.canvas` — kills the system white slab on ordinary roots.
    case canvas
    /// Home: let the page's own canvas + top wash show through scroll chrome.
    case clear
  }

  var fill: Fill = .canvas

  func makeUIView(context: Context) -> UIView {
    let view = UIView()
    view.isUserInteractionEnabled = false
    view.backgroundColor = .clear
    view.isOpaque = false
    return view
  }

  func updateUIView(_ uiView: UIView, context: Context) {
    let fill = fill
    DispatchQueue.main.async {
      Self.configureNearbyScrollViews(from: uiView, fill: fill)
      DispatchQueue.main.async {
        Self.configureNearbyScrollViews(from: uiView, fill: fill)
      }
    }
  }

  private static func configureNearbyScrollViews(from view: UIView, fill: Fill) {
    // Keep the three-tab pager clear so Home's wash / per-tab plates show
    // through without applying one screen's fill to neighboring content.
    var node: UIView? = view.superview
    while let current = node {
      if let pager = tabPager(in: current) {
        paint(pager, fill: .clear)
        break
      }
      node = current.superview
    }

    // Scope fill to this content VC only (root or pushed destination).
    let screen = enclosingContentView(from: view) ?? view.superview ?? view
    // UIKit's slide animates the VC's view — paint it so the plate is opaque
    // (canvas) or wash-through (clear) for the whole transition, not only
    // after SwiftUI commits its `.background`.
    screen.backgroundColor = fill == .clear ? .clear : canvasFill
    apply(in: screen, fill: fill)
  }

  /// Nearest non-container view controller that hosts `view`. Skips
  /// `UINavigationController` so a pushed destination and the tab root each
  /// configure only their own plate.
  private static func enclosingContentView(from view: UIView) -> UIView? {
    var node: UIView? = view
    while let current = node {
      var responder: UIResponder? = current
      while let next = responder {
        if let viewController = next as? UIViewController,
          !(viewController is UINavigationController),
          !(viewController is UITabBarController),
          let root = viewController.viewIfLoaded,
          current === root || current.isDescendant(of: root)
        {
          return root
        }
        responder = next.next
      }
      node = current.superview
    }
    return nil
  }

  /// Same geometry heuristic as `TabPagerScrollLock` — shared so Home's page
  /// fill and the pager lock agree on which scroll is the three-tab pager.
  static func isTabPager(_ scroll: UIScrollView) -> Bool {
    if scroll.isPagingEnabled { return true }
    guard scroll is UICollectionView else { return false }
    let width = scroll.bounds.width
    guard width > 100 else { return false }
    let pages = scroll.contentSize.width / width
    let mostlyHorizontal = scroll.contentSize.height <= scroll.bounds.height + 2
    return mostlyHorizontal && pages >= 1.8 && pages <= 4.5
  }

  private static func tabPager(in view: UIView) -> UIScrollView? {
    if let scroll = view as? UIScrollView, isTabPager(scroll) {
      return scroll
    }
    for child in view.subviews {
      if let scroll = child as? UIScrollView, isTabPager(scroll) {
        return scroll
      }
      for grand in child.subviews {
        if let scroll = grand as? UIScrollView, isTabPager(scroll) {
          return scroll
        }
      }
    }
    return nil
  }

  private static let canvasFill = UIColor { traits in
    if traits.userInterfaceStyle == .dark {
      // Matches `DashTheme.canvas` / `color-kumo-canvas` dark: 0x030303
      UIColor(red: 0x03 / 255, green: 0x03 / 255, blue: 0x03 / 255, alpha: 1)
    } else {
      // Matches `DashTheme.canvas` / `color-kumo-canvas` light: 0xFBFBFB
      UIColor(red: 0xFB / 255, green: 0xFB / 255, blue: 0xFB / 255, alpha: 1)
    }
  }

  private static func paint(_ scroll: UIScrollView, fill: Fill) {
    // Do NOT also force `isOpaque = true`: under nested hosting views it makes
    // CoreAnimation skip compositing the HostingScrollView's content, blanking
    // the whole screen.
    scroll.backgroundColor = fill == .clear ? .clear : canvasFill
    if #available(iOS 26.0, *) {
      scroll.topEdgeEffect.isHidden = true
      scroll.bottomEdgeEffect.isHidden = true
      scroll.leftEdgeEffect.isHidden = true
      scroll.rightEdgeEffect.isHidden = true
    }
  }

  private static func apply(in view: UIView, fill: Fill) {
    if let scroll = view as? UIScrollView {
      // Tab pager stays clear; content scrolls take the caller's fill.
      paint(scroll, fill: isTabPager(scroll) ? .clear : fill)
    }

    // Hosting/nav containers default to system white above the scroll view.
    // Home (`.clear`) must punch that out so the wash shows through — but
    // never do that on a `.canvas` screen: light canvas (0xFBFBFB) is itself
    // "near white", and clearing it leaves the UIKit push plate transparent.
    let name = NSStringFromClass(type(of: view))
    if name.contains("HostingView") || name.contains("NavigationController") {
      let unset =
        view.backgroundColor == nil
        || view.backgroundColor == .systemBackground
        || isNearWhite(view.backgroundColor)
      if unset {
        view.backgroundColor = fill == .clear ? .clear : canvasFill
      }
    }

    for child in view.subviews {
      apply(in: child, fill: fill)
    }
  }

  private static func isNearWhite(_ color: UIColor?) -> Bool {
    guard let color else { return false }
    var white: CGFloat = 0
    var alpha: CGFloat = 0
    return color.getWhite(&white, alpha: &alpha) && white > 0.96 && alpha > 0.9
  }
}

// MARK: - Tray content helpers

/// A form tray with exactly one action button. When a delete is supplied, a
/// circular header button morphs the form — in place — into a confirmation whose
/// single button is the destructive one; the Save button becomes Confirm rather
/// than a second button appearing. This is the canonical editor tray.
struct DashFormSheet<Content: View>: View {
  var saveTitle = "Save"
  var isSaving = false
  var canSave = true
  var deleteMessage: String? = nil
  var isDeleting = false
  /// Failure of the last delete attempt, shown inline while confirming so the
  /// morph stays open instead of pretending success.
  var deleteError: String? = nil
  var onDelete: (() -> Void)? = nil
  let onSave: () -> Void
  @ViewBuilder let content: Content
  @State private var confirmingDelete = false

  private var hasDelete: Bool { deleteMessage != nil && onDelete != nil }

  var body: some View {
    DashConfirmMorph(
      confirming: $confirmingDelete,
      message: deleteMessage,
      isBusy: confirmingDelete ? isDeleting : isSaving,
      actionTitle: saveTitle,
      confirmingActionTitle: "Delete",
      actionRole: nil,
      confirmingActionRole: .destructive,
      actionEnabled: confirmingDelete || canSave,
      errorMessage: confirmingDelete ? deleteError : nil,
      action: { confirmingDelete ? onDelete?() : onSave() },
      headerDelete: hasDelete,
      content: { content }
    )
    .dashKeyboardDismissal()
  }
}

/// The shared body/confirm morph: a body that swaps to a centered message, a
/// Cancel that dissolves in while confirming, and a primary `DashActionButton`
/// that dissolves with the same `.dashMorph` blur (idle Save/Make active ↔
/// Delete) instead of staying sharp while the body blurs. A header trash
/// button flips `confirming`. Reused by editor and detail trays so the whole
/// app shares one "primary action + optional sub-actions" interaction.
struct DashConfirmMorph<Content: View>: View {
  @Binding var confirming: Bool
  var message: String?
  var isBusy: Bool
  /// Idle primary action title. `nil` hides the footer button until confirming
  /// (detail trays that only offer header delete).
  var actionTitle: String?
  var confirmingActionTitle: String = "Delete"
  var actionRole: ButtonRole? = nil
  var confirmingActionRole: ButtonRole? = .destructive
  var actionEnabled: Bool = true
  var errorMessage: String? = nil
  var action: () -> Void
  var headerDelete = false
  @ViewBuilder var content: () -> Content
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dashTrayPinsFooter) private var pinsFooter

  private var morphAnimation: Animation {
    reduceMotion ? DashTheme.Motion.reduced : DashTheme.Motion.morph
  }

  private var morphTransition: AnyTransition {
    reduceMotion ? .opacity : .dashMorph
  }

  var body: some View {
    VStack(spacing: 16) {
      Group {
        if pinsFooter {
          DashFadedScrollView(
            surface: DashTheme.Sheet.background,
            bounceBasedOnSize: true
          ) {
            bodyContent
              .frame(maxWidth: .infinity, alignment: .top)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
          bodyContent
        }
      }

      if confirming {
        Button {
          withAnimation(morphAnimation) { confirming = false }
        } label: {
          Text(DashL10n.string("Cancel"))
            .dashTextStyle(.buttonMedium)
            .foregroundStyle(DashTheme.subtle)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(DashPressButtonStyle())
        .transition(morphTransition)

        DashActionButton(
          title: confirmingActionTitle,
          role: confirmingActionRole,
          isLoading: isBusy,
          holdToConfirm: true,
          action: action
        )
        .disabled(!actionEnabled)
        .opacity(actionEnabled ? 1 : 0.45)
        .transition(morphTransition)
      } else if let actionTitle {
        DashActionButton(
          title: actionTitle, role: actionRole, isLoading: isBusy, action: action
        )
        .disabled(!actionEnabled)
        .opacity(actionEnabled ? 1 : 0.45)
        .transition(morphTransition)
      }
    }
    .frame(
      maxWidth: .infinity,
      maxHeight: pinsFooter ? .infinity : nil,
      alignment: .top
    )
    .dashTrayHeaderAction(
      headerDelete && !confirming
        ? DashSheetHeaderAction(
          id: "delete", icon: SolarAsset.trash,
          accessibilityLabel: DashL10n.string("Delete")
        ) {
          withAnimation(morphAnimation) { confirming = true }
        }
        : nil
    )
  }

  @ViewBuilder
  private var bodyContent: some View {
    ZStack {
      if confirming, let message {
        VStack(spacing: 12) {
          Text(DashL10n.ui(message))
            .dashTextStyle(.supporting)
            .foregroundStyle(DashTheme.subtle)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
          if let errorMessage {
            DashNotice(kind: .error, message: errorMessage)
          }
        }
        .transition(morphTransition)
      } else {
        content()
          .transition(morphTransition)
      }
    }
  }
}

private struct DashKeyboardDismissalModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
      .scrollDismissesKeyboard(.immediately)
      .contentShape(Rectangle())
      .onTapGesture(perform: dismissKeyboard)
  }

  private func dismissKeyboard() {
    UIApplication.shared.sendAction(
      #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
  }
}

extension View {
  func dashKeyboardDismissal() -> some View {
    modifier(DashKeyboardDismissalModifier())
  }
}

struct DashFormField: View {
  let label: String
  @Binding var text: String
  var keyboard: UIKeyboardType = .default
  var contentType: UITextContentType? = nil
  @FocusState private var isFocused: Bool

  private var displayedLabel: String { DashL10n.ui(label) }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(displayedLabel)
        .dashTextStyle(.footnoteSemibold)
        .foregroundStyle(DashTheme.subtle)
      TextField(displayedLabel, text: $text)
        .dashTextStyle(.bodyMedium)
        .foregroundStyle(DashTheme.text)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .keyboardType(keyboard)
        .textContentType(contentType)
        .focused($isFocused)
        .submitLabel(.done)
        .onSubmit { isFocused = false }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(DashTheme.recessed)
        .clipShape(RoundedRectangle(cornerRadius: DashTheme.Radius.medium, style: .continuous))
    }
  }
}

/// Menu-backed form field (a dropdown) styled to match `DashFormField` — for
/// choosing among many options where a segmented control would cramp and can't
/// grow. One row, constant footprint, scales to any number of options.
struct DashFormMenuField: View {
  let label: String
  @Binding var selection: String
  let options: [String]

  private var displayedLabel: String { DashL10n.ui(label) }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(displayedLabel)
        .dashTextStyle(.footnoteSemibold)
        .foregroundStyle(DashTheme.subtle)
      Menu {
        Picker(displayedLabel, selection: $selection) {
          ForEach(options, id: \.self) { Text(DashL10n.ui($0)) }
        }
      } label: {
        HStack(spacing: 8) {
          Text(DashL10n.ui(selection))
            .dashTextStyle(.bodyMedium)
            .foregroundStyle(DashTheme.text)
          Spacer(minLength: 0)
          SolarIcon(
            asset: SolarAsset.chevronRight, size: DashTheme.Chevron.compact,
            color: DashTheme.placeholder
          )
          .rotationEffect(.degrees(90))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DashTheme.recessed)
        .clipShape(RoundedRectangle(cornerRadius: DashTheme.Radius.medium, style: .continuous))
      }
    }
  }
}

/// Multiline code variant of DashFormField for tray forms.
struct DashFormCodeField: View {
  let label: String
  @Binding var text: String
  var minHeight: CGFloat = 220

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(label)
        .dashTextStyle(.footnoteSemibold)
        .foregroundStyle(DashTheme.subtle)
      TextEditor(text: $text)
        .dashTextStyle(.code)
        .foregroundStyle(DashTheme.text)
        .scrollContentBackground(.hidden)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .frame(minHeight: minHeight)
        .padding(12)
        .background(DashTheme.recessed)
        .clipShape(RoundedRectangle(cornerRadius: DashTheme.Radius.medium, style: .continuous))
    }
  }
}

/// Circular close control shared by tray headers and the R2 image viewer.
struct DashCloseButton: View {
  var accessibilityLabel = "Close"
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      SolarIcon(asset: SolarAsset.close, size: 22, color: DashTheme.Sheet.closeIcon)
        .frame(width: 32, height: 32)
        .background(DashTheme.recessed, in: Circle())
        .dashCompactHitTarget()
    }
    .buttonStyle(DashPressButtonStyle())
    .accessibilityLabel(accessibilityLabel)
  }
}

// MARK: - Staggered reveal

private struct DashSplashLiftedKey: EnvironmentKey {
  static let defaultValue = true
}

private struct DashSectionsRevealedKey: EnvironmentKey {
  static let defaultValue = true
}

private struct DashLoginIconCloakedKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  /// False while the launch splash still covers the window. Entrance reveals
  /// wait on it so they play in view, not underneath the splash.
  var dashSplashLifted: Bool {
    get { self[DashSplashLiftedKey.self] }
    set { self[DashSplashLiftedKey.self] = newValue }
  }

  /// Shared entrance phase for the semantic sections on a catalog screen.
  fileprivate var dashSectionsRevealed: Bool {
    get { self[DashSectionsRevealedKey.self] }
    set { self[DashSectionsRevealedKey.self] = newValue }
  }

  /// True while the splash overlay's morphing lockup stands in for the
  /// welcome brand lockup; onboarding keeps its own copy invisible (but laid
  /// out) so the hand-off is a seamless same-frame swap.
  var dashLoginIconCloaked: Bool {
    get { self[DashLoginIconCloakedKey.self] }
    set { self[DashLoginIconCloakedKey.self] = newValue }
  }
}

/// Bubbles the welcome lockup icon's bounds up to the splash overlay, which
/// glides and scales the launch logo onto it on first launch.
struct DashLoginIconAnchorKey: PreferenceKey {
  static var defaultValue: Anchor<CGRect>? { nil }
  static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
    value = nextValue() ?? value
  }
}

/// Entrance reveal (after Transitions.dev "Texts reveal"): rises 12pt out of
/// a 3pt blur on a 0.5s deceleration curve. Elements stagger by 40ms and
/// semantic sections by 100ms so siblings land top to bottom. Works on any
/// view, not just text. Exits stay a plain short fade — never replay the
/// stagger in reverse.
private enum DashRevealCadence {
  static let element = 0.04
  static let section = 0.1
}

private struct DashRevealModifier: ViewModifier {
  let index: Int
  let shown: Bool
  let stagger: Double
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    let visible = shown || reduceMotion
    content
      .opacity(visible ? 1 : 0)
      .offset(y: visible ? 0 : 12)
      .blur(radius: visible ? 0 : 3)
      .animation(
        reduceMotion
          ? nil
          : .timingCurve(0.22, 1, 0.36, 1, duration: 0.5)
            .delay(Double(max(index, 0)) * stagger),
        value: shown
      )
  }
}

extension View {
  /// Staggered entrance; drive `shown` from state flipped on appear (waiting
  /// for `dashSplashLifted` when the view can sit under the launch splash).
  func dashReveal(_ index: Int = 0, shown: Bool) -> some View {
    modifier(
      DashRevealModifier(index: index, shown: shown, stagger: DashRevealCadence.element)
    )
  }

  /// Self-driving entrance for loaded content: plays once when the view first
  /// appears with `ready` true (and the splash lifted), then latches — pull
  /// refreshes and scroll-backs never replay it. Applied to a `@ViewBuilder`
  /// product it distributes per element, so lazy stacks stay lazy.
  func dashContentReveal(_ index: Int = 0, ready: Bool = true) -> some View {
    modifier(
      DashContentRevealModifier(
        index: index, ready: ready, stagger: DashRevealCadence.element)
    )
  }

  /// Marks a semantic screen section for the shared top-to-bottom entrance.
  func dashSectionReveal(_ index: Int = 0) -> some View {
    modifier(DashSectionRevealModifier(index: index))
  }

  /// Coordinates all `dashSectionReveal` descendants from one screen-level
  /// phase. Lazy sections created after the entrance are immediately visible.
  func dashSectionEntrance() -> some View {
    modifier(DashSectionEntranceModifier())
  }

  /// Self-driving reveal for sections inserted after async content loads.
  func dashSectionContentReveal(_ index: Int = 0, ready: Bool = true) -> some View {
    modifier(
      DashContentRevealModifier(
        index: index, ready: ready, stagger: DashRevealCadence.section)
    )
  }
}

private struct DashContentRevealModifier: ViewModifier {
  let index: Int
  let ready: Bool
  let stagger: Double
  @Environment(\.dashSplashLifted) private var splashLifted
  @State private var revealed = false

  @ViewBuilder
  func body(content: Content) -> some View {
    content
      .modifier(DashRevealModifier(index: index, shown: revealed, stagger: stagger))
      .onAppear { maybeReveal() }
      .onChange(of: ready) { _, _ in maybeReveal() }
      .onChange(of: splashLifted) { _, _ in maybeReveal() }
  }

  private func maybeReveal() {
    if ready && splashLifted { revealed = true }
  }
}

private struct DashSectionRevealModifier: ViewModifier {
  let index: Int
  @Environment(\.dashSectionsRevealed) private var revealed

  func body(content: Content) -> some View {
    content.modifier(
      DashRevealModifier(
        index: index, shown: revealed, stagger: DashRevealCadence.section)
    )
  }
}

private struct DashSectionEntranceModifier: ViewModifier {
  @Environment(\.dashSplashLifted) private var splashLifted
  @State private var revealed = false

  func body(content: Content) -> some View {
    content
      .environment(\.dashSectionsRevealed, revealed)
      .onAppear { maybeReveal() }
      .onChange(of: splashLifted) { _, _ in maybeReveal() }
  }

  private func maybeReveal() {
    if splashLifted { revealed = true }
  }
}

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

  private var morphAnimation: Animation {
    reduceMotion ? DashTheme.Motion.reduced : DashTheme.Motion.morph
  }

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
          withAnimation(morphAnimation) { pending = action }
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
          withAnimation(morphAnimation) { pending = nil }
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
                withAnimation(morphAnimation) { errorMessage = error.dashActionableMessage }
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
