import Foundation

/// Snapshot of Cloudflare's own status page (cloudflarestatus.com) — an
/// Atlassian Statuspage instance with a public, unauthenticated JSON API.
///
/// This is Cloudflare's published verdict about its own services, which is why
/// Dash may render it at all: nothing here is computed client-side. The page is
/// hosted by Atlassian, so the fetch deliberately does NOT go through
/// `CloudflareClient` — that path attaches a Cloudflare Bearer token, and a
/// third-party host must never see one.
public struct CloudflareStatusSummary: Hashable, Sendable, Codable {
  /// Statuspage's page-wide severity rollup. Anything unrecognised decodes as
  /// `.unknown` rather than optimistically healthy.
  public enum Indicator: String, Hashable, Sendable, Codable {
    case none
    case minor
    case major
    case critical
    case unknown

    init(wire: String?) {
      self = wire.flatMap(Indicator.init(rawValue:)) ?? .unknown
    }
  }

  public let indicator: Indicator
  /// Unresolved incidents only — `summary.json` drops an incident once it
  /// resolves, so an empty list is the normal, healthy answer.
  public let incidents: [CloudflareStatusIncident]
  /// Product-level components (Access, API, CDN…), excluding the per-colo
  /// entries that dominate the raw payload. See `serviceComponentGroupID`.
  public let serviceComponents: [CloudflareStatusComponent]
  /// Maintenances currently being performed or verified. Windows that are
  /// merely scheduled are dropped — Cloudflare announces one per colo, so the
  /// raw list is dominated by machine-room noise that says nothing about now.
  public let activeMaintenances: [CloudflareStatusMaintenance]

  public init(
    indicator: Indicator,
    incidents: [CloudflareStatusIncident] = [],
    serviceComponents: [CloudflareStatusComponent] = [],
    activeMaintenances: [CloudflareStatusMaintenance] = []
  ) {
    self.indicator = indicator
    self.incidents = incidents
    self.serviceComponents = serviceComponents
    self.activeMaintenances = activeMaintenances
  }
}

public struct CloudflareStatusIncident: Hashable, Sendable, Codable, Identifiable {
  /// Statuspage's incident lifecycle. `postmortem` folds into `.resolved` at
  /// the call site's discretion; here it stays distinct so nothing is lost.
  public enum Status: String, Hashable, Sendable, Codable {
    case investigating
    case identified
    case monitoring
    case resolved
    case postmortem
    case unknown

    init(wire: String?) {
      self = wire.flatMap(Status.init(rawValue:)) ?? .unknown
    }
  }

  public let id: String
  public let name: String
  public let status: Status
  public let updatedAt: Date?
  /// Body of the most recent incident update — Cloudflare's own English prose,
  /// rendered verbatim (free text can be neither localized nor branched on).
  public let latestUpdate: String?

  public init(
    id: String, name: String, status: Status, updatedAt: Date? = nil,
    latestUpdate: String? = nil
  ) {
    self.id = id
    self.name = name
    self.status = status
    self.updatedAt = updatedAt
    self.latestUpdate = latestUpdate
  }
}

public struct CloudflareStatusComponent: Hashable, Sendable, Codable, Identifiable {
  public enum Status: String, Hashable, Sendable, Codable {
    case operational
    case degradedPerformance = "degraded_performance"
    case partialOutage = "partial_outage"
    case majorOutage = "major_outage"
    case underMaintenance = "under_maintenance"
    case unknown

    init(wire: String?) {
      self = wire.flatMap(Status.init(rawValue:)) ?? .unknown
    }
  }

  public let id: String
  public let name: String
  public let status: Status

  public init(id: String, name: String, status: Status) {
    self.id = id
    self.name = name
    self.status = status
  }
}

public struct CloudflareStatusMaintenance: Hashable, Sendable, Codable, Identifiable {
  public enum Status: String, Hashable, Sendable, Codable {
    case scheduled
    case inProgress = "in_progress"
    case verifying
    case completed
    case unknown

    init(wire: String?) {
      self = wire.flatMap(Status.init(rawValue:)) ?? .unknown
    }
  }

  public let id: String
  public let name: String
  public let status: Status

