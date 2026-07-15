import CloudflareAPI
import Foundation

/// Persisted mute / snooze for Watchtower signal ids. Muted ids are hidden from
/// local notifications and can be filtered from the issues list.
enum WatchtowerMuteStore {
  static let key = "dash.watchtower_muted"
  /// Default snooze window when the user mutes a check.
  static let defaultDuration: TimeInterval = 24 * 3600

  struct Entry: Codable, Hashable, Sendable {
    var id: String
    var title: String
    var until: Date
  }

  static func entries(defaults: UserDefaults = .standard) -> [Entry] {
    guard let data = defaults.data(forKey: key),
      let decoded = try? JSONDecoder().decode([Entry].self, from: data)
    else { return [] }
    let now = Date()
    return decoded.filter { $0.until > now }
  }

  static func mutedIDs(defaults: UserDefaults = .standard) -> Set<String> {
    Set(entries(defaults: defaults).map(\.id))
  }

  static func mutedTitles(defaults: UserDefaults = .standard) -> Set<String> {
    Set(entries(defaults: defaults).map(\.title))
  }

  static func isMuted(_ id: String, defaults: UserDefaults = .standard) -> Bool {
    mutedIDs(defaults: defaults).contains(id)
  }

  static func mute(
    _ id: String, title: String, for duration: TimeInterval = defaultDuration,
    defaults: UserDefaults = .standard
  ) {
    var next = entries(defaults: defaults).filter { $0.id != id }
    next.append(Entry(id: id, title: title, until: Date().addingTimeInterval(duration)))
    if let data = try? JSONEncoder().encode(next) {
      defaults.set(data, forKey: key)
    }
  }

  static func unmute(_ id: String, defaults: UserDefaults = .standard) {
    let next = entries(defaults: defaults).filter { $0.id != id }
    if let data = try? JSONEncoder().encode(next) {
      defaults.set(data, forKey: key)
    }
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
