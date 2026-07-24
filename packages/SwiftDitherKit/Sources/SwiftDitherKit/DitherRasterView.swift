import CoreGraphics
import SwiftUI

enum DitherRevealStyle: Hashable, Sendable {
  case leading
  case angular
  case radial
}

struct DitherAnimatedRaster: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var currentFrame: DitherRenderedRaster
  @State private var previousFrame: DitherRenderedRaster?
  @State private var progress: DitherRasterTransitionProgress
  @State private var didStart = false
  @State private var lastMotionState: DitherRasterMotionState
  @State private var operationID: UInt64 = 0

  private let incomingFrame: DitherRenderedRaster
  private let rasterChecksum: UInt64
  let size: CGSize
  let bloom: DitherBloom
  let revealStyle: DitherRevealStyle
  let animate: Bool
  let animationDuration: TimeInterval
  let transitionKey: Int
  let replayToken: Int

  init(
    frame: DitherRenderedRaster,
    size: CGSize,
    bloom: DitherBloom,
    revealStyle: DitherRevealStyle,
    animate: Bool,
    animationDuration: TimeInterval,
    transitionKey: Int,
    replayToken: Int
  ) {
    let initialMotionState = DitherRasterMotionState(
      checksum: frame.checksum,
      transitionKey: transitionKey,
      replayToken: replayToken,
      animate: animate,
      reduceMotion: false
    )

    incomingFrame = frame
    rasterChecksum = frame.checksum
    self.size = size
    self.bloom = bloom
    self.revealStyle = revealStyle
    self.animate = animate
    self.animationDuration = animationDuration
    self.transitionKey = transitionKey
    self.replayToken = replayToken
    _currentFrame = State(initialValue: frame)
    _previousFrame = State(initialValue: nil)
    _progress = State(initialValue: DitherRasterTransitionProgress(animate: animate))
    _lastMotionState = State(initialValue: initialMotionState)
  }

  var body: some View {
    DitherRevealContainer(
      frame: currentFrame,
      previousFrame: previousFrame,
      size: size,
      bloom: bloom,
      revealStyle: revealStyle,
      entranceProgress: progress.entrance,
      updateProgress: progress.update,
      reduceMotion: reduceMotion
    )
    .task(id: motionState) { await synchronizeMotion(to: motionState) }
  }

  private var motionState: DitherRasterMotionState {
    DitherRasterMotionState(
      checksum: rasterChecksum,
      transitionKey: transitionKey,
      replayToken: replayToken,
      animate: animate,
      reduceMotion: reduceMotion
    )
  }

  @MainActor
  private func synchronizeMotion(to next: DitherRasterMotionState) async {
    operationID &+= 1
    let currentOperationID = operationID

    guard didStart else {
      didStart = true
      lastMotionState = next
      currentFrame = incomingFrame
      await runEntrance(reduceMotion: next.reduceMotion, operationID: currentOperationID)
      return
    }

    let decision = DitherRasterMotionDecision.decide(from: lastMotionState, to: next)
    lastMotionState = next

    switch decision {
    case .none:
      return
    case .replace:
      currentFrame = incomingFrame
      previousFrame = nil
      progress.prepare(for: decision)
    case .crossfade:
      progress.entrance = 1
      await crossfade(
        to: incomingFrame,
        reduceMotion: next.reduceMotion,
        operationID: currentOperationID
      )
    case .replay:
      currentFrame = incomingFrame
      previousFrame = nil
      progress.prepare(for: decision)
      await runEntrance(reduceMotion: next.reduceMotion, operationID: currentOperationID)
    case .settle:
      previousFrame = nil
      progress.update = 1
      withAnimation(DitherMotion.reduced) {
        progress.entrance = 1
      }
    }
  }

  @MainActor
  private func runEntrance(reduceMotion: Bool, operationID: UInt64) async {
    guard animate else {
      progress.settle()
      return
    }

    progress.prepare(for: .replay)
    await Task.yield()
    guard !Task.isCancelled, self.operationID == operationID else {
      settleCancelledOperation(operationID)
      return
    }
    withAnimation(
      reduceMotion
        ? DitherMotion.reduced
        : DitherMotion.entrance(duration: animationDuration)
    ) {
      progress.entrance = 1
    }
  }

  @MainActor
  private func crossfade(
    to frame: DitherRenderedRaster,
    reduceMotion: Bool,
    operationID: UInt64
  ) async {
    guard animate else {
      currentFrame = frame
      previousFrame = nil
      progress.settle()
      return
    }

    previousFrame = currentFrame
    currentFrame = frame
    progress.prepare(for: .crossfade)
    await Task.yield()
    guard !Task.isCancelled, self.operationID == operationID else {
      settleCancelledOperation(operationID)
      return
    }

    let duration = reduceMotion ? DitherMotion.reducedMotionDuration : DitherMotion.updateDuration
    withAnimation(reduceMotion ? DitherMotion.reduced : DitherMotion.update) {
      progress.update = 1
    }

    try? await Task.sleep(for: .seconds(duration + 0.04))
    guard !Task.isCancelled, self.operationID == operationID else { return }
    previousFrame = nil
  }

  @MainActor
  private func settleCancelledOperation(_ cancelledOperationID: UInt64) {
    guard operationID == cancelledOperationID else { return }
    previousFrame = nil
    progress.settle()
  }
}

