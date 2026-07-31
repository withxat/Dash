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
    guard let date = ExpiryReminders.date(fromISO8601: value) else {
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
    guard let date = ExpiryReminders.date(fromISO8601: value) else {
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
