import CloudflareAPI
import Foundation

/// Device-local semantics for Watchtower's account-scoped inbox.
///
/// Cloudflare exposes delivery history, not read state. Dash establishes the
/// first fetched page as history, then tracks later delivery IDs as unread on
/// this iPhone. Current Dash detections stay separate from that history.
enum WatchtowerInboxStore {
  static let ignoredKey = "dash.watchtower_inbox_ignored"
  static let readKey = "dash.watchtower_inbox_read"
  /// Best-effort merge window for Cloudflare + Dash rows about the same issue.
  static let dedupeWindow: TimeInterval = 48 * 3600

  private struct IgnoredPayload: Codable, Sendable {
    var byAccount: [String: [String]]
  }

  private struct ReadPayload: Codable, Sendable {
    var initializedAccounts: [String]
    var byAccount: [String: [String]]
    /// Most recently fetched Cloudflare page. Optional so an early build of
    /// this additive payload decodes without migration or data loss.
    var latestByAccount: [String: [String]]?
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

  static func ignoreAll(
    _ entryIDs: [String], accountID: String, defaults: UserDefaults = .standard
  ) {
    var allActionableIDs = Set(entryIDs)
    let payload = readPayload(defaults: defaults)
    let latest = Set(payload.latestByAccount?[accountID] ?? [])
    let read = Set(payload.byAccount[accountID] ?? [])
    // A Dash + Cloudflare row can dedupe under the Dash ID. Expand Ignore all
    // with every unread delivery from the current page so the Cloudflare half
    // cannot reappear after the Dash issue resolves.
    allActionableIDs.formUnion(latest.subtracting(read))
    ignore(Array(allActionableIDs), accountID: accountID, defaults: defaults)
  }

  static func liveDashID(signalID: String) -> String { "dash:live:\(signalID)" }

  // MARK: Cloudflare read state

