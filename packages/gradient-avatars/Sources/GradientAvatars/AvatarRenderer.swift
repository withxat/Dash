import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The visual pattern used to render an avatar.
public enum AvatarPattern: String, CaseIterable, Sendable {
  case mesh
  case dither
}

/// Renders deterministic avatars without storage or network access.
public enum AvatarRenderer {
  /// The upstream mesh blur radius as a fraction of the output dimension.
  public static let defaultBlurFraction = 0.06

  /// Renders a square `CGImage` for a string seed.
  public static func image(
    seed: String,
    size: Int = 512,
    pattern: AvatarPattern = .mesh,
    blur: Double? = nil
  ) -> CGImage? {
    image(seed: AvatarSeed(seed), size: size, pattern: pattern, blur: blur)
  }

  /// Renders a square `CGImage` for a numeric seed.
  public static func image(
    seed: UInt32,
    size: Int = 512,
    pattern: AvatarPattern = .mesh,
    blur: Double? = nil
  ) -> CGImage? {
    image(seed: AvatarSeed(seed), size: size, pattern: pattern, blur: blur)
  }

  /// Renders a square `CGImage` for a normalized seed.
  public static func image(
    seed: AvatarSeed,
    size: Int = 512,
    pattern: AvatarPattern = .mesh,
    blur: Double? = nil
  ) -> CGImage? {
    guard size > 0 else { return nil }

    switch pattern {
    case .mesh:
      guard let rawImage = rawMeshImage(seed: seed, size: size) else { return nil }
      let blurRadius =
        blur == 0
        ? 0
        : max(0, blur ?? (Double(size) * defaultBlurFraction).rounded())
      return blurred(
        rawImage,
        size: size,
        radius: blurRadius
      )
    case .dither:
      return ditherImage(seed: seed, size: size)
    }
  }

  /// Encodes an avatar as PNG data for persistence, sharing, or upload.
  public static func pngData(
    seed: String,
    size: Int = 512,
    pattern: AvatarPattern = .mesh,
    blur: Double? = nil
  ) -> Data? {
    pngData(seed: AvatarSeed(seed), size: size, pattern: pattern, blur: blur)
  }

  /// Encodes an avatar as PNG data for persistence, sharing, or upload.
  public static func pngData(
    seed: UInt32,
    size: Int = 512,
    pattern: AvatarPattern = .mesh,
    blur: Double? = nil
  ) -> Data? {
    pngData(seed: AvatarSeed(seed), size: size, pattern: pattern, blur: blur)
  }

