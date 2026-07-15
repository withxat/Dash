import Combine
import SwiftUI

// MARK: - Sheet presentation

enum DashSheetSizing: Equatable {
  /// A floating card whose height hugs its content (Profile, forms).
  case content
  /// Presents expanded to a full-height sheet; the grab bar drags it down to
  /// a floating detent styled like `.content` (Edit shortcuts).
  case large
}

struct TrayPresentedPreferenceKey: PreferenceKey {
  static let defaultValue = false
  static func reduce(value: inout Bool, nextValue: () -> Bool) {
    value = value || nextValue()
  }
}

private struct DashTrayDismissKey: EnvironmentKey {
  nonisolated(unsafe) static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
  var dashTrayDismiss: () -> Void {
    get { self[DashTrayDismissKey.self] }
    set { self[DashTrayDismissKey.self] = newValue }
  }
}

extension View {
  func dashTray<Content: View>(
    isPresented: Binding<Bool>,
    title: String,
    sizing: DashSheetSizing = .content,
    @ViewBuilder content: @escaping () -> Content
  ) -> some View {
    modifier(
      DashTrayModifier(
        isPresented: isPresented, title: title, sizing: sizing, trayContent: content))
  }

  func dashTray<Item: Identifiable & Equatable, Content: View>(
    item: Binding<Item?>,
    title: @escaping (Item) -> String,
    sizing: DashSheetSizing = .content,
    @ViewBuilder content: @escaping (Item) -> Content
  ) -> some View {
    modifier(
      DashTrayItemModifier(item: item, title: title, sizing: sizing, trayContent: content)
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

  /// Expandable tray: projection chooses a detent, but dismissal also requires
  /// real downward travel. From the expanded detent the finger must cross the
  /// floating detent before it can dismiss, so one small flick advances at most
  /// one resting state.
  static func expandable(
    baseTop: CGFloat,
    translation: CGFloat? = nil,
    predictedEndTranslation: CGFloat,
    expandedTop: CGFloat,
    floatingTop: CGFloat,
    dismissPastFloatingFraction: CGFloat = 0.4,
    minimumDismissPull: CGFloat? = nil
  ) -> TrayDragOutcome {
    let detentSpan = floatingTop - expandedTop
    let actualTranslation = translation ?? predictedEndTranslation
    let predictedTop = baseTop + predictedEndTranslation
    let dismissThreshold = floatingTop + detentSpan * dismissPastFloatingFraction
    let intentDistance = minimumDismissPull ?? min(max(detentSpan * 0.18, 56), 72)
    let distanceToFloating = max(0, floatingTop - baseTop)
    let crossedDismissIntent = actualTranslation > distanceToFloating + intentDistance
    if crossedDismissIntent && predictedTop > dismissThreshold {
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

/// Tray motion is intentionally split by job: presentation settles without a
/// bounce, while a finger-driven release gets a little elasticity. Keeping the
/// two separate avoids making programmatic opens feel toy-like.
private enum DashTrayMotion {
  static let present = Animation.spring(response: 0.42, dampingFraction: 0.94, blendDuration: 0.12)
  static let release = Animation.spring(response: 0.34, dampingFraction: 0.82, blendDuration: 0.14)
  static let dismiss = Animation.spring(response: 0.34, dampingFraction: 0.96, blendDuration: 0.08)
}

/// Shared header (title + close, optional grab bar and trailing action) for both
/// tray styles.
private struct DashSheetHeader: View {
  let title: String
  var showsGrabBar = false
  var trailingAction: DashSheetHeaderAction? = nil
  let dismiss: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @AccessibilityFocusState private var titleFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      if showsGrabBar { DashSheetGrabBar() }

      HStack(alignment: .center, spacing: 8) {
        Text(title)
          .dashTextStyle(.trayTitle)
          .foregroundStyle(DashTheme.strong)
          .lineLimit(1)
          .minimumScaleFactor(0.85)
          .contentTransition(reduceMotion ? .identity : .opacity)
          .animation(
            reduceMotion ? DashTheme.Motion.reduced : DashTheme.Motion.morph, value: title
          )
          .id(title)
          .accessibilityAddTraits(.isHeader)
          .accessibilityFocused($titleFocused)
        Spacer(minLength: 12)
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
      .padding(.horizontal, DashTheme.Sheet.content)
      .padding(.top, showsGrabBar ? 12 : DashTheme.Sheet.headerTop)
      .padding(.bottom, DashTheme.Sheet.headerBottom)

      Rectangle()
        .fill(DashTheme.Sheet.headerBorder)
        .frame(height: 1)
        .padding(.horizontal, DashTheme.Sheet.content)
    }
    .onAppear {
      titleFocused = true
      UIAccessibility.post(notification: .screenChanged, argument: title)
    }
    .onChange(of: title) { _, newTitle in
      titleFocused = true
      UIAccessibility.post(notification: .screenChanged, argument: newTitle)
    }
  }
}

/// `.content` trays: a full-screen transparent cover with our own dim and a
/// bottom-pinned card. The card springs its own height (DashSheetCard) so morphs
/// resize smoothly in both directions — there's no native detent to clip or snap.
/// The dim fades and the card slides/drags independently of the cover, which is
/// presented without its own transition (see DashTrayModifier).
private struct DashCustomSheet<Content: View>: View {
  let title: String
  /// Removes the cover once the exit animation has finished.
  let onDismiss: () -> Void
  @ViewBuilder var content: () -> Content
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @State private var shown = false
  @State private var drag: CGFloat = 0
  @State private var cardHeight: CGFloat = 0
  @State private var keyboardHeight: CGFloat = 0
  @State private var headerAction: DashSheetHeaderAction?
  @State private var contentTitle: String?

  private var resolvedTitle: String { contentTitle ?? title }

  var body: some View {
    ZStack(alignment: .bottom) {
      Color.black.opacity(shown ? DashTheme.Sheet.scrimOpacity : 0)
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
          // Drag-to-dismiss lives on the header only, so the scrollable body
          // keeps its own vertical scroll.
          DashSheetHeader(title: resolvedTitle, trailingAction: headerAction, dismiss: close)
            .contentShape(Rectangle())
            .gesture(dragGesture)
        } content: {
          content()
        }
        .frame(
          maxWidth: horizontalSizeClass == .regular
            ? DashTheme.Layout.trayMaxWidth : .infinity
        )
        .padding(.horizontal, DashTheme.Sheet.floatingMargin)
        .padding(.bottom, bottomLift(proxy))
        // Always laid out so it moves as one piece; bottom-pinned. The reveal
        // uses a bounded fraction of the card height while opacity, blur, and
        // scale carry the rest, so tall trays never shoot in from far away.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .offset(
          y: reduceMotion ? drag : (shown ? drag : max(revealOffset, drag + 48))
        )
        .scaleEffect(reduceMotion || shown ? 1 : 0.985, anchor: .bottom)
        .opacity(shown ? 1 : 0)
        .blur(radius: reduceMotion ? 0 : (shown ? 0 : 4))
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
    .onAppear {
      withAnimation(reduceMotion ? DashTheme.Motion.reduced : DashTrayMotion.present) {
        shown = true
      }
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
  /// typing; otherwise the home-indicator inset already reads as the gap, so
  /// an explicit margin is added only on square-bottomed devices.
  private func bottomLift(_ proxy: GeometryProxy) -> CGFloat {
    let keyboard = keyboardInset(proxy)
    if keyboard > 0 { return keyboard + DashTheme.Sheet.floatingMargin }
    return proxy.safeAreaInsets.bottom > 0 ? 0 : DashTheme.Sheet.floatingMargin
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

/// `.large` trays: a custom two-detent sheet. It presents expanded — full
/// width, edge-to-edge at the bottom, native-sheet top corners — and the grab
/// bar or header drags it down to a floating detent styled exactly like a
/// `.content` tray (screen-edge margins, concentric all-corner radius).
/// Margins and radii interpolate continuously with the drag; past the floating
/// detent it dismisses. Native sheet behavior, our chrome.
private struct DashExpandableSheet<Content: View>: View {
  let title: String
  /// Removes the cover once the exit animation has finished.
  let onDismiss: () -> Void
  @ViewBuilder var content: () -> Content
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
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
      DashSheetHeader(title: resolvedTitle, showsGrabBar: true, dismiss: close)
        .contentShape(Rectangle())
        .gesture(detentGesture(metrics))
      // No top padding here: the gap below the header border belongs to the
      // scrollable content, so it scrolls away instead of sitting as a fixed
      // blank strip.
      content()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .safeAreaPadding(.bottom, metrics.contentBottomInset)
    }
    .frame(height: metrics.height)
    .frame(
      maxWidth: horizontalSizeClass == .regular ? DashTheme.Layout.trayMaxWidth : .infinity
    )
    .background { shape.fill(DashTheme.canvas) }
    .clipShape(shape)
    .padding(.horizontal, metrics.horizontalMargin)
    .padding(.bottom, metrics.bottomMargin)
  }

  /// Detent geometry for the current drag, interpolating chrome between the
  /// expanded sheet and the floating card.
  private func metrics(in proxy: GeometryProxy) -> Metrics {
    let safeBottom = proxy.safeAreaInsets.bottom
    let expandedTop = DashTheme.Sheet.expandedTopGap
    let floatingBottomMargin = max(safeBottom, DashTheme.Sheet.floatingMargin)
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
        let baseTop = expanded ? metrics.expandedTop : metrics.floatingTop
        switch TrayDragDecision.expandable(
          baseTop: baseTop,
          translation: value.translation.height,
          predictedEndTranslation: value.predictedEndTranslation.height,
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

      ScrollView {
        // The body owns its vertical margins so every tray breathes the same:
        // content pieces must not add their own bottom padding.
        content()
          .frame(maxWidth: .infinity, alignment: .top)
          .padding(.top, DashTheme.Sheet.bodyVertical)
          .padding(.bottom, DashTheme.Sheet.bodyBottom)
          .background {
            GeometryReader { proxy in
              Color.clear.preference(key: DashSheetBodyIdealKey.self, value: proxy.size.height)
            }
          }
      }
      .scrollBounceBehavior(.basedOnSize)
      .scrollDismissesKeyboard(.interactively)
      .frame(height: bodyDisplay > 0 ? bodyDisplay : nil)
    }
    .frame(maxWidth: .infinity)
    // A floating card: every corner rounded, concentric with the display, and
    // nothing extends past the card — the gaps around it are the design.
    .background {
      RoundedRectangle(cornerRadius: DashDisplayChrome.floatingRadius, style: .continuous)
        .fill(DashTheme.canvas)
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

private struct DashTrayModifier<TrayContent: View>: ViewModifier {
  @Binding var isPresented: Bool
  let title: String
  var sizing: DashSheetSizing = .content
  @ViewBuilder var trayContent: () -> TrayContent
  @State private var covered = false

  @ViewBuilder
  func body(content: Content) -> some View {
    content
      .preference(key: TrayPresentedPreferenceKey.self, value: isPresented)
      .onChange(of: isPresented, initial: true) { _, present in
        dashPresentWithoutAnimation { covered = present }
      }
      .fullScreenCover(isPresented: $covered) {
        if sizing == .content {
          DashCustomSheet(
            title: title, onDismiss: { isPresented = false }, content: trayContent)
        } else {
          DashExpandableSheet(
            title: title, onDismiss: { isPresented = false }, content: trayContent)
        }
      }
  }
}

private struct DashTrayItemModifier<Item: Identifiable & Equatable, TrayContent: View>: ViewModifier
{
  @Binding var item: Item?
  let title: (Item) -> String
  var sizing: DashSheetSizing = .content
  @ViewBuilder var trayContent: (Item) -> TrayContent
  @State private var coveredItem: Item?

  private var isPresented: Bool { item != nil }

  @ViewBuilder
  func body(content: Content) -> some View {
    content
      .preference(key: TrayPresentedPreferenceKey.self, value: isPresented)
      .onChange(of: item, initial: true) { _, newItem in
        dashPresentWithoutAnimation { coveredItem = newItem }
      }
      .fullScreenCover(item: $coveredItem) { value in
        if sizing == .content {
          DashCustomSheet(
            title: title(value), onDismiss: { item = nil }, content: { trayContent(value) })
        } else {
          DashExpandableSheet(
            title: title(value), onDismiss: { item = nil }, content: { trayContent(value) })
        }
      }
  }
}

// MARK: - Root chrome

private struct ShowsProfileKey: EnvironmentKey {
  static let defaultValue: Binding<Bool> = .constant(false)
}

private struct ShowsEditShortcutsKey: EnvironmentKey {
  static let defaultValue: Binding<Bool> = .constant(false)
}

extension EnvironmentValues {
  var showsProfile: Binding<Bool> {
    get { self[ShowsProfileKey.self] }
    set { self[ShowsProfileKey.self] = newValue }
  }

  var showsEditShortcuts: Binding<Bool> {
    get { self[ShowsEditShortcutsKey.self] }
    set { self[ShowsEditShortcutsKey.self] = newValue }
  }
}

struct CatalogToolbar: ToolbarContent {
  @Environment(AppModel.self) private var model
  @Environment(\.showsProfile) private var showsProfile
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some ToolbarContent {
    leadingAvatarItem
  }

  @ToolbarContentBuilder
  private var leadingAvatarItem: some ToolbarContent {
    if #available(iOS 26.0, *) {
      ToolbarItem(placement: .topBarLeading) { profileButton }
        .sharedBackgroundVisibility(.hidden)
    } else {
      ToolbarItem(placement: .topBarLeading) { profileButton }
    }
  }

  private var accountLabel: String {
    model.activeAccount?.name ?? model.profileTitle
  }

  private var profileButton: some View {
    Button {
      showsProfile.wrappedValue = true
    } label: {
      HStack(spacing: 8) {
        HeaderProfileAvatar(email: model.user?.email ?? "")
        if !dynamicTypeSize.isAccessibilitySize {
          Text(accountLabel)
            .dashTextStyle(.supportingMedium)
            .foregroundStyle(DashTheme.subtle)
            .lineLimit(1)
        }
      }
    }
    .buttonStyle(DashPressButtonStyle())
    .accessibilityLabel("Profile, \(accountLabel)")
  }
}

extension View {
  func dashCatalogScreen(_ title: String) -> some View {
    navigationTitle(title)
      .navigationBarTitleDisplayMode(.large)
      // Breathing room between the large title and the first group — one
      // section gap, so entering a screen reads like scrolling between groups.
      .contentMargins(.top, DashTheme.Spacing.section, for: .scrollContent)
      .toolbar {
        CatalogToolbar()
      }
      .background(DashTheme.canvas)
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
      confirmingActionTitle: "Confirm",
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
/// Cancel that fades in while confirming, and one persistent `DashActionButton`
/// that morphs in place (e.g. Save → Confirm). A header trash button flips
/// `confirming`. Reused by editor and detail trays so the whole app shares one
/// "a tray has one action button, or none" interaction.
struct DashConfirmMorph<Content: View>: View {
  @Binding var confirming: Bool
  var message: String?
  var isBusy: Bool
  /// Idle primary action title. `nil` hides the footer button until confirming
  /// (detail trays that only offer header delete).
  var actionTitle: String?
  var confirmingActionTitle: String = "Confirm"
  var actionRole: ButtonRole? = nil
  var confirmingActionRole: ButtonRole? = .destructive
  var actionEnabled: Bool = true
  var errorMessage: String? = nil
  var action: () -> Void
  var headerDelete = false
  /// When false, the caller owns horizontal insets (inline page morphs).
  var appliesContentPadding = true
  @ViewBuilder var content: () -> Content
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var morphAnimation: Animation {
    reduceMotion ? DashTheme.Motion.reduced : DashTheme.Motion.morph
  }

  private var resolvedActionTitle: String? {
    confirming ? confirmingActionTitle : actionTitle
  }

  private var resolvedActionRole: ButtonRole? {
    confirming ? confirmingActionRole : actionRole
  }

  var body: some View {
    VStack(spacing: 16) {
      ZStack {
        if confirming, let message {
          VStack(spacing: 12) {
            Text(message)
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
          .transition(reduceMotion ? .opacity : .dashMorph)
        } else {
          content()
            .transition(reduceMotion ? .opacity : .dashMorph)
        }
      }

      if confirming {
        Button {
          withAnimation(morphAnimation) { confirming = false }
        } label: {
          Text("Cancel")
            .dashTextStyle(.buttonMedium)
            .foregroundStyle(DashTheme.subtle)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(DashPressButtonStyle())
        .transition(reduceMotion ? .opacity : .dashMorph)
      }

      if let resolvedActionTitle {
        DashActionButton(
          title: resolvedActionTitle, role: resolvedActionRole, isLoading: isBusy, action: action
        )
        .disabled(!actionEnabled)
        .opacity(actionEnabled ? 1 : 0.45)
      }
    }
    .padding(.horizontal, appliesContentPadding ? DashTheme.Sheet.content : 0)
    .dashTrayHeaderAction(
      headerDelete && !confirming
        ? DashSheetHeaderAction(
          id: "delete", icon: SolarAsset.trash, accessibilityLabel: "Delete"
        ) {
          withAnimation(morphAnimation) { confirming = true }
        }
        : nil
    )
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
  @FocusState private var isFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(label)
        .dashTextStyle(.footnoteSemibold)
        .foregroundStyle(DashTheme.subtle)
      TextField(label, text: $text)
        .dashTextStyle(.bodyMedium)
        .foregroundStyle(DashTheme.text)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .keyboardType(keyboard)
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

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(label)
        .dashTextStyle(.footnoteSemibold)
        .foregroundStyle(DashTheme.subtle)
      Menu {
        Picker(label, selection: $selection) {
          ForEach(options, id: \.self) { Text($0) }
        }
      } label: {
        HStack(spacing: 8) {
          Text(selection)
            .dashTextStyle(.bodyMedium)
            .foregroundStyle(DashTheme.text)
          Spacer(minLength: 0)
          SolarIcon(asset: SolarAsset.chevronRight, size: 14, color: DashTheme.placeholder)
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

/// Circular close control shared by tray headers and the catalog search bar.
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

  /// True while the splash overlay's gliding logo stands in for the login
  /// icon; the login screen keeps its own icon invisible (but laid out) so
  /// the hand-off is a seamless same-frame swap.
  var dashLoginIconCloaked: Bool {
    get { self[DashLoginIconCloakedKey.self] }
    set { self[DashLoginIconCloakedKey.self] = newValue }
  }
}

/// Bubbles the login icon's bounds up to the splash overlay, which glides the
/// launch logo onto it on first sign-in.
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
        }
        Text(title)
          .dashTextStyle(.button)
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
    Text(title)
      .dashTextStyle(.buttonBold)
      .foregroundStyle(DashTheme.strong)
      .frame(maxWidth: .infinity, minHeight: 52)
      .background(DashTheme.recessed, in: DashTheme.pillShape)
      .overlay {
        DashTheme.pillShape.stroke(DashTheme.line, lineWidth: 0.5)
      }
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
  /// matchedGeometryEffect hero.
  @MainActor static var dashMorph: AnyTransition {
    if UIAccessibility.isReduceMotionEnabled { return .opacity }
    return .opacity.combined(
      with: .modifier(
        active: DashBlurModifier(radius: 3),
        identity: DashBlurModifier(radius: 0)))
  }

}

/// A single high-risk action presented inside a tray. Tapping its row morphs —
/// via matchedGeometryEffect — into an inline confirmation step before `perform`
/// runs. This is the canonical tray danger pattern; reuse it everywhere a
/// destructive action needs a second tap (purge, delete, sign out).
struct DashDangerAction: Identifiable {
  /// Stable across re-renders — it drives the matchedGeometryEffect morph, so it
  /// must NOT be a fresh UUID per render. Defaults to `title`.
  let id: String
  let title: String
  let icon: String
  let message: String
  /// When set, Confirm stays disabled until the user types this exact string
  /// — for deletes whose blast radius deserves a name echo (zone, bucket,
  /// database).
  let confirmationText: String?
  /// A thrown error keeps the confirmation open and surfaces the message
  /// inline; only a clean return dismisses the tray.
  let perform: () async throws -> Void

  init(
    id: String? = nil,
    title: String,
    icon: String = SolarAsset.trash,
    message: String,
    confirmationText: String? = nil,
    perform: @escaping () async throws -> Void
  ) {
    self.id = id ?? title
    self.title = title
    self.icon = icon
    self.message = message
    self.confirmationText = confirmationText
    self.perform = perform
  }
}

/// Tray content that lists destructive actions as menu rows and morphs a tapped
/// one — via matchedGeometryEffect — into a confirm step (message, a plain
/// Cancel, and a red Confirm that the row grows into). Self-insets for standalone
/// trays; pass `horizontalInset: 0` when embedding under content that already
/// insets (e.g. `DashDetailTray`).
struct DashConfirmableActions: View {
  let actions: [DashDangerAction]
  var horizontalInset: CGFloat = DashTheme.Sheet.content
  @Namespace private var morph
  @State private var pending: DashDangerAction?
  @State private var working = false
  @State private var errorMessage: String?
  @State private var typedConfirmation = ""
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
    .padding(.horizontal, horizontalInset)
  }

  private var menu: some View {
    VStack(spacing: 10) {
      ForEach(actions) { action in
        Button {
          errorMessage = nil
          typedConfirmation = ""
          withAnimation(morphAnimation) { pending = action }
        } label: {
          dangerRow(action)
        }
        .buttonStyle(DashPressButtonStyle())
      }
    }
  }

  // List-item styled after Edit shortcuts rows, with an outline icon.
  private func dangerRow(_ action: DashDangerAction) -> some View {
    HStack(spacing: 12) {
      SolarIcon(asset: action.icon, size: 22, color: DashTheme.danger)
      Text(action.title)
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
      Text(action.message)
        .dashTextStyle(.supporting)
        .foregroundStyle(DashTheme.subtle)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 4)
        .padding(.top, 4)

      if let expected = action.confirmationText {
        DashFormField(label: "Type \(expected) to confirm", text: $typedConfirmation)
      }

      if let errorMessage {
        DashNotice(kind: .error, message: errorMessage)
      }

      VStack(spacing: 4) {
        Button {
          errorMessage = nil
          typedConfirmation = ""
          withAnimation(morphAnimation) { pending = nil }
        } label: {
          Text("Cancel")
            .dashTextStyle(.buttonMedium)
            .foregroundStyle(DashTheme.subtle)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(DashPressButtonStyle())
        .disabled(working)

        Button {
          Task {
            working = true
            errorMessage = nil
            do {
              try await action.perform()
              dismiss()
            } catch {
              withAnimation(morphAnimation) { errorMessage = error.dashActionableMessage }
              UINotificationFeedbackGenerator().notificationOccurred(.error)
              working = false
            }
          }
        } label: {
          Text("Confirm")
            .dashTextStyle(.button)
            .foregroundStyle(DashTheme.inverse)
            .frame(maxWidth: .infinity, minHeight: 52)
            .overlay(alignment: .trailing) {
              if working {
                DashLoadingRing()
                  .padding(.trailing, 18)
              }
            }
            .background {
              confirmBackground(action)
            }
            .opacity(confirmationSatisfied(action) ? 1 : 0.45)
        }
        .buttonStyle(DashPressButtonStyle())
        .disabled(working || !confirmationSatisfied(action))
      }
    }
  }

  private func confirmationSatisfied(_ action: DashDangerAction) -> Bool {
    guard let expected = action.confirmationText else { return true }
    return typedConfirmation.trimmingCharacters(in: .whitespacesAndNewlines) == expected
  }

  @ViewBuilder
  private func confirmBackground(_ action: DashDangerAction) -> some View {
    if reduceMotion {
      DashTheme.pillShape.fill(DashTheme.danger)
    } else {
      DashTheme.pillShape
        .fill(DashTheme.danger)
        .matchedGeometryEffect(id: action.id, in: morph)
    }
  }
}

/// The single primary action button a `.content` tray should have — one, or
/// none. It morphs in place between a neutral state (e.g. Save) and a
/// destructive one (e.g. Confirm) by animating its own fill and label rather than
/// swapping two buttons, so it never shifts position.
struct DashActionButton: View {
  let title: String
  var role: ButtonRole? = nil
  var isLoading = false
  let action: () -> Void

  private var fill: Color { role == .destructive ? DashTheme.danger : DashTheme.strong }

  var body: some View {
    Button(action: action) {
      Text(title)
        .dashTextStyle(.button)
        .contentTransition(.opacity)
        .foregroundStyle(DashTheme.inverse)
        .frame(maxWidth: .infinity, minHeight: 52)
        .overlay(alignment: .trailing) {
          if isLoading {
            DashLoadingRing()
              .padding(.trailing, 18)
          }
        }
        .background(fill, in: DashTheme.pillShape)
    }
    .buttonStyle(DashPressButtonStyle())
    .disabled(isLoading)
  }
}

/// A secondary pill for tray accessories — reversible writes like enable/disable
/// or lock/unlock. High-impact toggles pair this with `GenericRowUpdate.confirmMessage`
/// so the first tap asks for confirmation instead of mutating immediately.
struct DashTrayPillButton: View {
  let title: String
  var isLoading = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title)
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
        .overlay {
          DashTheme.pillShape.stroke(DashTheme.line, lineWidth: 0.5)
        }
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