  public init(id: String, name: String, status: Status) {
    self.id = id
    self.name = name
    self.status = status
  }
}

public enum CloudflareStatusClient: Sendable {
  public enum FetchError: Error, Sendable {
    case httpStatus(Int)
    case invalidResponse
  }

  public static let summaryURL = URL(
    string: "https://www.cloudflarestatus.com/api/v2/summary.json")!

  /// Statuspage object id of the "Cloudflare Sites and Services" component
  /// group — the product-level components, as opposed to the region groups
  /// holding one entry per colo. Object ids are stable on Statuspage (this one
  /// dates to 2014), so it is a wire contract the same way an API path is. If
  /// the group ever disappears, `serviceComponents` degrades to empty and the
  /// UI keeps the indicator and incidents, which are the headline anyway —
  /// never fall back to the full component list, which is colo noise.
  static let serviceComponentGroupID = "1km35smx8p41"

  public static func summary(
    session: URLSession = .shared
  ) async throws -> CloudflareStatusSummary {
    var request = URLRequest(url: summaryURL)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw FetchError.invalidResponse
    }
    guard (200..<300).contains(http.statusCode) else {
      throw FetchError.httpStatus(http.statusCode)
    }
    return try parse(data)
  }

  static func parse(_ data: Data) throws -> CloudflareStatusSummary {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    decoder.dateDecodingStrategy = .custom { decoder in
      let value = try decoder.singleValueContainer().decode(String.self)
      guard let date = parseDate(value) else {
        throw DecodingError.dataCorrupted(
          DecodingError.Context(
            codingPath: decoder.codingPath,
            debugDescription: "Unrecognized Statuspage date: \(value)"))
      }
      return date
    }
    let raw = try decoder.decode(RawSummary.self, from: data)

    let serviceIDs =
      raw.components?
      .first { $0.group == true && $0.id == serviceComponentGroupID }?
      .components ?? []
    // Preserve the payload's order — Statuspage sorts components by their
    // configured position, which is alphabetical for this group.
    let serviceComponents = (raw.components ?? [])
      .filter { $0.group != true && serviceIDs.contains($0.id) }
      .map {
        CloudflareStatusComponent(
          id: $0.id, name: $0.name, status: .init(wire: $0.status))
      }

    let incidents = (raw.incidents ?? []).map { incident in
      CloudflareStatusIncident(
        id: incident.id,
        name: incident.name,
        status: .init(wire: incident.status),
        updatedAt: incident.updatedAt,
        // Statuspage returns updates newest-first.
        latestUpdate: incident.incidentUpdates?.first?.body)
    }

    let maintenances = (raw.scheduledMaintenances ?? [])
      .map {
        CloudflareStatusMaintenance(
          id: $0.id, name: $0.name, status: .init(wire: $0.status))
      }
      .filter { $0.status == .inProgress || $0.status == .verifying }

    return CloudflareStatusSummary(
      indicator: .init(wire: raw.status.indicator),
      incidents: incidents,
      serviceComponents: serviceComponents,
      activeMaintenances: maintenances)
  }

  /// Statuspage emits fractional-second ISO 8601 (`2026-08-04T08:28:59.415Z`);
  /// accept the plain form too so a formatting change upstream cannot take the
  /// whole payload down over a timestamp.
  private static func parseDate(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: value)
  }
}

/// Wire shapes for `summary.json`. Every field the UI does not consume is
/// omitted; unknown enum values are mapped, not thrown, so a Statuspage
/// vocabulary addition cannot break the fetch.
private struct RawSummary: Decodable {
  struct Status: Decodable {
    let indicator: String?
  }

  struct Component: Decodable {
    let id: String
    let name: String
    let status: String?
    let group: Bool?
    /// Ids of the group's members — present on group entries only.
    let components: [String]?
  }

  struct IncidentUpdate: Decodable {
    let body: String?
  }

  struct Incident: Decodable {
    let id: String
    let name: String
    let status: String?
    let updatedAt: Date?
    let incidentUpdates: [IncidentUpdate]?
  }

  struct Maintenance: Decodable {
    let id: String
    let name: String
    let status: String?
  }

  let status: Status
  let components: [Component]?
  let incidents: [Incident]?
  let scheduledMaintenances: [Maintenance]?
}
