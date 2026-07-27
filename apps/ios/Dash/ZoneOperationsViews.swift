import CloudflareAPI
import SwiftDitherKit
import SwiftUI

struct CachePurgeView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.featureAllowsWrites) private var featureAllowsWrites
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let zoneID: String
  @State private var url = ""
  @State private var status: String?
  @State private var failed = false
  @State private var working = false
  @State private var showsMore = false

  private var requiredWriteScopes: Set<String> {
    writeScopes(for: .cache(zoneID))
  }

  private var allowsWrites: Bool {
    featureAllowsWrites && model.hasScopes(requiredWriteScopes)
  }

  var body: some View {
    DashFeatureScreen {
      ScrollView {
        VStack(spacing: DashTheme.Spacing.section) {
          DashCard {
            VStack(alignment: .leading, spacing: 16) {
              if !allowsWrites {
                FeatureWriteAccessNotice(
                  message: "Read-only — grant cache purge access before removing cached assets.",
                  scopes: requiredWriteScopes,
                  buttonTitle: "Grant purge access")
              }
              VStack(alignment: .leading, spacing: 4) {
                Text("Purge by URL")
                  .dashTextStyle(.sectionTitle)
                  .foregroundStyle(DashTheme.strong)
                Text("Remove one cached asset without disturbing the rest of the domain.")
                  .dashTextStyle(.supporting)
                  .foregroundStyle(DashTheme.subtle)
              }
              DashFormField(
                label: "Asset URL",
                text: $url,
                keyboard: .URL,
                contentType: .URL
              )
              .disabled(!allowsWrites)
              DashPillButton(
                title: "Purge URL",
                isLoading: working,
                isEnabled: allowsWrites && !url.isEmpty
              ) {
                Task { await purge(files: [url]) }
              }
            }
          }

          if let status {
            DashNotice(kind: failed ? .error : .success, message: status)
              .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
          }
        }
        .padding(.horizontal, DashTheme.Spacing.screen)
        .padding(.top, DashTheme.Spacing.section)
        .padding(.bottom, DashTheme.Spacing.scrollBottomInset)
        .animation(
          reduceMotion ? DashTheme.Motion.reduced : DashTheme.Motion.quick, value: status)
      }
      .dashKeyboardDismissal()
    }
    .detailHeader(icon: .solar(SolarAsset.Content.bolt), title: "Cache")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        if allowsWrites {
          DashMoreButton(isPresented: $showsMore)
        }
      }
      .dashSeparateToolbarBackground()
    }
    .dashMoreMenu(
      isPresented: $showsMore,
      title: "Purge cache",
      actions: [
        DashDangerAction(
          title: "Purge everything",
          message:
            "This removes every cached asset in this domain. Requests may temporarily reach your origin.",
          confirmTitle: "Purge everything"
        ) {
          await purge(files: nil)
        }
      ]
    )
  }

  private func purge(files: [String]?) async {
    guard model.hasScopes(requiredWriteScopes) else {
      model.requestAccess(to: requiredWriteScopes)
      return
    }
    working = true
    do {
      try await model.client.purgeCache(zoneID: zoneID, files: files)
      status = DashL10n.string("Cache purged.")
      failed = false
      model.toasts.success(DashL10n.string("Cache purged."))
    } catch {
      status = error.dashActionableMessage
      failed = true
    }
    working = false
  }
}

/// Dashboard-style buckets for the flat zone-settings list.
/// The settings this screen offers, in display order.
///
/// Cloudflare returns 50-60 settings per zone; all but these are decisions you
/// make once, from a laptop, when you set the zone up. These five are the ones
/// worth reaching for away from your desk — the top two are the same pair the
/// App Intents expose.
///
/// Values whose valid range depends on the zone's plan stay out: browser_cache_ttl
/// rejects anything under two hours on Free, so a fixed menu would offer choices
/// that can only fail.
private let curatedZoneSettings: [String] = [
  "security_level",
  "development_mode",
  "ssl",
  "always_online",
  "always_use_https",
]

/// Enum-valued settings the API accepts as plain strings; everything listed here
/// renders as an editable menu instead of a read-only value row. Values come
/// from Cloudflare's OpenAPI schema (zones_*_value enums). The rest of
/// `curatedZoneSettings` is on/off.
private let zoneSettingOptions: [String: [String]] = [
  "ssl": ["off", "flexible", "full", "strict"],
  "security_level": ["off", "essentially_off", "low", "medium", "high", "under_attack"],
]

