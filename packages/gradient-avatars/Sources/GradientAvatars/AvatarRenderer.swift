import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The visual pattern used to render an avatar.
public enum AvatarPattern: String, CaseIterable, Hashable, Sendable {
  /// Six blurred polygons blended over a base fill.
  case gradient
  /// A two-tone sweep resolved through an ordered Bayer matrix.
  case dither
}

/// The pacing of an animated avatar.
///
/// Motion is a continuous function of `phase`, so the same renderer serves a
/// still frame (`phase == 0`) and every animated one. Playback quantizes time
/// instead of sampling the display link, because a dithered cell is either on
/// or off and redrawing it faster than it can change is wasted raster work.
public enum AvatarMotion {
  /// Phase units advanced per second of wall time.
  public static let phasePerSecond = 0.55
  /// Frames drawn per second.
  public static let framesPerSecond = 20.0
  /// The shortest gap between two rendered frames.
  public static let frameInterval = 1 / framesPerSecond
  /// The largest avatar animation may drive.
  ///
  /// Every frame is a fresh CPU raster, so this keeps motion on the handful of
  /// large avatars it reads on and off the list rows it would not.
  public static let animatablePixelSize = 256

  /// The phase to draw for a moment in time.
  public static func phase(at date: Date) -> Double {
    let frame = (date.timeIntervalSinceReferenceDate * framesPerSecond).rounded(.down)
    return frame / framesPerSecond * phasePerSecond
  }
}

/// Renders deterministic avatars without storage or network access.
public enum AvatarRenderer {
  /// Renders a square `CGImage` for a string seed.
  public static func image(
    seed: String,
    size: Int = 512,
    pattern: AvatarPattern = .gradient,
    dotScale: Int? = nil,
    phase: Double = 0
  ) -> CGImage? {
    image(
      seed: AvatarSeed(seed),
      size: size,
      pattern: pattern,
      dotScale: dotScale,
      phase: phase
    )
  }

  /// Renders a square `CGImage` for a numeric seed.
  public static func image(
    seed: UInt32,
    size: Int = 512,
    pattern: AvatarPattern = .gradient,
    dotScale: Int? = nil,
    phase: Double = 0
  ) -> CGImage? {
    image(
      seed: AvatarSeed(seed),
      size: size,
      pattern: pattern,
      dotScale: dotScale,
      phase: phase
    )
  }

  /// Renders a square `CGImage` for a normalized seed.
  public static func image(
    seed: AvatarSeed,
    size: Int = 512,
    pattern: AvatarPattern = .gradient,
    dotScale: Int? = nil,
    phase: Double = 0
  ) -> CGImage? {
    guard size > 0 else { return nil }

    switch pattern {
    case .gradient:
      return gradientImage(seed: seed, size: size, phase: phase)
    case .dither:
      return ditherImage(seed: seed, size: size, dotScale: dotScale, phase: phase)
    }
  }

  /// Encodes an avatar as PNG data for persistence, sharing, or upload.
  public static func pngData(
    seed: String,
    size: Int = 512,
    pattern: AvatarPattern = .gradient,
    dotScale: Int? = nil
  ) -> Data? {
    pngData(
      seed: AvatarSeed(seed),
      size: size,
      pattern: pattern,
      dotScale: dotScale
    )
  }

  /// Encodes an avatar as PNG data for persistence, sharing, or upload.
  public static func pngData(
    seed: UInt32,
    size: Int = 512,
    pattern: AvatarPattern = .gradient,
    dotScale: Int? = nil
  ) -> Data? {
    pngData(
      seed: AvatarSeed(seed),
      size: size,
      pattern: pattern,
      dotScale: dotScale
    )
  }

  /// Encodes an avatar as PNG data for persistence, sharing, or upload.
  public static func pngData(
    seed: AvatarSeed,
    size: Int = 512,
    pattern: AvatarPattern = .gradient,
    dotScale: Int? = nil
  ) -> Data? {
    guard
      let image = image(seed: seed, size: size, pattern: pattern, dotScale: dotScale),
      let data = CFDataCreateMutable(nil, 0),
      let destination = CGImageDestinationCreateWithData(
        data,
        UTType.png.identifier as CFString,
        1,
        nil
      )
    else {
      return nil
    }

    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
  }

  /// The dither cell edge, in pixels, for an avatar of `size` pixels.
  public static func defaultDotScale(for size: Int) -> Int {
    max(1, Int((Double(size) / 35).rounded()))
  }

  // MARK: - Dither

