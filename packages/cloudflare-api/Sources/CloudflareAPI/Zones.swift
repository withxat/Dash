import Foundation

public struct CloudflareZone: CloudflareResource, Hashable {
  public let id: String
  public let name: String
  public let status: String?
  public let paused: Bool?
  public let developmentMode: Int?
  public let nameServers: [String]?
  public let plan: ZonePlan?

  enum CodingKeys: String, CodingKey {
    case id, name, status, paused, plan
    case developmentMode = "development_mode"
    case nameServers = "name_servers"
  }
}

public struct ZonePlan: Codable, Hashable, Sendable {
  public let id: String?
  public let name: String?
  public let legacyId: String?

  enum CodingKeys: String, CodingKey {
    case id, name
    case legacyId = "legacy_id"
  }
}

/// Structured payload used by SRV and CAA records. Cloudflare still echoes a
/// derived `content` string on read, but create/update for these types must
/// send the type-specific fields under `data` rather than free-text content.
public struct DNSRecordData: Codable, Hashable, Sendable {
  // SRV
  public var priority: Int?
  public var weight: Int?
  public var port: Int?
  public var target: String?
  // CAA
  public var flags: Int?
  public var tag: String?
  public var value: String?

  public init(
    priority: Int? = nil, weight: Int? = nil, port: Int? = nil, target: String? = nil,
    flags: Int? = nil, tag: String? = nil, value: String? = nil
  ) {
    self.priority = priority
    self.weight = weight
    self.port = port
    self.target = target
    self.flags = flags
    self.tag = tag
    self.value = value
  }
}

public struct DNSRecord: CloudflareResource, Hashable {
  public let id: String
  public let zoneID: String?
  public let type: String
  public let name: String
  public let content: String
  public let proxied: Bool?
  public let ttl: Int
  public let priority: Int?
  public let data: DNSRecordData?
  public let comment: String?

  enum CodingKeys: String, CodingKey {
    case id, type, name, content, proxied, ttl, priority, data, comment
    case zoneID = "zone_id"
  }
}

public struct DNSRecordInput: Codable, Hashable, Sendable {
  public var type: String
  public var name: String
  /// Free-text value for A/AAAA/CNAME/TXT/MX/…. Omit for SRV — send `data` instead.
  public var content: String?
  public var proxied: Bool?
  public var ttl: Int
  public var priority: Int?
  public var data: DNSRecordData?
  public var comment: String?

  public init(
    type: String, name: String, content: String? = nil, proxied: Bool? = nil, ttl: Int = 1,
    priority: Int? = nil, data: DNSRecordData? = nil, comment: String? = nil
  ) {
    self.type = type
    self.name = name
    self.content = content
    self.proxied = proxied
    self.ttl = ttl
    self.priority = priority
    self.data = data
    self.comment = comment
  }
}

public struct ZoneSetting: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let value: JSONValue
  public let editable: Bool?
  public let modifiedOn: String?

  enum CodingKeys: String, CodingKey {
    case id, value, editable
    case modifiedOn = "modified_on"
  }

  public init(
    id: String, value: JSONValue, editable: Bool? = nil, modifiedOn: String? = nil
  ) {
    self.id = id
    self.value = value
    self.editable = editable
    self.modifiedOn = modifiedOn
  }

  /// Copy with a new value — used for optimistic zone-setting toggles/menus.
  public func withValue(_ value: JSONValue) -> ZoneSetting {
    ZoneSetting(id: id, value: value, editable: editable, modifiedOn: modifiedOn)
  }
}

extension CloudflareClient {
  public func listZones(accountID: String, page: Int = 1, perPage: Int = 50, name: String? = nil)
    async throws -> Page<CloudflareZone>
  {
    try await list(
      "/zones",
      query: [
        "account.id": accountID, "page": String(page), "per_page": String(perPage), "name": name,
      ])
  }
  public func getZone(_ id: String) async throws -> CloudflareZone {
    try await request("/zones/\(id)")
  }
  /// Adds a domain to the account. The created zone carries the assigned
  /// `nameServers`, which the caller must surface — the domain stays pending
  /// until the registrar points at them.
  public func createZone(name: String, accountID: String) async throws -> CloudflareZone {
    let body: [String: JSONValue] = [
      "name": .string(name),
      "account": .object(["id": .string(accountID)]),
    ]
    return try await request("/zones", method: "POST", body: body)
  }
  /// Asks Cloudflare to re-check the zone's name servers now instead of on the
  /// hourly sweep. Cloudflare rate-limits the trigger per zone; the 400 carries
  /// the wait message, so it surfaces unchanged.
  public func triggerZoneActivationCheck(zoneID: String) async throws {
    let _: JSONValue = try await request("/zones/\(zoneID)/activation_check", method: "PUT")
  }
  /// Removes the zone from the account. Used to abandon an unfinished setup
  /// (`pending` / `initializing` / `moved`); Dash does not expose this for
  /// active domains.
  public func deleteZone(zoneID: String) async throws {
    let _: JSONValue = try await request("/zones/\(zoneID)", method: "DELETE")
  }
  public func listDNSRecords(
    zoneID: String, page: Int = 1, perPage: Int = 100, search: String? = nil, type: String? = nil
  ) async throws -> Page<DNSRecord> {
    try await list(
      "/zones/\(zoneID)/dns_records",
      query: [
        "page": String(page),
        "per_page": String(perPage),
        "search": search.flatMap { $0.isEmpty ? nil : $0 },
        "type": type.flatMap { $0.isEmpty ? nil : $0 },
      ])
  }
  public func getDNSRecord(zoneID: String, recordID: String) async throws -> DNSRecord {
    try await request("/zones/\(zoneID)/dns_records/\(recordID)")
  }
  public func createDNSRecord(zoneID: String, input: DNSRecordInput) async throws -> DNSRecord {
    try await request("/zones/\(zoneID)/dns_records", method: "POST", body: input)
  }
  public func updateDNSRecord(zoneID: String, recordID: String, input: DNSRecordInput) async throws
    -> DNSRecord
  {
    try await request("/zones/\(zoneID)/dns_records/\(recordID)", method: "PUT", body: input)
  }
  public func deleteDNSRecord(zoneID: String, recordID: String) async throws {
    let _: JSONValue = try await request(
      "/zones/\(zoneID)/dns_records/\(recordID)", method: "DELETE")
  }
  public func listZoneSettings(zoneID: String) async throws -> [ZoneSetting] {
    try await list("/zones/\(zoneID)/settings").items
  }
  public func updateZoneSetting(zoneID: String, settingID: String, value: JSONValue) async throws
    -> ZoneSetting
  {
    try await request(
      "/zones/\(zoneID)/settings/\(settingID)", method: "PATCH", body: ["value": value])
  }
}
