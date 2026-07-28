import Foundation
import UserNotifications

/// Decides which local notifications a Watchtower refresh should fire, by
/// diffing the previous account baseline against the new one. Pure so the
/// rules are unit-tested; display state remains a single current-account
/// widget file, while notification baselines stay isolated per account.
///
/// The diff is over Cloudflare's own deliveries: a delivery the account has not
/// seen before is worth a notification, and Dash never decides on its own that
/// something is wrong.
enum WatchtowerNotificationPlanner {
  struct Plan: Equatable {
    var identifier: String
    var title: String
    var body: String
  }

  private static func normalizedAccountID(
    in snapshot: WatchtowerWidgetSnapshot
  ) -> String? {
    guard
      let accountID = snapshot.accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
      !accountID.isEmpty
    else {
      return nil
    }
    return accountID
  }

  static func plans(
    previous: WatchtowerWidgetSnapshot?, current: WatchtowerWidgetSnapshot
  ) -> [Plan] {
    // Nothing to compare against on a first run. A snapshot from another
    // account — or a legacy snapshot without an account — is also a first run
    // for the current account and must never become its notification baseline.
    guard
      let previous,
      let currentAccountID = normalizedAccountID(in: current),
      normalizedAccountID(in: previous) == currentAccountID
    else {
      return []
    }

    let seen = Set(previous.alerts.map(\.id))
    let arrived = current.alerts.filter { !seen.contains($0.id) }

    guard let first = arrived.first else { return [] }
    guard arrived.count > 1 else {
      return [
        Plan(
          identifier: "watchtower.alert.\(first.id)",
          title: first.title,
          body: first.detail ?? "New alert from Cloudflare.")
      ]
    }

    let remaining = arrived.count - 1
    return [
      Plan(
        identifier: "watchtower.alerts",
        title: first.title,
        body:
          "\(first.detail ?? "New alert from Cloudflare.") · \(remaining) more unread \(remaining == 1 ? "alert" : "alerts")."
      )
    ]
  }
}

/// Persists the last notification comparison point per account. The widget
/// file cannot serve this role because account switches intentionally clear
/// that single display surface before the next account finishes loading.
enum WatchtowerNotificationBaselineStore {
  static let key = "dash.watchtower_notification_baselines"

  private struct Payload: Codable {
    var byAccount: [String: WatchtowerWidgetSnapshot]
  }

  static func snapshot(
    accountID: String,
    defaults: UserDefaults = .standard
  ) -> WatchtowerWidgetSnapshot? {
    guard !accountID.isEmpty else { return nil }
    return payload(defaults: defaults).byAccount[accountID]
  }

  static func store(
    _ snapshot: WatchtowerWidgetSnapshot,
    accountID: String,
    defaults: UserDefaults = .standard
  ) {
    guard !accountID.isEmpty, snapshot.accountID == accountID else { return }
    var payload = payload(defaults: defaults)
    payload.byAccount[accountID] = snapshot
    guard let data = try? JSONEncoder().encode(payload) else { return }
    defaults.set(data, forKey: key)
  }

  static func clearAll(defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: key)
  }

  private static func payload(defaults: UserDefaults) -> Payload {
    guard let data = defaults.data(forKey: key),
      let payload = try? JSONDecoder().decode(Payload.self, from: data)
    else {
      return Payload(byAccount: [:])
    }
    return payload
  }
}

/// Bridges the planner to UNUserNotificationCenter, gated on the user's opt-in
/// and system authorization.
@MainActor
enum WatchtowerNotifier {
  static let optInDefaultsKey = "dash.watchtower_notifications"
  static let badgeAuthorizationMigrationKey = "dash.notifications.badge_migration_v1"

  nonisolated static func watchtowerRoute(accountID: String) -> String? {
    route(host: "watchtower", path: nil, accountID: accountID)
  }

  /// Account-scoped deep link to one domain, for locally-scheduled reminders.
  nonisolated static func zoneRoute(zoneID: String, accountID: String) -> String? {
    let zoneID = zoneID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !zoneID.isEmpty else { return nil }
    return route(host: "zone", path: zoneID, accountID: accountID)
  }

  private nonisolated static func route(
    host: String,
    path: String?,
    accountID: String
  ) -> String? {
    let accountID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !accountID.isEmpty else { return nil }
    var components = URLComponents()
    components.scheme = "dash"
    components.host = host
    if let path {
      components.path = "/\(path)"
    }
    components.queryItems = [URLQueryItem(name: "account", value: accountID)]
    return components.url?.absoluteString
  }

