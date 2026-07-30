import CloudflareAPI
import SwiftDitherKit
import SwiftGlobeKit
import SwiftUI

struct CachePurgeView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.featureAllowsWrites) private var featureAllowsWrites
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let zoneID: String
  @State private var url = ""
  @State private var status: String?
  @State private var failed = false
  @State private var actionPhase: DashActionPhase = .idle
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
                  scopes: requiredWriteScopes)
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
                phase: actionPhase,
                isEnabled: allowsWrites && !url.isEmpty,
                onSuccessPresentationCompleted: { actionPhase = .idle }
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
          try await performPurge(files: nil)
        }
      ]
    )
  }

  private func purge(files: [String]?) async {
    guard model.hasScopes(requiredWriteScopes) else {
      model.requestAccess(to: requiredWriteScopes)
      return
    }
    actionPhase = .loading
    do {
      try await performPurge(files: files)
      actionPhase = .succeeded
    } catch {
      actionPhase = .idle
      guard !error.dashIsCancellation else { return }
      status = error.dashActionableMessage
      failed = true
    }
  }

  private func performPurge(files: [String]?) async throws {
    try await model.client.purgeCache(zoneID: zoneID, files: files)
    try Task.checkCancellation()
    status = DashL10n.string("Cache purged.")
    failed = false
    model.toasts.success(DashL10n.string("Cache purged."))
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
///
/// `security_level` deliberately omits `under_attack`, even though the API
/// accepts it: this menu commits through a plain `updateZoneSetting`, so raising
/// the shield here would never stash the level it replaced, and the next time
/// the WAF screen's Under Attack switch went off the zone would land on the
/// "medium" fallback instead of the "high" it actually had. Under Attack is
/// raised and lowered only through `ZoneSecurityLevelOperation`. A zone already
/// at `under_attack` still reads correctly here — `DashMenuRow` labels itself
/// from `value`, not from `options`.
let zoneSettingOptions: [String: [String]] = [
  "ssl": ["off", "flexible", "full", "strict"],
  "security_level": ["off", "essentially_off", "low", "medium", "high"],
]

/// Names the control that owns a value the menu above cannot offer, so the
/// missing choice reads as "elsewhere" rather than "gone".
private let zoneSettingCaptions: [String: String] = [
  "security_level": "Under Attack mode lives on the zone's WAF screen."
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

  /// Settings is only reachable from zone detail, so the zone is already
  /// cached; this is where active zones keep their assigned nameservers now
  /// that the detail card only appears during activation.
  private var nameservers: [String] {
    model.featureCache.cachedZone(id: zoneID, accountID: model.activeAccountID)?
      .nameServers ?? []
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
      if !nameservers.isEmpty {
        ZoneNameserversGroup(servers: nameservers)
          .dashSectionBoundary(!allowsWrites)
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
      .dashSectionBoundary(!allowsWrites || !nameservers.isEmpty)
      DashSurfaceStack {
        ForEach(curated) { setting in
          settingRow(setting)
        }
      }
      .dashSectionBoundary()
      ZoneAlertsSection(zoneID: zoneID)
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
            caption: zoneSettingCaptions[setting.id],
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
    defer { loading = false }
    do {
      settings = try await model.client.listZoneSettings(zoneID: zoneID)
      model.featureCache.set(key, settings)
      error = nil
    } catch {
      guard !error.dashIsCancellation else { return }
      self.error = error.dashActionableMessage
    }
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
    if let when = entry.occurredAt {
      parts.append(DashDateFormatting.dateAndTime(fromISO8601: when))
    }
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
    defer { loading = false }
    do {
      entries = try await model.client.listAuditLogs(accountID: accountID, perPage: 50)
      model.featureCache.set(key, entries)
    } catch {
      guard !error.dashIsCancellation else { return }
      self.error = error.dashActionableMessage
    }
  }
}

/// Pure conversion for the WAF top-countries visualization, so capping,
/// ordering, and accessibility copy stay unit-tested away from the view.
enum WAFChartModel {
  /// Six markers and ranking cells preserve legibility on a compact iPhone.
  static let countryLimit = 6

  static func topCountries(
    _ buckets: [FirewallEventsBucket], limit: Int = countryLimit
  ) -> [FirewallEventsBucket] {
    Array(
      buckets.sorted {
        if $0.count == $1.count { return $0.label < $1.label }
        return $0.count > $1.count
      }.prefix(limit)
    )
  }

  static func countriesAccessibilitySummary(
    buckets: [FirewallEventsBucket],
    totalBlocked: Int? = nil
  ) -> String {
    let total = totalBlocked ?? buckets.reduce(0) { $0 + $1.count }
    guard let top = topCountries(buckets, limit: 1).first else {
      return DashL10n.string("No blocked events in this window.")
    }
    let name =
      top.label.count == 2
      ? DashL10n.activeLocale.localizedString(forRegionCode: top.label) ?? top.label
      : top.label
    let topCount = top.count.formatted(.number.locale(DashL10n.activeLocale))
    let totalCount = total.formatted(.number.locale(DashL10n.activeLocale))
    return DashL10n.string(
      "Blocked requests by country. \(name) leads with \(topCount) of \(totalCount) blocks."
    )
  }
}

/// Render-ready country data for the WAF globe. Keeping the count alongside the
/// marker geometry lets the view preserve exact values in its list and
/// accessibility copy instead of trying to recover meaning from marker size.
struct WAFGlobePoint: Identifiable, Hashable, Sendable {
  var id: String { countryCode }

  let countryCode: String
  let count: Int
  let coordinate: GlobeCoordinate
  let markerSize: Double

  func marker(accessibilityLabel: String? = nil) -> GlobeMarker {
    GlobeMarker(
      id: countryCode,
      coordinate: coordinate,
      size: markerSize,
      accessibilityLabel: accessibilityLabel)
  }
}

/// Pure conversion from Cloudflare's country buckets to stable globe points.
///
/// Cloudflare normally returns one row per ISO 3166-1 alpha-2 code, but the
/// fold also makes duplicate or differently-cased rows deterministic. Unknown
/// provider sentinels such as `XX` and `T1`, malformed codes, and zero-count
/// rows do not become misleading markers.
enum WAFGlobeModel {
  static let minimumMarkerSize = 0.07
  static let maximumMarkerSize = 0.18

  static func points(from buckets: [FirewallEventsBucket]) -> [WAFGlobePoint] {
    var countsByCountry: [String: Int] = [:]
    for bucket in buckets {
      guard bucket.count > 0,
        let countryCode = WAFISOCountryCentroids.normalizedCode(bucket.label),
        WAFISOCountryCentroids.coordinate(for: countryCode) != nil
      else { continue }

      let (sum, overflowed) = countsByCountry[countryCode, default: 0]
        .addingReportingOverflow(bucket.count)
      countsByCountry[countryCode] = overflowed ? Int.max : sum
    }

    guard let maximumCount = countsByCountry.values.max(), maximumCount > 0 else {
      return []
    }

    return
      countsByCountry
      .compactMap { countryCode, count in
        guard let coordinate = WAFISOCountryCentroids.coordinate(for: countryCode) else {
          return nil
        }
        return WAFGlobePoint(
          countryCode: countryCode,
          count: count,
          coordinate: coordinate,
          markerSize: markerSize(count: count, maximumCount: maximumCount))
      }
      .sorted {
        if $0.count == $1.count { return $0.countryCode < $1.countryCode }
        return $0.count > $1.count
      }
  }

  /// Marker radius follows the square root of the count ratio. This keeps
  /// visible area approximately proportional to event count while retaining a
  /// nonzero floor for low-volume countries and marker hit testing.
  static func markerSize(count: Int, maximumCount: Int) -> Double {
    guard count > 0, maximumCount > 0 else { return minimumMarkerSize }
    let ratio = min(Double(count) / Double(maximumCount), 1)
    return minimumMarkerSize
      + (maximumMarkerSize - minimumMarkerSize) * ratio.squareRoot()
  }
}

/// Local ISO 3166-1 country label points used only by the WAF visualization.
/// Values are generated from Natural Earth 5.1.2; see
/// `apps/ios/scripts/generate-country-centroids.mjs`.
enum WAFISOCountryCentroids {
  static var supportedCodes: Set<String> { Set(coordinates.keys) }

  static func normalizedCode(_ rawCode: String) -> String? {
    let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard code.count == 2, code.unicodeScalars.allSatisfy({ (65...90).contains($0.value) })
    else { return nil }
    return code
  }

  static func coordinate(for rawCode: String) -> GlobeCoordinate? {
    guard let code = normalizedCode(rawCode), let point = coordinates[code] else {
      return nil
    }
    return GlobeCoordinate(latitude: point.latitude, longitude: point.longitude)
  }

  private struct Point: Hashable, Sendable {
    let latitude: Double
    let longitude: Double
  }

  // BEGIN GENERATED WAF COUNTRY CENTROIDS
  private static let coordinates: [String: Point] = [
    "AD": Point(latitude: 42.547643, longitude: 1.539409),
    "AE": Point(latitude: 23.466285, longitude: 54.547256),
    "AF": Point(latitude: 34.164262, longitude: 66.496586),
    "AG": Point(latitude: 17.352249, longitude: -61.790612),
    "AI": Point(latitude: 18.242979, longitude: -63.026361),
    "AL": Point(latitude: 40.654855, longitude: 20.11384),
    "AM": Point(latitude: 40.459077, longitude: 44.800564),
    "AO": Point(latitude: -12.182762, longitude: 17.984249),
    "AQ": Point(latitude: -79.843222, longitude: 35.885455),
    "AR": Point(latitude: -33.501159, longitude: -64.173331),
    "AS": Point(latitude: -14.32671, longitude: -170.747153),
    "AT": Point(latitude: 47.518859, longitude: 14.130515),
    "AU": Point(latitude: -24.129522, longitude: 134.04972),
    "AW": Point(latitude: 12.5174, longitude: -69.972795),
    "AX": Point(latitude: 60.156467, longitude: 19.869671),
    "AZ": Point(latitude: 40.402387, longitude: 47.210994),
    "BA": Point(latitude: 44.091051, longitude: 18.06841),
    "BB": Point(latitude: 13.163709, longitude: -59.568966),
    "BD": Point(latitude: 24.214956, longitude: 89.684963),
    "BE": Point(latitude: 50.785392, longitude: 4.800448),
    "BF": Point(latitude: 12.673048, longitude: -1.36388),
    "BG": Point(latitude: 42.508785, longitude: 25.15709),
    "BH": Point(latitude: 26.055972, longitude: 50.554816),
    "BI": Point(latitude: -3.332836, longitude: 29.917086),
    "BJ": Point(latitude: 10.324775, longitude: 2.352018),
    "BL": Point(latitude: 17.901987, longitude: -62.833193),
    "BM": Point(latitude: 32.296592, longitude: -64.763573),
    "BN": Point(latitude: 4.448298, longitude: 114.551943),
    "BO": Point(latitude: -16.666015, longitude: -64.593433),
    "BQ": Point(latitude: 17.5438, longitude: -63.1334),
    "BR": Point(latitude: -12.098687, longitude: -49.55945),
    "BS": Point(latitude: 26.401789, longitude: -77.146688),
    "BT": Point(latitude: 27.536685, longitude: 90.040294),
    "BV": Point(latitude: -54.415335, longitude: 3.414486),
    "BW": Point(latitude: -22.102634, longitude: 24.179216),
    "BY": Point(latitude: 53.821888, longitude: 28.417701),
    "BZ": Point(latitude: 17.202068, longitude: -88.712962),
    "CA": Point(latitude: 60.324287, longitude: -101.9107),
    "CC": Point(latitude: -12.159615, longitude: 96.830147),
    "CD": Point(latitude: -1.858167, longitude: 23.458829),
    "CF": Point(latitude: 6.989681, longitude: 20.906897),
    "CG": Point(latitude: 0.142331, longitude: 15.9005),
    "CH": Point(latitude: 46.719114, longitude: 7.463965),
    "CI": Point(latitude: 7.49139, longitude: -5.568618),
    "CK": Point(latitude: -21.215993, longitude: -159.785675),
    "CL": Point(latitude: -38.151771, longitude: -72.318871),
    "CM": Point(latitude: 4.585041, longitude: 12.473488),
    "CN": Point(latitude: 32.498178, longitude: 106.337289),
    "CO": Point(latitude: 3.373111, longitude: -73.174347),
    "CR": Point(latitude: 10.0651, longitude: -84.077922),
    "CU": Point(latitude: 21.334024, longitude: -77.975855),
    "CV": Point(latitude: 15.074761, longitude: -23.639434),
    "CW": Point(latitude: 12.145039, longitude: -68.920578),
    "CX": Point(latitude: -10.490789, longitude: 105.67259),
    "CY": Point(latitude: 34.913329, longitude: 33.084182),
    "CZ": Point(latitude: 49.882364, longitude: 15.377555),
    "DE": Point(latitude: 50.961733, longitude: 9.678348),
    "DJ": Point(latitude: 11.976343, longitude: 42.498825),
    "DK": Point(latitude: 55.966965, longitude: 9.018163),
    "DM": Point(latitude: 15.458829, longitude: -61.344958),
    "DO": Point(latitude: 19.104137, longitude: -70.653998),
    "DZ": Point(latitude: 27.397406, longitude: 2.808241),
    "EC": Point(latitude: -1.259076, longitude: -78.188375),
    "EE": Point(latitude: 58.724865, longitude: 25.867126),
    "EG": Point(latitude: 26.186173, longitude: 29.445837),
    "EH": Point(latitude: 23.967592, longitude: -12.630304),
    "ER": Point(latitude: 15.787401, longitude: 38.285566),
    "ES": Point(latitude: 40.090953, longitude: -3.464718),
    "ET": Point(latitude: 8.032795, longitude: 39.0886),
    "FI": Point(latitude: 63.252361, longitude: 27.276449),
    "FJ": Point(latitude: -17.826099, longitude: 177.975427),
    "FK": Point(latitude: -51.608913, longitude: -58.738602),
    "FM": Point(latitude: 6.887553, longitude: 158.234019),
    "FO": Point(latitude: 62.185604, longitude: -7.058429),
    "FR": Point(latitude: 46.696113, longitude: 2.552275),
    "GA": Point(latitude: -0.437739, longitude: 11.835939),
    "GB": Point(latitude: 54.402739, longitude: -2.116346),
    "GD": Point(latitude: 12.113156, longitude: -61.680461),
    "GE": Point(latitude: 41.870087, longitude: 43.735724),
    "GF": Point(latitude: 3.999223, longitude: -53.068349),
    "GG": Point(latitude: 49.463533, longitude: -2.561736),
    "GH": Point(latitude: 7.717639, longitude: -1.036941),
    "GI": Point(latitude: 36.129426, longitude: -5.3467),
    "GL": Point(latitude: 74.319387, longitude: -39.335251),
    "GM": Point(latitude: 13.641721, longitude: -14.998318),
    "GN": Point(latitude: 10.618516, longitude: -10.016402),
    "GP": Point(latitude: 16.299332, longitude: -61.433565),
    "GQ": Point(latitude: 2.333, longitude: 8.9902),
    "GR": Point(latitude: 39.492763, longitude: 21.72568),
    "GS": Point(latitude: -55.683402, longitude: -31.063179),
    "GT": Point(latitude: 14.982133, longitude: -90.497134),
    "GU": Point(latitude: 13.354173, longitude: 144.703614),
    "GW": Point(latitude: 12.163712, longitude: -14.52413),
    "GY": Point(latitude: 5.124317, longitude: -58.942643),
    "HK": Point(latitude: 22.448829, longitude: 114.097769),
    "HM": Point(latitude: -53.103462, longitude: 73.50521),
    "HN": Point(latitude: 14.794801, longitude: -86.887604),
    "HR": Point(latitude: 45.805799, longitude: 16.37241),
    "HT": Point(latitude: 19.263784, longitude: -72.224051),
    "HU": Point(latitude: 47.086841, longitude: 19.447867),
    "ID": Point(latitude: -0.954404, longitude: 101.892949),
    "IE": Point(latitude: 53.078726, longitude: -7.798588),
    "IL": Point(latitude: 30.911148, longitude: 34.847915),
    "IM": Point(latitude: 54.220833, longitude: -4.530069),
    "IN": Point(latitude: 22.686852, longitude: 79.358105),
    "IO": Point(latitude: -6.190826, longitude: 71.348349),
    "IQ": Point(latitude: 33.09403, longitude: 43.26181),
    "IR": Point(latitude: 32.166225, longitude: 54.931495),
    "IS": Point(latitude: 64.779286, longitude: -18.673711),
    "IT": Point(latitude: 44.732482, longitude: 11.076907),
    "JE": Point(latitude: 49.220808, longitude: -2.090146),
    "JM": Point(latitude: 18.137124, longitude: -77.318767),
    "JO": Point(latitude: 30.805025, longitude: 36.375991),
    "JP": Point(latitude: 36.142538, longitude: 138.44217),
    "KE": Point(latitude: 0.549043, longitude: 37.907632),
    "KG": Point(latitude: 41.66854, longitude: 74.532637),
    "KH": Point(latitude: 12.647584, longitude: 104.50487),
    "KI": Point(latitude: 1.820437, longitude: -157.384577),
    "KM": Point(latitude: -11.727683, longitude: 43.318094),
    "KN": Point(latitude: 17.336558, longitude: -62.757975),
    "KP": Point(latitude: 39.885252, longitude: 126.444516),
    "KR": Point(latitude: 36.384924, longitude: 128.129504),
    "KW": Point(latitude: 29.413628, longitude: 47.313999),
    "KY": Point(latitude: 19.319862, longitude: -81.24055),
    "KZ": Point(latitude: 49.054149, longitude: 68.685548),
    "LA": Point(latitude: 19.431821, longitude: 102.533912),
    "LB": Point(latitude: 34.133368, longitude: 35.992892),
    "LC": Point(latitude: 13.892371, longitude: -60.980094),
    "LI": Point(latitude: 47.111405, longitude: 9.559439),
    "LK": Point(latitude: 7.581097, longitude: 80.704823),
    "LR": Point(latitude: 6.447177, longitude: -9.460379),
    "LS": Point(latitude: -29.480158, longitude: 28.246639),
    "LT": Point(latitude: 55.103703, longitude: 24.089932),
    "LU": Point(latitude: 49.733732, longitude: 6.07762),
    "LV": Point(latitude: 57.066872, longitude: 25.458723),
    "LY": Point(latitude: 26.638944, longitude: 18.011015),
    "MA": Point(latitude: 31.650723, longitude: -7.187296),
    "MC": Point(latitude: 43.739652, longitude: 7.398291),
    "MD": Point(latitude: 47.434999, longitude: 28.487904),
    "ME": Point(latitude: 42.803101, longitude: 19.143727),
    "MF": Point(latitude: 18.081302, longitude: -63.049399),
    "MG": Point(latitude: -18.628288, longitude: 46.704241),
    "MH": Point(latitude: 7.082568, longitude: 171.193609),
    "MK": Point(latitude: 41.558223, longitude: 21.555839),
    "ML": Point(latitude: 18.692713, longitude: -2.038455),
    "MM": Point(latitude: 21.573855, longitude: 95.804497),
    "MN": Point(latitude: 45.997488, longitude: 104.150405),
    "MO": Point(latitude: 22.129735, longitude: 113.556038),
    "MP": Point(latitude: 15.188188, longitude: 145.734397),
    "MQ": Point(latitude: 14.711979, longitude: -61.055657),
    "MR": Point(latitude: 19.587062, longitude: -9.740299),
    "MS": Point(latitude: 16.73717, longitude: -62.188252),
    "MT": Point(latitude: 35.892886, longitude: 14.433005),
    "MU": Point(latitude: -20.299506, longitude: 57.565848),
    "MV": Point(latitude: 4.174441, longitude: 73.507554),
    "MW": Point(latitude: -13.386737, longitude: 33.608082),
    "MX": Point(latitude: 23.919988, longitude: -102.289448),
    "MY": Point(latitude: 2.528667, longitude: 113.83708),
    "MZ": Point(latitude: -13.94323, longitude: 37.83789),
    "NA": Point(latitude: -20.575298, longitude: 17.108166),
    "NC": Point(latitude: -21.064697, longitude: 165.084004),
    "NE": Point(latitude: 17.446195, longitude: 9.504356),
    "NF": Point(latitude: -29.033042, longitude: 167.954531),
    "NG": Point(latitude: 9.439799, longitude: 7.50322),
    "NI": Point(latitude: 12.670697, longitude: -85.069347),
    "NL": Point(latitude: 52.422211, longitude: 5.61144),
    "NO": Point(latitude: 61.357092, longitude: 9.679975),
    "NP": Point(latitude: 28.297925, longitude: 83.639914),
    "NR": Point(latitude: -0.520261, longitude: 166.932644),
    "NU": Point(latitude: -19.045956, longitude: -169.862565),
    "NZ": Point(latitude: -39.759, longitude: 172.787),
    "OM": Point(latitude: 22.120427, longitude: 57.336553),
    "PA": Point(latitude: 8.72198, longitude: -80.352106),
    "PE": Point(latitude: -12.976679, longitude: -72.90016),
    "PF": Point(latitude: -17.628081, longitude: -149.46157),
    "PG": Point(latitude: -5.695285, longitude: 143.910216),
    "PH": Point(latitude: 11.198, longitude: 122.465),
    "PK": Point(latitude: 29.328389, longitude: 68.545632),
    "PL": Point(latitude: 51.990316, longitude: 19.490468),
    "PM": Point(latitude: 47.040344, longitude: -56.332352),
    "PN": Point(latitude: -24.364576, longitude: -128.317536),
    "PR": Point(latitude: 18.234668, longitude: -66.481065),
    "PS": Point(latitude: 32.047431, longitude: 35.291341),
    "PT": Point(latitude: 39.606675, longitude: -8.271754),
    "PW": Point(latitude: 7.518252, longitude: 134.580157),
    "PY": Point(latitude: -21.674509, longitude: -60.146394),
    "QA": Point(latitude: 25.237383, longitude: 51.143509),
    "RE": Point(latitude: -21.113488, longitude: 55.535699),
    "RO": Point(latitude: 45.733237, longitude: 24.972624),
    "RS": Point(latitude: 44.189919, longitude: 20.787989),
    "RU": Point(latitude: 58.249357, longitude: 44.686469),
    "RW": Point(latitude: -1.897196, longitude: 30.103894),
    "SA": Point(latitude: 23.806908, longitude: 44.6996),
    "SB": Point(latitude: -8.029548, longitude: 159.170468),
    "SC": Point(latitude: -4.676659, longitude: 55.480175),
    "SD": Point(latitude: 16.330746, longitude: 29.260657),
    "SE": Point(latitude: 65.85918, longitude: 19.01705),
    "SG": Point(latitude: 1.366587, longitude: 103.816925),
    "SH": Point(latitude: -15.950487, longitude: -5.71262),
    "SI": Point(latitude: 46.06076, longitude: 14.915312),
    "SJ": Point(latitude: 78.778287, longitude: 18.080737),
    "SK": Point(latitude: 48.734044, longitude: 19.049868),
    "SL": Point(latitude: 8.617449, longitude: -11.763677),
    "SM": Point(latitude: 43.933916, longitude: 12.441206),
    "SN": Point(latitude: 15.138125, longitude: -14.778586),
    "SO": Point(latitude: 3.568925, longitude: 45.19238),
    "SR": Point(latitude: 4.143987, longitude: -55.91094),
    "SS": Point(latitude: 7.230477, longitude: 30.390151),
    "ST": Point(latitude: 0.9709, longitude: 7.021),
    "SV": Point(latitude: 13.685371, longitude: -88.890124),
    "SX": Point(latitude: 18.04088, longitude: -63.070133),
    "SY": Point(latitude: 35.006636, longitude: 38.277783),
    "SZ": Point(latitude: -26.533676, longitude: 31.467264),
    "TC": Point(latitude: 21.81663, longitude: -71.752704),
    "TD": Point(latitude: 15.142959, longitude: 18.645041),
    "TF": Point(latitude: -49.303721, longitude: 69.122136),
    "TG": Point(latitude: 8.80722, longitude: 1.058113),
    "TH": Point(latitude: 15.45974, longitude: 101.073198),
    "TJ": Point(latitude: 38.199835, longitude: 72.587276),
    "TK": Point(latitude: -8.561824, longitude: -172.48629),
    "TL": Point(latitude: -8.803705, longitude: 125.854679),
    "TM": Point(latitude: 39.855246, longitude: 58.676647),
    "TN": Point(latitude: 33.687263, longitude: 9.007881),
    "TO": Point(latitude: -21.210026, longitude: -175.163014),
    "TR": Point(latitude: 39.345388, longitude: 34.508268),
    "TT": Point(latitude: 10.9989, longitude: -60.9184),
    "TV": Point(latitude: -8.513717, longitude: 179.209587),
    "TW": Point(latitude: 23.652408, longitude: 120.868204),
    "TZ": Point(latitude: -6.051866, longitude: 34.959183),
    "UA": Point(latitude: 49.724739, longitude: 32.140865),
    "UG": Point(latitude: 1.972589, longitude: 32.948555),
    "UM": Point(latitude: 16.727398, longitude: -169.53804),
    "US": Point(latitude: 39.538479, longitude: -97.482602),
    "UY": Point(latitude: -32.961127, longitude: -55.966942),
    "UZ": Point(latitude: 41.693603, longitude: 64.005429),
    "VA": Point(latitude: 41.903323, longitude: 12.453418),
    "VC": Point(latitude: 13.0879, longitude: -61.3359),
    "VE": Point(latitude: 7.182476, longitude: -64.599381),
    "VG": Point(latitude: 18.426606, longitude: -64.63661),
    "VI": Point(latitude: 17.746706, longitude: -64.779172),
    "VN": Point(latitude: 21.715416, longitude: 105.387292),
    "VU": Point(latitude: -15.37153, longitude: 166.908762),
    "WF": Point(latitude: -14.286415, longitude: -178.137436),
    "WS": Point(latitude: -13.639139, longitude: -172.438241),
    "XK": Point(latitude: 42.593587, longitude: 20.860719),
    "YE": Point(latitude: 15.328226, longitude: 45.874383),
    "YT": Point(latitude: -12.774755, longitude: 45.151319),
    "ZA": Point(latitude: -29.708776, longitude: 23.665734),
    "ZM": Point(latitude: -14.660804, longitude: 26.395298),
    "ZW": Point(latitude: -18.91164, longitude: 29.925444),
  ]
  // END GENERATED WAF COUNTRY CENTROIDS
}

struct WAFEventsView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.featureAllowsWrites) private var featureAllowsWrites
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let zoneID: String
  @State private var selectedCountryCode: String?
  @State private var globeCamera = GlobeCamera(longitude: 0, latitude: 15)
  @State private var didSetInitialGlobeCamera = false
  @State private var summary: FirewallEventsSummary?
  @State private var loading = true
  @State private var error: String?
  @State private var underAttack = false
  @State private var securityLoaded = false
  /// A settled settings response with no `security_level` is an answer, not a
  /// failure: the toggle hides rather than sitting disabled forever.
  @State private var securityAvailable = true
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
      retry: { Task { await load(force: true) } },
      skeleton: { wafDetailSkeleton }
    ) {
      if let summary {
        // A metric tile — the surface `DashGlassCard` exists for.
        DashGlassCard {
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
      if securityAvailable {
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
      }
      if let summary {
        let topCountries = WAFChartModel.topCountries(summary.countries)
        if summary.countries.isEmpty || WAFGlobeModel.points(from: topCountries).isEmpty {
          wafBucketGroup(
            title: "Top countries", buckets: summary.countries, labelsAreRegionCodes: true
          )
          .dashSectionBoundary()
        } else {
          countriesGlobeGroup(topCountries, totalBlocked: summary.blocked)
            .dashSectionBoundary()
        }
        wafBucketGroup(title: "Top rules", buckets: summary.rules)
          .dashSectionBoundary()
      }
    }
    .detailHeader(icon: .solar(SolarAsset.Content.shieldCheck), title: "WAF")
    .refreshable { await load(force: true) }
    .task(id: model.grantedScopes) { await load() }
  }

  /// Blocked-requests metric panel, Under Attack toggle, then Top countries /
  /// Top rules row groups.
  private var wafDetailSkeleton: some View {
    VStack(alignment: .leading, spacing: 0) {
      DashGlassCard {
        VStack(alignment: .leading, spacing: 8) {
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .dashSkeletonFill(DashSkeletonStyle.strong)
            .frame(width: 96, height: 12)
          Text(verbatim: "888,888")
            .dashTextStyle(.sectionTitle)
            .monospacedDigit()
            .lineLimit(1)
            .redacted(reason: .placeholder)
            .dashSkeletonShimmer()
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .dashSkeletonFill(DashSkeletonStyle.soft)
            .frame(width: 112, height: 11)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      DashToggleRowPlaceholder()
        .dashSectionBoundary()
      DashListGroup(title: "Top countries") {
        DashListRowPlaceholders(rows: 3)
      }
      .dashSectionBoundary()
      DashListGroup(title: "Top rules") {
        DashListRowPlaceholders(rows: 3)
      }
      .dashSectionBoundary()
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Loading")
  }

  /// The GraphQL country dimension is an ISO 3166 alpha-2 code — show the
  /// localized region name when we can resolve one.
  private func regionName(_ code: String) -> String {
    guard let normalizedCode = WAFISOCountryCentroids.normalizedCode(code) else {
      return code
    }
    return DashL10n.activeLocale.localizedString(forRegionCode: normalizedCode)
      ?? normalizedCode
  }

  private var countryRankingColumns: [GridItem] {
    if dynamicTypeSize.isAccessibilitySize {
      return [GridItem(.flexible(), spacing: 0, alignment: .leading)]
    }
    return [
      GridItem(.flexible(), spacing: 8, alignment: .leading),
      GridItem(.flexible(), spacing: 8, alignment: .leading),
    ]
  }

  private func countriesGlobeGroup(
    _ countries: [FirewallEventsBucket],
    totalBlocked: Int
  ) -> some View {
    let points = WAFGlobeModel.points(from: countries)
    // One heading, not two: the card inside this group used to carry its own
    // “Blocks by country” title, saying what the group header already says.
    return DashListGroup(title: "Top countries") {
      DashGlassCard {
        VStack(alignment: .leading, spacing: 12) {
          DotGlobeView(
            camera: $globeCamera,
            style: GlobeStyle(
              baseColor: DashTheme.faint,
              glowColor: DashTheme.hairline,
              defaultMarkerColor: DashTheme.warning,
              mapSamples: 12_000,
              mapBrightness: colorScheme == .dark ? 7 : 5,
              diffuse: 1.1,
              markerElevation: 0.025
            ),
            markers: globeMarkers(points),
            behavior: GlobeBehavior(
              autoRotationSpeed: selectedCountryCode == nil ? 0.07 : 0,
              allowsDragging: true,
              allowsInertia: true,
              quality: .adaptive
            ),
            accessibilityLabel: WAFChartModel.countriesAccessibilitySummary(
              buckets: countries,
              totalBlocked: totalBlocked)
          ) { marker in
            selectCountry(marker.id)
          }
          .frame(height: 220)
          .contentShape(Rectangle())

          countryRanking(countries)
        }
      }
    }
  }

  private func globeMarkers(_ points: [WAFGlobePoint]) -> [GlobeMarker] {
    points.map { point in
      let isSelected = selectedCountryCode == point.countryCode
      let countLabel = localizedBlockCount(point.count)
      let selectionLabel =
        isSelected ? ", \(DashL10n.ui("Selected"))" : ""
      return GlobeMarker(
        id: point.countryCode,
        coordinate: point.coordinate,
        size: point.markerSize,
        color: isSelected ? DashTheme.brand : DashTheme.warning,
        accessibilityLabel:
          "\(regionName(point.countryCode)), \(countLabel)\(selectionLabel)"
      )
    }
  }

  private func countryRanking(_ countries: [FirewallEventsBucket]) -> some View {
    LazyVGrid(columns: countryRankingColumns, alignment: .leading, spacing: 4) {
      ForEach(Array(countries.enumerated()), id: \.element.id) { index, bucket in
        if let countryCode = WAFISOCountryCentroids.normalizedCode(bucket.label),
          let coordinate = WAFISOCountryCentroids.coordinate(for: countryCode)
        {
          Button {
            selectCountry(countryCode, focus: coordinate)
          } label: {
            countryRankingCell(index: index, bucket: bucket)
          }
          .buttonStyle(DashSurfaceButtonStyle())
          .accessibilityLabel(
            "\(regionName(bucket.label)), \(localizedBlockCount(bucket.count))"
          )
          .accessibilityAddTraits(
            selectedCountryCode == countryCode ? .isSelected : [])
        } else {
          countryRankingCell(index: index, bucket: bucket)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
              "\(regionName(bucket.label)), \(localizedBlockCount(bucket.count))")
        }
      }
    }
  }

  private func countryRankingCell(
    index: Int,
    bucket: FirewallEventsBucket
  ) -> some View {
    let isSelected =
      selectedCountryCode == WAFISOCountryCentroids.normalizedCode(bucket.label)
    return HStack(spacing: 8) {
      Text((index + 1).formatted(.number.locale(DashL10n.activeLocale)))
        .dashTextStyle(.captionSemibold)
        .monospacedDigit()
        .foregroundStyle(isSelected ? DashTheme.brand : DashTheme.faint)
        .frame(minWidth: 14, alignment: .trailing)
      Text(regionName(bucket.label))
        .dashTextStyle(.footnote)
        .foregroundStyle(isSelected ? DashTheme.strong : DashTheme.text)
        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
      Spacer(minLength: 4)
      Text(bucket.count.formatted(.number.locale(DashL10n.activeLocale)))
        .dashTextStyle(.captionSemibold)
        .monospacedDigit()
        .foregroundStyle(isSelected ? DashTheme.brand : DashTheme.subtle)
    }
    .padding(.horizontal, 8)
    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
    .background(
      isSelected ? DashTheme.infoTint : Color.clear,
      in: RoundedRectangle(cornerRadius: DashTheme.Radius.small, style: .continuous)
    )
    .contentShape(
      RoundedRectangle(cornerRadius: DashTheme.Radius.small, style: .continuous))
  }

  private func localizedBlockCount(_ count: Int) -> String {
    let formatted = count.formatted(.number.locale(DashL10n.activeLocale))
    return DashL10n.string("\(formatted) blocks")
  }

  private func selectCountry(
    _ countryCode: String,
    focus coordinate: GlobeCoordinate? = nil
  ) {
    let nextSelection = selectedCountryCode == countryCode ? nil : countryCode
    guard nextSelection != selectedCountryCode else { return }
    DashDelight.selectionChanged()
    if nextSelection != nil, let coordinate {
      globeCamera = GlobeCamera(
        longitude: coordinate.longitude,
        latitude: coordinate.latitude
      )
    }
    withAnimation(DashTheme.Motion.settle) {
      selectedCountryCode = nextSelection
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
      applySummary(cached)
      return
    }
    do {
      let fetched = try await model.client.firewallEventsSummary(zoneID: zoneID, hours: 24)
      applySummary(fetched)
      model.featureCache.set(key, fetched)
    } catch {
      guard !error.dashIsCancellation else { return }
      self.error = error.dashActionableMessage
    }
  }

  private func applySummary(_ fetched: FirewallEventsSummary) {
    let countriesChanged = fetched.countries != summary?.countries
    summary = fetched
    guard countriesChanged else { return }

    let points = WAFGlobeModel.points(
      from: WAFChartModel.topCountries(fetched.countries))
    if let selectedCountryCode,
      !points.contains(where: { $0.countryCode == selectedCountryCode })
    {
      self.selectedCountryCode = nil
    }
    guard !didSetInitialGlobeCamera, let leader = points.first else { return }
    globeCamera = GlobeCamera(
      longitude: leader.coordinate.longitude,
      latitude: leader.coordinate.latitude
    )
    didSetInitialGlobeCamera = true
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
      guard !error.dashIsCancellation, !Task.isCancelled else { return }
      // A failed re-check keeps the last-known toggle state; the summary's
      // failure message, when present, owns the banner.
      if self.error == nil { self.error = error.dashActionableMessage }
    }
  }

  private func applySecurity(_ settings: [ZoneSetting]) {
    if case .string(let value)? = settings.first(where: { $0.id == "security_level" })?.value {
      underAttack = value == "under_attack"
      securityLoaded = true
      securityAvailable = true
    } else {
      securityAvailable = false
    }
  }

  private func setUnderAttack(_ enabled: Bool) async {
    guard model.hasScopes(requiredWriteScopes) else {
      model.requestAccess(to: requiredWriteScopes)
      return
    }
    guard let context = model.accountRequestContext else { return }
    securityUpdating = true
    defer { securityUpdating = false }
    do {
      let outcome = try await ZoneSecurityLevelOperation.setUnderAttack(
        zoneID: zoneID,
        enabled: enabled,
        client: model.client,
        isCurrent: { model.isCurrentAccount(context) })
      underAttack = outcome.isUnderAttack
      model.featureCache.remove(FeatureCacheKey.zoneSettings(zoneID))
      DashDelight.celebrateSuccess()
    } catch {
      guard !error.dashIsCancellation, model.isCurrentAccount(context) else { return }
      underAttack = !enabled
      model.toasts.error(error.dashActionableMessage)
    }
  }
}
