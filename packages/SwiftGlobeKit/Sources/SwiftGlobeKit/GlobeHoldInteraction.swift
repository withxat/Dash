import Foundation

#if os(iOS)
  import UIKit
#endif

/// Tuning for the hold-to-engage gesture that guards globe rotation.
///
/// The globe sits inside a scrolling page that also owns a vertical scroll, a
/// horizontal pager, and a leading-edge back swipe. Spinning on the first touch
/// fights all three, so rotation starts only after a deliberate hold — and once
/// it has, the globe keeps the finger until it lifts.
/// `SwiftDitherKit.DitherHoldInteraction` is the same contract for charts; the
/// two are meant to stay in step.
public enum GlobeHoldInteraction {
  /// How long the finger must hold still before the globe claims it.
  public static let holdDuration: TimeInterval = 0.35

  /// Finger travel that cancels the hold. A scroll or a swipe travels further
  /// than this well inside `holdDuration`, so neither ever arms the globe.
  public static let holdSlop: CGFloat = 10

  #if os(iOS)
    /// Fired once, at the instant a hold engages — the cue that the globe, not
    /// the page, now owns the finger. Replace it to route the feedback through
    /// a host app's haptics policy, or set it to `nil` for silence.
    @MainActor public static var onEngage: (@MainActor () -> Void)? = {
      UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }
  #endif
}

/// Pure rule behind the ancestor claim: which enclosing recognizers an engaged
/// globe switches off. Only continuous directional recognizers can steal the
/// drag — scroll pans, page pagers, and the navigation controller's interactive
/// pop are all pans — so taps and presses elsewhere are left alone.
///
/// Free of UIKit types so it can be exercised on any host.
enum GlobeHoldClaimRules {
  static func claims(isDirectional: Bool, isEnabled: Bool, isOwn: Bool) -> Bool {
    isDirectional && isEnabled && !isOwn
  }
}
