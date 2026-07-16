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
    guard let fetchedAt else { return "Open Watchtower to check this account" }
    let age = max(0, now.timeIntervalSince(fetchedAt))
    let relative: String
    if age < 60 {
      relative = "just now"
    } else if age < 3_600 {
      relative = "\(Int(age / 60)) min ago"
    } else if age < 86_400 {
      relative = "\(Int(age / 3_600)) hr ago"
    } else {
      let days = Int(age / 86_400)
      relative = "\(days) day\(days == 1 ? "" : "s") ago"
    }

    switch classify(fetchedAt: fetchedAt, now: now) {
    case .fresh:
      return "Checked \(relative)"
    case .aging:
      return "Checked \(relative) · Refresh recommended"
    case .stale:
      return "Checked \(relative) · Refresh now"
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
  var accountName: String?
  var fetchedAt: Date

  /// VoiceOver / widget headline that names severity instead of relying on color alone.
  var severityHeadline: String {
    Self.severityHeadline(criticalCount: criticalCount, warningCount: warningCount)
  }

  static func severityHeadline(criticalCount: Int, warningCount: Int) -> String {
    if criticalCount == 0, warningCount == 0 { return "All clear" }
    var parts: [String] = []
    if criticalCount > 0 {
      parts.append("\(criticalCount) critical")
    }
    if warningCount > 0 {
      parts.append("\(warningCount) warning\(warningCount == 1 ? "" : "s")")
    }
    return parts.joined(separator: ", ")
  }

  static let appGroupID = "group.sh.xat.dash"
  static let fileName = "watchtower-widget-snapshot.json"

  static var containerFileURL: URL? {
    FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
      .appendingPathComponent(fileName)
  }

  func staleness(now: Date = .now) -> WatchtowerFreshness {
    WatchtowerFreshness.classify(fetchedAt: fetchedAt, now: now)
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
