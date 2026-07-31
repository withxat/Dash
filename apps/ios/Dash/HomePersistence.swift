import Foundation

/// Watchtower account-analytics card layout. Each preference is stored as a
/// comma-separated list of metric raw values so a new metric can be appended
/// automatically without invalidating an existing layout.
enum WatchtowerAnalyticsCardLayout {
  static let key = "dash.watchtower_analytics_collapsed"
  static let orderKey = "dash.watchtower_analytics_order"
  static let hiddenKey = "dash.watchtower_analytics_hidden"

  /// A resolved layout: the full metric order plus the collapsed and hidden
  /// subsets. Kept as one value so a fresh install and a saved layout come from
  /// the same place instead of three `?? ""` reads.
  struct Layout: Equatable, Sendable {
    var order: [WatchtowerAnalyticsMetric]
    var collapsed: Set<WatchtowerAnalyticsMetric>
    var hidden: Set<WatchtowerAnalyticsMetric>
  }

  /// Fresh-install charts: one expanded headline metric over four collapsed
  /// companions. Everything else starts hidden and is one tap away in the
  /// editor's Add chart menu.
  static let defaultVisibleMetrics: [WatchtowerAnalyticsMetric] = [
    .webTraffic, .cpuTime, .workerInvocations, .cacheRate, .clientRequestErrors,
  ]
  /// The one metric that opens expanded on a fresh install.
  static let defaultExpandedMetric: WatchtowerAnalyticsMetric = .webTraffic

  static var defaultLayout: Layout {
    // Hidden metrics keep their `allCases` order behind the visible five, so
    // adding one back lands it in a stable place instead of at a random index.
    let order = orderedMetrics(in: encodeOrder(defaultVisibleMetrics))
    let visible = Set(defaultVisibleMetrics)
    return Layout(
      order: order,
      collapsed: visible.subtracting([defaultExpandedMetric]),
      hidden: Set(order).subtracting(visible))
  }

  /// Resolves the stored layout. The fresh-install defaults apply only when no
  /// preference has ever been written — a saved layout that hides nothing (an
  /// empty string, not a missing key) stays an explicit choice across app
  /// updates, and so does a pre-editor install that only ever stored collapsed
  /// metrics.
  static func layout(orderRaw: String?, collapsedRaw: String?, hiddenRaw: String?) -> Layout {
    guard orderRaw != nil || collapsedRaw != nil || hiddenRaw != nil else {
      return defaultLayout
    }
    return Layout(
      order: orderedMetrics(in: orderRaw ?? ""),
      collapsed: Set(
        collapsedIDs(in: collapsedRaw ?? "").compactMap(WatchtowerAnalyticsMetric.init(rawValue:))),
      hidden: Set(
        hiddenIDs(in: hiddenRaw ?? "").compactMap(WatchtowerAnalyticsMetric.init(rawValue:))))
  }

  static func collapsedIDs(in raw: String) -> Set<String> {
    Set(raw.split(separator: ",").map(String.init).filter { !$0.isEmpty })
  }

  static func hiddenIDs(in raw: String) -> Set<String> {
    Set(raw.split(separator: ",").map(String.init).filter { !$0.isEmpty })
  }

  static func isExpanded(_ metricID: String, raw: String) -> Bool {
    !collapsedIDs(in: raw).contains(metricID)
  }

  static func encode(_ collapsed: Set<String>) -> String {
    collapsed.sorted().joined(separator: ",")
  }

  static func toggled(_ metricID: String, in raw: String) -> String {
    var next = collapsedIDs(in: raw)
    if next.contains(metricID) {
      next.remove(metricID)
    } else {
      next.insert(metricID)
    }
    return encode(next)
  }

  static func orderedMetrics(
    in raw: String,
    available: [WatchtowerAnalyticsMetric] = Array(WatchtowerAnalyticsMetric.allCases)
  ) -> [WatchtowerAnalyticsMetric] {
    let availableSet = Set(available)
    var seen = Set<WatchtowerAnalyticsMetric>()
    var ordered = raw.split(separator: ",").compactMap { token -> WatchtowerAnalyticsMetric? in
      guard let metric = WatchtowerAnalyticsMetric(rawValue: String(token)),
        availableSet.contains(metric),
        seen.insert(metric).inserted
      else { return nil }
      return metric
    }
    ordered.append(contentsOf: available.filter { seen.insert($0).inserted })
    return ordered
  }

