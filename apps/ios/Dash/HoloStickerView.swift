import Combine
import CoreMotion
import SwiftUI

/// One device-motion source shared by every holographic sticker.
///
/// Core Motion keeps its latest sample internally. Dash publishes that sample
/// only when this manager's single timer fires, so adding stickers adds no
/// motion managers, timers, or sampling work.
@MainActor
final class HoloMotionManager: ObservableObject {
  struct Snapshot: Equatable, Sendable {
    let relativePitch: Double
    let relativeRoll: Double

    static let zero = Snapshot(relativePitch: 0, relativeRoll: 0)
  }

  static let shared = HoloMotionManager()

  @Published private(set) var snapshot = Snapshot.zero
  @Published private(set) var isMotionAvailable: Bool

  /// Points of gradient travel per radian of relative pitch.
  @Published var gradientSensitivity = 180.0
  /// Sparkle stays within the requested 0...0.7 range.
  @Published var sparkleMaximumOpacity = 0.7
  /// Maximum pitch delta across one stillness window that counts as stationary.
  @Published var resetThreshold = 0.02
  /// How often one motion snapshot is published to every sticker.
  @Published var updateFrequency = 20.0 {
    didSet {
      guard
        updateFrequency != oldValue,
        !activeClients.isEmpty,
        motionManager.isDeviceMotionActive
      else { return }
      scheduleTimer()
    }
  }

  private let motionManager: CMMotionManager
  private let stillnessCheckInterval: TimeInterval = 3
  private var timer: Timer?
  private var activeClients: Set<UUID> = []
  private var initialPitch: Double?
  private var initialRoll: Double?
  private var lastRelativePitchSnapshot = 0.0
  private var lastStillnessCheck = Date.distantPast
  private var shouldResetReference = true

  init(motionManager: CMMotionManager = CMMotionManager()) {
    self.motionManager = motionManager
    self.isMotionAvailable = motionManager.isDeviceMotionAvailable
  }

  isolated deinit {
    timer?.invalidate()
    motionManager.stopDeviceMotionUpdates()
  }