  /// Encodes an avatar as PNG data for persistence, sharing, or upload.
  public static func pngData(
    seed: AvatarSeed,
    size: Int = 512,
    pattern: AvatarPattern = .mesh,
    blur: Double? = nil
  ) -> Data? {
    guard
      let image = image(seed: seed, size: size, pattern: pattern, blur: blur),
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

  private static func rawMeshImage(seed: AvatarSeed, size: Int) -> CGImage? {
    guard let context = bitmapContext(size: size) else { return nil }
    let dimension = CGFloat(size)
    let bounds = CGRect(x: 0, y: 0, width: dimension, height: dimension)
    let palette = AvatarGenerator.palette(for: seed)
    var random = SeededRandom(seed: seed.rawValue &* 12_345)

    withTopLeftCoordinates(context, size: dimension) {
      context.setFillColor(palette.colors[0].cgColor)
      context.fill(bounds)

      let spotCount = 8 + Int(floor(random.next() * 5))
      var spots: [MeshSpot] = []
      spots.reserveCapacity(spotCount)

      for index in 0..<spotCount {
        let angle = random.next() * Double.pi * 2
        let distance = random.next() * Double(size) * 0.4
        let centerX = Double(size) / 2 + cos(angle) * distance
        let centerY = Double(size) / 2 + sin(angle) * distance
        spots.append(
          MeshSpot(
            index: index,
            x: centerX + (random.next() - 0.5) * Double(size) * 0.3,
            y: centerY + (random.next() - 0.5) * Double(size) * 0.3,
            radius: Double(size) * (0.3 + random.next() * 0.4),
            color: palette.colors[index % palette.colors.count]
          )
        )
      }

      spots.sort {
        if $0.radius == $1.radius {
          return $0.index < $1.index
        }
        return $0.radius > $1.radius
      }

      context.setBlendMode(.normal)
      for spot in spots {
        drawRadialGradient(
          context: context,
          bounds: bounds,
          center: CGPoint(x: spot.x, y: spot.y),
          radius: CGFloat(spot.radius),
          color: spot.color
        )
      }

      let highlightX = dimension * 0.3 + CGFloat(random.next()) * dimension * 0.2
      let highlightY = dimension * 0.3 + CGFloat(random.next()) * dimension * 0.2
      drawHighlight(
        context: context,
        center: CGPoint(x: highlightX, y: highlightY),
        radius: dimension * 0.3
      )
    }

    return context.makeImage()
  }

  private static func ditherImage(seed: AvatarSeed, size: Int) -> CGImage? {
    guard let context = bitmapContext(size: size) else { return nil }
    let dimension = CGFloat(size)
    let palette = AvatarGenerator.palette(for: seed)
    var random = SeededRandom(seed: seed.rawValue ^ 0x9E37_79B9)
    let cell = max(2, Int((Double(size) / 72).rounded()))
    let count = Int(ceil(Double(size) / Double(cell)))
    let angle = random.next() * Double.pi * 2
    let deltaX = cos(angle)
    let deltaY = sin(angle)
    let minimum = min(0, deltaX) + min(0, deltaY)
    let span = max(Double.leastNonzeroMagnitude, abs(deltaX) + abs(deltaY))

    withTopLeftCoordinates(context, size: dimension) {
      for gridY in 0..<count {
        for gridX in 0..<count {
          let pointX = (Double(gridX) + 0.5) / Double(count)
          let pointY = (Double(gridY) + 0.5) / Double(count)
          let value = (pointX * deltaX + pointY * deltaY - minimum) / span
          let scaled = value * Double(palette.colors.count - 1)
          let index = Int(floor(scaled))
          let fraction = scaled - Double(index)
          let threshold = bayer[gridY % 8][gridX % 8]
          let colorIndex =
            fraction > threshold
            ? min(index + 1, palette.colors.count - 1)
            : index
          context.setFillColor(palette.colors[colorIndex].cgColor)
          context.fill(
            CGRect(
              x: gridX * cell,
              y: gridY * cell,
              width: cell + 1,
              height: cell + 1
            )
          )
        }
      }
    }

    return context.makeImage()
  }

  private static func blurred(
    _ image: CGImage,
    size: Int,
    radius: Double
  ) -> CGImage? {
    guard radius > 0 else { return image }

    let dimension = CGFloat(size)
    let bounds = CGRect(x: 0, y: 0, width: dimension, height: dimension)
    let scale = 1 + (CGFloat(radius) / dimension) * 4
    let center = dimension / 2
    let transform =
      CGAffineTransform(translationX: center, y: center)
      .scaledBy(x: scale, y: scale)
      .translatedBy(x: -center, y: -center)
    let input = CIImage(cgImage: image)
      .transformed(by: transform)
      .clampedToExtent()
      .applyingGaussianBlur(sigma: radius)
      .cropped(to: bounds)
    return CIContext(options: [.cacheIntermediates: false])
      .createCGImage(input, from: bounds)
  }

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

  private static func withTopLeftCoordinates(
    _ context: CGContext,
    size: CGFloat,
    draw: () -> Void
  ) {
    context.saveGState()
    context.translateBy(x: 0, y: size)
    context.scaleBy(x: 1, y: -1)
    draw()
    context.restoreGState()
  }

  private static func drawRadialGradient(
    context: CGContext,
    bounds: CGRect,
    center: CGPoint,
    radius: CGFloat,
    color: AvatarColor
  ) {
    let channels = color.components
    let components: [CGFloat] = [
      channels.red, channels.green, channels.blue, 1,
      channels.red, channels.green, channels.blue, 0xDD.cgFloat / 255,
      channels.red, channels.green, channels.blue, 0x88.cgFloat / 255,
      channels.red, channels.green, channels.blue, 0,
    ]
    guard
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let gradient = CGGradient(
        colorSpace: colorSpace,
        colorComponents: components,
        locations: [0, 0.3, 0.6, 1],
        count: 4
      )
    else {
      return
    }

    context.saveGState()
    context.clip(to: bounds)
    context.drawRadialGradient(
      gradient,
      startCenter: center,
      startRadius: 0,
      endCenter: center,
      endRadius: radius,
      options: []
    )
    context.restoreGState()
  }

  private static func drawHighlight(
    context: CGContext,
    center: CGPoint,
    radius: CGFloat
  ) {
    guard
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let gradient = CGGradient(
        colorSpace: colorSpace,
        colorComponents: [
          1, 1, 1, 0.15,
          1, 1, 1, 0,
        ],
        locations: [0, 1],
        count: 2
      )
    else {
      return
    }
    context.drawRadialGradient(
      gradient,
      startCenter: center,
      startRadius: 0,
      endCenter: center,
      endRadius: radius,
      options: []
    )
  }

  private static let bayer: [[Double]] = {
    var matrix = [[0]]
    for _ in 0..<3 {
      let currentSize = matrix.count
      var next = Array(
        repeating: Array(repeating: 0, count: currentSize * 2),
        count: currentSize * 2
      )
      for y in 0..<(currentSize * 2) {
        for x in 0..<(currentSize * 2) {
          let base = matrix[y % currentSize][x % currentSize] * 4
          let addition =
            x < currentSize
            ? (y < currentSize ? 0 : 3)
            : (y < currentSize ? 2 : 1)
          next[y][x] = base + addition
        }
      }
      matrix = next
    }
    let maximum = Double(matrix.count * matrix.count)
    return matrix.map { row in
      row.map { (Double($0) + 0.5) / maximum }
    }
  }()
}

private struct MeshSpot {
  let index: Int
  let x: Double
  let y: Double
  let radius: Double
  let color: AvatarColor
}

extension Int {
  fileprivate var cgFloat: CGFloat {
    CGFloat(self)
  }
}
