import Foundation

/// A concrete account resource opened from Search or a deep link. Home's
/// Continue section returns to the same Worker, zone, bucket, or namespace.
struct RecentResource: Hashable, Identifiable, Sendable {
  enum Kind: String, Sendable {
    case zone, worker, r2, kv

    var displayName: String {
      switch self {
      case .zone: "Zone"
      case .worker: "Worker"
      case .r2: "R2"
      case .kv: "KV"
      }
    }
  }

  let kind: Kind
  let accountID: String
  /// Zone id, Worker name, R2 bucket name, or KV namespace id.
  let resourceID: String
  let title: String

  var id: String { "\(kind.rawValue)|\(accountID)|\(resourceID)" }

  var destination: Destination {
    switch kind {
    case .zone: .zone(resourceID)
    case .worker: .worker(resourceID)
    case .r2: .r2Bucket(resourceID)
    case .kv: .kvNamespace(resourceID)
    }
  }

  var featureID: FeatureID {
    switch kind {
    case .zone: .zones
    case .worker: .workers
    case .r2: .r2
    case .kv: .kv
    }
  }
}

enum RecentResources {
  static let key = "dash.recent_resources"
  static let limit = 6

  static func record(_ resource: RecentResource, defaults: UserDefaults = .standard) {
    let existing = defaults.string(forKey: key) ?? ""
    defaults.set(updated(existing: existing, adding: resource), forKey: key)
    DashSpotlight.index(resource)
  }

  static func updated(existing: String, adding resource: RecentResource) -> String {
    let token = encodeToken(resource)
    let others = existing.split(separator: ",").map(String.init).filter { $0 != token }
    return ([token] + others).prefix(limit).joined(separator: ",")
  }

  static func decode(_ raw: String) -> [RecentResource] {
    raw.split(separator: ",").compactMap { decodeToken(String($0)) }
  }

  static func continueItems(
    recent: [RecentResource], accountID: String?, limit: Int = limit
  ) -> [RecentResource] {
    guard let accountID else { return [] }
    var seen = Set<String>()
    var items: [RecentResource] = []
    for resource in recent where resource.accountID == accountID {
      guard seen.insert(resource.id).inserted else { continue }
      items.append(resource)
      if items.count == limit { break }
    }
    return items
  }

  private static func encodeToken(_ resource: RecentResource) -> String {
    [
      resource.kind.rawValue,
      resource.accountID,
      resource.resourceID,
      resource.title.replacingOccurrences(of: "|", with: "/").replacingOccurrences(
        of: ",", with: " "),
    ].joined(separator: "|")
  }

  private static func decodeToken(_ token: String) -> RecentResource? {
    let parts = token.split(separator: "|", maxSplits: 3).map(String.init)
    guard parts.count == 4, let kind = RecentResource.Kind(rawValue: parts[0]) else { return nil }
    return RecentResource(
      kind: kind, accountID: parts[1], resourceID: parts[2], title: parts[3])
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
