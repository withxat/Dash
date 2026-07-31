import Foundation
import WidgetKit

/// App Group keys and mirrors shared by the app and DashWidgets. Keep this
/// file Foundation + WidgetKit only — no SwiftUI, CloudflareAPI, or app chrome.
enum DashWidgetBridges {
  static var defaults: UserDefaults? {
    UserDefaults(suiteName: DashAppGroup.id)
  }

  static var mirroredActiveAccountID: String? {
    let value = defaults?.string(forKey: DashAppGroup.activeAccountKey)
    return value?.isEmpty == false ? value : nil
  }
}

// MARK: - Chart style mirror

extension DashWidgetBridges {
  /// Same key as Settings → Chart style (`DashChartStylePreference.storageKey`).
  static let chartStyleKey = "dash.chart_style"
  static let chartStyleDefaultRaw = "dither"

  static func mirrorChartStyle(_ raw: String, in store: UserDefaults? = defaults) {
    store?.set(raw, forKey: chartStyleKey)
  }

  static func mirroredChartStyleRaw(in store: UserDefaults? = defaults) -> String {
    store?.string(forKey: chartStyleKey) ?? chartStyleDefaultRaw
  }

  static func mirroredChartStyleIsSystem(in store: UserDefaults? = defaults) -> Bool {
    mirroredChartStyleRaw(in: store) == "system"
  }

  /// `true` when Settings chose Swift Charts; anything else (including missing)
  /// keeps the dither sparkline widgets ship with today.
  static var mirroredChartStyleIsSystem: Bool {
    mirroredChartStyleIsSystem()
  }

  static func reloadMetricsWidgets() {
    WidgetCenter.shared.reloadTimelines(ofKind: MetricsWidgetKind.account)
    WidgetCenter.shared.reloadTimelines(ofKind: MetricsWidgetKind.domain)
  }
}

// MARK: - Language mirror

extension DashWidgetBridges {
  /// Same App Group mirror maintained by `DashAlertStrings`.
  static let languageKey = "dash.app_language"

  static func mirroredLocale(
    in store: UserDefaults? = defaults,
    systemLocale: Locale = .autoupdatingCurrent
  ) -> Locale {
    guard
      let raw = store?.string(forKey: languageKey),
      raw != "system",
      !raw.isEmpty
    else {
      return systemLocale
    }
    return Locale(identifier: raw)
  }
}

// MARK: - Quick actions

enum QuickActionsWidgetKind {
  static let id = "QuickActionsWidget"
}

enum HomeActionID: String, CaseIterable, Hashable, Identifiable, Sendable {
  case addDomain
  case uploadR2
  case addDNSRecord
  case createKVKey
  case createR2Bucket
  case addPagesDomain
  case addWorkerDomain
  case enableDevelopmentMode
  case enableUnderAttackMode
  case purgeCache

  var id: String { rawValue }
}

/// Home's operation buttons are independent from feature Shortcuts. A maximum
/// of three keeps the compact iPhone row stable while still letting people tune
/// the launcher to the work they actually do.
enum HomeActions {
  static let key = "dash.home_actions"
  static let limit = 3
  /// Used only while `key` is absent. `@AppStorage` continues to return a
  /// person's saved raw selection after an app update.
  static let defaults: [HomeActionID] = [.purgeCache, .enableUnderAttackMode, .uploadR2]
  static let defaultValue = encode(defaults)

  static func decode(_ raw: String) -> [HomeActionID] {
    var seen = Set<HomeActionID>()
    return raw.split(separator: ",").compactMap { token in
      guard let action = HomeActionID(rawValue: String(token)), seen.insert(action).inserted else {
        return nil
      }
      return action
    }
    .prefix(limit)
    .map { $0 }
  }

  static func encode(_ actions: [HomeActionID]) -> String {
    actions.prefix(limit).map(\.rawValue).joined(separator: ",")
  }

  static func toggled(_ action: HomeActionID, in raw: String) -> String {
    var actions = decode(raw)
    if let index = actions.firstIndex(of: action) {
      actions.remove(at: index)
    } else if actions.count < limit {
      actions.append(action)
    }
    return encode(actions)
  }

  static func mirrorToAppGroup(_ raw: String) {
    DashWidgetBridges.defaults?.set(raw, forKey: key)
    WidgetCenter.shared.reloadTimelines(ofKind: QuickActionsWidgetKind.id)
  }

  static func mirroredRaw(in store: UserDefaults? = DashWidgetBridges.defaults) -> String {
    store?.string(forKey: key) ?? defaultValue
  }

  static func mirroredActions(in store: UserDefaults? = DashWidgetBridges.defaults)
    -> [HomeActionID]
  {
    decode(mirroredRaw(in: store))
  }

  /// `dash://action/<id>?account=<account-id>` — account is optional but
  /// producers that know the active account should include it.
  static func deepLink(action: HomeActionID, accountID: String?) -> URL? {
    var components = URLComponents()
    components.scheme = "dash"
    components.host = "action"
    components.path = "/\(action.rawValue)"
    if let accountID {
      let trimmed = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        components.queryItems = [URLQueryItem(name: "account", value: trimmed)]
      }
    }
    return components.url
  }
}
