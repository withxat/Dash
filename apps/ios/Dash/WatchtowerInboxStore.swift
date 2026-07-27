import CloudflareAPI
import Foundation

/// Device-local semantics for Cloudflare's notification history.
///
/// The inbox is Cloudflare's own deliveries and nothing else: an account's
/// notification policies are the only place Cloudflare declares that something
/// needs attention, so Dash relays them instead of inventing its own.
///
/// Cloudflare exposes delivery history without read state, so Dash establishes
/// the first fetched page as history and tracks later delivery IDs as unread on
/// this iPhone.
enum WatchtowerInboxStore {
  static let ignoredKey = "dash.watchtower_inbox_ignored"
  static let readKey = "dash.watchtower_inbox_read"

  private struct IgnoredPayload: Codable, Sendable {
    var byAccount: [String: [String]]
  }

  private struct ReadPayload: Codable, Sendable {
    var initializedAccounts: [String]
    var byAccount: [String: [String]]
    /// Local point-in-time that separates pre-existing history from later
    /// deliveries. This also protects accounts whose first history fetch was
    /// unavailable and therefore returned an empty page.
    var baselineByAccount: [String: Date]?
  }

  // MARK: Ignore

  static func ignoredIDs(accountID: String, defaults: UserDefaults = .standard) -> Set<String> {
    Set(ignoredPayload(defaults: defaults).byAccount[accountID] ?? [])
  }

  static func isIgnored(
    _ entryID: String, accountID: String, defaults: UserDefaults = .standard
  ) -> Bool {
    ignoredIDs(accountID: accountID, defaults: defaults).contains(entryID)
  }

  static func ignore(
    _ entryIDs: [String], accountID: String, defaults: UserDefaults = .standard
  ) {
    guard !entryIDs.isEmpty else { return }
    var payload = ignoredPayload(defaults: defaults)
    var set = Set(payload.byAccount[accountID] ?? [])
    set.formUnion(entryIDs)
    payload.byAccount[accountID] = Array(set).sorted()
    saveIgnored(payload, defaults: defaults)
  }

  static func unignore(
    _ entryID: String, accountID: String, defaults: UserDefaults = .standard
  ) {
    unignore([entryID], accountID: accountID, defaults: defaults)
  }

  static func unignore(
    _ entryIDs: [String], accountID: String, defaults: UserDefaults = .standard
  ) {
    guard !entryIDs.isEmpty else { return }
    var payload = ignoredPayload(defaults: defaults)
    var set = Set(payload.byAccount[accountID] ?? [])
    set.subtract(entryIDs)
    payload.byAccount[accountID] = Array(set).sorted()
    saveIgnored(payload, defaults: defaults)
  }

  // MARK: Read state

  static func readIDs(
    accountID: String, defaults: UserDefaults = .standard
  ) -> Set<String> {
    Set(readPayload(defaults: defaults).byAccount[accountID] ?? [])
  }

  static func markRead(
    _ entryIDs: [String], accountID: String, defaults: UserDefaults = .standard
  ) {
    let notificationIDs = entryIDs.filter { $0.hasPrefix("cf:") }
    guard !notificationIDs.isEmpty else { return }
    var payload = readPayload(defaults: defaults)
    var initialized = Set(payload.initializedAccounts)
    initialized.insert(accountID)
    payload.initializedAccounts = Array(initialized).sorted()
    var baselines = payload.baselineByAccount ?? [:]
    if baselines[accountID] == nil { baselines[accountID] = .now }
    payload.baselineByAccount = baselines
    var read = Set(payload.byAccount[accountID] ?? [])
    read.formUnion(notificationIDs)
    payload.byAccount[accountID] = Array(read).sorted()
    saveRead(payload, defaults: defaults)
  }

  // MARK: Feed

  /// Unread deliveries only — the source of truth for the tab red dot and the
  /// floating inbox badge. History never counts.
  static func unreadCount(
    accountID: String,
    alerts: [NotificationHistoryEntry],
    defaults: UserDefaults = .standard
  ) -> Int {
    contents(accountID: accountID, alerts: alerts, defaults: defaults)
      .unreadNotifications
      .count
  }