  private static func ditherImage(
    seed: AvatarSeed,
    size: Int,
    dotScale: Int?,
    phase: Double
  ) -> CGImage? {
    guard
      let context = bitmapContext(size: size),
      let buffer = context.data
    else {
      return nil
    }

    let palette = AvatarGenerator.palette(for: seed, count: 2)
    guard let foreground = palette.colors.first else { return nil }
    let background = palette.colors[min(1, palette.colors.count - 1)]
    let seeds = AvatarGenerator.seeds(for: seed, count: 4)

    let cell = max(1, dotScale ?? defaultDotScale(for: size))
    let padding = 1
    let grid = Int((Double(size) / Double(cell)).rounded(.up)) + padding * 2
    let span = Double(max(1, grid - padding * 2))

    let angle = seeds[0] * 2 * .pi + phase * ditherSwirlSpeed
    let falloff = 0.55 + seeds[1] * 0.25
    let cosine = cos(angle)
    let sine = sin(angle)
    let moves = phase != 0

    let bytesPerRow = context.bytesPerRow
    let pixels = buffer.bindMemory(to: UInt8.self, capacity: bytesPerRow * size)

    for y in 0..<size {
      let row = y * bytesPerRow
      for x in 0..<size {
        let offset = row + x * 4
        pixels[offset] = background.red
        pixels[offset + 1] = background.green
        pixels[offset + 2] = background.blue
        pixels[offset + 3] = 255
      }
    }

    for gridY in 0..<grid {
      for gridX in 0..<grid {
        let normalizedX = (Double(gridX - padding) + 0.5) / span
        let normalizedY = (Double(gridY - padding) + 0.5) / span
        let projection = (normalizedX - 0.5) * cosine + (normalizedY - 0.5) * sine
        let drift =
          moves
          ? cellDrift(gridX: gridX, gridY: gridY, seeds: seeds, phase: phase)
          : 0
        let ramp = (projection - drift + falloff) / (falloff * 2)
        let clamped = min(max(ramp, 0), 1)
        let coverage = clamped * clamped * (3 - 2 * clamped)
        guard coverage <= bayer8[gridY % 8][gridX % 8] else { continue }

        for cellY in 0..<cell {
          let y = (gridY - padding) * cell + cellY
          guard y >= 0, y < size else { continue }
          let row = y * bytesPerRow
          for cellX in 0..<cell {
            let x = (gridX - padding) * cell + cellX
            guard x >= 0, x < size else { continue }
            let offset = row + x * 4
            pixels[offset] = foreground.red
            pixels[offset + 1] = foreground.green
            pixels[offset + 2] = foreground.blue
          }
        }
      }
    }

    return context.makeImage()
  }

  /// A per-cell wobble that keeps neighbouring cells out of lockstep.
  private static func cellDrift(
    gridX: Int,
    gridY: Int,
    seeds: [Double],
    phase: Double
  ) -> Double {
    let cellPhase =
      (Double(gridX * 31 + gridY * 17) * (seeds[2] * 1000 + 1)
      + Double(Int(seeds[3] * 1000)))
      .truncatingRemainder(dividingBy: 1000) / 1000 * 2 * .pi
    let amplitude =
      0.035
      + Double(Int(Double(gridX * 7 + gridY * 13) + seeds[2] * 50) % 55) / 1100

    return amplitude * sin(phase * 0.3 + cellPhase)
      + amplitude * 0.55 * sin(phase * 0.1 + cellPhase * 1.7)
      + 0.012 * sin(phase * 0.2)
  }

  // MARK: - Gradient

  private static func gradientImage(
    seed: AvatarSeed,
    size: Int,
    phase: Double
  ) -> CGImage? {
    let palette = AvatarGenerator.palette(for: seed, count: 4)
    guard
      palette.colors.count == 4,
      let context = bitmapContext(size: size)
    else {
      return nil
    }

    let dimension = Double(size)
    context.setFillColor(palette.colors[0].cgColor)
    context.fill(CGRect(x: 0, y: 0, width: dimension, height: dimension))

    let seeds = AvatarGenerator.seeds(
      for: seed,
      count: 24,
      salt: AvatarGenerator.geometrySalt
    )
    let blur = max(2, (dimension * 0.21).rounded())
    let inset = (blur * 1.9).rounded(.up)
    let padded = Int(dimension + inset * 2)
    let moves = phase != 0

    for index in 0..<6 {
      let base = index * 4
      let rotation =
        (seeds[base + 2] - 0.5) * .pi * 1.2
        + (moves ? phase * layerRotationSpeeds[index] : 0)
      let driftAmplitude = dimension * 0.18
      let driftX =
        moves
        ? driftAmplitude
          * sin(phase * layerDriftFrequencies[index] + layerDriftPhases[index])
        : 0
      let driftY =
        moves
        ? driftAmplitude
          * sin(
            phase * layerDriftFrequencies[(index + 2) % 6]
              + layerDriftPhases[index] * 1.3)
        : 0
      let pulse = moves ? 1 + 0.15 * sin(phase * 0.9 + Double(index) * 0.7) : 1
      let layer = layerImage(
        shape: shapes[index],
        size: dimension,
        padded: padded,
        translation: CGPoint(
          x: (seeds[base] - 0.5) * dimension * 0.35 + driftX,
          y: (seeds[base + 1] - 0.5) * dimension * 0.35 + driftY
        ),
        rotation: rotation,
        scale: (0.85 + seeds[base + 3] * 0.5) * pulse,
        color: palette.colors[1 + index % 3],
        inset: inset
      )

      guard
        let layer,
        let softened = gaussianBlurred(layer, sigma: blur)
      else {
        continue
      }

      context.saveGState()
      context.setBlendMode(layerBlends[index].blend)
      context.setAlpha(layerBlends[index].alpha)
      context.draw(
        softened,
        in: CGRect(
          x: -inset,
          y: -inset,
          width: Double(padded),
          height: Double(padded)
        )
      )
      context.restoreGState()
    }

    return context.makeImage()
  }

