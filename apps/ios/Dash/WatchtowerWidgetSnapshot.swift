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
  struct Signal: Codable, Hashable, Sendable {
    var title: String
    var detail: String
    var status: String  // "ok" | "warning" | "critical"
  }

  var issueCount: Int
  var criticalCount: Int
  var warningCount: Int
  /// Every non-ok signal, critical before warning. The widget renders a few;
  /// the notification planner diffs the whole set.
  var signals: [Signal]
  /// True when the latest refresh could not establish full account health,
  /// without inflating the operational issue badge. Defaults to false when
  /// decoding snapshots written by older app versions.
  var checksIncomplete: Bool
  /// Account binding for widget taps. Optional so snapshots written by an
  /// older app version remain decodable; an unbound snapshot is display-only.
  var accountID: String?
  var accountName: String?
  var fetchedAt: Date

  init(
    issueCount: Int,
    criticalCount: Int,
    warningCount: Int,
    signals: [Signal],
    checksIncomplete: Bool = false,
    accountID: String? = nil,
    accountName: String?,
    fetchedAt: Date
  ) {
    self.issueCount = issueCount
    self.criticalCount = criticalCount
    self.warningCount = warningCount
    self.signals = signals
    self.checksIncomplete = checksIncomplete
    self.accountID = accountID
    self.accountName = accountName
    self.fetchedAt = fetchedAt
  }

  private enum CodingKeys: String, CodingKey {
    case issueCount
    case criticalCount
    case warningCount
    case signals
    case checksIncomplete
    case accountID
    case accountName
    case fetchedAt
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    issueCount = try container.decode(Int.self, forKey: .issueCount)
    criticalCount = try container.decode(Int.self, forKey: .criticalCount)
    warningCount = try container.decode(Int.self, forKey: .warningCount)
    signals = try container.decode([Signal].self, forKey: .signals)
    checksIncomplete =
      try container.decodeIfPresent(Bool.self, forKey: .checksIncomplete) ?? false
    accountID = try container.decodeIfPresent(String.self, forKey: .accountID)
    accountName = try container.decodeIfPresent(String.self, forKey: .accountName)
    fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(issueCount, forKey: .issueCount)
    try container.encode(criticalCount, forKey: .criticalCount)
    try container.encode(warningCount, forKey: .warningCount)
    try container.encode(signals, forKey: .signals)
    try container.encode(checksIncomplete, forKey: .checksIncomplete)
    try container.encodeIfPresent(accountID, forKey: .accountID)
    try container.encodeIfPresent(accountName, forKey: .accountName)
    try container.encode(fetchedAt, forKey: .fetchedAt)
  }

  /// VoiceOver / widget headline that names severity instead of relying on color alone.
  var severityHeadline: String {
    Self.severityHeadline(
      criticalCount: criticalCount,
      warningCount: warningCount,
      checksIncomplete: checksIncomplete)
  }

  static func severityHeadline(
    criticalCount: Int,
    warningCount: Int,
    checksIncomplete: Bool = false
  ) -> String {
    if criticalCount == 0, warningCount == 0 {
      return checksIncomplete ? "Checks incomplete" : "All clear"
    }
    var parts: [String] = []
    if criticalCount > 0 {
      parts.append("\(criticalCount) critical")
    }
    if warningCount > 0 {
      parts.append("\(warningCount) warning\(warningCount == 1 ? "" : "s")")
    }
    return parts.joined(separator: ", ")
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
    guard
      let accountID = accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
      !accountID.isEmpty
    else {
      return nil
    }
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
