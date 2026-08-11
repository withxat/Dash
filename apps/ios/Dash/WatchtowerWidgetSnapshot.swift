import Foundation

enum WatchtowerFreshness: Equatable, Sendable {
  case fresh
  case aging
  case stale

  static func classify(fetchedAt: Date, now: Date = .now) -> WatchtowerFreshness {
    let age = max(0, now.timeIntervalSince(fetchedAt))
    if age > 24 * 3_600 { return .stale }
    if age > 2 * 3_600 { return .aging }
    return .fresh
  }

  static func checkedText(fetchedAt: Date?, now: Date = .now) -> String {
    guard let fetchedAt else {
      return String(localized: "Open Watchtower to check this account")
    }
    let age = max(0, now.timeIntervalSince(fetchedAt))
    let relative: String
    if age < 60 {
      relative = String(localized: "just now")
    } else if age < 3_600 {
      relative = String(localized: "\(Int(age / 60)) min ago")
    } else if age < 86_400 {
      relative = String(localized: "\(Int(age / 3_600)) hr ago")
    } else {
      let days = Int(age / 86_400)
      relative =
        days == 1 ? String(localized: "1 day ago") : String(localized: "\(days) days ago")
    }

    switch classify(fetchedAt: fetchedAt, now: now) {
    case .fresh:
      return String(localized: "Checked \(relative)")
    case .aging:
      return String(localized: "Checked \(relative) · Refresh recommended")
    case .stale:
      return String(localized: "Checked \(relative) · Refresh now")
    }
  }
}

/// The Watchtower state shared from the app to the widget through the App
/// Group container. Deliberately Foundation-only and Codable with no
/// dependency on the CloudflareAPI or app types, so the widget target can
/// compile this one file and read the JSON without touching the network,
/// the keychain, or the engine.
struct WatchtowerWidgetSnapshot: Codable, Hashable, Sendable {
  /// One Cloudflare notification delivery this iPhone has not read yet.
  struct Alert: Codable, Hashable, Sendable {
    var id: String
    var title: String
    var detail: String?
  }

  var unreadCount: Int
  /// Every unread delivery, newest first. The widget renders a few; the
  /// notification planner diffs the whole set by id.
  var alerts: [Alert]
  /// True when the latest refresh could not read notification history at all
  /// (permission missing or the request failed), so an empty widget does not
  /// claim there is nothing to report.
  var alertsUnavailable: Bool
  /// Account binding for widget taps.
  var accountID: String
  var accountName: String?
  var fetchedAt: Date

  init(
    unreadCount: Int,
    alerts: [Alert],
    alertsUnavailable: Bool = false,
    accountID: String,
    accountName: String?,
    fetchedAt: Date
  ) {
    self.unreadCount = unreadCount
    self.alerts = alerts
    self.alertsUnavailable = alertsUnavailable
    self.accountID = accountID
    self.accountName = accountName
    self.fetchedAt = fetchedAt
  }

  /// VoiceOver / widget headline. Counts deliveries — it never characterises
  /// the account, because Cloudflare is the only thing that decides that here.
  var headline: LocalizedStringResource {
    Self.headline(unreadCount: unreadCount, alertsUnavailable: alertsUnavailable)
  }

  static func headline(
    unreadCount: Int,
    alertsUnavailable: Bool = false
  ) -> LocalizedStringResource {
    if alertsUnavailable { return "Alerts unavailable" }
    if unreadCount == 0 { return "No unread alerts" }
    return "\(unreadCount) unread alerts"
  }

  static let appGroupID = "group.sh.xat.dash.app"
  static let fileName = "watchtower-widget-snapshot.json"

  static var containerFileURL: URL? {
    FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
      .appendingPathComponent(fileName)
  }

  func staleness(now: Date = .now) -> WatchtowerFreshness {
    WatchtowerFreshness.classify(fetchedAt: fetchedAt, now: now)
  }

  var deepLinkURL: URL? {
    let accountID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !accountID.isEmpty else { return nil }
    var components = URLComponents()
    components.scheme = "dash"
    components.host = "watchtower"
    components.queryItems = [URLQueryItem(name: "account", value: accountID)]
    return components.url
  }

  static func load(from url: URL) throws -> WatchtowerWidgetSnapshot {
    try JSONDecoder().decode(WatchtowerWidgetSnapshot.self, from: Data(contentsOf: url))
  }

  func write(to url: URL) throws {
    try JSONEncoder().encode(self).write(to: url, options: .atomic)
  }

  static func clear(at url: URL) {
    try? FileManager.default.removeItem(at: url)
  }
}
