import CloudflareAPI
import SwiftUI

/// Bot Management for one zone: renders whichever boolean switches the
/// account's plan actually returns and PUTs the mutated config back.
struct BotManagementView: View {
  @Environment(AppModel.self) private var model
  let zoneID: String
  let zoneName: String
  @State private var config: [String: JSONValue] = [:]
  @State private var loading = true
  @State private var error: String?
  @State private var saveError: String?

  /// Response keys the API reports but refuses in a PUT.
  private static let readOnlyKeys: Set<String> = [
    "using_latest_model", "stale_zone_configuration",
  ]

  private static let labels: [String: (title: String, subtitle: String)] = [
    "fight_mode": ("Bot Fight Mode", "Challenge traffic matching known bot patterns"),
    "enable_js": ("JavaScript detections", "Detect headless browsers with lightweight JS"),
    "suppress_session_score": ("Suppress session score", "Disable session-based bot scoring"),
    "auto_update_model": ("Auto-update model", "Adopt new detection models automatically"),
    "optimize_wordpress": ("Optimize for WordPress", "Reduce false positives on WordPress paths"),
    "crawler_protection": ("Crawler protection", "Block AI crawlers scraping this zone"),
  ]

  private var toggleKeys: [String] {
    config.keys
      .filter { key in
        guard !Self.readOnlyKeys.contains(key) else { return false }
        if case .bool = config[key] { return true }
        return false
      }
      .sorted()
  }

  private var infoRows: [(key: String, value: String)] {
    config
      .compactMap { key, value -> (String, String)? in
        guard case .string(let string) = value else { return nil }
        return (key, string)
      }
      .sorted { $0.0 < $1.0 }
  }

  private var allowsWrites: Bool {
    FeatureID.botManagement.capability.accessLevel(grantedScopes: model.grantedScopes) == .full
  }

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      retry: { Task { await load(force: true) } }
    ) {
      if let saveError {
        DashNotice(kind: .error, message: saveError)
      }
      if !toggleKeys.isEmpty {
        VStack(spacing: 12) {
          ForEach(toggleKeys, id: \.self) { key in
            DashToggleRow(
              title: Self.labels[key]?.title ?? key.replacingOccurrences(of: "_", with: " "),
              subtitle: Self.labels[key]?.subtitle,
              isOn: binding(for: key),
              isEnabled: allowsWrites
            )
          }
        }
      }
      if !infoRows.isEmpty {
        VStack(spacing: 12) {
          ForEach(infoRows, id: \.key) { row in
            DashValueCard(
              title: row.key.replacingOccurrences(of: "_", with: " "),
              value: row.value
            )
          }
        }
      }
      if !loading, toggleKeys.isEmpty, infoRows.isEmpty, error == nil {
        DashEmptyState(
          icon: SolarAsset.shield,
          title: "No Bot Management config",
          message: "Cloudflare returned no configuration for this zone."
        )
      }
    }
    .navigationTitle(zoneName)
    .navigationBarTitleDisplayMode(.inline)
    .refreshable { await load(force: true) }
    .task { await load() }
  }

  private func binding(for key: String) -> Binding<Bool> {
    Binding(
      get: {
        if case .bool(let value)? = config[key] { return value }
        return false
      },
      set: { newValue in
        let previous = config
        config[key] = .bool(newValue)
        Task { await save(revertingTo: previous) }
      }
    )
  }

  private func save(revertingTo previous: [String: JSONValue]) async {
    let body = config.filter { !Self.readOnlyKeys.contains($0.key) }
    do {
      let result = try await model.client.mutate(
        path: "/zones/\(zoneID)/bot_management", method: "PUT", body: body)
      if case .object(let updated) = result { config = updated }
      saveError = nil
    } catch {
      config = previous
      saveError = error.dashActionableMessage
    }
  }

  private func load(force: Bool = false) async {
    let key = FeatureCacheKey.generic(path: "/zones/\(zoneID)/bot_management")
    if !force, let cached: [String: JSONValue] = model.featureCache.get(key) {
      config = cached
      loading = false
      return
    }
    if config.isEmpty { loading = true }
    error = nil
    do {
      let result = try await model.client.mutate(
        path: "/zones/\(zoneID)/bot_management", method: "GET")
      if case .object(let object) = result { config = object }
      model.featureCache.set(key, config)
    } catch {
      self.error = error.dashActionableMessage
    }
    loading = false
  }
}