  static func readCloudflareIDs(
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

  /// Actionable rows only: current Dash issues + unread Cloudflare deliveries.
  /// This is intentionally narrower than Cloudflare history and is the source
  /// of truth for the tab red dot and floating inbox badge.
  static func activeCount(
    accountID: String,
    alerts: [NotificationHistoryEntry],
    signals: [WatchtowerSignal] = [],
    defaults: UserDefaults = .standard
  ) -> Int {
    build(
      accountID: accountID, alerts: alerts, signals: signals, defaults: defaults
    )
    .count
  }

  /// Compatibility surface for badge and Ignore-all callers. Historical
  /// Cloudflare deliveries never appear here.
  static func build(
    accountID: String,
    alerts: [NotificationHistoryEntry],
    signals: [WatchtowerSignal] = [],
    defaults: UserDefaults = .standard
  ) -> [WatchtowerInboxEntry] {
    let contents = contents(
      accountID: accountID,
      alerts: alerts,
      signals: signals,
      defaults: defaults)
    return contents.currentIssues + contents.unreadNotifications
  }

  static func contents(
    accountID: String,
    alerts: [NotificationHistoryEntry],
    signals: [WatchtowerSignal] = [],
    defaults: UserDefaults = .standard
  ) -> WatchtowerInboxContents {
    let ignored = ignoredIDs(accountID: accountID, defaults: defaults)
    let cloudflareEntries = alerts.map { alert in
      let entryID = "cf:\(alert.id)"
      return WatchtowerInboxEntry(
        id: entryID,
        title: alert.title,
        detail: alert.subtitle,
        sentAt: alert.sent.flatMap(parseISO8601),
        sources: [.cloudflare],
        destination: nil,
        externalURL: nil,
        status: nil,
        signalID: nil,
        notificationIDs: [entryID],
        category: .history
      )
    }
    let read = cloudflareReadIDs(
      accountID: accountID,
      currentEntries: cloudflareEntries,
      defaults: defaults)
    let categorizedCloudflare: [WatchtowerInboxEntry] = cloudflareEntries.map { entry in
      var entry = entry
      entry.category = read.contains(entry.id) ? .history : .unreadNotification
      return entry
    }
    let unreadCloudflare = categorizedCloudflare.filter { $0.category == .unreadNotification }
    let history = cloudflareEntries.filter { read.contains($0.id) }

    let muted = WatchtowerMuteStore.mutedIDs(accountID: accountID, defaults: defaults)
    let liveIssues = signals.compactMap { signal -> WatchtowerInboxEntry? in
      guard signal.status != .ok,
        signal.id != WatchtowerEngine.coverageSignalID,
        !muted.contains(signal.id)
      else { return nil }
      let detail: String = {
        if let resource = signal.resourceName, !signal.detail.contains(resource) {
          return "\(signal.detail) · \(resource)"
        }
        return signal.detail
      }()
      return WatchtowerInboxEntry(
        id: liveDashID(signalID: signal.id),
        title: signal.title,
        detail: detail,
        sentAt: signal.observedAt,
        sources: [.dash],
        destination: signal.destination,
        externalURL: signal.externalURL,
        status: signal.status,
        signalID: signal.id,
        notificationIDs: [],
        category: .currentIssue
      )
    }

    // Only unread deliveries can collapse into a current Dash issue. Read
    // deliveries remain in History so the audit trail does not disappear.
    let actionable = sorted(dedupe(liveIssues + unreadCloudflare))
    let currentIssues = actionable.filter {
      $0.category == .currentIssue && !isIgnored($0, ignoredIDs: ignored)
    }
    let unreadNotifications = actionable.filter {
      $0.category == .unreadNotification && !isIgnored($0, ignoredIDs: ignored)
    }
    let visibleHistory = sorted(history).filter { !isIgnored($0, ignoredIDs: ignored) }
    let ignoredEntries = sorted(actionable + history).filter {
      isIgnored($0, ignoredIDs: ignored)
    }

    return WatchtowerInboxContents(
      currentIssues: currentIssues,
      unreadNotifications: unreadNotifications,
      history: visibleHistory,
      ignored: ignoredEntries)
  }

  private static func cloudflareReadIDs(
    accountID: String,
    currentEntries: [WatchtowerInboxEntry],
    defaults: UserDefaults
  ) -> Set<String> {
    var payload = readPayload(defaults: defaults)
    var initialized = Set(payload.initializedAccounts)
    var baselines = payload.baselineByAccount ?? [:]
    let currentNotificationIDs = Set(currentEntries.map(\.id))
    var latest = payload.latestByAccount ?? [:]
    latest[accountID] = Array(currentNotificationIDs).sorted()
    payload.latestByAccount = latest
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

  private static func isIgnored(
    _ entry: WatchtowerInboxEntry, ignoredIDs: Set<String>
  ) -> Bool {
    !entry.localStateIDs.isDisjoint(with: ignoredIDs)
  }

  private static func sorted(_ entries: [WatchtowerInboxEntry]) -> [WatchtowerInboxEntry] {
    entries.sorted {
      ($0.sentAt ?? .distantPast) > ($1.sentAt ?? .distantPast)
    }
  }

  /// Merges Cloudflare + Dash rows that share meaningful tokens inside the
  /// dedupe window. Prefer keeping actionable Dash navigation when present.
  static func dedupe(_ entries: [WatchtowerInboxEntry]) -> [WatchtowerInboxEntry] {
    var result: [WatchtowerInboxEntry] = []
    for entry in entries {
      if let index = result.firstIndex(where: { shouldMerge($0, entry) }) {
        result[index] = merge(result[index], entry)
      } else {
        result.append(entry)
      }
    }
    return result
  }

  // MARK: Private

  private static func shouldMerge(_ a: WatchtowerInboxEntry, _ b: WatchtowerInboxEntry) -> Bool {
    // Only collapse across sources — two Dash rows or two CF rows stay distinct.
    let aDash = a.sources.contains(.dash)
    let bDash = b.sources.contains(.dash)
    guard aDash != bDash else { return false }
    let aTime = a.sentAt ?? .distantPast
    let bTime = b.sentAt ?? .distantPast
    guard abs(aTime.timeIntervalSince(bTime)) <= dedupeWindow else { return false }
    let overlap = tokens(a).intersection(tokens(b)).filter { $0.count >= 4 }
    return !overlap.isEmpty
  }

  private static func merge(_ a: WatchtowerInboxEntry, _ b: WatchtowerInboxEntry)
    -> WatchtowerInboxEntry
  {
    let dashFirst = a.sources.contains(.dash) ? a : b
    let other = dashFirst.id == a.id ? b : a
    return WatchtowerInboxEntry(
      id: dashFirst.id,
      title: dashFirst.title,
      detail: dashFirst.detail ?? other.detail,
      sentAt: [dashFirst.sentAt, other.sentAt].compactMap { $0 }.max(),
      sources: dashFirst.sources.union(other.sources),
      destination: dashFirst.destination ?? other.destination,
      externalURL: dashFirst.externalURL ?? other.externalURL,
      status: dashFirst.status ?? other.status,
      signalID: dashFirst.signalID ?? other.signalID,
      notificationIDs: dashFirst.notificationIDs.union(other.notificationIDs),
      category: dashFirst.sources.contains(.dash) ? .currentIssue : .unreadNotification
    )
  }

  private static func tokens(_ entry: WatchtowerInboxEntry) -> Set<String> {
    let text = [entry.title, entry.detail ?? ""].joined(separator: " ").lowercased()
    let parts = text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    return Set(parts)
  }

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
        latestByAccount: nil,
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
    currentIssues: [], unreadNotifications: [], history: [], ignored: [])

  var currentIssues: [WatchtowerInboxEntry]
  var unreadNotifications: [WatchtowerInboxEntry]
  var history: [WatchtowerInboxEntry]
  var ignored: [WatchtowerInboxEntry]

  var actionable: [WatchtowerInboxEntry] { currentIssues + unreadNotifications }
  var isEmpty: Bool {
    currentIssues.isEmpty && unreadNotifications.isEmpty && history.isEmpty && ignored.isEmpty
  }
}

enum WatchtowerInboxCategory: Hashable, Sendable {
  case currentIssue
  case unreadNotification
  case history
}

enum WatchtowerInboxSource: String, Hashable, Sendable {
  case cloudflare
  case dash

  var label: String {
    switch self {
    case .cloudflare: DashL10n.string("Cloudflare")
    case .dash: DashL10n.string("Dash")
    }
  }

  /// Leading list glyph — Cloudflare brand mark vs Dash detection.
  var listIcon: String {
    switch self {
    case .cloudflare: SolarAsset.cloudflare
    case .dash: SolarAsset.Content.danger
    }
  }
}

struct WatchtowerInboxEntry: Identifiable, Hashable, Sendable {
  let id: String
  var title: String
  var detail: String?
  var sentAt: Date?
  var sources: Set<WatchtowerInboxSource>
  var destination: Destination?
  var externalURL: URL?
  var status: WatchtowerStatus?
  /// Present for Dash live-signal rows (and merged rows that kept the Dash id).
  var signalID: String?
  /// Cloudflare delivery IDs carried by this row. A merged Dash + Cloudflare
  /// row retains both identities so read/ignore state stays accurate.
  var notificationIDs: Set<String>
  var category: WatchtowerInboxCategory

  var localStateIDs: Set<String> { notificationIDs.union([id]) }

  var primarySource: WatchtowerInboxSource {
    sources.contains(.dash) ? .dash : .cloudflare
  }
}
