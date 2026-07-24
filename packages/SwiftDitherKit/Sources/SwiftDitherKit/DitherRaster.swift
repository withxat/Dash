import CoreGraphics
import Foundation

struct DitherRaster: Equatable, Sendable {
  let width: Int
  let height: Int
  private(set) var bytes: [UInt8]

  init(width: Int, height: Int) {
    self.width = max(1, width)
    self.height = max(1, height)
    self.bytes = Array(repeating: 0, count: max(1, width) * max(1, height) * 4)
  }

  mutating func blend(_ color: DitherRGB, alpha: Double, x: Int, y: Int) {
    guard x >= 0, x < width, y >= 0, y < height else { return }
    let sourceAlpha = min(1, max(0, alpha))
    guard sourceAlpha > 0 else { return }

    let offset = (y * width + x) * 4
    let destinationAlpha = Double(bytes[offset + 3]) / 255
    let inverse = 1 - sourceAlpha
    let outputAlpha = sourceAlpha + destinationAlpha * inverse

    let sourceRed = Double(color.red) / 255 * sourceAlpha
    let sourceGreen = Double(color.green) / 255 * sourceAlpha
    let sourceBlue = Double(color.blue) / 255 * sourceAlpha
    let destinationRed = Double(bytes[offset]) / 255
    let destinationGreen = Double(bytes[offset + 1]) / 255
    let destinationBlue = Double(bytes[offset + 2]) / 255

    bytes[offset] = Self.byte(sourceRed + destinationRed * inverse)
    bytes[offset + 1] = Self.byte(sourceGreen + destinationGreen * inverse)
    bytes[offset + 2] = Self.byte(sourceBlue + destinationBlue * inverse)
    bytes[offset + 3] = Self.byte(outputAlpha)
  }

  func alpha(x: Int, y: Int) -> UInt8 {
    guard x >= 0, x < width, y >= 0, y < height else { return 0 }
    return bytes[(y * width + x) * 4 + 3]
  }

  var nonTransparentPixelCount: Int {
    stride(from: 3, to: bytes.count, by: 4).reduce(into: 0) { count, offset in
      if bytes[offset] > 0 { count += 1 }
    }
  }

  var checksum: UInt64 {
    bytes.reduce(1_469_598_103_934_665_603) { hash, byte in
      (hash ^ UInt64(byte)) &* 1_099_511_628_211
    }
  }

  func makeCGImage() -> CGImage? {
    let data = Data(bytes)
    guard let provider = CGDataProvider(data: data as CFData) else { return nil }
    let alpha = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    let bitmapInfo = alpha.union(.byteOrder32Big)
    return CGImage(
      width: width,
      height: height,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: bitmapInfo,
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    )
  }

  private static func byte(_ unit: Double) -> UInt8 {
    UInt8(min(255, max(0, Int((unit * 255).rounded()))))
  }
}

enum DitherKernel {
  static let cellSize: CGFloat = 2
  static let maximumColumns = 520
  static let maximumRows = 200
  static let borderAlpha = 0.72
  static let offTier = 0.4

  private static let bayer: [Double] = [
    0, 8, 2, 10,
    12, 4, 14, 6,
    3, 11, 1, 9,
    15, 7, 13, 5,
  ].map { ($0 + 0.5) / 16 }

  static func threshold(x: Int, y: Int) -> Double {
    bayer[(y & 3) * 4 + (x & 3)]
  }

  static func backingSize(width: CGFloat, height: CGFloat) -> (columns: Int, rows: Int) {
    let columns = min(maximumColumns, max(8, Int((width / cellSize).rounded())))
    let rows = min(maximumRows, max(8, Int((height / cellSize).rounded())))
    return (columns, rows)
  }

  static func paintColumn(
    raster: inout DitherRaster,
    x: Int,
    top: Double,
    floor: Double,
    color: DitherRGB,
    variant: DitherVariant,
    intensity: Double,
    dim: Double,
    stacked: Bool,
    sparse: Double = 0
  ) {
    let topRow = Int(top.rounded())
    let floorRow = Int(floor.rounded())
    let depth = floorRow - topRow

    guard depth > 0 else {
      raster.blend(color, alpha: borderAlpha * dim, x: x, y: topRow)
      return
    }

    let bias = (variant == .dotted ? 0.12 : 0) + (stacked ? 0.2 : 0) - sparse
    for y in topRow..<floorRow {
      var density = Double(y - topRow) / Double(depth)
      if stacked { density = 0.5 + 0.5 * density }
      if variant == .hatched, ((x + y) & 3) >= 2 { continue }

      let lit =
        variant == .solid
        || density > threshold(x: x, y: y) - 0.1 * intensity - bias
      if variant == .dotted, !lit { continue }

      let strength = (0.3 + density * 0.7) * (1 + 0.22 * intensity)
      let alpha = min(1, max(0, (lit ? strength : strength * offTier) * dim))
      raster.blend(color, alpha: alpha, x: x, y: y)
    }

    raster.blend(color, alpha: borderAlpha * dim, x: x, y: topRow)
    if depth > 1 {
      raster.blend(color, alpha: borderAlpha * 0.5 * dim, x: x, y: topRow + 1)
    }
  }
}
