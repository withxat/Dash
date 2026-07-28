import Foundation

#if os(iOS)
  import SwiftUI
  import UIKit
#endif

/// Tuning for the hold-to-engage gesture every touch-driven chart shares.
///
/// A chart lives inside a scrolling page, and on a phone that page also owns a
/// vertical scroll, a horizontal pager, and a leading-edge back swipe. Reading
/// the finger the moment it lands fights all three, so a chart takes the touch
/// only after a deliberate hold — and once it has, it keeps it until the finger
/// lifts. `SwiftGlobeKit.GlobeHoldInteraction` is the same contract for the
/// globe; the two are meant to stay in step.
public enum DitherHoldInteraction {
  /// How long the finger must hold still before a chart claims it.
  public static let holdDuration: TimeInterval = 0.35

  /// Finger travel that cancels the hold. A scroll or a swipe travels further
  /// than this well inside `holdDuration`, so neither ever arms a chart.
  public static let holdSlop: CGFloat = 10

  #if os(iOS)
    /// Fired once, at the instant a hold engages — the cue that the chart, not
    /// the page, now owns the finger. Replace it to route the feedback through
    /// a host app's haptics policy, or set it to `nil` for silence.
    @MainActor public static var onEngage: (@MainActor () -> Void)? = {
      UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }
  #endif
}

/// Pure rule behind the ancestor claim: which enclosing recognizers an engaged
/// chart switches off. Only continuous directional recognizers can steal a
/// scrub — scroll pans, page pagers, and the navigation controller's
/// interactive pop are all pans — so taps and presses elsewhere are left alone.
///
/// Free of UIKit types so it can be exercised on any host.
enum DitherHoldClaimRules {
  static func claims(isDirectional: Bool, isEnabled: Bool, isOwn: Bool) -> Bool {
    isDirectional && isEnabled && !isOwn
  }
}

#if os(iOS)
  /// Transparent catcher over a plot: a hold engages scrubbing, a plain tap
  /// still selects. Before the hold engages the enclosing scroll views read the
  /// finger exactly as they always did; after it engages they cannot read it at
  /// all until the finger lifts and a new touch begins.
  struct DitherHoldScrubCatcher: UIViewRepresentable {
    var onScrub: (CGPoint?) -> Void
    var onTap: ((CGPoint) -> Void)?

    func makeUIView(context: Context) -> DitherHoldScrubView {
      let view = DitherHoldScrubView()
      view.onScrub = onScrub
      view.onTap = onTap
      return view
    }

    func updateUIView(_ uiView: DitherHoldScrubView, context: Context) {
      uiView.onScrub = onScrub
      uiView.onTap = onTap
    }

    static func dismantleUIView(_ uiView: DitherHoldScrubView, coordinator: ()) {
      uiView.releaseClaim()
    }
  }

  final class DitherHoldScrubView: UIView, UIGestureRecognizerDelegate {
    var onScrub: ((CGPoint?) -> Void)?
    var onTap: ((CGPoint) -> Void)?

    private let hold = UILongPressGestureRecognizer()
    private let tap = UITapGestureRecognizer()
    /// Ancestor recognizers switched off for the duration of one hold. Held
    /// strongly so they can be restored even if the chart is torn down first.
    private var claimed: [UIGestureRecognizer] = []

    override init(frame: CGRect) {
      super.init(frame: frame)
      backgroundColor = .clear
      isMultipleTouchEnabled = false

      hold.minimumPressDuration = DitherHoldInteraction.holdDuration
      hold.allowableMovement = DitherHoldInteraction.holdSlop
      hold.cancelsTouchesInView = false
      hold.delaysTouchesBegan = false
      hold.delaysTouchesEnded = false
      hold.delegate = self
      hold.addTarget(self, action: #selector(handleHold(_:)))
      addGestureRecognizer(hold)

      tap.numberOfTapsRequired = 1
      tap.cancelsTouchesInView = false
      tap.delaysTouchesBegan = false
      tap.delegate = self
      tap.addTarget(self, action: #selector(handleTap(_:)))
      // A hold that engaged is not a tap. This costs a plain tap nothing: the
      // hold fails the instant a short touch lifts.
      tap.require(toFail: hold)
      addGestureRecognizer(tap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func willMove(toWindow newWindow: UIWindow?) {
      if newWindow == nil { releaseClaim() }
      super.willMove(toWindow: newWindow)
    }

    @objc private func handleHold(_ gesture: UILongPressGestureRecognizer) {
      switch gesture.state {
      case .began:
        claimAncestorGestures()
        DitherHoldInteraction.onEngage?()
        onScrub?(gesture.location(in: self))
      case .changed:
        onScrub?(gesture.location(in: self))
      case .ended, .cancelled, .failed:
        releaseClaim()
        onScrub?(nil)
      default:
        break
      }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
      guard gesture.state == .ended else { return }
      onTap?(gesture.location(in: self))
    }

    /// Only this view's own pair recognizes alongside the hold. Everything
    /// outside is refused, which is what settles a fresh conflict in the
    /// chart's favour once the hold has engaged.
    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
      otherGestureRecognizer === hold || otherGestureRecognizer === tap
    }

    /// Refusing simultaneous recognition only settles conflicts UIKit asks us
    /// about; a scroll view whose own delegate opts into simultaneity would
    /// still read the finger. Switching the ancestors off is the part that
    /// actually holds — and it is what keeps the page still until release.
    private func claimAncestorGestures() {
      guard claimed.isEmpty else { return }
      var ancestor = superview
      while let view = ancestor {
        for recognizer in view.gestureRecognizers ?? [] {
          let isDirectional =
            recognizer is UIPanGestureRecognizer || recognizer is UISwipeGestureRecognizer
          guard
            DitherHoldClaimRules.claims(
              isDirectional: isDirectional,
              isEnabled: recognizer.isEnabled,
              isOwn: recognizer === hold || recognizer === tap)
          else { continue }
          recognizer.isEnabled = false
          claimed.append(recognizer)
        }
        ancestor = view.superview
      }
    }

    /// Restores every claimed recognizer. Idempotent, and called on teardown as
    /// well as on release: a chart can be swapped out mid-hold, and a stranded
    /// scroll view would never scroll again.
    func releaseClaim() {
      for recognizer in claimed {
        recognizer.isEnabled = true
      }
      claimed.removeAll()
    }
  }
#endif