struct ZoneSettingsView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.featureAllowsWrites) private var featureAllowsWrites
  let zoneID: String
  @State private var settings: [ZoneSetting] = []
  @State private var error: String?
  @State private var loading = true
  @State private var updatingSettingIDs: Set<String> = []

  private var requiredWriteScopes: Set<String> {
    writeScopes(for: .zoneSettings(zoneID))
  }

  private var allowsWrites: Bool {
    featureAllowsWrites && model.hasScopes(requiredWriteScopes)
  }

  var body: some View {
    DashFeatureList(
      isLoading: loading, error: error, hasContent: !curated.isEmpty,
      retry: { Task { await load() } }
    ) {
      if !allowsWrites {
        FeatureWriteAccessNotice(
          message: "Read-only — grant zone settings write access to make changes.",
          scopes: requiredWriteScopes)
      }
      DashCard {
        Text(
          DashL10n.string(
            "Removing a domain isn't available in Dash. Use the Cloudflare dashboard."
          )
        )
        .dashTextStyle(.footnote)
        .foregroundStyle(DashTheme.subtle)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .dashSectionBoundary(!allowsWrites)
      DashSurfaceStack {
        ForEach(curated) { setting in
          settingRow(setting)
        }
      }
      .dashSectionBoundary()
    }
    .detailHeader(icon: .solar(SolarAsset.Content.settings), title: "Settings")
    .refreshable { await load(force: true) }
    .task { await load() }
  }

  /// `curatedZoneSettings` order, not response order, and silently short when a
  /// plan omits one.
  private var curated: [ZoneSetting] {
    curatedZoneSettings.compactMap { id in settings.first { $0.id == id } }
  }

  @ViewBuilder
  private func settingRow(_ setting: ZoneSetting) -> some View {
    if setting.editable == false {
      // Some settings are readable but locked by plan. Show the value rather
      // than a control that can only fail.
      DashValueCard(title: setting.displayTitle, value: setting.value.displayText)
    } else {
      switch setting.value {
      case .string(let value):
        // The enum map wins over the on/off toggle: security_level reads "high"
        // or "off" but accepts six states.
        if let options = zoneSettingOptions[setting.id] {
          DashMenuRow(
            title: setting.displayTitle,
            value: value,
            options: options,
            isEnabled: allowsWrites && !updatingSettingIDs.contains(setting.id),
            isLoading: updatingSettingIDs.contains(setting.id)
          ) { chosen in
            scheduleUpdate(setting, value: .string(chosen))
          }
        } else if value == "on" || value == "off" {
          // Cloudflare encodes most binary zone settings as "on"/"off" strings,
          // not booleans — render them as the switches they are.
          DashToggleRow(
            title: setting.displayTitle,
            isOn: Binding(
              get: { value == "on" },
              set: { enabled in
                scheduleUpdate(setting, value: .string(enabled ? "on" : "off"))
              }),
            isEnabled: allowsWrites && !updatingSettingIDs.contains(setting.id),
            isLoading: updatingSettingIDs.contains(setting.id)
          )
        } else {
          DashValueCard(title: setting.displayTitle, value: DashL10n.ui(value))
        }
      case .bool(let enabled):
        DashToggleRow(
          title: setting.displayTitle,
          isOn: Binding(
            get: { enabled },
            set: { value in scheduleUpdate(setting, value: .bool(value)) }),
          isEnabled: allowsWrites && !updatingSettingIDs.contains(setting.id),
          isLoading: updatingSettingIDs.contains(setting.id)
        )
      default:
        DashValueCard(title: setting.displayTitle, value: setting.value.displayText)
      }
    }
  }

  private func load(force: Bool = false) async {
    let key = FeatureCacheKey.zoneSettings(zoneID)
    if !force, let cached: [ZoneSetting] = model.featureCache.get(key) {
      settings = cached
      error = nil
      loading = false
      return
    }
    do {
      settings = try await model.client.listZoneSettings(zoneID: zoneID)
      model.featureCache.set(key, settings)
      error = nil
    } catch { self.error = error.dashActionableMessage }
    loading = false
  }

  /// Flips local state immediately, then commits over the network.
  private func scheduleUpdate(_ setting: ZoneSetting, value: JSONValue) {
    guard model.hasScopes(requiredWriteScopes) else {
      model.requestAccess(to: requiredWriteScopes)
      return
    }
    guard !updatingSettingIDs.contains(setting.id) else { return }
    guard let index = settings.firstIndex(where: { $0.id == setting.id }) else { return }
    let previous = settings[index]
    settings[index] = previous.withValue(value)
    updatingSettingIDs.insert(setting.id)
    error = nil
    Task { await commitUpdate(settingID: setting.id, value: value, previous: previous) }
  }

  private func commitUpdate(settingID: String, value: JSONValue, previous: ZoneSetting) async {
    do {
      let updated = try await model.client.updateZoneSetting(
        zoneID: zoneID, settingID: settingID, value: value)
      if let latest = settings.firstIndex(where: { $0.id == settingID }) {
        settings[latest] = updated
      }
      model.featureCache.set(FeatureCacheKey.zoneSettings(zoneID), settings)
      DashDelight.celebrateSuccess()
    } catch {
      if let latest = settings.firstIndex(where: { $0.id == settingID }) {
        settings[latest] = previous
      }
      model.toasts.error(error.dashActionableMessage)
    }
    updatingSettingIDs.remove(settingID)
  }
}

