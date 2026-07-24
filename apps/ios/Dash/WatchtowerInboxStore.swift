import CloudflareAPI
import Foundation

/// Local ignore state for the Watchtower inbox.
/// Cloudflare notification history has no read API, so ignore is device-local
/// and account-scoped. The feed itself is CF delivery history plus Dash's
/// current non-ok Watchtower signals.
enum WatchtowerInboxStore {
  static let ignoredKey = "dash.watchtower_inbox_ignored"
  /// Best-effort merge window for Cloudflare + Dash rows about the same issue.
  static let dedupeWindow: TimeInterval = 48 * 3600

  private struct IgnoredPayload: Codable, Sendable {
    var byAccount: [String: [String]]
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
    var payload = ignoredPayload(defaults: defaults)
    var list = payload.byAccount[accountID] ?? []
    list.removeAll { $0 == entryID }
    payload.byAccount[accountID] = list
    saveIgnored(payload, defaults: defaults)
  }

  static func ignoreAll(
    _ entryIDs: [String], accountID: String, defaults: UserDefaults = .standard
  ) {
    ignore(entryIDs, accountID: accountID, defaults: defaults)
  }

  static func liveDashID(signalID: String) -> String { "dash:live:\(signalID)" }

  // MARK: Feed

  /// Active (non-ignored) inbox rows — drives the Watchtower tab badge and
  /// the floating inbox count.
  static func activeCount(
    accountID: String,
    alerts: [NotificationHistoryEntry],
    signals: [WatchtowerSignal] = [],
    defaults: UserDefaults = .standard
  ) -> Int {
    build(
      accountID: accountID, alerts: alerts, signals: signals, defaults: defaults
    )
    .filter { !ignoredIDs(accountID: accountID, defaults: defaults).contains($0.id) }
    .count
  }

  static func build(
    accountID: String,
    alerts: [NotificationHistoryEntry],
    signals: [WatchtowerSignal] = [],
    defaults: UserDefaults = .standard
  ) -> [WatchtowerInboxEntry] {
    var entries: [WatchtowerInboxEntry] = alerts.map { alert in
      WatchtowerInboxEntry(
        id: "cf:\(alert.id)",
        title: alert.title,
        detail: alert.subtitle,
        sentAt: alert.sent.flatMap(parseISO8601),
        sources: [.cloudflare],
        destination: nil,
        externalURL: nil,
        status: nil,
        signalID: nil
      )
    }

    let muted = WatchtowerMuteStore.mutedIDs(defaults: defaults)
    for signal in signals where signal.status != .ok {
      // Mute hides the check from Watchtower health; keep it out of the inbox.
      guard !muted.contains(signal.id) else { continue }
      let detail: String = {
        if let resource = signal.resourceName, !signal.detail.contains(resource) {
          return "\(signal.detail) · \(resource)"
        }
        return signal.detail
      }()
      entries.append(
        WatchtowerInboxEntry(
          id: liveDashID(signalID: signal.id),
          title: signal.title,
          detail: detail,
          sentAt: signal.observedAt,
          sources: [.dash],
          destination: signal.destination,
          externalURL: signal.externalURL,
          status: signal.status,
          signalID: signal.id
        ))
    }

    return dedupe(entries).sorted {
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
      signalID: dashFirst.signalID ?? other.signalID
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

  var primarySource: WatchtowerInboxSource {
    sources.contains(.dash) ? .dash : .cloudflare
  }
}