  static func encodeOrder(_ metrics: [WatchtowerAnalyticsMetric]) -> String {
    metrics.map(\.rawValue).joined(separator: ",")
  }

  static func encodeHidden(_ metrics: Set<WatchtowerAnalyticsMetric>) -> String {
    metrics.map(\.rawValue).sorted().joined(separator: ",")
  }

  /// Moves a dragged card across its target. Downward moves land after the
  /// target; upward moves land before it, matching the native list reorder
  /// convention as the pointer crosses a row.
  static func moving(
    _ metrics: [WatchtowerAnalyticsMetric],
    item: WatchtowerAnalyticsMetric,
    across target: WatchtowerAnalyticsMetric
  ) -> [WatchtowerAnalyticsMetric] {
    guard item != target,
      let sourceIndex = metrics.firstIndex(of: item),
      let targetIndex = metrics.firstIndex(of: target)
    else { return metrics }

    var next = metrics
    let moved = next.remove(at: sourceIndex)
    next.insert(moved, at: targetIndex)
    return next
  }

  /// Moves a dragged card to an absolute slot. `index` counts the order with
  /// the dragged card already removed, which is what a reading-order hit test
  /// over the remaining cards produces — including `count`, the slot past the
  /// last card that `moving(_:item:across:)` has no way to express.
  static func moving(
    _ metrics: [WatchtowerAnalyticsMetric],
    item: WatchtowerAnalyticsMetric,
    to index: Int
  ) -> [WatchtowerAnalyticsMetric] {
    guard let sourceIndex = metrics.firstIndex(of: item) else { return metrics }
    var next = metrics
    let moved = next.remove(at: sourceIndex)
    next.insert(moved, at: min(max(index, 0), next.count))
    return next
  }

  /// Packs metrics into visual rows: each expanded metric owns a solo row;
  /// collapsed metrics pair into two-up rows (a leftover occupies half width).
  static func rows(
    _ metrics: [WatchtowerAnalyticsMetric],
    collapsedRaw: String,
    forceExpanded: Bool
  ) -> [[WatchtowerAnalyticsMetric]] {
    var rows: [[WatchtowerAnalyticsMetric]] = []
    var collapsedBuffer: [WatchtowerAnalyticsMetric] = []

    func flushCollapsed() {
      var index = 0
      while index < collapsedBuffer.count {
        if index + 1 < collapsedBuffer.count {
          rows.append([collapsedBuffer[index], collapsedBuffer[index + 1]])
          index += 2
        } else {
          rows.append([collapsedBuffer[index]])
          index += 1
        }
      }
      collapsedBuffer.removeAll(keepingCapacity: true)
    }

    for metric in metrics {
      if forceExpanded || isExpanded(metric.rawValue, raw: collapsedRaw) {
        flushCollapsed()
        rows.append([metric])
      } else {
        collapsedBuffer.append(metric)
      }
    }
    flushCollapsed()
    return rows
  }
}

/// The feature launchers shown in Home's editable Shortcuts card.
///
/// The raw value is deliberately just a comma-separated list of `FeatureID`
/// values: feature ids cannot contain commas, and an empty stored value remains
/// a valid explicit choice instead of being mistaken for an uninitialized state.
enum HomeShortcuts {
  static let key = "dash.home_shortcuts"
  static let defaults: [FeatureID] = [.zones, .workers, .pages, .r2]
  static let defaultValue = encode(defaults)

  static func decode(_ raw: String) -> [FeatureID] {
    var seen = Set<FeatureID>()
    return raw.split(separator: ",").compactMap { token in
      guard let feature = FeatureID(rawValue: String(token)), seen.insert(feature).inserted else {
        return nil
      }
      return feature
    }
  }

  static func encode(_ features: [FeatureID]) -> String {
    features.map(\.rawValue).joined(separator: ",")
  }

  static func toggled(_ feature: FeatureID, in raw: String) -> String {
    var features = decode(raw)
    if let index = features.firstIndex(of: feature) {
      features.remove(at: index)
    } else {
      features.append(feature)
    }
    return encode(features)
  }
}

struct PinnedZone: Hashable, Identifiable, Sendable {
  let accountID: String
  let zoneID: String
  let name: String

  var id: String { zoneID }
}

