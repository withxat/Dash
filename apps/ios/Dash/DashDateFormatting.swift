import Foundation

/// Parsing and presentation for Cloudflare resource timestamps.
///
/// Semantic slots:
/// - `dateOnly` — registration, expiry, account created, R2 bucket created
/// - `dateAndTime` — audit, tunnel connection, R2 uploaded, email added/verified
/// - `fullRelativeTime` — readable Watchtower, build, and tunnel ages
/// - `abbreviatedRelativeTime` — compact Worker, Pages, and widget ages
enum DashDateFormatting {
  static func dateOnly(
    fromISO8601 value: String,
    locale: Locale = DashL10n.activeLocale,
    timeZone: TimeZone = .current
  ) -> String {
    if let day = date(fromCalendarDay: value, timeZone: timeZone) {
      return dateOnly(day, locale: locale, timeZone: timeZone)
    }
    guard let date = date(fromInternetTimestamp: value) else {
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

  /// Parses Cloudflare and RDAP internet timestamps with or without fractional
  /// seconds, plus exact bare calendar days in the current time zone.
  ///
  /// Kept as a single-argument overload so `flatMap(DashDateFormatting.date(fromISO8601:))`
  /// keeps resolving; the bare-day zone override is the two-argument form below.
  static func date(fromISO8601 value: String) -> Date? {
    date(fromISO8601: value, bareDayTimeZone: .current)
  }

  /// Parses Cloudflare and RDAP internet timestamps with or without fractional
  /// seconds, plus exact bare calendar days.
  ///
  /// A bare day is interpreted in `bareDayTimeZone`; it is not a UTC instant.
  static func date(
    fromISO8601 value: String,
    bareDayTimeZone: TimeZone
  ) -> Date? {
    date(fromInternetTimestamp: value)
      ?? date(fromCalendarDay: value, timeZone: bareDayTimeZone)
  }

  /// Interprets an exact `yyyy-MM-dd` value as a calendar day in `timeZone`.
  ///
  /// Callers that later display the result must use the same time zone.
  static func date(
    fromCalendarDay value: String,
    timeZone: TimeZone
  ) -> Date? {
    var scanner = ASCIIDateScanner(value)
    guard
      let year = scanner.integer(digits: 4),
      scanner.consume("-"),
      let month = scanner.integer(digits: 2),
      scanner.consume("-"),
      let day = scanner.integer(digits: 2),
      scanner.isAtEnd
    else {
      return nil
    }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let components = DateComponents(year: year, month: month, day: day)
    guard let date = calendar.date(from: components) else { return nil }
    let resolved = calendar.dateComponents([.year, .month, .day], from: date)
    guard resolved.year == year, resolved.month == month, resolved.day == day else {
      return nil
    }
    return date
  }

  /// `RelativeDateTimeFormatter` has no value-style equivalent that preserves
  /// an explicit `relativeTo` date. Keep this mutable, non-`Sendable` formatter
  /// local to each infrequent call rather than sharing unsafe state.
  static func abbreviatedRelativeTime(
    _ date: Date,
    relativeTo referenceDate: Date = .now,
    locale: Locale = DashL10n.activeLocale
  ) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = locale
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: referenceDate)
  }

  static func fullRelativeTime(
    _ date: Date,
    relativeTo referenceDate: Date = .now,
    locale: Locale = DashL10n.activeLocale
  ) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = locale
    formatter.unitsStyle = .full
    return formatter.localizedString(for: date, relativeTo: referenceDate)
  }

  private static let internetTimestampStyle = Date.ISO8601FormatStyle(
    includingFractionalSeconds: true)

  private static func date(fromInternetTimestamp value: String) -> Date? {
    guard
      let expected = internetTimestampComponents(value),
      let date = try? internetTimestampStyle.parse(value)
    else {
      return nil
    }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = expected.timeZone
    let resolved = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second],
      from: date)
    guard
      resolved.year == expected.year,
      resolved.month == expected.month,
      resolved.day == expected.day,
      resolved.hour == expected.hour,
      resolved.minute == expected.minute,
      resolved.second == expected.second
    else {
      return nil
    }
    return date
  }

  private static func internetTimestampComponents(
    _ value: String
  ) -> InternetTimestampComponents? {
    var scanner = ASCIIDateScanner(value)
    guard
      let year = scanner.integer(digits: 4),
      scanner.consume("-"),
      let month = scanner.integer(digits: 2),
      scanner.consume("-"),
      let day = scanner.integer(digits: 2),
      scanner.consume("T"),
      let hour = scanner.integer(digits: 2),
      scanner.consume(":"),
      let minute = scanner.integer(digits: 2),
      scanner.consume(":"),
      let second = scanner.integer(digits: 2),
      (0...23).contains(hour),
      (0...59).contains(minute),
      (0...59).contains(second)
    else {
      return nil
    }

    if scanner.consume(".") {
      guard scanner.consumeDigits() else { return nil }
    }

    let timeZone: TimeZone?
    if scanner.consume("Z") {
      timeZone = TimeZone(secondsFromGMT: 0)
    } else {
      let sign: Int
      if scanner.consume("+") {
        sign = 1
      } else if scanner.consume("-") {
        sign = -1
      } else {
        return nil
      }
      guard
        let offsetHour = scanner.integer(digits: 2),
        scanner.consume(":"),
        let offsetMinute = scanner.integer(digits: 2),
        (0...23).contains(offsetHour),
        (0...59).contains(offsetMinute)
      else {
        return nil
      }
      timeZone = TimeZone(
        secondsFromGMT: sign * (offsetHour * 60 * 60 + offsetMinute * 60))
    }
    guard scanner.isAtEnd, let timeZone else { return nil }
    return InternetTimestampComponents(
      year: year,
      month: month,
      day: day,
      hour: hour,
      minute: minute,
      second: second,
      timeZone: timeZone)
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

private struct InternetTimestampComponents {
  let year: Int
  let month: Int
  let day: Int
  let hour: Int
  let minute: Int
  let second: Int
  let timeZone: TimeZone
}

private struct ASCIIDateScanner {
  private let bytes: String.UTF8View
  private var index: String.UTF8View.Index

  init(_ value: String) {
    let bytes = value.utf8
    self.bytes = bytes
    index = bytes.startIndex
  }

  var isAtEnd: Bool {
    index == bytes.endIndex
  }

  mutating func consume(_ character: Character) -> Bool {
    guard
      let asciiValue = character.asciiValue,
      index != bytes.endIndex,
      bytes[index] == asciiValue
    else {
      return false
    }
    bytes.formIndex(after: &index)
    return true
  }

  mutating func integer(digits: Int) -> Int? {
    var value = 0
    for _ in 0..<digits {
      guard index != bytes.endIndex else { return nil }
      let byte = bytes[index]
      guard (48...57).contains(byte) else { return nil }
      value = value * 10 + Int(byte - 48)
      bytes.formIndex(after: &index)
    }
    return value
  }

  mutating func consumeDigits() -> Bool {
    var consumed = false
    while index != bytes.endIndex {
      let byte = bytes[index]
      guard (48...57).contains(byte) else { break }
      consumed = true
      bytes.formIndex(after: &index)
    }
    return consumed
  }
}
