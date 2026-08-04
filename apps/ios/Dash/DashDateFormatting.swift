import Foundation

/// Absolute date/time labels for resource stamps. Relative ages stay elsewhere.
///
/// Semantic slots:
/// - `dateOnly` — registration, expiry, account created, R2 bucket created
/// - `dateAndTime` — audit, tunnel connection, R2 uploaded, email added/verified
enum DashDateFormatting {
  static func dateOnly(
    fromISO8601 value: String,
    locale: Locale = DashL10n.activeLocale,
    timeZone: TimeZone = .current
  ) -> String {
    guard let date = date(fromISO8601: value) else {
      return String(value.prefix(10))
    }
    return dateOnly(date, locale: locale, timeZone: timeZone)
  }

  static func dateOnly(
    _ date: Date,
    locale: Locale = DashL10n.activeLocale,
    timeZone: TimeZone = .current
  ) -> String {
    formatter(
      locale: locale,
      timeZone: timeZone,
      includesTime: false
    ).string(from: date)
  }

  static func dateAndTime(
    fromISO8601 value: String,
    locale: Locale = DashL10n.activeLocale,
    timeZone: TimeZone = .current
  ) -> String {
    guard let date = date(fromISO8601: value) else {
      return String(value.prefix(10))
    }
    return dateAndTime(date, locale: locale, timeZone: timeZone)
  }

  static func dateAndTime(
    _ date: Date,
    locale: Locale = DashL10n.activeLocale,
    timeZone: TimeZone = .current
  ) -> String {
    formatter(
      locale: locale,
      timeZone: timeZone,
      includesTime: true
    ).string(from: date)
  }

  /// Parses Cloudflare and RDAP timestamps with or without fractional seconds.
  /// WHOIS occasionally returns a bare calendar day.
  static func date(fromISO8601 value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    if let date = fractional.date(from: value) ?? plain.date(from: value) {
      return date
    }
    let day = DateFormatter()
    day.locale = Locale(identifier: "en_US_POSIX")
    day.timeZone = TimeZone(identifier: "UTC")
    day.dateFormat = "yyyy-MM-dd"
    return day.date(from: String(value.prefix(10)))
  }

  private static func formatter(
    locale: Locale,
    timeZone: TimeZone,
    includesTime: Bool
  ) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.timeZone = timeZone
    formatter.dateStyle = .medium
    formatter.timeStyle = includesTime ? .short : .none
    return formatter
  }
}