/// Pinned zones as `accountID|zoneID|name` triples joined by commas — domain
/// names cannot contain `|` or `,`, so the encoding is unambiguous.
enum PinnedZones {
  static let key = "dash.pinned_zones"
  /// Accounts whose pins have been seeded once. Separate from `key` so that a
  /// deliberately emptied pin set stays empty instead of re-seeding on the next
  /// zone load.
  static let initializedAccountsKey = "dash.pinned_zones_initialized"

  static let defaultLimit = 4

  static func decode(_ raw: String) -> [PinnedZone] {
    raw.split(separator: ",").compactMap { entry in
      let parts = entry.split(separator: "|", maxSplits: 2).map(String.init)
      guard parts.count == 3 else { return nil }
      return PinnedZone(accountID: parts[0], zoneID: parts[1], name: parts[2])
    }
  }

  static func encode(_ pins: [PinnedZone]) -> String {
    pins.map { "\($0.accountID)|\($0.zoneID)|\($0.name)" }.joined(separator: ",")
  }

  static func isPinned(_ raw: String, zoneID: String) -> Bool {
    decode(raw).contains { $0.zoneID == zoneID }
  }

  /// Adds the pin newest-first, or removes it when the zone is already pinned.
  static func toggled(_ raw: String, pin: PinnedZone) -> String {
    var pins = decode(raw)
    if pins.contains(where: { $0.zoneID == pin.zoneID }) {
      pins.removeAll { $0.zoneID == pin.zoneID }
    } else {
      pins.insert(pin, at: 0)
    }
    return encode(pins)
  }

  /// This account's pinned zone ids, in pin order.
  static func pinnedZoneIDs(in raw: String, accountID: String) -> [String] {
    decode(raw).filter { $0.accountID == accountID }.map(\.zoneID)
  }

  /// `ids` reordered so this account's pins lead, in pin order; everything else
  /// keeps its incoming order behind them.
  static func prioritizedZoneIDs(
    _ ids: [String],
    pinsRaw: String,
    accountID: String
  ) -> [String] {
    let pinned = pinnedZoneIDs(in: pinsRaw, accountID: accountID)
    let available = Set(ids)
    let leading = pinned.filter(available.contains)
    let leadingSet = Set(leading)
    return leading + ids.filter { !leadingSet.contains($0) }
  }

  /// Seeds an account's pins from `defaults` the first time its zones load, and
  /// records that it happened. Already-initialized accounts are returned
  /// untouched, so clearing every pin is a decision the app respects.
  static func bootstrapped(
    _ raw: String,
    initializedAccountsRaw: String,
    accountID: String,
    defaults: [PinnedZone],
    limit: Int = defaultLimit
  ) -> (pins: String, initializedAccounts: String) {
    var initialized = initializedAccountsRaw.split(separator: ",").map(String.init)
    guard !initialized.contains(accountID) else {
      return (raw, initializedAccountsRaw)
    }
    initialized.append(accountID)
    let seeded = defaults.filter { $0.accountID == accountID }.prefix(limit)
    let pins = Array(seeded) + decode(raw).filter { $0.accountID != accountID }
    return (encode(pins), initialized.joined(separator: ","))
  }
}

/// A resource the user drilled into, remembered so Home can offer the way
/// back. Kinds mirror the `Destination` cases that carry a resource identity.
struct RecentResource: Codable, Hashable, Identifiable, Sendable {
  enum Kind: String, Codable, Sendable {
    case zone
    case worker
    case pagesProject
    case r2Bucket
    case kvNamespace

    var displayName: String {
      switch self {
      case .zone: DashL10n.string("Domain")
      case .worker: DashL10n.string("Worker")
      case .pagesProject: DashL10n.string("Pages")
      case .r2Bucket: DashL10n.string("R2 bucket")
      case .kvNamespace: DashL10n.string("KV namespace")
      }
    }

    /// Content-row glyph for Home Recently used — matches the feature list
    /// item (box / pin / code square), not the catalog tile (cloud / key).
    var listIcon: String? {
      switch self {
      case .zone: nil
      case .worker: SolarAsset.Content.code
      case .pagesProject: SolarAsset.Content.codeCircle
      case .r2Bucket: SolarAsset.Content.box
      case .kvNamespace: SolarAsset.Content.pinList
      }
    }
  }