/// Cache & performance switches for one zone. Each setting is its own
/// endpoint; plan-gated ones surface their error inline and stay disabled.
struct CachePerformanceView: View {
  @Environment(AppModel.self) private var model
  let zoneID: String
  let zoneName: String

  private struct Setting: Identifiable {
    let title: String
    let subtitle: String
    let path: String
    var id: String { path }
  }

  private static let settings: [Setting] = [
    Setting(
      title: "Argo Smart Routing", subtitle: "Route traffic across the fastest paths",
      path: "argo/smart_routing"),
    Setting(
      title: "Argo Tiered Caching", subtitle: "Serve misses from upper-tier data centers",
      path: "argo/tiered_caching"),
    Setting(
      title: "Cache Reserve", subtitle: "Persistent R2-backed cache retention",
      path: "cache/cache_reserve"),
    Setting(
      title: "Regional Tiered Cache", subtitle: "Add a regional tier for dynamic content",
      path: "cache/regional_tiered_cache"),
  ]

  @State private var values: [String: Bool] = [:]
  @State private var rowErrors: [String: String] = [:]
  @State private var loading = true
  @State private var saveError: String?

  private var allowsWrites: Bool {
    FeatureID.cacheSettings.capability.accessLevel(grantedScopes: model.grantedScopes) == .full
  }

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: nil,
      retry: { Task { await load() } }
    ) {
      if let saveError {
        DashNotice(kind: .error, message: saveError)
      }
      VStack(spacing: 12) {
        ForEach(Self.settings) { setting in
          if let message = rowErrors[setting.path] {
            DashValueCard(title: setting.title, value: "unavailable", caption: message)
          } else {
            DashToggleRow(
              title: setting.title,
              subtitle: setting.subtitle,
              isOn: binding(for: setting),
              isEnabled: allowsWrites && values[setting.path] != nil
            )
          }
        }
      }
      DashListCard {
        DashListGroupLink(value: .cache(zoneID)) {
          DashListRow(
            title: "Purge cache",
            subtitle: "Purge everything or selected URLs",
            icon: SolarAsset.trash
          )
        }
      }
    }
    .navigationTitle(zoneName)
    .navigationBarTitleDisplayMode(.inline)
    .refreshable { await load() }
    .task { await load() }
  }

  private func binding(for setting: Setting) -> Binding<Bool> {
    Binding(
      get: { values[setting.path] ?? false },
      set: { newValue in
        let previous = values[setting.path]
        values[setting.path] = newValue
        Task { await save(setting: setting, enabled: newValue, previous: previous) }
      }
    )
  }

  private func save(setting: Setting, enabled: Bool, previous: Bool?) async {
    do {
      _ = try await model.client.mutate(
        path: "/zones/\(zoneID)/\(setting.path)", method: "PATCH",
        body: ["value": .string(enabled ? "on" : "off")])
      saveError = nil
    } catch {
      values[setting.path] = previous
      saveError = error.dashActionableMessage
    }
  }

  private func load() async {
    loading = values.isEmpty
    let client = model.client
    let zoneID = zoneID
    await withTaskGroup(of: (String, Result<Bool, Error>).self) { group in
      for setting in Self.settings {
        group.addTask {
          do {
            let result = try await client.mutate(
              path: "/zones/\(zoneID)/\(setting.path)", method: "GET")
            if case .object(let object) = result, case .string(let value)? = object["value"] {
              return (setting.path, .success(value == "on"))
            }
            return (setting.path, .success(false))
          } catch {
            return (setting.path, .failure(error))
          }
        }
      }
      for await (path, outcome) in group {
        switch outcome {
        case .success(let enabled):
          values[path] = enabled
          rowErrors[path] = nil
        case .failure(let error):
          rowErrors[path] = error.dashActionableMessage
        }
      }
    }
    loading = false
  }
}

/// Account-level DNS defaults (`zone_defaults`): the switches PATCH back on
/// change, `zone_mode` edits through a menu, and structured values render
/// read-only. This is the DNS surface Zones → DNS doesn't cover.
struct AccountDNSSettingsView: View {
  @Environment(AppModel.self) private var model
  @State private var defaults: [String: JSONValue] = [:]
  @State private var loading = true
  @State private var error: String?
  @State private var saveError: String?

