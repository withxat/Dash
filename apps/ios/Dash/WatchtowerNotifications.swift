import Foundation
import UIKit
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

  private static func notifiableIssueCount(_ snapshot: WatchtowerWidgetSnapshot) -> Int {
    snapshot.signals.filter { $0.status != "ok" && isNotifiable($0) }.count
  }

  static func plans(
    previous: WatchtowerWidgetSnapshot?, current: WatchtowerWidgetSnapshot
  ) -> [Plan] {
    // Nothing to compare against on a first run.
    guard let previous else { return [] }

    // Signals that are critical now but weren't before → one alert each, with
    // a stable identifier so a still-critical signal never re-notifies.
    let previousCritical = Set(
      previous.signals.filter { $0.status == "critical" && isNotifiable($0) }.map(\.title))
    let newCritical = current.signals.filter {
      $0.status == "critical" && isNotifiable($0) && !previousCritical.contains($0.title)
    }
    if !newCritical.isEmpty {
      return newCritical.map { signal in
        Plan(
          identifier: "watchtower.critical.\(signal.title)",
          title: signal.title,
          body: signal.detail)
      }
    }

    // Otherwise, a rise in the overall issue count → one summary alert.
    let previousCount = notifiableIssueCount(previous)
    let currentCount = notifiableIssueCount(current)
    if currentCount > previousCount {
      return [
        Plan(
          identifier: "watchtower.issues",
          title: "Watchtower",
          body:
            "\(currentCount) \(currentCount == 1 ? "issue needs" : "issues need") attention."
        )
      ]
    }

    return []
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

    for plan in WatchtowerNotificationPlanner.plans(previous: previous, current: current) {
      let content = UNMutableNotificationContent()
      content.title = plan.title
      content.body = plan.body
      content.sound = .default
      let request = UNNotificationRequest(
        identifier: plan.identifier, content: content, trigger: nil)
      try? await center.add(request)
    }
  }

  /// Prompts for authorization; returns whether alerts are allowed.
  /// On grant, also registers for remote notifications so Account → Alerts
  /// push can mint a device token (local Watchtower alerts need only the
  /// authorization; remote registration is idempotent and cheap).
  static func requestAuthorization() async -> Bool {
    let center = UNUserNotificationCenter.current()
    let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    if granted {
      await MainActor.run {
        UIApplication.shared.registerForRemoteNotifications()
      }
    }
    return granted
  }
}