  let accountID: String
  let kind: Kind
  let resourceID: String
  let title: String

  var id: String { "\(accountID)|\(kind.rawValue)|\(resourceID)" }

  /// Where reopening this resource lands.
  var destination: Destination {
    switch kind {
    case .zone: .zone(resourceID)
    case .worker: .worker(resourceID)
    case .pagesProject: .pagesProject(resourceID)
    case .r2Bucket: .r2Bucket(resourceID, prefix: "")
    case .kvNamespace: .kvNamespace(resourceID)
    }
  }

  /// The feature whose visual identity (icon tone, outline asset) the row borrows.
  var featureID: FeatureID {
    switch kind {
    case .zone: .zones
    case .worker: .workers
    case .pagesProject: .pages
    case .r2Bucket: .r2
    case .kvNamespace: .kv
    }
  }
}

/// Recently opened resources as a JSON blob in `@AppStorage`. Unlike pins,
/// titles here include KV namespace names, which can contain `|` and `,` —
/// so the pipe encoding the other keys use is not safe for this one.
enum RecentResources {
  static let key = "dash.recent_resources"
  /// Enough to remember across accounts without growing unbounded.
  static let limit = 24
  /// Rows Home actually shows for the active account.
  static let displayLimit = 5

  static func decode(_ raw: String) -> [RecentResource] {
    guard !raw.isEmpty, let data = raw.data(using: .utf8) else { return [] }
    return (try? JSONDecoder().decode([RecentResource].self, from: data)) ?? []
  }

  static func encode(_ recents: [RecentResource]) -> String {
    guard let data = try? JSONEncoder().encode(recents) else { return "" }
    return String(decoding: data, as: UTF8.self)
  }

  /// The entry moves (or inserts) to the front; the tail is trimmed so the
  /// stored list stays bounded.
  static func recording(_ entry: RecentResource, in raw: String) -> String {
    var recents = decode(raw)
    recents.removeAll { $0.id == entry.id }
    recents.insert(entry, at: 0)
    return encode(Array(recents.prefix(limit)))
  }

  /// This account's recents, newest first, capped for display.
  static func visible(in raw: String, accountID: String) -> [RecentResource] {
    Array(decode(raw).filter { $0.accountID == accountID }.prefix(displayLimit))
  }
}

enum HomeEducationTip: String, Codable, Hashable, Sendable {
  case r2ShareExtension
}

/// Small, evidence-led Home tips. Recommendations are derived only from local,
/// account-scoped usage and each dismissal is stored per account so switching
/// accounts never leaks another account's learning state.
enum HomeEducation {
  static let dismissalsKey = "dash.home_education_dismissals"

  private struct Dismissal: Codable, Hashable {
    let accountID: String
    let tip: HomeEducationTip
  }

  static func recommendation(
    recentsRaw: String,
    accountID: String?,
    dismissalsRaw: String,
    isDemoSession: Bool
  ) -> HomeEducationTip? {
    guard !isDemoSession, let accountID, !accountID.isEmpty else { return nil }

    let tip = HomeEducationTip.r2ShareExtension
    guard
      RecentResources.decode(recentsRaw).contains(where: {
        $0.accountID == accountID && $0.kind == .r2Bucket
      }),
      !decodeDismissals(dismissalsRaw).contains(
        where: { $0.accountID == accountID && $0.tip == tip })
    else { return nil }

    return tip
  }

  static func recordingDismissal(
    _ tip: HomeEducationTip,
    accountID: String,
    in raw: String
  ) -> String {
    guard !accountID.isEmpty else { return raw }
    var dismissals = decodeDismissals(raw)
    let dismissal = Dismissal(accountID: accountID, tip: tip)
    guard !dismissals.contains(dismissal) else { return raw }
    dismissals.append(dismissal)
    dismissals.sort {
      if $0.accountID == $1.accountID {
        return $0.tip.rawValue < $1.tip.rawValue
      }
      return $0.accountID < $1.accountID
    }
    guard let data = try? JSONEncoder().encode(dismissals) else { return raw }
    return String(decoding: data, as: UTF8.self)
  }

  private static func decodeDismissals(_ raw: String) -> [Dismissal] {
    guard !raw.isEmpty, let data = raw.data(using: .utf8) else { return [] }
    return (try? JSONDecoder().decode([Dismissal].self, from: data)) ?? []
  }
}

