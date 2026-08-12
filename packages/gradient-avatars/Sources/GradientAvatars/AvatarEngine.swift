import CoreGraphics
import Foundation

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

  /// The lowercase hexadecimal representation used by the upstream engine.
  public var hex: String {
    let digits = Array("0123456789abcdef")
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

/// A color in Oklch, the space the palette is generated in.
///
/// Hue stays constant across a palette while lightness and chroma vary, which
/// is what gives an avatar one colour family instead of a spectrum.
public struct AvatarOklch: Hashable, Sendable {
  public let lightness: Double
  public let chroma: Double
  public let hue: Double

  public init(lightness: Double, chroma: Double, hue: Double) {
    self.lightness = lightness
    self.chroma = chroma
    self.hue = hue
  }

  /// Converts to gamut-clipped sRGB.
  public var color: AvatarColor {
    let radians = hue * .pi / 180
    let a = chroma * cos(radians)
    let b = chroma * sin(radians)

    let long = lightness + 0.396_337_777_4 * a + 0.215_803_757_3 * b
    let medium = lightness - 0.105_561_345_8 * a - 0.063_854_172_8 * b
    let short = lightness - 0.089_484_177_5 * a - 1.291_485_548_0 * b

    let longCubed = long * long * long
    let mediumCubed = medium * medium * medium
    let shortCubed = short * short * short

    let linearRed =
      4.076_741_662_1 * longCubed - 3.307_711_591_3 * mediumCubed
      + 0.230_969_929_2 * shortCubed
    let linearGreen =
      -1.268_438_004_6 * longCubed + 2.609_757_401_1 * mediumCubed
      - 0.341_319_396_5 * shortCubed
    let linearBlue =
      -0.004_196_086_3 * longCubed - 0.703_418_614_7 * mediumCubed
      + 1.707_614_701_0 * shortCubed

    func channel(_ value: Double) -> UInt8 {
      let clamped = min(max(value, 0), 1)
      let encoded =
        clamped <= 0.003_130_8
        ? clamped * 12.92
        : 1.055 * pow(clamped, 1 / 2.4) - 0.055
      return UInt8(clamping: Int((encoded * 255).rounded()))
    }

    return AvatarColor(
      red: channel(linearRed),
      green: channel(linearGreen),
      blue: channel(linearBlue)
    )
  }
}

/// The deterministic colors generated for an avatar seed.
public struct AvatarPalette: Hashable, Sendable {
  public let seed: UInt32
  public let oklch: [AvatarOklch]
  public let colors: [AvatarColor]

  public init(seed: UInt32, oklch: [AvatarOklch]) {
    self.seed = seed
    self.oklch = oklch
    self.colors = oklch.map(\.color)
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
  /// Separates the layer geometry stream from the palette stream.
  ///
  /// Upstream re-hashes the decimal text of its first four seeds, which cannot
  /// be reproduced without JavaScript's number formatting. Salting one stream
  /// gives the same independence with a rule Swift can state.
  static let geometrySalt: UInt32 = 0x9E37_79B9

  /// Hashes a string exactly like `hashvatar`: FNV-1a over the trimmed,
  /// lowercased input.
  ///
  /// Two JavaScript details are reproduced on purpose, because an avatar is an
  /// identity and the two implementations have to agree on it. The upstream
  /// hashes UTF-16 code units, so this iterates `utf16` rather than Swift
  /// `Character` values or UTF-8 bytes. It also multiplies with `*` instead of
  /// `Math.imul`, and the FNV product reaches 2⁵⁶ where a `Double` can no
  /// longer hold every integer, so the low bits are rounded away before the
  /// result is folded back to 32 bits. Doing the multiply exactly would be the
  /// textbook FNV-1a and would disagree with the reference on most inputs.
  public static func seed(from input: String) -> UInt32 {
    let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    var hash = Double(2_166_136_261)
    for codeUnit in normalized.utf16 {
      hash = Double(int32(hash) ^ Int32(codeUnit))
      hash = Double(uint32(hash * 16_777_619))
    }
    return uint32(hash)
  }

  /// JavaScript's `ToInt32`: truncate, wrap into 32 bits, read as signed.
  private static func int32(_ value: Double) -> Int32 {
    Int32(bitPattern: uint32(value))
  }

  /// JavaScript's `ToUint32`.
  private static func uint32(_ value: Double) -> UInt32 {
    guard value.isFinite else { return 0 }
    var wrapped = value.rounded(.towardZero)
      .truncatingRemainder(dividingBy: 4_294_967_296)
    if wrapped < 0 { wrapped += 4_294_967_296 }
    return UInt32(wrapped)
  }

  /// Draws `count` deterministic values in `[0, 1)` from a seed.
  public static func seeds(
    for seed: AvatarSeed,
    count: Int,
    salt: UInt32 = 0
  ) -> [Double] {
    guard count > 0 else { return [] }
    var random = SeededRandom(seed: seed.rawValue ^ salt)
    return (0..<count).map { _ in random.next() }
  }

  /// Derives the stable palette for a string seed.
  public static func palette(for seed: String, count: Int = 2) -> AvatarPalette {
    palette(for: AvatarSeed(seed), count: count)
  }

  /// Derives the stable palette for a numeric seed.
  public static func palette(for seed: UInt32, count: Int = 2) -> AvatarPalette {
    palette(for: AvatarSeed(seed), count: count)
  }

  /// Derives the stable palette for a normalized seed.
  ///
  /// Passing `tones` restricts the result to those hue families; the default
  /// keeps one hue drawn from the seed and varies only lightness and chroma.
  public static func palette(
    for seed: AvatarSeed,
    count: Int = 2,
    tones: [AvatarOklch]? = nil
  ) -> AvatarPalette {
    let count = max(1, count)
    let seeds = seeds(for: seed, count: count * 3)
    let tones = (tones?.isEmpty ?? true) ? nil : tones
    let baseHue =
      tones == nil
      ? (seeds[0] * 360).truncatingRemainder(dividingBy: 360)
      : nil
    let oklch = (0..<count).map { index in
      color(
        seed: seeds[index * 3],
        lightnessSeed: seeds[index * 3 + 1],
        chromaSeed: seeds[index * 3 + 2],
        tones: tones,
        isSecondary: index > 0,
        baseHue: baseHue
      )
    }
    return AvatarPalette(seed: seed.rawValue, oklch: oklch)
  }

  private static func color(
    seed: Double,
    lightnessSeed: Double,
    chromaSeed: Double,
    tones: [AvatarOklch]?,
    isSecondary: Bool,
    baseHue: Double?
  ) -> AvatarOklch {
    let hue: Double
    let lightness: Double
    let chroma: Double

    if let tones, !tones.isEmpty {
      let index = Int(floor(seed * Double(tones.count))) % tones.count
      let tone = tones[index]
      hue = (tone.hue + (seed * 2 - 1) * 30 + 360).truncatingRemainder(dividingBy: 360)
      lightness = isSecondary ? 0.22 + lightnessSeed * 0.18 : 0.52 + lightnessSeed * 0.22
      chroma =
        isSecondary
        ? max(tone.chroma * 0.5, 0.06) + chromaSeed * 0.08
        : max(tone.chroma * 0.8, 0.14) + chromaSeed * 0.10
    } else {
      hue = ((baseHue ?? seed * 360) + 360).truncatingRemainder(dividingBy: 360)
      if isSecondary {
        // The secondary reads the two seeds in the opposite order. Upstream
        // does the same, and swapping them back reshuffles every avatar.
        lightness = 0.18 + chromaSeed * 0.20
        chroma = 0.08 + lightnessSeed * 0.12
      } else {
        lightness = 0.55 + lightnessSeed * 0.22
        chroma = 0.18 + chromaSeed * 0.18
      }
    }

    return AvatarOklch(lightness: lightness, chroma: min(chroma, 0.37), hue: hue)
  }
}

/// Mulberry32, the PRNG the upstream generator seeds from its hash.
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
