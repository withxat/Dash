import Foundation
import UserNotifications

/// Where a notification action sends the user, expressed as a transform of the
/// route the notification already carries.
///
/// The relay sends one `dashRoute`; the actions derive theirs from it. That
/// keeps the resource identifier — and the `?account=` scope the app checks
/// before opening anything — in exactly one place. An action that shipped its
/// own literal route would be a second, unaudited way for a push to name a
/// destination.
enum DashNotificationRouteTransform: Equatable, Sendable {
  /// Replace a zone route's section, e.g. `dash://zone/<id>` → `…/<id>/cache`.
  case zoneSection(DashZoneSection)
  /// Drop a Pages deployment and land on its project.
  case pagesProject
  case watchtower

  enum DashZoneSection: String, Equatable, Sendable {
    case cache
    case settings
    case waf
  }

  /// Pure route derivation. Returns nil when the delivered route cannot satisfy
  /// this transform, in which case the action falls back to the plain tap route
  /// rather than opening something unrelated.
  func apply(to route: DashRoute) -> DashRoute? {
    let accountID = route.accountID
    let derived: DashRoute?

    switch (self, route.unscoped) {
    case (.watchtower, _):
      derived = .watchtower

    case (.zoneSection(let section), let unscoped):
      guard let zoneID = unscoped.zoneID else { return nil }
      derived =
        switch section {
        case .cache: .zoneCache(zoneID)
        case .settings: .zoneSettings(zoneID)
        case .waf: .zoneWAF(zoneID)
        }

    case (.pagesProject, .pagesDeployment(let project, _)),
      (.pagesProject, .pagesDomains(let project)),
      (.pagesProject, .pagesProject(let project)):
      derived = .pagesProject(project)

    case (.pagesProject, _):
      derived = nil
    }

    guard let derived else { return nil }
    return accountID.map { derived.scoped(to: $0) } ?? derived
  }
}

struct DashNotificationAction: Equatable, Sendable {
  let identifier: String
  let title: String
  let transform: DashNotificationRouteTransform
}

/// The notification categories the relay may name in `aps.category`.
///
/// Raw values are a wire contract with `AlertCategory` in the relay's
/// `alert.ts`. A value the app does not register arrives as a notification with
/// no buttons — harmless, but it means the two lists drifted.
///
/// Every action opens the app. Purging a cache or flipping Under Attack from a
/// Lock Screen button would be an unconfirmed write against live traffic, so the
/// buttons are shortcuts to the screen that performs the change behind its own
/// confirmation — not a way to skip it.
enum DashNotificationCategory: String, CaseIterable, Sendable {
  case generic = "dash.alert.generic"
  case pages = "dash.alert.pages"
  case worker = "dash.alert.worker"
  case zoneAttack = "dash.alert.zone.attack"
  case zoneCertificate = "dash.alert.zone.certificate"
  case zoneOrigin = "dash.alert.zone.origin"

  var actions: [DashNotificationAction] {
    switch self {
    case .zoneOrigin:
      // Origin 5xx: the first thing you try is serving a fresh copy.
      [
        DashNotificationAction(
          identifier: "dash.action.purge",
          title: DashL10n.string("Purge cache"),
          transform: .zoneSection(.cache))
      ]
    case .zoneAttack:
      // The tap lands on the zone; Under Attack lives one screen deeper.
      [
        DashNotificationAction(
          identifier: "dash.action.security",
          title: DashL10n.string("Security"),
          transform: .zoneSection(.waf))
      ]
    case .zoneCertificate:
      [
        DashNotificationAction(
          identifier: "dash.action.zoneSettings",
          title: DashL10n.string("Domain settings"),
          transform: .zoneSection(.settings))
      ]
    case .pages:
      // The tap opens the deployment; the project shows the surrounding history.
      [
        DashNotificationAction(
          identifier: "dash.action.pagesProject",
          title: DashL10n.string("All deployments"),
          transform: .pagesProject)
      ]
    case .generic, .worker:
      [
        DashNotificationAction(
          identifier: "dash.action.watchtower",
          title: DashL10n.string("Open Watchtower"),
          transform: .watchtower)
      ]
    }
  }

  /// Resolves an action identifier back to its route, given the notification's
  /// own route. Pure, so the routing rules are unit-testable without a device.
  static func route(
    forAction actionIdentifier: String,
    category: String?,
    notificationRoute: DashRoute
  ) -> DashRoute {
    guard actionIdentifier != UNNotificationDefaultActionIdentifier,
      let category = category.flatMap(DashNotificationCategory.init(rawValue:)),
      let action = category.actions.first(where: { $0.identifier == actionIdentifier })
    else {
      return notificationRoute
    }
    return action.transform.apply(to: notificationRoute) ?? notificationRoute
  }

  private var unNotificationCategory: UNNotificationCategory {
    UNNotificationCategory(
      identifier: rawValue,
      actions: actions.map {
        UNNotificationAction(
          identifier: $0.identifier,
          title: $0.title,
          // .foreground so the destination screen — and its confirmation — is
          // what actually runs. No action mutates anything on its own.
          options: [.foreground])
      },
      intentIdentifiers: [],
      options: [])
  }

  static func registerAll(with center: UNUserNotificationCenter = .current()) {
    center.setNotificationCategories(Set(allCases.map(\.unNotificationCategory)))
  }
}

extension DashRoute {
  /// The zone this route is about, if any. Used to retarget an action at a
  /// different section of the same domain.
  var zoneID: String? {
    switch self {
    case .zone(let id), .zoneAnalytics(let id), .zoneCache(let id), .zoneDNS(let id),
      .zoneSettings(let id), .zoneWAF(let id):
      id
    case .scoped(_, let route):
      route.zoneID
    case .feature, .kv, .pagesDeployment, .pagesDomains, .pagesProject, .r2, .settings, .watchtower,
      .worker:
      nil
    }
  }
}