  /// A sticker activates the shared source while it is visible. The first
  /// client starts Core Motion; the last one leaving stops it.
  func activate(clientID: UUID) {
    let wasEmpty = activeClients.isEmpty
    activeClients.insert(clientID)
    guard wasEmpty, !activeClients.isEmpty else { return }

    isMotionAvailable = motionManager.isDeviceMotionAvailable
    guard isMotionAvailable else { return }

    shouldResetReference = true
    lastStillnessCheck = .now
    motionManager.deviceMotionUpdateInterval = timerInterval
    motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical)
    scheduleTimer()
  }

  func deactivate(clientID: UUID) {
    activeClients.remove(clientID)
    guard activeClients.isEmpty else { return }
    timer?.invalidate()
    timer = nil
    motionManager.stopDeviceMotionUpdates()
    clearReference()
  }

  /// Recenter pitch and roll on the next available Core Motion sample.
  func resetReference() {
    shouldResetReference = true
  }

  private var timerInterval: TimeInterval {
    1 / min(max(updateFrequency, 5), 30)
  }

  private func scheduleTimer() {
    timer?.invalidate()
    motionManager.deviceMotionUpdateInterval = timerInterval

    let timer = Timer(timeInterval: timerInterval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.publishLatestMotion()
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  private func publishLatestMotion() {
    guard
      !activeClients.isEmpty,
      let attitude = motionManager.deviceMotion?.attitude
    else { return }

    let pitch = attitude.pitch
    let roll = attitude.roll

    guard !shouldResetReference, let initialPitch, let initialRoll else {
      setReference(pitch: pitch, roll: roll)
      return
    }

    let nextPitch = pitch - initialPitch
    let nextRoll = Self.normalizedAngle(roll - initialRoll)
    let now = Date.now

    if now.timeIntervalSince(lastStillnessCheck) >= stillnessCheckInterval {
      let pitchDelta = abs(nextPitch - lastRelativePitchSnapshot)
      lastStillnessCheck = now

      if pitchDelta < max(resetThreshold, 0) {
        setReference(pitch: pitch, roll: roll)
        return
      } else {
        lastRelativePitchSnapshot = nextPitch
      }
    }

    snapshot = Snapshot(relativePitch: nextPitch, relativeRoll: nextRoll)
  }

  private func setReference(pitch: Double, roll: Double) {
    initialPitch = pitch
    initialRoll = roll
    lastRelativePitchSnapshot = 0
    lastStillnessCheck = .now
    shouldResetReference = false
    snapshot = .zero
  }

  private func clearReference() {
    initialPitch = nil
    initialRoll = nil
    lastRelativePitchSnapshot = 0
    shouldResetReference = true
    snapshot = .zero
  }

  private static func normalizedAngle(_ angle: Double) -> Double {
    atan2(sin(angle), cos(angle))
  }
}

/// A reusable sticker that accepts any SwiftUI content, including `Image`.
/// Pass the same `HoloMotionManager` to every instance in a wall.
struct HoloStickerView<Content: View, StickerShape: Shape>: View {
  @ObservedObject private var motion: HoloMotionManager
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase

  private let shape: StickerShape
  private let content: Content
  private let holoOpacity: Double
  @State private var clientID = UUID()
  @State private var isVisible = false

  init(
    motion: HoloMotionManager,
    shape: StickerShape,
    holoOpacity: Double = 0.66,
    @ViewBuilder content: () -> Content
  ) {
    self.motion = motion
    self.shape = shape
    self.holoOpacity = holoOpacity
    self.content = content()
  }

  var body: some View {
    ZStack {
      content

      GeometryReader { proxy in
        effect(in: proxy.size)
      }
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    }
    .clipShape(shape)
    .contentShape(shape)
    .compositingGroup()
    .onAppear {
      isVisible = true
      updateMotionActivation()
    }
    .onDisappear {
      isVisible = false
      updateMotionActivation()
    }
    .onChange(of: scenePhase) { _, _ in
      updateMotionActivation()
    }
    .onChange(of: reduceMotion) { _, _ in
      updateMotionActivation()
    }
  }

  private func effect(in size: CGSize) -> some View {
    let pitch = reduceMotion ? 0 : motion.snapshot.relativePitch
    let roll = reduceMotion ? 0 : motion.snapshot.relativeRoll
    let maximumOffset = max(size.width, size.height)
    let gradientOffset = min(
      max(pitch * motion.gradientSensitivity, -maximumOffset),
      maximumOffset
    )
    let sparkleRange = 0.35
    let sparkleProgress =
      reduceMotion
      ? 0.18
      : min(abs(pitch) / sparkleRange, 1)
    let sparkleOpacity =
      min(max(motion.sparkleMaximumOpacity, 0), 0.7) * sparkleProgress

    return ZStack {
      LinearGradient(
        colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple],
        startPoint: .leading,
        endPoint: .trailing
      )
      .frame(width: size.width * 3, height: size.height * 3)
      .offset(x: gradientOffset)
      .opacity(holoOpacity)
      .blendMode(.color)

      HoloSparkleLayer(offset: gradientOffset)
        .frame(width: size.width * 1.6, height: size.height * 1.6)
        .opacity(sparkleOpacity)
        .blendMode(.plusLighter)
    }
    .frame(width: size.width, height: size.height)
    .rotationEffect(.radians(roll * 0.85))
  }

  private func updateMotionActivation() {
    if isVisible, scenePhase == .active, !reduceMotion {
      motion.activate(clientID: clientID)
    } else {
      motion.deactivate(clientID: clientID)
    }
  }
}

private struct HoloSparkleLayer: View {
  let offset: Double

  private let sparklePoints: [(x: Double, y: Double, radius: Double)] = [
    (0.10, 0.20, 1.6),
    (0.22, 0.72, 1.1),
    (0.34, 0.38, 2.0),
    (0.46, 0.86, 1.3),
    (0.58, 0.16, 1.0),
    (0.67, 0.57, 1.8),
    (0.79, 0.30, 1.2),
    (0.90, 0.76, 2.1),
  ]

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [.clear, .white.opacity(0.15), .white, .white.opacity(0.12), .clear],
        startPoint: .leading,
        endPoint: .trailing
      )
      .offset(x: -offset * 0.45)

      Canvas { context, size in
        for sparkle in sparklePoints {
          let diameter = sparkle.radius * 2
          let rect = CGRect(
            x: size.width * sparkle.x - sparkle.radius,
            y: size.height * sparkle.y - sparkle.radius,
            width: diameter,
            height: diameter
          )
          context.fill(Path(ellipseIn: rect), with: .color(.white))
        }
      }
    }
  }
}
