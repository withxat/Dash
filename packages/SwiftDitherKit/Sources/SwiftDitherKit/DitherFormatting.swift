import Foundation

/// Locale-aware formatting presets for axes, tooltips, and accessibility values.
public enum DitherValueFormat: Hashable, Sendable {
  /// Compact values above one thousand, while preserving up to two fractional digits below it.
  case automatic
  /// A regular number with the requested maximum number of fractional digits.
  case number(maximumFractionDigits: Int = 2)
  /// A compact localized number such as `1.2K` in supported locales.
  case compact
  /// A percentage where `1` represents one hundred percent.
  case percent(maximumFractionDigits: Int = 1)
  /// A localized currency value for an ISO 4217 currency code.
  case currency(code: String, maximumFractionDigits: Int = 2)
  /// A localized byte count such as `4.2 MB`, for series measured in bytes.
  case byteCount(style: ByteCountFormatStyle.Style = .binary)

  func string(_ value: Double, locale: Locale) -> String {
    let finiteValue = value.isFinite ? value : 0
    switch self {
    case .automatic:
      if abs(finiteValue) >= 1_000 {
        return finiteValue.formatted(
          .number
            .notation(.compactName)
            .precision(.fractionLength(0...1))
            .locale(locale)
        )
      }
      return finiteValue.formatted(
        .number
          .precision(.fractionLength(0...2))
          .locale(locale)
      )
    case .number(let maximumFractionDigits):
      return finiteValue.formatted(
        .number
          .precision(.fractionLength(0...max(0, maximumFractionDigits)))
          .locale(locale)
      )
    case .compact:
      return finiteValue.formatted(
        .number
          .notation(.compactName)
          .precision(.fractionLength(0...1))
          .locale(locale)
      )
    case .percent(let maximumFractionDigits):
      return finiteValue.formatted(
        .percent
          .precision(.fractionLength(0...max(0, maximumFractionDigits)))
          .locale(locale)
      )
    case .currency(let code, let maximumFractionDigits):
      return finiteValue.formatted(
        .currency(code: code)
          .precision(.fractionLength(0...max(0, maximumFractionDigits)))
          .locale(locale)
      )
    case .byteCount(let style):
      // `.byteCount` needs an integer, and Double(Int64.max) overflows on the
      // way back, so clamp well inside the representable range first.
      let bytes = Int64(min(max(finiteValue.rounded(), -9e18), 9e18))
      return bytes.formatted(.byteCount(style: style).locale(locale))
    }
  }
}