struct DitherAsyncRaster: View {
  @Environment(\.ditherRenderingMode) private var renderingMode
  @State private var frame: DitherRenderedRaster?

  let request: DitherRenderRequest
  let size: CGSize
  let bloom: DitherBloom
  let revealStyle: DitherRevealStyle
  let animate: Bool
  let animationDuration: TimeInterval
  let transitionKey: Int
  let replayToken: Int

  @ViewBuilder
  var body: some View {
    switch renderingMode {
    case .asynchronous:
      asynchronousContent
    case .immediate:
      content(frame: request.renderFrame())
    }
  }

  private var asynchronousContent: some View {
    content(frame: frame)
      .task(id: request) {
        do {
          let rendered = try await DitherRenderCache.shared.frame(for: request)
          guard !Task.isCancelled else { return }
          frame = rendered
        } catch is CancellationError {
          // A newer render request superseded this one.
        } catch {
          assertionFailure("Unexpected dither render failure: \(error)")
        }
      }
  }

  @ViewBuilder
  private func content(frame: DitherRenderedRaster?) -> some View {
    Group {
      if let frame {
        DitherAnimatedRaster(
          frame: frame,
          size: size,
          bloom: bloom,
          revealStyle: revealStyle,
          animate: animate,
          animationDuration: animationDuration,
          transitionKey: transitionKey,
          replayToken: replayToken
        )
      } else {
        Color.clear
      }
    }
  }
}

private struct DitherRevealContainer: View {
  let frame: DitherRenderedRaster
  let previousFrame: DitherRenderedRaster?
  let size: CGSize
  let bloom: DitherBloom
  let revealStyle: DitherRevealStyle
  let entranceProgress: CGFloat
  let updateProgress: CGFloat
  let reduceMotion: Bool

  var body: some View {
    DitherRasterTransitionLayers(
      frame: frame,
      previousFrame: previousFrame,
      size: size,
      bloom: bloom,
      progress: updateProgress,
      reduceMotion: reduceMotion
    )
    .mask {
      DitherRevealMask(
        revealStyle: revealStyle,
        progress: entranceProgress,
        reduceMotion: reduceMotion
      )
    }
    .scaleEffect(revealScale)
    .opacity(revealOpacity)
    .frame(width: size.width, height: size.height)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private var revealScale: CGFloat {
    guard !reduceMotion, revealStyle == .radial else { return 1 }
    return DitherMotion.radarScale(progress: entranceProgress)
  }

  private var revealOpacity: Double {
    reduceMotion || revealStyle == .radial
      ? Double(DitherMotion.clamped(entranceProgress))
      : 1
  }
}

private struct DitherRasterTransitionLayers: View {
  let frame: DitherRenderedRaster
  let previousFrame: DitherRenderedRaster?
  let size: CGSize
  let bloom: DitherBloom
  let progress: CGFloat
  let reduceMotion: Bool

  var body: some View {
    let clampedProgress = DitherMotion.clamped(progress)
    ZStack {
      if let previousFrame {
        DitherRasterLayers(
          frame: previousFrame,
          size: size,
          bloom: bloom,
          reduceMotion: reduceMotion
        )
        .opacity(1 - clampedProgress)
        .blur(
          radius: DitherMotion.outgoingBlur(
            progress: clampedProgress,
            reduceMotion: reduceMotion
          ))
      }
      DitherRasterLayers(
        frame: frame,
        size: size,
        bloom: bloom,
        reduceMotion: reduceMotion
      )
      .opacity(previousFrame == nil ? 1 : clampedProgress)
      .blur(
        radius: DitherMotion.incomingBlur(
          progress: previousFrame == nil ? 1 : clampedProgress,
          reduceMotion: reduceMotion
        ))
    }
  }
}

private struct DitherRasterLayers: View {
  let frame: DitherRenderedRaster
  let size: CGSize
  let bloom: DitherBloom
  let reduceMotion: Bool

