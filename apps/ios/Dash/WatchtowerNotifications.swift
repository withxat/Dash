import Foundation
import UserNotifications

/// Decides which local notifications a Watchtower refresh should fire, by
/// diffing the previous account baseline against the new one. Pure so the
/// rules are unit-tested; display state remains a single current-account
/// widget file, while notification baselines stay isolated per account.
enum WatchtowerNotificationPlanner {
  struct Plan: Equatable {
    var identifier: String
    var title: String
    var body: String
  }

  /// Coverage is a permanent sampling limit, not a new operational issue.
  private static func isNotifiable(_ signal: WatchtowerWidgetSnapshot.Signal) -> Bool {
    signal.title != WatchtowerEngine.coverageSignalTitle
  }

  private static func severity(_ status: String) -> Int {
    switch status {
    case "critical": 2
    case "warning": 1
    default: 0
    }
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
    previous: WatchtowerWidgetSnapshot?, current: WatchtowerWidgetSnapshot,
    mutedTitles: Set<String> = []
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

    let previousStatuses = previous.signals.reduce(into: [String: String]()) {
      $0[$1.title] = $1.status
    }
    let newIssues = current.signals.filter { signal in
      guard isNotifiable(signal), !mutedTitles.contains(signal.title) else { return false }
      return severity(signal.status) > severity(previousStatuses[signal.title] ?? "ok")
    }

    guard let first = newIssues.first else { return [] }
    guard newIssues.count > 1 else {
      return [
        Plan(
          identifier: "watchtower.\(first.status).\(first.title)",
          title: first.title,
          body: first.detail)
      ]
    }

    let remaining = newIssues.count - 1
    return [
      Plan(
        identifier: "watchtower.issues",
        title: first.title,
        body:
          "\(first.detail) · \(remaining) more \(remaining == 1 ? "issue needs" : "issues need") attention."
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

  nonisolated static func watchtowerRoute(accountID: String) -> String? {
    let accountID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !accountID.isEmpty else { return nil }
    var components = URLComponents()
    components.scheme = "dash"
    components.host = "watchtower"
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
    guard settings.authorizationStatus == .authorized else { return }

    let mutedTitles = WatchtowerMuteStore.mutedTitles(accountID: accountID)

    for plan in WatchtowerNotificationPlanner.plans(
      previous: previous, current: current, mutedTitles: mutedTitles
    ) {
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

  /// Prompts only for local notification authorization.
  static func requestAuthorization() async -> Bool {
    let center = UNUserNotificationCenter.current()
    return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
  }

  /// Current system authorization (does not prompt).
  static func isAuthorized() async -> Bool {
    let settings = await UNUserNotificationCenter.current().notificationSettings()
    switch settings.authorizationStatus {
    case .authorized, .provisional, .ephemeral:
      return true
    case .notDetermined, .denied:
      return false
    @unknown default:
      return false
    }
  }
}
