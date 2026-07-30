import Foundation

/// Absolute date/time labels for resource stamps. Relative ages stay elsewhere.
///
/// Semantic slots:
/// - `dateOnly` — registration, expiry, account created, R2 bucket created
/// - `dateAndTime` — audit, tunnel connection, R2 uploaded, email added/verified
enum DashDateFormatting {
  static func dateOnly(
    fromISO8601 value: String,
    preference: DashTimeFormatPreference = .current,
    locale: Locale = DashL10n.activeLocale,
    timeZone: TimeZone = .current
  ) -> String {
    guard let date = ExpiryReminders.date(fromISO8601: value) else {
      return String(value.prefix(10))
    }
    return dateOnly(date, preference: preference, locale: locale, timeZone: timeZone)
  }

  static func dateOnly(
    _ date: Date,
    preference: DashTimeFormatPreference = .current,
    locale: Locale = DashL10n.activeLocale,
    timeZone: TimeZone = .current
  ) -> String {
    formatter(
      preference: preference,
      locale: locale,
      timeZone: timeZone,
      includesTime: false
    ).string(from: date)
  }

  static func dateAndTime(
    fromISO8601 value: String,
    preference: DashTimeFormatPreference = .current,
    locale: Locale = DashL10n.activeLocale,
    timeZone: TimeZone = .current
  ) -> String {
    guard let date = ExpiryReminders.date(fromISO8601: value) else {
      return String(value.prefix(10))
    }
    return dateAndTime(date, preference: preference, locale: locale, timeZone: timeZone)
  }

  static func dateAndTime(
    _ date: Date,
    preference: DashTimeFormatPreference = .current,
    locale: Locale = DashL10n.activeLocale,
    timeZone: TimeZone = .current
  ) -> String {
    formatter(
      preference: preference,
      locale: locale,
      timeZone: timeZone,
      includesTime: true
    ).string(from: date)
  }

  private static func formatter(
    preference: DashTimeFormatPreference,
    locale: Locale,
    timeZone: TimeZone,
    includesTime: Bool
  ) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.timeZone = timeZone
    switch preference {
    case .iso:
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.dateFormat = includesTime ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"
    case .system, .twelveHour, .twentyFourHour:
      formatter.locale = displayLocale(for: preference, base: locale)
      formatter.dateStyle = .medium
      formatter.timeStyle = includesTime ? .short : .none
    }
    return formatter
  }

  /// Date shape follows the in-app language locale; hour cycle follows the
  /// preference (System borrows the iPhone's 24-Hour Time setting).
  private static func displayLocale(
    for preference: DashTimeFormatPreference,
    base: Locale
  ) -> Locale {
    var components = Locale.Components(locale: base)
    switch preference {
    case .system:
      components.hourCycle = Locale.autoupdatingCurrent.hourCycle
    case .twelveHour:
      components.hourCycle = .oneToTwelve
    case .twentyFourHour:
      components.hourCycle = .zeroToTwentyThree
    case .iso:
      break
    }
    return Locale(components: components)
  }
}
