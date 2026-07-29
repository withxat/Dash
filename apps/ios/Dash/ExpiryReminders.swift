import Foundation
import UserNotifications

/// Both services are process-wide, internally synchronized Foundation APIs.
/// Their SDK declarations do not conform to `Sendable`, so crossing the
/// migration actor/task boundary requires one explicit ownership assertion
/// instead of scattering `@preconcurrency` over every notification call.
private struct ExpiryReminderMigrationDependencies: @unchecked Sendable {
  let defaults: UserDefaults
  let center: UNUserNotificationCenter
}

/// Serializes the one-shot identifier sweep across every caller in this
/// process. The persisted flag alone is not enough: a second caller can observe
/// it while the first caller is still awaiting `pendingNotificationRequests()`,
/// schedule a new reminder, and then have that reminder removed by the sweep.
private actor ExpiryReminderIdentifierMigration {
  private var inFlight: Task<Void, Never>?

  func runIfNeeded(
    key: String,
    dependencies: ExpiryReminderMigrationDependencies
  ) async {
    if let inFlight {
      await inFlight.value
      return
    }
    guard !dependencies.defaults.bool(forKey: key) else { return }

    let task = Task { [dependencies] in
      await ExpiryReminders.cancelAll(center: dependencies.center)
    }
    inFlight = task
    await task.value
    // Persist only after the sweep. If the process is killed while the
    // notification center is being queried, the next launch must retry rather
    // than trusting a cleanup that may never have completed.
    dependencies.defaults.set(true, forKey: key)
    inFlight = nil
  }
}

/// On-device reminders for deadlines Cloudflare never alerts about.
///
/// Cloudflare's notification catalog has no domain-expiry alert — expiry lives
/// with the registrar, and for a domain registered elsewhere Cloudflare does not
/// know the date at all. Dash already reads it twice over: from the account's
/// Cloudflare Registrar index when the domain was bought here, and from
/// RDAP/WHOIS otherwise. Either way the reminder costs one
/// `UNCalendarNotification` and no server: no relay call, no stored token,
/// nothing scheduled anywhere but this iPhone.
///
/// Scope is deliberately just registration expiry, and only the registrations
/// that actually have a deadline. Certificate expiry looks like the obvious
/// sibling and is not: Cloudflare renews Universal SSL itself and publishes
/// `universal_ssl_event_type` when that fails, so a local countdown to an
/// automatic renewal is precisely the invented alarm this app removed from
/// Watchtower — a warning Cloudflare never raised, about a date it was already
/// handling. **A Cloudflare-registered domain with auto-renew on is the same
/// case**, which is why `Renewal` exists: the countdown is withdrawn, not
/// merely skipped, and the old body copy ("Renew it with your registrar") is
/// never shown for a domain whose registrar is renewing it.
///
/// Everything here is idempotent by identifier, and domain reminders are keyed
/// on the **lowercased domain name** rather than a zone id — the zone screen and
/// the registrar screen both describe the same deadline, and two identifier
/// namespaces would double-book it.
enum ExpiryReminders {
  /// How far ahead to warn. A month is enough to renew without panic, a week is
  /// the reminder that actually gets acted on, and a day is the last chance.
  static let leadDays = [30, 7, 1]

  /// Late morning local time. A deadline reminder that fires at 3am is a
  /// reminder the user reads at 9am with the urgency already spent.
  static let fireHour = 10

  private static let identifierPrefix = "dash.expiry."

  /// One-shot cleanup flag. Reminders used to be keyed on the **zone id**, so
  /// every pending request from a previous build carries an identifier the new
  /// key can never replace — and a body that tells the user to renew a domain
  /// Cloudflare may be renewing itself. Those are withdrawn once, on the first
  /// reminder this build applies.
  static let identifierMigrationKey = "dash.expiry.migrated_v2"

  private static let identifierMigration = ExpiryReminderIdentifierMigration()