  private static let labels: [String: (title: String, subtitle: String)] = [
    "flatten_all_cnames": (
      "Flatten all CNAMEs", "Flatten every CNAME in the zone, not only the apex"
    ),
    "foundation_dns": ("Foundation DNS", "Advanced nameservers with added resilience"),
    "multi_provider": (
      "Multi-provider DNS", "Treat Cloudflare as one of several DNS providers"
    ),
    "secondary_overrides": ("Secondary overrides", "Allow record edits on secondary zones"),
  ]

  private static let zoneModes = ["standard", "cdn_only", "dns_only"]

  private var toggleKeys: [String] {
    defaults.keys
      .filter { key in
        if case .bool = defaults[key] { return true }
        return false
      }
      .sorted()
  }

  private var infoKeys: [String] {
    defaults.keys
      .filter { key in
        guard key != "zone_mode" else { return false }
        switch defaults[key] {
        case .bool, nil: return false
        default: return true
        }
      }
      .sorted()
  }

  private var allowsWrites: Bool {
    model.grantedScopes?.contains("account-dns-settings.write") ?? true
  }

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      retry: { Task { await load(force: true) } }
    ) {
      if let saveError {
        DashNotice(kind: .error, message: saveError)
      }
      if !defaults.isEmpty {
        VStack(spacing: 12) {
          ForEach(toggleKeys, id: \.self) { key in
            DashToggleRow(
              title: Self.labels[key]?.title ?? key.humanizedSettingTitle,
              subtitle: Self.labels[key]?.subtitle,
              isOn: binding(for: key),
              isEnabled: allowsWrites
            )
          }
          if case .string(let mode)? = defaults["zone_mode"] {
            DashMenuRow(
              title: "Zone mode",
              value: mode,
              caption: "How new zones proxy traffic by default.",
              options: Self.zoneModes
            ) { chosen in
              let previous = defaults
              defaults["zone_mode"] = .string(chosen)
              Task { await save(revertingTo: previous) }
            }
          }
          ForEach(infoKeys, id: \.self) { key in
            DashValueCard(
              title: key.humanizedSettingTitle,
              value: defaults[key]?.displayText ?? "—"
            )
          }
        }
      }
      if !loading, defaults.isEmpty, error == nil {
        DashEmptyState(
          icon: SolarAsset.globus,
          title: "No DNS defaults",
          message: "Cloudflare returned no account-level DNS settings."
        )
      }
    }
    .navigationTitle("Account DNS settings")
    .navigationBarTitleDisplayMode(.inline)
    .refreshable { await load(force: true) }
    .task { await load() }
  }

  private var path: String { "/accounts/\(model.activeAccountID ?? "")/dns_settings" }

  private func binding(for key: String) -> Binding<Bool> {
    Binding(
      get: {
        if case .bool(let value)? = defaults[key] { return value }
        return false
      },
      set: { newValue in
        let previous = defaults
        defaults[key] = .bool(newValue)
        Task { await save(revertingTo: previous) }
      }
    )
  }

  private func save(revertingTo previous: [String: JSONValue]) async {
    do {
      let result = try await model.client.mutate(
        path: path, method: "PATCH", body: ["zone_defaults": .object(defaults)])
      if case .object(let object) = result, case .object(let updated)? = object["zone_defaults"] {
        defaults = updated
      }
      saveError = nil
      model.featureCache.remove(FeatureCacheKey.generic(path: path))
    } catch {
      defaults = previous
      saveError = error.dashActionableMessage
    }
  }

  private func load(force: Bool = false) async {
    let key = FeatureCacheKey.generic(path: path)
    if !force, let cached: [String: JSONValue] = model.featureCache.get(key) {
      defaults = cached
      loading = false
      return
    }
    if defaults.isEmpty { loading = true }
    error = nil
    do {
      let result = try await model.client.mutate(path: path, method: "GET")
      if case .object(let object) = result,
        case .object(let zoneDefaults)? = object["zone_defaults"]
      {
        defaults = zoneDefaults
      }
      model.featureCache.set(key, defaults)
    } catch {
      self.error = error.dashActionableMessage
    }
    loading = false
  }
}

extension String {
  /// snake_case API keys → "Title Case" ("ns_ttl" → "Ns Ttl").
  fileprivate var humanizedSettingTitle: String {
    replacingOccurrences(of: "_", with: " ").capitalized
  }
}
