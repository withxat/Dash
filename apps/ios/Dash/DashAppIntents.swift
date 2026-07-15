import AppIntents
import CloudflareAPI
import Foundation

/// Surfaced to Siri, Spotlight, and the Shortcuts app. In-app intents run in
/// the app process, so they reuse the app's single `CloudflareClient` (via
/// `@Dependency`) to preserve its single-flight token refresh.
struct DashIntentError: Error, CustomLocalizedStringResourceConvertible {
  let message: String
  var localizedStringResource: LocalizedStringResource { "\(message)" }

  static let signedOut = DashIntentError(
    message: "Open Dash and sign in to your Cloudflare account first.")
}

/// A Cloudflare zone, chosen in Shortcuts by name.
struct ZoneEntity: AppEntity, Identifiable {
  let id: String
  let name: String

  static let typeDisplayRepresentation: TypeDisplayRepresentation = "Zone"
  var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
  static let defaultQuery = ZoneEntityQuery()

  init(id: String, name: String) {
    self.id = id
    self.name = name
  }
  init(zone: CloudflareZone) {
    self.init(id: zone.id, name: zone.name)
  }
}

struct ZoneEntityQuery: EntityStringQuery {
  @Dependency private var model: AppModel

  @MainActor
  private func accountID() throws -> String {
    guard let accountID = model.activeAccountID else { throw DashIntentError.signedOut }
    return accountID
  }

  @MainActor
  func entities(for identifiers: [String]) async throws -> [ZoneEntity] {
    var zones: [ZoneEntity] = []
    for id in identifiers {
      if let zone = try? await model.client.getZone(id) {
        zones.append(ZoneEntity(zone: zone))
      }
    }
    return zones
  }

  @MainActor
  func entities(matching string: String) async throws -> [ZoneEntity] {
    let page = try await model.client.listZones(accountID: try accountID(), name: string)
    return page.items.map(ZoneEntity.init(zone:))
  }

  @MainActor
  func suggestedEntities() async throws -> [ZoneEntity] {
    let accountID = try accountID()
    if let cached: [CloudflareZone] = model.featureCache.get(FeatureCacheKey.zones(accountID)) {
      return cached.map(ZoneEntity.init(zone:))
    }
    let page = try await model.client.listZones(accountID: accountID)
    return page.items.map(ZoneEntity.init(zone:))
  }
}

struct PurgeCacheIntent: AppIntent {
  static let title: LocalizedStringResource = "Purge Cache"
  static let description = IntentDescription("Purge everything from a Cloudflare zone's cache.")

  @Parameter(title: "Zone") var zone: ZoneEntity
  @Dependency private var model: AppModel

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    // The non-deprecated requestConfirmation(conditions:actionName:dialog:) is
    // iOS 18+, and the old overload is deprecated unconditionally (no version),
    // so this warns until IPHONEOS_DEPLOYMENT_TARGET reaches 18.0.
    try await requestConfirmation(
      result: .result(dialog: "Purge everything from \(zone.name)'s cache?"))
    try await model.client.purgeCache(zoneID: zone.id, files: nil)
    return .result(dialog: "Purged everything from \(zone.name).")
  }
}

struct SetUnderAttackIntent: AppIntent {
  static let title: LocalizedStringResource = "Set Under Attack Mode"
  static let description = IntentDescription(
    "Turn Under Attack mode on, or restore the previous security level.")

  @Parameter(title: "Zone") var zone: ZoneEntity
  @Parameter(title: "Enabled") var enabled: Bool
  @Dependency private var model: AppModel

  private static func stashKey(_ zoneID: String) -> String {
    "dash.previous_security_level.\(zoneID)"
  }

  /// Pure: the level to restore when turning Under Attack off.
  static func restoreLevel(stashed: String?) -> String { stashed ?? "medium" }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    let defaults = UserDefaults.standard
    if enabled {
      let settings = try await model.client.listZoneSettings(zoneID: zone.id)
      if case .string(let current)? = settings.first(where: { $0.id == "security_level" })?.value {
        defaults.set(current, forKey: Self.stashKey(zone.id))
      }
      _ = try await model.client.updateZoneSetting(
        zoneID: zone.id, settingID: "security_level", value: .string("under_attack"))
      return .result(dialog: "Under Attack mode is on for \(zone.name).")
    } else {
      let level = Self.restoreLevel(stashed: defaults.string(forKey: Self.stashKey(zone.id)))
      defaults.removeObject(forKey: Self.stashKey(zone.id))
      _ = try await model.client.updateZoneSetting(
        zoneID: zone.id, settingID: "security_level", value: .string(level))
      return .result(dialog: "Security level for \(zone.name) restored to \(displayLevel(level)).")
    }
  }

  private func displayLevel(_ level: String) -> String {
    level.replacingOccurrences(of: "_", with: " ").capitalized
  }
}

struct ToggleDevelopmentModeIntent: AppIntent {
  static let title: LocalizedStringResource = "Set Development Mode"
  static let description = IntentDescription(
    "Turn a zone's development mode on or off. Cloudflare auto-disables it after three hours.")

  @Parameter(title: "Zone") var zone: ZoneEntity
  @Parameter(title: "Enabled") var enabled: Bool
  @Dependency private var model: AppModel

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    _ = try await model.client.updateZoneSetting(
      zoneID: zone.id, settingID: "development_mode", value: .string(enabled ? "on" : "off"))
    return .result(
      dialog: enabled
        ? "Development mode is on for \(zone.name). Cloudflare turns it off automatically after three hours."
        : "Development mode is off for \(zone.name).")
  }
}

struct OpenWatchtowerIntent: AppIntent {
  static let title: LocalizedStringResource = "Open Watchtower"
  static let description = IntentDescription("Open Dash to the Watchtower health screen.")
  static let openAppWhenRun = true

  @Dependency private var model: AppModel

  @MainActor
  func perform() async throws -> some IntentResult {
    model.pendingRoute = .watchtower
    return .result()
  }
}

struct DashShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: PurgeCacheIntent(),
      phrases: ["Purge cache with \(.applicationName)"],
      shortTitle: "Purge Cache",
      systemImageName: "trash")
    AppShortcut(
      intent: SetUnderAttackIntent(),
      phrases: ["Set under attack mode in \(.applicationName)"],
      shortTitle: "Under Attack Mode",
      systemImageName: "shield.lefthalf.filled")
    AppShortcut(
      intent: ToggleDevelopmentModeIntent(),
      phrases: ["Set development mode in \(.applicationName)"],
      shortTitle: "Development Mode",
      systemImageName: "hammer")
    AppShortcut(
      intent: OpenWatchtowerIntent(),
      phrases: ["Open Watchtower in \(.applicationName)"],
      shortTitle: "Open Watchtower",
      systemImageName: "binoculars")
  }
}
