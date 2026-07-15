import Foundation

/// The "Recently opened" list: FeatureID rawValues as a CSV in UserDefaults,
/// most recent first, deduped, capped. Shared by Home and Search so both
/// record through one implementation.
enum RecentFeatures {
  static let key = "dash.recent_items"
  static let limit = 6

  static func record(_ item: FeatureID, defaults: UserDefaults = .standard) {
    let existing = defaults.string(forKey: key) ?? ""
    defaults.set(updated(existing: existing, adding: item), forKey: key)
  }

  static func updated(existing: String, adding item: FeatureID) -> String {
    let others = existing.split(separator: ",").map(String.init)
      .filter { $0 != item.rawValue }
    return ([item.rawValue] + others).prefix(limit).joined(separator: ",")
  }

  /// Home "Continue" list: recent first, then shortcuts, deduped and capped.
  static func continueItems(
    recent: [FeatureID], shortcuts: [FeatureID], limit: Int = limit
  ) -> [FeatureID] {
    var seen = Set<FeatureID>()
    var items: [FeatureID] = []
    for feature in recent + shortcuts where seen.insert(feature).inserted {
      items.append(feature)
      if items.count == limit { break }
    }
    return items
  }
}

/// A zone pinned to Home. Pins for every account share one storage key;
/// render-time filtering by accountID keeps accounts separated.
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

  /// Adds the pin, or removes it when the zone is already pinned.
  static func toggled(_ raw: String, pin: PinnedZone) -> String {
    var pins = decode(raw)
    if pins.contains(where: { $0.zoneID == pin.zoneID }) {
      pins.removeAll { $0.zoneID == pin.zoneID }
    } else {
      pins.append(pin)
    }
    return encode(pins)
  }
}
