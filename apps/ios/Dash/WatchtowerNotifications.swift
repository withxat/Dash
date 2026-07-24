import Foundation
import UserNotifications

/// Decides which local notifications a Watchtower refresh should fire, by
/// diffing the previous shared snapshot against the new one. Pure so the
/// rules are unit-tested; the previous value is the last snapshot written to
/// the App Group file, which is exactly the state last shown to the user.
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

  static func plans(
    previous: WatchtowerWidgetSnapshot?, current: WatchtowerWidgetSnapshot,
    mutedTitles: Set<String> = []
  ) -> [Plan] {
    // Nothing to compare against on a first run.
    guard let previous else { return [] }

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

/// Bridges the planner to UNUserNotificationCenter, gated on the user's opt-in
/// and system authorization.
@MainActor
enum WatchtowerNotifier {
  static let optInDefaultsKey = "dash.watchtower_notifications"

  static func notifyIfNeeded(
    previous: WatchtowerWidgetSnapshot?, current: WatchtowerWidgetSnapshot
  ) async {
    guard UserDefaults.standard.bool(forKey: optInDefaultsKey) else { return }
    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()
    guard settings.authorizationStatus == .authorized else { return }

    let mutedTitles = WatchtowerMuteStore.mutedTitles()

    for plan in WatchtowerNotificationPlanner.plans(
      previous: previous, current: current, mutedTitles: mutedTitles
    ) {
      let content = UNMutableNotificationContent()
      content.title = plan.title
      content.body = plan.body
      content.sound = .default
      content.userInfo = ["dashRoute": "dash://watchtower"]
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