  /// Namespaces the identifier. One case today; the shape is what keeps a
  /// second kind from colliding with domain reminders later.
  ///
  /// Deliberately **not** split into `.domain` / `.registrarDomain`:
  /// `identifier()` interpolates `subject.rawValue`, so two subjects are two
  /// namespaces, and the zone screen and the registrar screen would schedule
  /// the same deadline twice under different names.
  enum Subject: String, Sendable {
    case domain
  }

  /// Whether this registration has a deadline the user can meet, and who has to
  /// meet it. Derived from Cloudflare's own answer — never from wording.
  enum Renewal: Equatable, Sendable {
    /// Cloudflare is the registrar, said the domain is active, and said
    /// auto-renew is **off**. The only first-party case with a real deadline.
    case registrarManual
    /// Cloudflare is the registrar and there is nothing to count down to:
    /// it renews the domain itself, it did not say (its own default is
    /// auto-renew on), or the domain is past the point where renewing is what
    /// fixes it (`suspended`, `redemption_period`, `pending_delete`).
    case registrarNoDeadline
    /// Not a Cloudflare registration. The date comes from RDAP/WHOIS and Dash
    /// knows nothing about renewal, so the reminder stays generic.
    case thirdParty

    var schedules: Bool {
      switch self {
      case .registrarManual, .thirdParty: true
      case .registrarNoDeadline: false
      }
    }

    fileprivate var autoRenewIsOff: Bool {
      self == .registrarManual
    }
  }

  /// Reads the renewal policy off one Cloudflare Registrar registration.
  ///
  /// Positive claim only: a countdown exists when Cloudflare said the domain is
  /// active **and** said auto-renew is off. An unrecognised status, an absent
  /// status, or an absent `auto_renew` all mean "Cloudflare did not say", and
  /// Cloudflare Registrar's own default is to renew — so guessing a deadline
  /// there would raise an alarm about a date Cloudflare is already handling.
  static func renewal(registrarStatus: String?, autoRenew: Bool?) -> Renewal {
    let status =
      (registrarStatus ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: " ", with: "_")
    let isActive = status == "active"
    guard isActive, autoRenew == false else { return .registrarNoDeadline }
    return .registrarManual
  }

  struct Plan: Equatable, Sendable {
    let identifier: String
    /// Every lead-time identifier for this resource, including plans already
    /// past. Scheduling uses the complete set as its replacement boundary.
    let resourceIdentifiers: [String]
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

