import Foundation

/// Last-used R2 upload destination per account, shared with the DashShare
/// extension through App Group defaults so the share sheet lands where the
/// user last uploaded. JSON (not pipes) because bucket names and prefixes can
/// contain any separator — the same reasoning as `RecentResources`.
///
/// Compiled into the app, share extension, and File Provider; keep it
/// Foundation-only.
struct R2ShareDestination: Codable, Equatable, Sendable {
  static let appGroupID = DashAppGroup.id
  static let destinationsKey = "dash.r2_share_destinations"
  /// The share extension cannot present Cloudflare's OAuth flow. Real-account
  /// sign-in already requests these with `core`; every process-outside-the-app
  /// upload still checks the shared Keychain scope record before issuing a PUT
  /// (Demo and signed-out sessions fail closed).
  static let requiredWriteScopes: Set<String> = [
    "workers-r2.write",
    "workers-r2-bucket-item.write",
  ]

  static func hasWriteAccess(grantedScopes: Set<String>?) -> Bool {
    guard let grantedScopes else { return false }
    return requiredWriteScopes.isSubset(of: grantedScopes)
  }
  /// Mirror of the app's standard-defaults active account id — extensions
  /// can't read `UserDefaults.standard` across processes.
  static let activeAccountKey = DashAppGroup.activeAccountKey
  static let limit = 8

  var accountID: String
  var bucket: String
  var prefix: String
  /// The bucket's public host at last sighting (custom domain or r2.dev), so
  /// the extension can copy a URL without extra requests. Empty = not public.
  var publicHost: String

  static var sharedDefaults: UserDefaults? {
    UserDefaults(suiteName: appGroupID)
  }

  static func activeAccountID(in defaults: UserDefaults? = sharedDefaults) -> String? {
    let value = defaults?.string(forKey: activeAccountKey)
    return value?.isEmpty == false ? value : nil
  }

  static func isActiveAccount(
    _ accountID: String,
    in defaults: UserDefaults? = sharedDefaults
  ) -> Bool {
    activeAccountID(in: defaults) == accountID
  }

  static func setActiveAccountID(_ accountID: String?, in defaults: UserDefaults? = sharedDefaults)
  {
    if let accountID {
      defaults?.set(accountID, forKey: activeAccountKey)
    } else {
      defaults?.removeObject(forKey: activeAccountKey)
    }
  }

  static func destination(
    accountID: String, in defaults: UserDefaults? = sharedDefaults
  ) -> R2ShareDestination? {
    decode(defaults?.string(forKey: destinationsKey) ?? "").first { $0.accountID == accountID }
  }

  static func record(
    _ destination: R2ShareDestination, in defaults: UserDefaults? = sharedDefaults
  ) {
    var all = decode(defaults?.string(forKey: destinationsKey) ?? "")
    all.removeAll { $0.accountID == destination.accountID }
    all.insert(destination, at: 0)
    if all.count > limit { all.removeLast(all.count - limit) }
    defaults?.set(encode(all), forKey: destinationsKey)
  }

  static func clear(in defaults: UserDefaults? = sharedDefaults) {
    defaults?.removeObject(forKey: destinationsKey)
    defaults?.removeObject(forKey: activeAccountKey)
  }

  static func decode(_ raw: String) -> [R2ShareDestination] {
    guard !raw.isEmpty,
      let decoded = try? JSONDecoder().decode([R2ShareDestination].self, from: Data(raw.utf8))
    else { return [] }
    return decoded
  }

  static func encode(_ destinations: [R2ShareDestination]) -> String {
    guard let data = try? JSONEncoder().encode(destinations) else { return "" }
    return String(decoding: data, as: UTF8.self)
  }
}