extension ZoneSetting {
  fileprivate var displayTitle: String {
    zoneSettingDisplayTitle(id)
  }
}

func zoneSettingDisplayTitle(_ id: String) -> String {
  switch id {
  case "ssl": "SSL"
  case "always_use_https": "Always Use HTTPS"
  case "min_tls_version": "Minimum TLS version"
  default: id.replacingOccurrences(of: "_", with: " ").capitalized
  }
}

extension JSONValue {
  var displayText: String {
    switch self {
    case .array(let values):
      values.isEmpty
        ? DashL10n.string("None") : values.map(\.displayText).joined(separator: ", ")
    case .bool(let value): value ? DashL10n.string("On") : DashL10n.string("Off")
    case .null: DashL10n.string("Not set")
    case .number(let value):
      value.rounded() == value ? String(Int(value)) : value.formatted()
    case .object(let value):
      value.isEmpty ? DashL10n.string("None") : DashL10n.string("\(value.count) values")
    case .string(let value): value
    }
  }
}

struct AuditLogView: View {
  @Environment(AppModel.self) private var model
  @State private var entries: [AuditLogEntry] = []
  @State private var loading = true
  @State private var error: String?

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      hasContent: !entries.isEmpty,
      retry: { Task { await load(force: true) } }
    ) {
      if entries.isEmpty {
        DashEmptyState(
          icon: SolarAsset.Content.shieldCheck,
          title: "No audit events",
          message: "Account activity from the last seven days will show up here."
        )
      } else {
        dashListCard {
          dashListCardRows(items: entries) { entry in
            DashListRow(
              title: DashL10n.ui(entry.title),
              subtitle: auditSubtitle(entry),
              icon: SolarAsset.Content.shieldCheck,
              showsChevron: false
            )
          }
        }
      }
    }
    .detailHeader(icon: .solar(SolarAsset.Content.shieldCheck), title: "Audit log")
    .refreshable { await load(force: true) }
    .task { await load() }
  }

  /// Mirrors `AuditLogEntry.subtitle`, but renders the ISO 8601 "when" stamp
  /// as a localized date instead of the raw API string.
  private func auditSubtitle(_ entry: AuditLogEntry) -> String? {
    var parts: [String] = []
    if let who = entry.actor?.email ?? entry.actor?.type { parts.append(who) }
    if let what = entry.resource?.product ?? entry.resource?.type { parts.append(what) }
    if let when = entry.occurredAt { parts.append(auditDateLabel(when)) }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private func load(force: Bool = false) async {
    guard let accountID = model.activeAccountID else { return }
    let key = FeatureCacheKey.auditLogs(accountID)
    if !force, let cached: [AuditLogEntry] = model.featureCache.get(key) {
      entries = cached
      loading = false
      error = nil
      return
    }
    if entries.isEmpty { loading = true }
    error = nil
    do {
      entries = try await model.client.listAuditLogs(accountID: accountID, perPage: 50)
      model.featureCache.set(key, entries)
    } catch {
      self.error = error.dashActionableMessage
    }
    loading = false
  }
}

/// Audit "when" stamps are ISO 8601 with or without fractional seconds; show a
/// localized date + time, falling back to the raw day prefix.
private func auditDateLabel(_ value: String) -> String {
  let fractional = ISO8601DateFormatter()
  fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  let plain = ISO8601DateFormatter()
  plain.formatOptions = [.withInternetDateTime]
  guard let date = fractional.date(from: value) ?? plain.date(from: value) else {
    return String(value.prefix(10))
  }
  let label = DateFormatter()
  label.dateStyle = .medium
  label.timeStyle = .short
  label.locale = DashL10n.activeLocale
  return label.string(from: date)
}

/// Pure conversion for the WAF top-countries bar chart, so the capping and
/// accessibility strings are unit-tested away from the view.
enum WAFChartModel {
  /// The bar chart renders every category label only while there are at most
  /// six bars, so the countries list is capped to the top entries by count.
  static let countryLimit = 6

