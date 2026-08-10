import Foundation

enum DashChartTrendDirection: Hashable, Sendable {
  case up
  case down
  case flat
}

/// One Bold ↗ mark states every chart-trend direction. `.up` is upright;
/// `.down` is that same glyph 90° clockwise (↘). Swapping two assets cannot
/// rotate, so range-tab changes would only cross-fade — one identity lets the
/// tip swing and the tint recolor together. Flat has no mark.
enum DashChartTrendArrowRules {
  /// Degrees clockwise from the upright ↗ Bold asset. Nil when no arrow.
  static func rotationDegrees(for direction: DashChartTrendDirection) -> Double? {
    switch direction {
    case .up: 0
    case .down: 90
    case .flat: nil
    }
  }
}

/// Period comparison shared by app charts and WidgetKit so direction,
/// zero-baseline handling, and localized percentages cannot drift.
struct DashChartTrendComparison: Hashable, Sendable {
  let direction: DashChartTrendDirection
  let percentChange: Double?

  init?(current: Double, previous: Double?) {
    guard current.isFinite, let previous, previous.isFinite else { return nil }

    if current > previous {
      direction = .up
    } else if current < previous {
      direction = .down
    } else {
      direction = .flat
    }

    if previous == 0 {
      percentChange = current == 0 ? 0 : nil
    } else {
      let comparison = (current - previous) / abs(previous)
      percentChange = comparison.isFinite ? comparison : nil
    }
  }

  func formattedPercentage(locale: Locale) -> String? {
    guard let percentChange else { return nil }
    let magnitude = abs(percentChange).formatted(
      .percent
        .precision(.fractionLength(0...1))
        .locale(locale))
    switch direction {
    case .up: return "+\(magnitude)"
    case .down: return "−\(magnitude)"
    case .flat: return magnitude
    }
  }
}

enum DashChartTrendColorConvention: Hashable, Sendable {
  case redUpGreenDown
  case greenUpRedDown

  static func resolved(locale: Locale) -> Self {
    locale.language.languageCode?.identifier == "zh"
      ? .redUpGreenDown
      : .greenUpRedDown
  }
}

struct DashChartTrendColorToken: Hashable, Sendable {
  let light: UInt32
  let dark: UInt32
  let highLight: UInt32
  let highDark: UInt32

  func hex(isDark: Bool, increasedContrast: Bool) -> UInt32 {
    switch (isDark, increasedContrast) {
    case (false, false): light
    case (true, false): dark
    case (false, true): highLight
    case (true, true): highDark
    }
  }
}

enum DashChartTrendColorTokens {
  static let green = DashChartTrendColorToken(
    light: 0x008236,
    dark: 0x7BF1A8,
    highLight: 0x006045,
    highDark: 0xA4F4CF)
  static let red = DashChartTrendColorToken(
    light: 0xC10007,
    dark: 0xFF6467,
    highLight: 0xC10007,
    highDark: 0xFFA2A2)
}