  private static func layerImage(
    shape: [(x: Double, y: Double)],
    size: Double,
    padded: Int,
    translation: CGPoint,
    rotation: Double,
    scale: Double,
    color: AvatarColor,
    inset: Double
  ) -> CGImage? {
    guard
      let context = bitmapContext(size: padded),
      let first = shape.first
    else {
      return nil
    }

    let center = size / 2
    withTopLeftCoordinates(context, size: Double(padded)) {
      context.translateBy(x: inset + center, y: inset + center)
      context.translateBy(x: translation.x, y: translation.y)
      context.rotate(by: rotation)
      context.scaleBy(x: scale, y: scale)
      context.translateBy(x: -center, y: -center)

      context.beginPath()
      context.move(to: CGPoint(x: first.x * size, y: first.y * size))
      for point in shape.dropFirst() {
        context.addLine(to: CGPoint(x: point.x * size, y: point.y * size))
      }
      context.closePath()
      context.setFillColor(color.cgColor)
      context.fillPath()
    }

    return context.makeImage()
  }

  private static func gaussianBlurred(_ image: CGImage, sigma: Double) -> CGImage? {
    guard sigma > 0 else { return image }
    let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    let blurred = CIImage(cgImage: image)
      .clampedToExtent()
      .applyingGaussianBlur(sigma: sigma)
      .cropped(to: bounds)
    return blurContext.createCGImage(blurred, from: bounds)
  }

  // MARK: - Shared drawing

  private static func bitmapContext(size: Int) -> CGContext? {
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    return CGContext(
      data: nil,
      width: size,
      height: size,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.byteOrder32Big.rawValue
    )
  }

  /// Runs `draw` with the canvas coordinate system the upstream shapes assume.
  private static func withTopLeftCoordinates(
    _ context: CGContext,
    size: Double,
    draw: () -> Void
  ) {
    context.saveGState()
    context.translateBy(x: 0, y: size)
    context.scaleBy(x: 1, y: -1)
    draw()
    context.restoreGState()
  }

  /// `CIContext` is documented as thread-safe, and building one per blur pass
  /// costs more than every other part of a gradient render combined.
  nonisolated(unsafe) private static let blurContext = CIContext(
    options: [.cacheIntermediates: false]
  )

  private static let ditherSwirlSpeed = 0.45

  private static let layerRotationSpeeds = [0.5, 0.6, 0.45, 0.55, 0.5, 0.65]
  private static let layerDriftFrequencies = [0.5, 0.45, 0.4, 0.48, 0.52, 0.38]
  private static let layerDriftPhases = [0.0, 1.0, 2.0, 0.5, 1.5, 3.0]

  private static let layerBlends: [(blend: CGBlendMode, alpha: Double)] = [
    (.normal, 0.9),
    (.overlay, 0.48),
    (.softLight, 0.7),
    (.normal, 0.78),
    (.overlay, 0.4),
    (.softLight, 0.6),
  ]

  /// Irregular polygons centred near the middle, blurred into soft blobs.
  private static let shapes: [[(x: Double, y: Double)]] = [
    [(0.85, 0.5), (0.75, 0.18), (0.38, 0.22), (0.18, 0.52), (0.38, 0.82), (0.72, 0.78)],
    [(0.22, 0.32), (0.78, 0.28), (0.82, 0.62), (0.5, 0.88), (0.18, 0.68), (0.28, 0.48)],
    [(0.5, 0.12), (0.88, 0.45), (0.72, 0.88), (0.28, 0.82), (0.12, 0.42), (0.35, 0.18)],
    [(0.62, 0.25), (0.9, 0.55), (0.65, 0.9), (0.25, 0.7), (0.1, 0.4), (0.35, 0.15)],
    [(0.15, 0.2), (0.55, 0.08), (0.92, 0.35), (0.78, 0.75), (0.4, 0.92), (0.2, 0.6)],
    [(0.45, 0.08), (0.82, 0.3), (0.7, 0.85), (0.3, 0.88), (0.08, 0.5), (0.25, 0.25)],
  ]

  private static let bayer8: [[Double]] = [
    [0, 32, 8, 40, 2, 34, 10, 42],
    [48, 16, 56, 24, 50, 18, 58, 26],
    [12, 44, 4, 36, 14, 46, 6, 38],
    [60, 28, 52, 20, 62, 30, 54, 22],
    [3, 35, 11, 43, 1, 33, 9, 41],
    [51, 19, 59, 27, 49, 17, 57, 25],
    [15, 47, 7, 39, 13, 45, 5, 37],
    [63, 31, 55, 23, 61, 29, 53, 21],
  ].map { row in row.map { $0 / 64 } }
}
