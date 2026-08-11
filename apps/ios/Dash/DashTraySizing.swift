import SwiftUI

/// Pure lift arithmetic for the floating tray card. Kept free of UIKit so the
/// "window safe inset ignored → card stuck at floatingMargin" regression
/// stays unit-testable.
enum DashTrayBottomLiftRules {
  /// Padding from the full-bleed container's bottom edge to the card.
  ///
  /// - Keyboard: `keyboardCovered` is already measured from the window bottom,
  ///   and the reader ignores the home-indicator inset, so do not subtract safe
  ///   again or the card under-lifts above the keyboard.
  /// - Resting: `safeBottom` must be the *window* inset. Feeding the ignoring
  ///   GeometryReader's 0 here collapses to `floatingMargin` and parks the
  ///   card inside the home-indicator region forever. A small `tuck` then sits
  ///   the card slightly into that region without negative padding.
  static func padding(
    safeBottom: CGFloat,
    keyboardCovered: CGFloat,
    floatingMargin: CGFloat = DashTheme.Sheet.floatingMargin,
    tuck: CGFloat = DashTheme.Sheet.floatingBottomTuck
  ) -> CGFloat {
    if keyboardCovered > 0 { return keyboardCovered + floatingMargin }
    if safeBottom > 0 { return max(floatingMargin, safeBottom - tuck) }
    return floatingMargin
  }
}

/// Pure geometry for the standard Tray shell's off-screen travel. The hidden
/// top edge rests exactly at the screen bottom: the full card height clears its
/// resting position, then the bottom lift clears the gap below the card.
enum DashTrayRevealRules {
  static func travel(cardHeight: CGFloat, bottomLift: CGFloat) -> CGFloat? {
    guard cardHeight.isFinite, cardHeight > 0,
      bottomLift.isFinite, bottomLift >= 0
    else {
      return nil
    }
    return cardHeight + bottomLift
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

/// GeometryReader → preference → `@State` → frame is how trays size themselves.
/// Sub-point measure chatter must not rewrite that state, or the loop re-enters
/// AttributeGraph (seen when an in-tray list animates a constant-count reorder).
enum DashTrayMeasuredHeight {
  static let changeThreshold: CGFloat = 0.5

  static func shouldCommit(_ current: CGFloat, _ next: CGFloat) -> Bool {
    next.isFinite && next >= 0 && abs(next - current) > changeThreshold
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
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) {
          guard DashTrayMeasuredHeight.shouldCommit(actionHeight, $0) else { return }
          actionHeight = $0
        }
    }
    .onPreferenceChange(DashTrayBoundaryBodyIdealKey.self) { ideal in
      guard DashTrayMeasuredHeight.shouldCommit(bodyIdeal, ideal) else { return }
      bodyIdeal = ideal
    }
  }
}
