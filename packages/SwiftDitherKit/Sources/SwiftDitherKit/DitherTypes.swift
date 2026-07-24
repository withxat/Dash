import CoreGraphics
import Foundation

/// A portable RGB colour used by the dither renderer.
///
/// SwiftDitherKit includes the seven colours from the original Dither Kit
/// palette as static presets, while this value type also accepts application
/// brand colours.
public struct DitherColor: Hashable, Sendable {
  public let red: Double
  public let green: Double
  public let blue: Double

  /// Creates a colour from finite component values in the closed range `0...1`.
  /// Values outside that range are clamped.
  public init(red: Double, green: Double, blue: Double) {
    self.red = Self.clamp(red)
    self.green = Self.clamp(green)
    self.blue = Self.clamp(blue)
  }

  /// Creates a colour from a six-digit RGB value such as `0x358FF3`.
  public init(hex: UInt32) {
    self.init(
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255
    )
  }

  public static let green = DitherColor(hex: 0x28D26E)
  public static let blue = DitherColor(hex: 0x358FF3)
  public static let purple = DitherColor(hex: 0x966EFF)
  public static let pink = DitherColor(hex: 0xF05ABE)
  public static let orange = DitherColor(hex: 0xFF9632)
  public static let red = DitherColor(hex: 0xF04646)
  public static let grey = DitherColor(hex: 0x5C5C64)

  private static func clamp(_ component: Double) -> Double {
    guard component.isFinite else { return 0 }
    return min(1, max(0, component))
  }
}

/// How occupied cells are selected inside a chart shape.
public enum DitherVariant: String, CaseIterable, Hashable, Sendable {
  case gradient
  case dotted
  case hatched
  case solid
}

/// Optional glow made from a blurred copy of the low-resolution raster.
public enum DitherBloom: String, CaseIterable, Hashable, Sendable {
  case off
  case low
  case high
  case aura
}

/// How multiple cartesian series share the value axis.
public enum DitherStacking: String, CaseIterable, Hashable, Sendable {
  /// Every series starts at zero and overlaps the other series.
  case overlaid
  /// Positive values stack above zero and negative values stack below zero.
  case stacked
  /// Like ``stacked``, with each sign independently normalized to one.
  case percent
}

/// Insets reserved for labels and chart chrome around the pixel raster.
public struct DitherMargins: Hashable, Sendable {
  public var top: CGFloat
  public var trailing: CGFloat
  public var bottom: CGFloat
  public var leading: CGFloat

  public init(
    top: CGFloat = 10,
    trailing: CGFloat = 12,
    bottom: CGFloat = 24,
    leading: CGFloat = 38
  ) {
    self.top = top
    self.trailing = trailing
    self.bottom = bottom
    self.leading = leading
  }

  public static let cartesian = DitherMargins()
  public static let sparkline = DitherMargins(top: 0, trailing: 0, bottom: 0, leading: 0)
  public static let polar = DitherMargins(top: 14, trailing: 14, bottom: 14, leading: 14)
}

/// One category along a cartesian chart's x-axis, or one spoke on a radar chart.
///
/// IDs must remain stable for as long as the chart is displayed. Values whose
/// series key is absent, infinite, or NaN are treated as zero.
public struct DitherDatum: Identifiable, Hashable, Sendable {
  public let id: String
  public let label: String
  public let values: [String: Double]

  public init(id: String, label: String, values: [String: Double]) {
    self.id = id
    self.label = label
    self.values = values
  }

  public subscript(seriesID: String) -> Double {
    guard let value = values[seriesID], value.isFinite else { return 0 }
    return value
  }
}

/// Visual configuration for one area, line, bar, or radar series.
public struct DitherSeries: Identifiable, Hashable, Sendable {
  public let id: String
  public let label: String
  public let color: DitherColor
  public let variant: DitherVariant

  public init(
    id: String,
    label: String? = nil,
    color: DitherColor,
    variant: DitherVariant = .gradient
  ) {
    self.id = id
    self.label = label ?? id
    self.color = color
    self.variant = variant
  }
}

/// One wedge in a pie or donut chart.
///
/// Negative, infinite, and NaN values are treated as zero when rendered.
public struct DitherSlice: Identifiable, Hashable, Sendable {
  public let id: String
  public let label: String
  public let value: Double
  public let color: DitherColor
  public let variant: DitherVariant

  public init(
    id: String,
    label: String? = nil,
    value: Double,
    color: DitherColor,
    variant: DitherVariant = .gradient
  ) {
    self.id = id
    self.label = label ?? id
    self.value = value
    self.color = color
    self.variant = variant
  }
}

struct DitherRGB: Hashable, Sendable {
  let red: UInt8
  let green: UInt8
  let blue: UInt8
}

enum DitherPalette {
  static func fill(for color: DitherColor) -> DitherRGB {
    DitherRGB(
      red: byte(color.red),
      green: byte(color.green),
      blue: byte(color.blue)
    )
  }

  private static func byte(_ component: Double) -> UInt8 {
    UInt8((component * 255).rounded())
  }
}

enum DitherChartKind: Hashable, Sendable {
  case area
  case line
  case bar
}

struct DitherBloomStyle: Hashable, Sendable {
  let blur: CGFloat
  let brightness: Double
  let opacity: Double
  let saturation: Double
}

extension DitherBloom {
  var style: DitherBloomStyle? {
    switch self {
    case .off:
      nil
    case .low:
      DitherBloomStyle(blur: 3, brightness: 0.08, opacity: 0.70, saturation: 1.4)
    case .high:
      DitherBloomStyle(blur: 5, brightness: 0.14, opacity: 0.78, saturation: 1.5)
    case .aura:
      DitherBloomStyle(blur: 15, brightness: 0.35, opacity: 0.10, saturation: 3)
    }
  }
}