  static func topCountries(
    _ buckets: [FirewallEventsBucket], limit: Int = countryLimit
  ) -> [FirewallEventsBucket] {
    Array(buckets.sorted { $0.count > $1.count }.prefix(limit))
  }

  static func data(from buckets: [FirewallEventsBucket]) -> [DitherDatum] {
    buckets.map { bucket in
      DitherDatum(
        id: bucket.label,
        label: bucket.label,
        values: ["blocks": Double(bucket.count)])
    }
  }

  static func countriesAccessibilitySummary(buckets: [FirewallEventsBucket]) -> String {
    let total = buckets.reduce(0) { $0 + $1.count }
    guard let top = buckets.max(by: { $0.count < $1.count }) else {
      return DashL10n.string("No blocked events in this window.")
    }
    let name =
      top.label.count == 2
      ? DashL10n.activeLocale.localizedString(forRegionCode: top.label) ?? top.label
      : top.label
    return DashL10n.string(
      "Blocked requests by country. \(name) leads with \(top.count.formatted()) of \(total.formatted()) blocks."
    )
  }
}

struct WAFEventsView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.featureAllowsWrites) private var featureAllowsWrites
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let zoneID: String
  @State private var selectedSeriesID: String?
  @State private var summary: FirewallEventsSummary?
  @State private var loading = true
  @State private var error: String?
  @State private var underAttack = false
  @State private var securityLoaded = false
  @State private var securityUpdating = false

  private var requiredWriteScopes: Set<String> {
    writeScopes(for: .zoneWAF(zoneID))
  }

  private var canToggleSecurity: Bool {
    featureAllowsWrites && model.hasScopes(requiredWriteScopes)
  }

  private var underAttackBinding: Binding<Bool> {
    Binding(
      get: { underAttack },
      set: { enabled in
        guard securityLoaded, canToggleSecurity, !securityUpdating else { return }
        underAttack = enabled
        Task { await setUnderAttack(enabled) }
      })
  }

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      hasContent: summary != nil || securityLoaded,
      retry: { Task { await load(force: true) } }
    ) {
      if let summary {
        DashCard {
          VStack(alignment: .leading, spacing: 8) {
            Text("Last \(summary.hours) hours")
              .dashTextStyle(.footnoteSemibold)
              .foregroundStyle(DashTheme.subtle)
            Text(summary.blocked.formatted())
              .dashTextStyle(.sectionTitle)
              .foregroundStyle(DashTheme.text)
              .monospacedDigit()
            Text("Blocked requests")
              .dashTextStyle(.caption)
              .foregroundStyle(DashTheme.subtle)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      DashToggleRow(
        title: "Under Attack mode",
        subtitle: canToggleSecurity
          ? "Challenges every visitor. Restores the previous security level when turned off."
          : "Grant zone settings write access to change this.",
        isOn: underAttackBinding,
        isEnabled: securityLoaded && canToggleSecurity,
        isLoading: securityUpdating
      )
      .dashSectionBoundary(summary != nil)
      if !canToggleSecurity {
        FeatureWriteAccessNotice(
          message: "Read-only — grant zone settings write access to change Under Attack mode.",
          scopes: requiredWriteScopes
        )
        .dashItemBoundary()
      }
      if let summary {
        if summary.countries.isEmpty {
          wafBucketGroup(
            title: "Top countries", buckets: summary.countries, labelsAreRegionCodes: true
          )
          .dashSectionBoundary()
        } else {
          countriesChartGroup(summary.countries)
            .dashSectionBoundary()
        }
        wafBucketGroup(title: "Top rules", buckets: summary.rules)
          .dashSectionBoundary()
      }
    }
    .detailHeader(icon: .solar(SolarAsset.Content.shieldCheck), title: "WAF")
    .refreshable { await load(force: true) }
    .task { await load() }
  }

  /// The GraphQL country dimension is an ISO 3166 alpha-2 code — show the
  /// localized region name when we can resolve one.
  private func regionName(_ code: String) -> String {
    guard code.count == 2 else { return code }
    return DashL10n.activeLocale.localizedString(forRegionCode: code) ?? code
  }

  @ViewBuilder
  private func countriesChartGroup(_ countries: [FirewallEventsBucket]) -> some View {
    let top = WAFChartModel.topCountries(countries)
    DashListGroup(title: "Top countries") {
      DashCard {
        VStack(alignment: .leading, spacing: 12) {
          Text("Blocks by country")
            .dashTextStyle(.footnoteSemibold)
            .foregroundStyle(DashTheme.subtle)
          DitherBarChart(
            data: WAFChartModel.data(from: top),
            series: [
              DitherSeries(
                id: "blocks",
                label: DashL10n.ui("Blocks"),
                color: DashTheme.DitherChart.warning(
                  colorScheme: colorScheme,
                  contrast: colorSchemeContrast),
                variant: .gradient)
            ],
            options: DashTheme.DitherChart.options(
              showsLegend: false,
              accessibility: DitherAccessibility(
                title: DashL10n.ui("Top countries by blocked requests"),
                summary: WAFChartModel.countriesAccessibilitySummary(buckets: top),
                categoryAxisLabel: DashL10n.ui("Country"),
                valueAxisLabel: DashL10n.ui("Blocks"))),
            highlighted: selectedSeriesID != nil,
            selection: $selectedSeriesID
          )
          .frame(
            height: DashTheme.DitherChart.height(
              dynamicTypeSize: dynamicTypeSize,
              showsLegend: false))
        }
      }
    }
  }

  @ViewBuilder
  private func wafBucketGroup(
    title: String, buckets: [FirewallEventsBucket], labelsAreRegionCodes: Bool = false
  ) -> some View {
    DashListGroup(title: title) {
      if buckets.isEmpty {
        DashCard {
          Text("No blocked events in this window.")
            .dashTextStyle(.footnote)
            .foregroundStyle(DashTheme.subtle)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      } else {
        dashListCard {
          dashListCardRows(items: buckets) { bucket in
            DashListRow(
              title: labelsAreRegionCodes ? regionName(bucket.label) : bucket.label,
              subtitle: DashL10n.string("\(bucket.count.formatted()) blocks"),
              icon: SolarAsset.Content.shieldCheck,
              showsChevron: false
            )
          }
        }
      }
    }
  }

  private func load(force: Bool = false) async {
    if summary == nil { loading = true }
    error = nil
    await loadSummary(force: force)
    await loadSecurityLevel(force: force)
    loading = false
  }

  private func loadSummary(force: Bool) async {
    let key = FeatureCacheKey.zoneWAF(zoneID)
    if !force, let cached: FirewallEventsSummary = model.featureCache.get(key) {
      summary = cached
      return
    }
    do {
      let fetched = try await model.client.firewallEventsSummary(zoneID: zoneID, hours: 24)
      if fetched.countries != summary?.countries { selectedSeriesID = nil }
      summary = fetched
      model.featureCache.set(key, fetched)
    } catch {
      self.error = error.dashActionableMessage
    }
  }

  private func loadSecurityLevel(force: Bool) async {
    let key = FeatureCacheKey.zoneSettings(zoneID)
    if !force, let cached: [ZoneSetting] = model.featureCache.get(key) {
      applySecurity(cached)
      return
    }
    do {
      let settings = try await model.client.listZoneSettings(zoneID: zoneID)
      model.featureCache.set(key, settings)
      applySecurity(settings)
    } catch {
      securityLoaded = false
    }
  }

  private func applySecurity(_ settings: [ZoneSetting]) {
    if case .string(let value)? = settings.first(where: { $0.id == "security_level" })?.value {
      underAttack = value == "under_attack"
      securityLoaded = true
    }
  }

  private func setUnderAttack(_ enabled: Bool) async {
    guard model.hasScopes(requiredWriteScopes) else {
      model.requestAccess(to: requiredWriteScopes)
      return
    }
    securityUpdating = true
    defer { securityUpdating = false }
    let defaults = UserDefaults.standard
    let stashKey = "dash.previous_security_level.\(zoneID)"
    do {
      if enabled {
        let settings = try await model.client.listZoneSettings(zoneID: zoneID)
        if case .string(let current)? = settings.first(where: { $0.id == "security_level" })?
          .value, current != "under_attack"
        {
          defaults.set(current, forKey: stashKey)
        }
        _ = try await model.client.updateZoneSetting(
          zoneID: zoneID, settingID: "security_level", value: .string("under_attack"))
        underAttack = true
      } else {
        let level = SetUnderAttackIntent.restoreLevel(stashed: defaults.string(forKey: stashKey))
        defaults.removeObject(forKey: stashKey)
        _ = try await model.client.updateZoneSetting(
          zoneID: zoneID, settingID: "security_level", value: .string(level))
        underAttack = false
      }
      model.featureCache.remove(FeatureCacheKey.zoneSettings(zoneID))
      DashDelight.celebrateSuccess()
    } catch {
      underAttack = !enabled
      model.toasts.error(error.dashActionableMessage)
    }
  }
}