  static func notifyIfNeeded(
    previous: WatchtowerWidgetSnapshot?,
    current: WatchtowerWidgetSnapshot,
    accountID: String
  ) async {
    guard UserDefaults.standard.bool(forKey: optInDefaultsKey) else { return }
    guard let route = watchtowerRoute(accountID: accountID) else { return }
    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()
    // Provisional counts: quiet delivery is still delivery, and dropping it
    // here would make the opt-in look broken to anyone who never saw a prompt.
    guard delivers(settings.authorizationStatus) else { return }

    for plan in WatchtowerNotificationPlanner.plans(previous: previous, current: current) {
      let content = UNMutableNotificationContent()
      content.title = plan.title
      content.body = plan.body
      content.sound = .default
      content.userInfo = ["dashRoute": route]
      let request = UNNotificationRequest(
        identifier: plan.identifier, content: content, trigger: nil)
      try? await center.add(request)
    }
  }

  /// Requests notification delivery.
  ///
  /// Provisional by default. iOS grants provisional authorization with no
  /// dialog and delivers quietly to Notification Center, then asks the user to
  /// keep or turn off notifications *on the first real alert* — when they can
  /// see what they are deciding about, instead of at the instant they flipped a
  /// switch and have nothing to judge. `.alert` and `.sound` ride along so the
  /// grant is already complete if they choose to keep them prominently.
  ///
  /// Pass `prominently: true` only for an explicit "turn on banners" action:
  /// that is the one case where the system prompt is what the user asked for.
  static func requestAuthorization(prominently: Bool = false) async -> Bool {
    let center = UNUserNotificationCenter.current()
    let options = authorizationOptions(prominently: prominently)
    return (try? await center.requestAuthorization(options: options)) ?? false
  }

  nonisolated static func authorizationOptions(
    prominently: Bool
  ) -> UNAuthorizationOptions {
    prominently ? [.alert, .sound, .badge] : [.alert, .sound, .badge, .provisional]
  }

  /// Older Dash versions asked for alerts and sounds without asking for badge
  /// delivery. Retry that missing option once for an already-authorized user;
  /// iOS remains authoritative when the user has since changed notification
  /// settings, and the migration never nags on every launch.
  static func migrateLegacyBadgeAuthorizationIfNeeded(
    defaults: UserDefaults = .standard
  ) async {
    guard !defaults.bool(forKey: badgeAuthorizationMigrationKey) else { return }
    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()
    guard
      let options = badgeAuthorizationMigrationOptions(
        authorizationStatus: settings.authorizationStatus,
        badgeSetting: settings.badgeSetting)
    else {
      defaults.set(true, forKey: badgeAuthorizationMigrationKey)
      return
    }
    _ = try? await center.requestAuthorization(options: options)
    defaults.set(true, forKey: badgeAuthorizationMigrationKey)
  }

  /// Preserve quiet authorization while adding the previously omitted badge
  /// option. Only an explicit "turn on banners" action may make a prominent
  /// request.
  nonisolated static func badgeAuthorizationMigrationOptions(
    authorizationStatus: UNAuthorizationStatus,
    badgeSetting: UNNotificationSetting
  ) -> UNAuthorizationOptions? {
    guard badgeSetting == .disabled else { return nil }
    switch authorizationStatus {
    case .authorized:
      return [.badge]
    case .provisional:
      return [.badge, .provisional]
    case .notDetermined, .denied, .ephemeral:
      return nil
    @unknown default:
      return nil
    }
  }

  /// True once the system will deliver anything at all, quietly or otherwise.
  static func isAuthorized() async -> Bool {
    delivers(await UNUserNotificationCenter.current().notificationSettings().authorizationStatus)
  }

  /// True while Dash is delivering quietly and could be promoted to banners.
  static func isProvisional() async -> Bool {
    await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
      == .provisional
  }

  /// Pure predicate over a Sendable enum, so it carries no main-actor
  /// requirement of its own and only inherited one from the enclosing type.
  /// `ExpiryReminders` is nonisolated and needs to ask the same question.
  nonisolated static func delivers(_ status: UNAuthorizationStatus) -> Bool {
    switch status {
    case .authorized, .provisional, .ephemeral:
      return true
    case .notDetermined, .denied:
      return false
    @unknown default:
      return false
    }
  }
}