  /// The identity a domain reminder is filed under, from either screen.
  static func resourceID(forDomain domain: String) -> String {
    domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  /// The one entry point that schedules or withdraws a domain's reminders.
  ///
  /// Both the zone screen's registration card and the registrar detail screen
  /// call this, under the same subject and the same resource id, so the two can
  /// never double-book one domain. It is also what the auto-renew toggle calls
  /// on success: flipping auto-renew on is exactly the moment the reminder's
  /// premise stops being true, and leaving the pending requests behind would
  /// keep announcing a deadline Cloudflare has taken over.
  static func applyDomainReminder(
    domain: String,
    accountID: String,
    expiresOn: Date?,
    renewal: Renewal,
    route: String? = nil,
    now: Date = .now,
    calendar: Calendar = .current,
    defaults: UserDefaults = .standard,
    center: UNUserNotificationCenter = .current()
  ) async {
    let resourceID = resourceID(forDomain: domain)
    let accountID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !resourceID.isEmpty, !accountID.isEmpty else { return }

    await migrateIdentifiersIfNeeded(defaults: defaults, center: center)

    // A reschedule replaces the complete lead-time set, not only the plans that
    // are still in the future. Otherwise a renewed deadline that now has only
    // 7- and 1-day plans leaves the old 30-day request pending.
    await cancel(
      subject: .domain, accountID: accountID, resourceID: resourceID, center: center)

    guard renewal.schedules, let expiresOn else {
      return
    }
    let plans = plans(
      subject: .domain,
      displayName: domain,
      accountID: accountID,
      resourceID: resourceID,
      expiresOn: expiresOn,
      now: now,
      calendar: calendar,
      route: route,
      renewal: renewal)
    guard !plans.isEmpty else { return }
    await schedule(plans, defaults: defaults, center: center)
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
    route: String? = nil,
    renewal: Renewal = .thirdParty
  ) -> [Plan] {
    guard renewal.schedules else { return [] }
    let resourceIdentifiers = leadDays.map {
      identifier(
        subject: subject,
        accountID: accountID,
        resourceID: resourceID,
        leadDays: $0)
    }
    return leadDays.compactMap { lead in
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
        resourceIdentifiers: resourceIdentifiers,
        title: title(for: subject),
        body: body(
          for: subject, displayName: displayName, leadDays: lead,
          autoRenewIsOff: renewal.autoRenewIsOff),
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

  /// `autoRenewIsOff` is what separates the two true sentences. "Renew it with
  /// your registrar" is right for an RDAP-sourced domain and flatly wrong for a
  /// Cloudflare registration, where the registrar *is* the app the user is
  /// reading the notification from — and where the reason there is a deadline at
  /// all is that they turned auto-renew off.
  private static func body(
    for subject: Subject,
    displayName: String,
    leadDays: Int,
    autoRenewIsOff: Bool
  ) -> String {
    let when =
      leadDays == 1
      ? DashL10n.string("tomorrow")
      : DashL10n.string("in \(leadDays) days")
    switch subject {
    case .domain:
      if autoRenewIsOff {
        return DashL10n.string("\(displayName) expires \(when). Auto-renew is off.")
      }
      return DashL10n.string("\(displayName) expires \(when). Renew it with your registrar.")
    }
  }

  /// Schedules (or re-schedules) one resource's reminders. Silently does
  /// nothing without delivery authorization — this rides along with a data load
  /// and must never prompt.
  static func schedule(
    _ plans: [Plan],
    defaults: UserDefaults = .standard,
    center: UNUserNotificationCenter = .current()
  ) async {
    guard !plans.isEmpty else { return }
    // Every scheduling entry point waits for the same sweep. This includes the
    // zone registration path, which still calls `schedule(_:)` directly.
    await migrateIdentifiersIfNeeded(defaults: defaults, center: center)
    let settings = await center.notificationSettings()
    guard WatchtowerNotifier.delivers(settings.authorizationStatus) else { return }

    // Replace the resource's complete lead-time set, including plans whose new
    // fire date is already past. Removing only `plans.map(\.identifier)` leaves
    // the old 30-day request behind when the new date has only 7 and 1 days.
    center.removePendingNotificationRequests(
      withIdentifiers: Array(Set(plans.flatMap(\.resourceIdentifiers))))

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

  /// Withdraws one resource's reminders across every lead time.
  ///
  /// `schedule(_:)` opens with `guard !plans.isEmpty`, so handing it an empty
  /// plan list removes nothing. Turning auto-renew on, a domain entering
  /// redemption, and a renewal that moved the date past every lead time all
  /// need the pending requests actually gone, and this is the only thing that
  /// does that without touching another domain's.
  static func cancel(
    subject: Subject,
    accountID: String,
    resourceID: String,
    center: UNUserNotificationCenter = .current()
  ) async {
    let identifiers = leadDays.map {
      identifier(
        subject: subject, accountID: accountID, resourceID: resourceID, leadDays: $0)
    }
    center.removePendingNotificationRequests(withIdentifiers: identifiers)
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

  /// Withdraws the zone-id-keyed reminders written by earlier builds, once.
  ///
  /// Every concurrent caller awaits the same in-process task, and the flag is
  /// written only after that task finishes. That closes both failure windows:
  /// a second caller cannot schedule under the new ids before `cancelAll`
  /// finishes, and a process killed mid-sweep retries on its next launch.
  private static func migrateIdentifiersIfNeeded(
    defaults: UserDefaults,
    center: UNUserNotificationCenter
  ) async {
    let dependencies = ExpiryReminderMigrationDependencies(
      defaults: defaults,
      center: center)
    await identifierMigration.runIfNeeded(
      key: identifierMigrationKey,
      dependencies: dependencies)
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
