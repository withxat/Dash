import CloudflareAPI
import Foundation

/// Persisted, account-scoped mute / snooze for Watchtower signal ids. Muted ids
/// are hidden from local notifications and can be filtered from the issues
/// list without suppressing a same-named signal in another account.
enum WatchtowerMuteStore {
  static let key = "dash.watchtower_muted_by_account"
  /// Older builds stored one global array here. It is intentionally not
  /// migrated because no account can be attributed to those entries safely.
  static let legacyKey = "dash.watchtower_muted"
  /// Default snooze window when the user mutes a check.
  static let defaultDuration: TimeInterval = 24 * 3600

  struct Entry: Codable, Hashable, Sendable {
    var id: String
    var title: String
    var until: Date
  }

  private struct Payload: Codable, Sendable {
    var byAccount: [String: [Entry]]
  }

  private static func normalizedAccountID(_ accountID: String) -> String? {
    let accountID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
    return accountID.isEmpty ? nil : accountID
  }

  private static func payload(defaults: UserDefaults) -> Payload {
    guard let data = defaults.data(forKey: key),
      let decoded = try? JSONDecoder().decode(Payload.self, from: data)
    else {
      return Payload(byAccount: [:])
    }
    return decoded
  }

  private static func save(_ payload: Payload, defaults: UserDefaults) {
    guard let data = try? JSONEncoder().encode(payload) else { return }
    defaults.set(data, forKey: key)
  }

  static func entries(
    accountID: String,
    defaults: UserDefaults = .standard
  ) -> [Entry] {
    guard let accountID = normalizedAccountID(accountID) else { return [] }
    let now = Date()
    return (payload(defaults: defaults).byAccount[accountID] ?? [])
      .filter { $0.until > now }
  }

  static func mutedIDs(
    accountID: String,
    defaults: UserDefaults = .standard
  ) -> Set<String> {
    Set(entries(accountID: accountID, defaults: defaults).map(\.id))
  }

  static func mutedTitles(
    accountID: String,
    defaults: UserDefaults = .standard
  ) -> Set<String> {
    Set(entries(accountID: accountID, defaults: defaults).map(\.title))
  }

  static func isMuted(
    _ id: String,
    accountID: String,
    defaults: UserDefaults = .standard
  ) -> Bool {
    mutedIDs(accountID: accountID, defaults: defaults).contains(id)
  }

  static func mute(
    _ id: String,
    title: String,
    accountID: String,
    for duration: TimeInterval = defaultDuration,
    defaults: UserDefaults = .standard
  ) {
    guard let accountID = normalizedAccountID(accountID) else { return }
    var payload = payload(defaults: defaults)
    var next = (payload.byAccount[accountID] ?? [])
      .filter { $0.until > .now && $0.id != id }
    next.append(Entry(id: id, title: title, until: Date().addingTimeInterval(duration)))
    payload.byAccount[accountID] = next
    save(payload, defaults: defaults)
  }

  static func unmute(
    _ id: String,
    accountID: String,
    defaults: UserDefaults = .standard
  ) {
    guard let accountID = normalizedAccountID(accountID) else { return }
    var payload = payload(defaults: defaults)
    let next = (payload.byAccount[accountID] ?? [])
      .filter { $0.until > .now && $0.id != id }
    if next.isEmpty {
      payload.byAccount.removeValue(forKey: accountID)
    } else {
      payload.byAccount[accountID] = next
    }
    save(payload, defaults: defaults)
  }
}

/// Account-level feature readiness for Watchtower / Push surfaces.
enum DashCapabilityStatus: Hashable, Sendable {
  case available
  case needsPermission
  case needsPlan
  case unknown

  static func from(apiError: CloudflareAPIError?) -> DashCapabilityStatus {
    guard let apiError else { return .unknown }
    if apiError.isForbidden { return .needsPermission }
    if apiError.isMissingEntitlement { return .needsPlan }
    return .unknown
  }
}

extension CloudflareAPIError {
  var isMissingEntitlement: Bool {
    let haystack = (errorDescription ?? "").lowercased()
    return haystack.contains("not entitled")
      || haystack.contains("not enabled")
      || haystack.contains("upgrade")
      || haystack.contains("plan")
      || haystack.contains("subscription")
  }
}