  var body: some View {
    ZStack {
      if let image = frame.image {
        if let style = bloom.style {
          DitherRasterImage(image: image, size: size)
            .blur(radius: style.blur)
            .brightness(style.brightness)
            .saturation(style.saturation)
            .opacity(style.opacity)
            .blendMode(.plusLighter)
        }
        DitherRasterImage(image: image, size: size)
      }
      DitherSparkleOverlay(
        field: frame.sparkleField,
        size: size,
        reduceMotion: reduceMotion
      )
    }
  }
}

private struct DitherSparkleOverlay: View {
  @Environment(\.ditherRenderingMode) private var renderingMode

  let field: DitherSparkleField
  let size: CGSize
  let reduceMotion: Bool

  @ViewBuilder
  var body: some View {
    Group {
      if field.sparkles.isEmpty {
        Color.clear
      } else if reduceMotion {
        sparkleCanvas(tick: 0, reduceMotion: true)
      } else if renderingMode == .immediate {
        sparkleCanvas(tick: 0, reduceMotion: false)
      } else {
        TimelineView(.animation(minimumInterval: DitherSparkleMotion.tickInterval)) { context in
          sparkleCanvas(
            tick: DitherSparkleMotion.tick(at: context.date),
            reduceMotion: false
          )
        }
      }
    }
    .frame(width: size.width, height: size.height)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private func sparkleCanvas(tick: Int, reduceMotion: Bool) -> some View {
    Canvas { context, canvasSize in
      guard field.width > 0, field.height > 0 else { return }
      let cellWidth = canvasSize.width / CGFloat(field.width)
      let cellHeight = canvasSize.height / CGFloat(field.height)

      for sparkle in field.sparkles {
        guard sparkle.x >= 0, sparkle.x < field.width,
          sparkle.y >= 0, sparkle.y < field.height
        else {
          continue
        }
        let sample = DitherSparkleMotion.sample(
          tick: tick,
          phase: sparkle.phase,
          intensity: field.intensity,
          reduceMotion: reduceMotion
        )
        guard sample.isVisible else { continue }

        let red = Double(sparkle.color.red) / 255
        let green = Double(sparkle.color.green) / 255
        let blue = Double(sparkle.color.blue) / 255
        let centerColor = Color(
          .sRGB,
          red: red,
          green: green,
          blue: blue,
          opacity: sample.centerAlpha
        )
        let center = CGRect(
          x: CGFloat(sparkle.x) * cellWidth,
          y: CGFloat(sparkle.y) * cellHeight,
          width: cellWidth,
          height: cellHeight
        )
        context.fill(Path(center), with: .color(centerColor))

        guard sample.flareAlpha > 0 else { continue }
        let flareColor = Color(
          .sRGB,
          red: red,
          green: green,
          blue: blue,
          opacity: sample.flareAlpha
        )
        for (offsetX, offsetY) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
          let flareX = sparkle.x + offsetX
          let flareY = sparkle.y + offsetY
          guard flareX >= 0, flareX < field.width,
            flareY >= 0, flareY < field.height
          else {
            continue
          }
          let flare = CGRect(
            x: CGFloat(flareX) * cellWidth,
            y: CGFloat(flareY) * cellHeight,
            width: cellWidth,
            height: cellHeight
          )
          context.fill(Path(flare), with: .color(flareColor))
        }
      }
    }
  }
}

private struct DitherRasterImage: View {
  let image: CGImage
  let size: CGSize

  var body: some View {
    Image(decorative: image, scale: 1, orientation: .up)
      .resizable()
      .interpolation(.none)
      .frame(width: size.width, height: size.height)
  }
}

private struct DitherRevealMask: Shape {
  let revealStyle: DitherRevealStyle
  var progress: CGFloat
  let reduceMotion: Bool

  var animatableData: CGFloat {
    get { progress }
    set { progress = newValue }
  }

  func path(in rect: CGRect) -> Path {
    let clamped = DitherMotion.clamped(progress)
    guard !reduceMotion else { return Path(rect) }

    switch revealStyle {
    case .leading:
      return Path(
        CGRect(x: rect.minX, y: rect.minY, width: rect.width * clamped, height: rect.height))
    case .angular:
      return angularPath(in: rect, progress: clamped)
    case .radial:
      return Path(rect)
    }
  }

  private func angularPath(in rect: CGRect, progress: CGFloat) -> Path {
    guard progress > 0 else { return Path() }
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let radius = hypot(rect.width, rect.height)
    var path = Path()
    path.move(to: center)
    path.addLine(to: CGPoint(x: center.x, y: center.y - radius))
    path.addArc(
      center: center,
      radius: radius,
      startAngle: .degrees(-90),
      endAngle: .degrees(-90 + 360 * Double(progress)),
      clockwise: false
    )
    path.closeSubpath()
    return path
  }
}
