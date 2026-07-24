import CoreGraphics
import Foundation

/// The color-harmony rule used to derive an avatar palette.
public enum AvatarHarmony: String, CaseIterable, Sendable {
  case analogous
  case triadic
  case splitComplementary
  case tetradic
  case complementary
}

/// An sRGB color represented as eight-bit channels.
public struct AvatarColor: Hashable, Sendable {
  public let red: UInt8
  public let green: UInt8
  public let blue: UInt8

  public init(red: UInt8, green: UInt8, blue: UInt8) {
    self.red = red
    self.green = green
    self.blue = blue
  }

  /// The uppercase hexadecimal representation used by the upstream engine.
  public var hex: String {
    let digits = Array("0123456789ABCDEF")
    let values = [red, green, blue]
    return "#"
      + values.flatMap { value in
        [digits[Int(value >> 4)], digits[Int(value & 0x0F)]]
      }
  }

  public var cgColor: CGColor {
    CGColor(
      srgbRed: CGFloat(red) / 255,
      green: CGFloat(green) / 255,
      blue: CGFloat(blue) / 255,
      alpha: 1
    )
  }

  var components: (red: CGFloat, green: CGFloat, blue: CGFloat) {
    (
      CGFloat(red) / 255,
      CGFloat(green) / 255,
      CGFloat(blue) / 255
    )
  }
}

/// The deterministic colors and harmony generated for an avatar seed.
public struct AvatarPalette: Hashable, Sendable {
  public let seed: UInt32
  public let colors: [AvatarColor]
  public let harmony: AvatarHarmony

  public init(seed: UInt32, colors: [AvatarColor], harmony: AvatarHarmony) {
    self.seed = seed
    self.colors = colors
    self.harmony = harmony
  }
}

/// A normalized 32-bit seed accepted by the avatar engine.
public struct AvatarSeed: Hashable, Sendable {
  public let rawValue: UInt32

  public init(rawValue: UInt32) {
    self.rawValue = rawValue
  }

  public init(_ value: UInt32) {
    self.init(rawValue: value)
  }

  public init(_ value: String) {
    self.init(rawValue: AvatarGenerator.seed(from: value))
  }
}

extension AvatarSeed: ExpressibleByStringLiteral {
  public init(stringLiteral value: String) {
    self.init(value)
  }
}

extension AvatarSeed: ExpressibleByIntegerLiteral {
  public init(integerLiteral value: UInt32) {
    self.init(value)
  }
}

/// Pure deterministic helpers shared by the renderers.
public enum AvatarGenerator {
  private static let goldenAngle = 137.5

  /// Hashes a string exactly like `@outpacelabs/avatars`.
  ///
  /// JavaScript hashes UTF-16 code units, so this intentionally does the same
  /// instead of iterating Swift `Character` values or UTF-8 bytes.
  public static func seed(from input: String) -> UInt32 {
    var hash: UInt32 = 2_166_136_261
    for codeUnit in input.utf16 {
      hash ^= UInt32(codeUnit)
      hash = hash &* 16_777_619
    }
    hash ^= hash >> 16
    hash = hash &* 0x7FEB_352D
    hash ^= hash >> 15
    hash = hash &* 0x846C_A68B
    hash ^= hash >> 16
    return hash
  }

  /// Derives the stable palette for a string seed.
  public static func palette(for seed: String) -> AvatarPalette {
    palette(for: AvatarSeed(seed))
  }

  /// Derives the stable palette for a numeric seed.
  public static func palette(for seed: UInt32) -> AvatarPalette {
    palette(for: AvatarSeed(seed))
  }

  /// Derives the stable palette for a normalized seed.
  public static func palette(for seed: AvatarSeed) -> AvatarPalette {
    let numericSeed = seed.rawValue
    var random = SeededRandom(seed: numericSeed)
    let baseHue =
      (Double(numericSeed) * goldenAngle)
      .truncatingRemainder(dividingBy: 360)
    let harmonies = AvatarHarmony.allCases
    let harmonyIndex = Int(floor(random.next() * Double(harmonies.count)))
    let harmony = harmonies[harmonyIndex]
    let colors = hues(baseHue: baseHue, harmony: harmony).map { hue in
      let saturation = 75 + random.next() * 25
      let lightness = 50 + random.next() * 20
      return hslToColor(hue: hue, saturation: saturation, lightness: lightness)
    }
    return AvatarPalette(seed: numericSeed, colors: colors, harmony: harmony)
  }

  private static func hues(baseHue: Double, harmony: AvatarHarmony) -> [Double] {
    switch harmony {
    case .analogous:
      [baseHue, baseHue + 30, baseHue + 60, baseHue - 30]
    case .triadic:
      [baseHue, baseHue + 120, baseHue + 240]
    case .splitComplementary:
      [baseHue, baseHue + 150, baseHue + 210]
    case .tetradic:
      [baseHue, baseHue + 90, baseHue + 180, baseHue + 270]
    case .complementary:
      [baseHue, baseHue + 180, baseHue + 20, baseHue + 200]
    }
  }

  private static func hslToColor(
    hue: Double,
    saturation: Double,
    lightness: Double
  ) -> AvatarColor {
    let normalizedHue =
      (hue.truncatingRemainder(dividingBy: 360) + 360)
      .truncatingRemainder(dividingBy: 360)
    let normalizedSaturation = min(100, max(0, saturation)) / 100
    let normalizedLightness = min(100, max(0, lightness)) / 100

    let chroma =
      (1 - abs(2 * normalizedLightness - 1))
      * normalizedSaturation
    let secondary =
      chroma
      * (1 - abs((normalizedHue / 60).truncatingRemainder(dividingBy: 2) - 1))
    let match = normalizedLightness - chroma / 2

    let channels: (Double, Double, Double)
    switch normalizedHue {
    case ..<60:
      channels = (chroma, secondary, 0)
    case ..<120:
      channels = (secondary, chroma, 0)
    case ..<180:
      channels = (0, chroma, secondary)
    case ..<240:
      channels = (0, secondary, chroma)
    case ..<300:
      channels = (secondary, 0, chroma)
    default:
      channels = (chroma, 0, secondary)
    }

    func byte(_ value: Double) -> UInt8 {
      UInt8(clamping: Int(((value + match) * 255).rounded()))
    }

    return AvatarColor(
      red: byte(channels.0),
      green: byte(channels.1),
      blue: byte(channels.2)
    )
  }
}

struct SeededRandom {
  private var state: UInt32

  init(seed: UInt32) {
    state = seed
  }

  mutating func next() -> Double {
    state &+= 0x6D2B_79F5
    var value = state
    value = (value ^ (value >> 15)) &* (value | 1)
    value ^= value &+ ((value ^ (value >> 7)) &* (value | 61))
    let result = value ^ (value >> 14)
    return Double(result) / 4_294_967_296
  }
}
