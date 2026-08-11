import SwiftUI
import UIKit

/// Sparse delight for rare, high-value moments — not for list filters or typing.
/// All generators no-op when Settings → Haptic feedback is off.
@MainActor
enum DashDelight {
  /// A meaningful action completed (zone created, upload finished).
  static func celebrateSuccess() {
    guard DashInteractionPreferences.hapticsEnabled else { return }
    UINotificationFeedbackGenerator().notificationOccurred(.success)
  }

  /// Recovered from a transient failure (Watchtower refresh after an error).
  static func recoverFromIssue() {
    guard DashInteractionPreferences.hapticsEnabled else { return }
    UINotificationFeedbackGenerator().notificationOccurred(.success)
  }

  /// Destructive or irreversible action is about to happen.
  static func warnImpact() {
    guard DashInteractionPreferences.hapticsEnabled else { return }
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
  }

  /// Operation failed or was rejected.
  static func failError() {
    guard DashInteractionPreferences.hapticsEnabled else { return }
    UINotificationFeedbackGenerator().notificationOccurred(.error)
  }

  /// Lightweight tap on a secondary control (copy, chip toggle).
  static func lightImpact() {
    guard DashInteractionPreferences.hapticsEnabled else { return }
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
  }

  /// A drag lifted off. Stands in for the feedback UIKit plays with its own
  /// lift preview, which a `previewForLifting` of nil suppresses.
  static func dragLift() {
    guard DashInteractionPreferences.hapticsEnabled else { return }
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
  }

  /// A hold inside a chart or the globe engaged: that surface now owns the
  /// finger, and the page under it has stopped answering to it.
  static func gestureEngaged() {
    guard DashInteractionPreferences.hapticsEnabled else { return }
    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
  }

  /// Picker, tab, or segment selection changed.
  static func selectionChanged() {
    guard DashInteractionPreferences.hapticsEnabled else { return }
    UISelectionFeedbackGenerator().selectionChanged()
  }

}

/// Press feedback for genuine *button* controls: pills, circular icon buttons,
/// toolbar/back/close actions, small text actions (Cancel, Back, Save, Show
/// more…), and tab labels. The 0.97 shrink is the app's single "this is a
/// button" cue; a light haptic fires on press-down so every button operation
/// feels tactile.
///
/// Do NOT apply this to rows, list items, cards, or tiles — those are tappable
/// *surfaces*, not buttons, and must not shrink. Use `DashSurfaceButtonStyle`
/// for them (and `DestinationLink`, which already does). See "Press feedback"
/// in AGENTS.md. Sanctioned exception: the Home Quick-actions tool tiles are
/// launcher buttons and take this style — the shrink is their press cue.
struct DashPressButtonStyle: ButtonStyle {
  /// How long the pressed pose stays on screen before springing back — long
  /// enough for `Motion.press` (0.15s ease-out) to reach the dip. Kept on the
  /// non-generic style because Swift disallows static stored properties on
  /// generic types (`DashPressFeedback`).
  fileprivate static let minimumDwell: Duration = .milliseconds(120)

  /// Total time for a quick tap's pulse to play out: `minimumDwell` plus the
  /// 0.15s `Motion.press` spring-back. Heavyweight main-thread work triggered
  /// by a tap (system sheet presentations like `ASWebAuthenticationSession.start()`)
  /// should wait this long so the stall doesn't eat the pulse's frames.
  static let pulseSettle: Duration = .milliseconds(270)

  func makeBody(configuration: Configuration) -> some View {
    DashPressFeedback(isPressed: configuration.isPressed) {
      configuration.label
    }
  }
}

/// Renders the 0.97 shrink with a minimum visible dwell. On a quick tap —
/// especially inside a ScrollView, which delivers press and release nearly
/// simultaneously — animating `isPressed` directly starts the shrink and
/// immediately retargets it back, so nothing reads on screen and the button
/// looks dead even though the action fires. Holding the pressed pose for a
/// short floor turns a quick tap into a full dip-and-spring pulse; real
/// holds still release the moment the finger lifts.
private struct DashPressFeedback<Label: View>: View {
  let isPressed: Bool
  @ViewBuilder var label: () -> Label

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var visuallyPressed = false
  @State private var pressedAt: ContinuousClock.Instant?
  @State private var release: Task<Void, Never>?

  var body: some View {
    label()
      .scaleEffect(visuallyPressed && !reduceMotion ? DashTheme.Motion.pressScale : 1)
      .animation(reduceMotion ? nil : DashTheme.Motion.press, value: visuallyPressed)
      .onChange(of: isPressed) { _, pressed in
        if pressed {
          DashDelight.lightImpact()
          release?.cancel()
          release = nil
          pressedAt = .now
          visuallyPressed = true
        } else {
          let held: Duration = pressedAt.map { .now - $0 } ?? .zero
          pressedAt = nil
          let dwell = DashPressButtonStyle.minimumDwell
          if held >= dwell {
            visuallyPressed = false
          } else {
            release = Task {
              try? await Task.sleep(for: dwell - held)
              guard !Task.isCancelled else { return }
              visuallyPressed = false
            }
          }
        }
      }
  }
}

/// Press state a `DashSurfaceButtonStyle` button exposes to its label. The
/// surface hit target stays put by contract (no scale — shrink would read as a
/// button, not a surface). Embossed tiles (`dashEmbossed()`) read this for
/// optical sink: shadow, dim, and a 1pt visual-only offset on a non-interactive
/// copy so the stable label geometry still receives the tap.
private struct DashSurfacePressedKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  var dashSurfacePressed: Bool {
    get { self[DashSurfacePressedKey.self] }
    set { self[DashSurfacePressedKey.self] = newValue }
  }
}

/// Press style for tappable *surfaces* — full-width rows, list items, cards, and
/// tiles. These are not buttons: they carry no shrink and no press animation, so
/// the surface stays put while the tap routes (a push, a sheet, a toggle). Only
/// discrete button controls scale (`DashPressButtonStyle`). See "Press feedback"
/// in AGENTS.md. The style does publish `dashSurfacePressed` so opted-in
/// descendants (the embossed Home tiles) can render their own in-place feedback.
struct DashSurfaceButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    // Bridge through a real `View` ancestor — applying `.environment` directly
    // onto `configuration.label` can leave `@Environment` readers inside the
    // label stale for the whole press.
    DashSurfacePressedHost(isPressed: configuration.isPressed) {
      configuration.label
    }
  }
}

/// Publishes `dashSurfacePressed` for embossed tiles / domain cards.
private struct DashSurfacePressedHost<Content: View>: View {
  let isPressed: Bool
  @ViewBuilder var content: () -> Content

  var body: some View {
    content()
      .environment(\.dashSurfacePressed, isPressed)
  }
}