  static func contents(
    accountID: String,
    alerts: [NotificationHistoryEntry],
    defaults: UserDefaults = .standard
  ) -> WatchtowerInboxContents {
    let ignored = ignoredIDs(accountID: accountID, defaults: defaults)
    let entries = alerts.map { alert in
      WatchtowerInboxEntry(
        id: "cf:\(alert.id)",
        title: alert.title,
        detail: alert.subtitle,
        sentAt: alert.sent.flatMap(parseISO8601),
        category: .history)
    }
    let read = readIDs(
      accountID: accountID,
      currentEntries: entries,
      defaults: defaults)
    let categorized: [WatchtowerInboxEntry] = entries.map { entry in
      var entry = entry
      entry.category = read.contains(entry.id) ? .history : .unread
      return entry
    }

    return WatchtowerInboxContents(
      unreadNotifications: sorted(
        categorized.filter { $0.category == .unread && !ignored.contains($0.id) }),
      history: sorted(
        categorized.filter { $0.category == .history && !ignored.contains($0.id) }),
      ignored: sorted(categorized.filter { ignored.contains($0.id) }))
  }

  private static func readIDs(
    accountID: String,
    currentEntries: [WatchtowerInboxEntry],
    defaults: UserDefaults
  ) -> Set<String> {
    var payload = readPayload(defaults: defaults)
    var initialized = Set(payload.initializedAccounts)
    var baselines = payload.baselineByAccount ?? [:]
    let currentNotificationIDs = Set(currentEntries.map(\.id))
    if !initialized.contains(accountID) || baselines[accountID] == nil {
      // An upgrade must not turn Cloudflare's existing delivery page into ten
      // "new" alerts. The first page is the local read baseline.
      initialized.insert(accountID)
      payload.initializedAccounts = Array(initialized).sorted()
      baselines[accountID] = .now
      payload.baselineByAccount = baselines
      payload.byAccount[accountID] = Array(currentNotificationIDs).sorted()
      saveRead(payload, defaults: defaults)
      return currentNotificationIDs
    }

    // If notification access was unavailable during the empty baseline, treat
    // older deliveries as history once access arrives. Only deliveries after
    // the local baseline become unread.
    let baseline = baselines[accountID]!
    var read = Set(payload.byAccount[accountID] ?? [])
    for entry in currentEntries where !read.contains(entry.id) {
      guard let sentAt = entry.sentAt, sentAt > baseline else {
        read.insert(entry.id)
        continue
      }
    }
    payload.byAccount[accountID] = Array(read).sorted()
    saveRead(payload, defaults: defaults)
    return read
  }

  private static func sorted(_ entries: [WatchtowerInboxEntry]) -> [WatchtowerInboxEntry] {
    entries.sorted {
      ($0.sentAt ?? .distantPast) > ($1.sentAt ?? .distantPast)
    }
  }

  // MARK: Private

  private static func parseISO8601(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: value)
  }

  private static func ignoredPayload(defaults: UserDefaults) -> IgnoredPayload {
    guard let data = defaults.data(forKey: ignoredKey),
      let decoded = try? JSONDecoder().decode(IgnoredPayload.self, from: data)
    else { return IgnoredPayload(byAccount: [:]) }
    return decoded
  }

  private static func saveIgnored(_ payload: IgnoredPayload, defaults: UserDefaults) {
    if let data = try? JSONEncoder().encode(payload) {
      defaults.set(data, forKey: ignoredKey)
    }
  }

  private static func readPayload(defaults: UserDefaults) -> ReadPayload {
    guard let data = defaults.data(forKey: readKey),
      let decoded = try? JSONDecoder().decode(ReadPayload.self, from: data)
    else {
      return ReadPayload(
        initializedAccounts: [],
        byAccount: [:],
        baselineByAccount: nil)
    }
    return decoded
  }

  private static func saveRead(_ payload: ReadPayload, defaults: UserDefaults) {
    if let data = try? JSONEncoder().encode(payload) {
      defaults.set(data, forKey: readKey)
    }
  }
}

struct WatchtowerInboxContents: Hashable, Sendable {
  static let empty = WatchtowerInboxContents(
    unreadNotifications: [], history: [], ignored: [])

  var unreadNotifications: [WatchtowerInboxEntry]
  var history: [WatchtowerInboxEntry]
  var ignored: [WatchtowerInboxEntry]

  var isEmpty: Bool {
    unreadNotifications.isEmpty && history.isEmpty && ignored.isEmpty
  }
}

enum WatchtowerInboxCategory: Hashable, Sendable {
  case unread
  case history
}

struct WatchtowerInboxEntry: Identifiable, Hashable, Sendable {
  let id: String
  var title: String
  var detail: String?
  var sentAt: Date?
  var category: WatchtowerInboxCategory
}
