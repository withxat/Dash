import Foundation
import UserNotifications

/// On-device reminders for deadlines Cloudflare never alerts about.
///
/// Cloudflare's notification catalog has no domain-expiry alert — expiry lives
/// with the registrar, and for a domain registered elsewhere Cloudflare does not
/// know the date at all. Dash already reads it from RDAP/WHOIS for the zone
/// screen's registration card, so the reminder costs one `UNCalendarNotification`
/// and no server: no relay call, no stored token, nothing scheduled anywhere but
/// this iPhone.
///
/// Scope is deliberately just registration expiry. Certificate expiry looks like
/// the obvious sibling and is not: Cloudflare renews Universal SSL itself and
/// publishes `universal_ssl_event_type` when that fails, so a local countdown to
/// an automatic renewal is precisely the invented alarm this app removed from
/// Watchtower — a warning Cloudflare never raised, about a date it was already
/// handling.
///
/// Everything here is idempotent by identifier. Re-scheduling the same domain
/// replaces its pending requests instead of stacking a second set, so calling
/// this on every zone load is correct and cheap.
enum ExpiryReminders {
  /// How far ahead to warn. A month is enough to renew without panic, a week is
  /// the reminder that actually gets acted on, and a day is the last chance.
  static let leadDays = [30, 7, 1]

  /// Late morning local time. A deadline reminder that fires at 3am is a
  /// reminder the user reads at 9am with the urgency already spent.
  static let fireHour = 10

  private static let identifierPrefix = "dash.expiry."

  /// Namespaces the identifier. One case today; the shape is what keeps a
  /// second kind from colliding with domain reminders later.
  enum Subject: String, Sendable {
    case domain
  }

  struct Plan: Equatable, Sendable {
    let identifier: String
    let title: String
    let body: String
    let fireDate: DateComponents
    let route: String?
  }

  static func identifier(
    subject: Subject,
    accountID: String,
    resourceID: String,
    leadDays: Int
  ) -> String {
    "\(identifierPrefix)\(subject.rawValue).\(accountID).\(resourceID).\(leadDays)"
  }

  /// Pure plan derivation, so the date math is testable without a notification
  /// center. Lead times already past are dropped rather than fired immediately —
  /// scheduling a reminder for a deadline three days ago is noise.
  static func plans(
    subject: Subject,
    displayName: String,
    accountID: String,
    resourceID: String,
    expiresOn: Date,
    now: Date = .now,
    calendar: Calendar = .current,
    route: String? = nil
  ) -> [Plan] {
    leadDays.compactMap { lead in
      guard
        let day = calendar.date(byAdding: .day, value: -lead, to: expiresOn),
        let fireDate = calendar.date(
          bySettingHour: fireHour, minute: 0, second: 0, of: day),
        fireDate > now
      else { return nil }

      return Plan(
        identifier: identifier(
          subject: subject,
          accountID: accountID,
          resourceID: resourceID,
          leadDays: lead),
        title: title(for: subject),
        body: body(for: subject, displayName: displayName, leadDays: lead),
        fireDate: calendar.dateComponents(
          [.year, .month, .day, .hour, .minute], from: fireDate),
        route: route)
    }
  }

  private static func title(for subject: Subject) -> String {
    switch subject {
    case .domain: DashL10n.string("Domain expiring")
    }
  }

  private static func body(for subject: Subject, displayName: String, leadDays: Int) -> String {
    let when =
      leadDays == 1
      ? DashL10n.string("tomorrow")
      : DashL10n.string("in \(leadDays) days")
    switch subject {
    case .domain:
      return DashL10n.string("\(displayName) expires \(when). Renew it with your registrar.")
    }
  }

  /// Schedules (or re-schedules) one resource's reminders. Silently does
  /// nothing without delivery authorization — this rides along with a data load
  /// and must never prompt.
  static func schedule(
    _ plans: [Plan],
    center: UNUserNotificationCenter = .current()
  ) async {
    guard !plans.isEmpty else { return }
    let settings = await center.notificationSettings()
    guard WatchtowerNotifier.delivers(settings.authorizationStatus) else { return }

    // Replace rather than accumulate: the expiry date moves when a domain is
    // renewed, and a stale set would still fire on the old schedule.
    center.removePendingNotificationRequests(
      withIdentifiers: plans.map(\.identifier))

    for plan in plans {
      let content = UNMutableNotificationContent()
      content.title = plan.title
      content.body = plan.body
      content.sound = .default
      content.interruptionLevel = .active
      if let route = plan.route {
        content.userInfo = ["dashRoute": route]
      }
      let request = UNNotificationRequest(
        identifier: plan.identifier,
        content: content,
        trigger: UNCalendarNotificationTrigger(dateMatching: plan.fireDate, repeats: false))
      try? await center.add(request)
    }
  }

  /// Drops every scheduled expiry reminder. Called on sign-out and on account
  /// switch: these reminders name a specific domain in a specific Cloudflare
  /// account, and one left behind would announce a domain the user can no
  /// longer open.
  static func cancelAll(center: UNUserNotificationCenter = .current()) async {
    let pending = await center.pendingNotificationRequests()
    let ours = pending.map(\.identifier).filter { $0.hasPrefix(identifierPrefix) }
    guard !ours.isEmpty else { return }
    center.removePendingNotificationRequests(withIdentifiers: ours)
  }

  /// Parses ISO 8601 stamps from RDAP and Cloudflare APIs, with or without
  /// fractional seconds.
  static func date(fromISO8601 value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    if let date = fractional.date(from: value) ?? plain.date(from: value) {
      return date
    }
    // WHOIS occasionally yields a bare day.
    let day = DateFormatter()
    day.locale = Locale(identifier: "en_US_POSIX")
    day.timeZone = TimeZone(identifier: "UTC")
    day.dateFormat = "yyyy-MM-dd"
    return day.date(from: String(value.prefix(10)))
  }
}