/// The Add domain form accepts anything Cloudflare could plausibly take as a
/// zone name and leaves real validation to the API, which owns the rules.
enum AddDomainValidation {
  static func normalized(_ input: String) -> String {
    input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  static func isPlausibleZoneName(_ input: String) -> Bool {
    let name = normalized(input)
    guard name.count >= 3, name.count <= 253, !name.contains(" ") else { return false }
    let labels = name.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return false }
    guard let tld = labels.last, tld.count >= 2 else { return false }
    return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }
  }
}

struct DomainCardColorSelection: Hashable, Sendable {
  let accountID: String
  let zoneID: String
  let hex: UInt32
}

/// Per-account domain card colors encoded as `accountID|zoneID|#RRGGBB`.
/// Legacy named tints (`emerald`, `ocean`, …) still decode for existing installs.
enum DomainCardColors {
  static let key = "dash.domain_card_colors"

  /// Built-in card colors shown in the customize grid (4×5), and used for
  /// stable per-domain defaults until the user picks explicitly.
  static let defaultPalette: [UInt32] = [
    0xEE3B5C, 0xEE4191, 0xDD41F3, 0x8E4EF7, 0x4A43F3,
    0x2177F8, 0x349DED, 0x37A7FA, 0x3EAFC5, 0x40AE75,
    0x46BB52, 0x74C330, 0xECA82C, 0xF39328, 0xF0651D,
    0xEE3B35, 0xCEAC4B, 0xC28144, 0x0E2E5C, 0x1B191F,
  ]

  private static let legacyNames: [String: UInt32] = [
    "emerald": 0x047857,
    "ocean": 0x0369A1,
    "indigo": 0x4F46E5,
    "violet": 0x7E22CE,
    "rose": 0xBE123C,
    "orange": 0xB45309,
  ]

  static func decode(_ raw: String) -> [DomainCardColorSelection] {
    raw.split(separator: ",").compactMap { entry in
      let parts = entry.split(separator: "|", maxSplits: 2).map(String.init)
      guard parts.count == 3, let hex = parseToken(parts[2]) else { return nil }
      return DomainCardColorSelection(accountID: parts[0], zoneID: parts[1], hex: hex)
    }
  }

  static func encode(_ selections: [DomainCardColorSelection]) -> String {
    selections.map { "\($0.accountID)|\($0.zoneID)|\(formatHex($0.hex))" }
      .joined(separator: ",")
  }

  static func hex(
    in raw: String,
    accountID: String,
    zoneID: String,
    seed: String
  ) -> UInt32 {
    decode(raw).first { $0.accountID == accountID && $0.zoneID == zoneID }?.hex
      ?? defaultHex(for: seed)
  }

  static func setting(
    _ hex: UInt32,
    in raw: String,
    accountID: String,
    zoneID: String
  ) -> String {
    var selections = decode(raw)
    selections.removeAll { $0.accountID == accountID && $0.zoneID == zoneID }
    selections.append(
      DomainCardColorSelection(accountID: accountID, zoneID: zoneID, hex: hex))
    return encode(selections)
  }

  /// A stable default gives each domain a recognizable card color without
  /// persisting anything until the user makes an explicit choice.
  static func defaultHex(for seed: String) -> UInt32 {
    var hash: UInt32 = 2_166_136_261
    for byte in seed.utf8 {
      hash = (hash ^ UInt32(byte)) &* 16_777_619
    }
    return defaultPalette[Int(hash % UInt32(defaultPalette.count))]
  }

  static func formatHex(_ value: UInt32) -> String {
    String(format: "#%06X", value & 0xFFFFFF)
  }

  static func parseToken(_ token: String) -> UInt32? {
    if let legacy = legacyNames[token] { return legacy }
    var hex = token
    if hex.hasPrefix("#") { hex.removeFirst() }
    guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
    return value
  }

  /// Relative luminance under sRGB; below the cutoff, white card text stays readable.
  static func prefersLightContent(_ hex: UInt32) -> Bool {
    func channel(_ value: UInt32) -> Double {
      let c = Double(value) / 255
      return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    let r = channel((hex >> 16) & 0xFF)
    let g = channel((hex >> 8) & 0xFF)
    let b = channel(hex & 0xFF)
    let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
    return luminance < 0.55
  }
}
