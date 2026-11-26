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

  public init(
    id: String,
    zoneID: String? = nil,
    type: String,
    name: String,
    content: String,
    proxied: Bool? = nil,
    ttl: Int = 1,
    priority: Int? = nil,
    data: DNSRecordData? = nil,
    comment: String? = nil
  ) {
    self.id = id
    self.zoneID = zoneID
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

/// Enforcement action for a Zone IP Access Rule.
public enum IPAccessRuleMode: String, Codable, Hashable, CaseIterable, Sendable {
  case block
  case managedChallenge = "managed_challenge"
  case challenge
  case jsChallenge = "js_challenge"
  case whitelist
}

/// Match target for a Zone IP Access Rule.
public enum IPAccessRuleTarget: String, Codable, Hashable, CaseIterable, Sendable {
  case ip
  case ip6
  case ipRange = "ip_range"
  case asn
  case country
}

public struct IPAccessRuleConfiguration: Codable, Hashable, Sendable {
  public let target: String
  public let value: String

  public init(target: String, value: String) {
    self.target = target
    self.value = value
  }
}

public struct IPAccessRuleScope: Codable, Hashable, Sendable {
  public let id: String?
  public let type: String?
  public let email: String?

  public init(id: String? = nil, type: String? = nil, email: String? = nil) {
    self.id = id
    self.type = type
    self.email = email
  }
}

/// One IP Access Rule returned by `/zones/{zone_id}/firewall/access_rules/rules`.
public struct IPAccessRule: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let mode: String
  public let notes: String?
  public let configuration: IPAccessRuleConfiguration
  public let scope: IPAccessRuleScope?
  public let createdOn: String?
  public let modifiedOn: String?

  enum CodingKeys: String, CodingKey {
    case id, mode, notes, configuration, scope
    case createdOn = "created_on"
    case modifiedOn = "modified_on"
  }

  public init(
    id: String,
    mode: String,
    notes: String? = nil,
    configuration: IPAccessRuleConfiguration,
    scope: IPAccessRuleScope? = nil,
    createdOn: String? = nil,
    modifiedOn: String? = nil
  ) {
    self.id = id
    self.mode = mode
    self.notes = notes
    self.configuration = configuration
    self.scope = scope
    self.createdOn = createdOn
    self.modifiedOn = modifiedOn
  }
}

public struct IPAccessRuleInput: Encodable, Hashable, Sendable {
  public let mode: IPAccessRuleMode
  public let target: IPAccessRuleTarget
  public let value: String
  public let notes: String?

  public init(
    mode: IPAccessRuleMode,
    target: IPAccessRuleTarget,
    value: String,
    notes: String? = nil
  ) {
    self.mode = mode
    self.target = target
    self.value = value
    self.notes = notes
  }

  private enum CodingKeys: String, CodingKey {
    case mode, configuration, notes
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(mode.rawValue, forKey: .mode)
    try container.encode(
      IPAccessRuleConfiguration(target: target.rawValue, value: value), forKey: .configuration)
    if let notes = notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
      try container.encode(notes, forKey: .notes)
    }
  }
}

/// One X.509 certificate inside a Cloudflare SSL/TLS Edge Certificate Pack.
public struct SSLCertificate: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let hosts: [String]
  public let status: String?
  public let issuer: String?
  public let signature: String?
  public let expiresOn: String?
  public let uploadedOn: String?

  enum CodingKeys: String, CodingKey {
    case id, hosts, status, issuer, signature
    case expiresOn = "expires_on"
    case uploadedOn = "uploaded_on"
  }

  public init(
    id: String,
    hosts: [String] = [],
    status: String? = nil,
    issuer: String? = nil,
    signature: String? = nil,
    expiresOn: String? = nil,
    uploadedOn: String? = nil
  ) {
    self.id = id
    self.hosts = hosts
    self.status = status
    self.issuer = issuer
    self.signature = signature
    self.expiresOn = expiresOn
    self.uploadedOn = uploadedOn
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    hosts = try container.decodeIfPresent([String].self, forKey: .hosts) ?? []
    status = try container.decodeIfPresent(String.self, forKey: .status)
    issuer = try container.decodeIfPresent(String.self, forKey: .issuer)
    signature = try container.decodeIfPresent(String.self, forKey: .signature)
    expiresOn = try container.decodeIfPresent(String.self, forKey: .expiresOn)
    uploadedOn = try container.decodeIfPresent(String.self, forKey: .uploadedOn)
  }
}

/// An Edge Certificate Pack returned by `GET /zones/{zone_id}/ssl/certificate_packs`.
public struct SSLCertificatePack: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let type: String
  public let status: String
  public let hosts: [String]
  public let certificateAuthority: String?
  public let validationMethod: String?
  public let validityDays: Int?
  public let certificates: [SSLCertificate]

  enum CodingKeys: String, CodingKey {
    case id, type, status, hosts, certificates
    case certificateAuthority = "certificate_authority"
    case validationMethod = "validation_method"
    case validityDays = "validity_days"
  }

  public init(
    id: String,
    type: String,
    status: String,
    hosts: [String] = [],
    certificateAuthority: String? = nil,
    validationMethod: String? = nil,
    validityDays: Int? = nil,
    certificates: [SSLCertificate] = []
  ) {
    self.id = id
    self.type = type
    self.status = status
    self.hosts = hosts
    self.certificateAuthority = certificateAuthority
    self.validationMethod = validationMethod
    self.validityDays = validityDays
    self.certificates = certificates
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    type = try container.decodeIfPresent(String.self, forKey: .type) ?? "universal"
    status = try container.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
    hosts = try container.decodeIfPresent([String].self, forKey: .hosts) ?? []
    certificateAuthority = try container.decodeIfPresent(
      String.self, forKey: .certificateAuthority)
    validationMethod = try container.decodeIfPresent(String.self, forKey: .validationMethod)
    validityDays = try container.decodeIfPresent(Int.self, forKey: .validityDays)
    certificates = try container.decodeIfPresent([SSLCertificate].self, forKey: .certificates) ?? []
  }

  /// Earliest expiration timestamp reported across certificates in this pack.
  public var earliestExpiration: String? {
    certificates.compactMap(\.expiresOn).filter { !$0.isEmpty }.min()
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
  /// `files == nil` purges everything; otherwise only the listed URLs.
  public func purgeCache(zoneID: String, files: [String]? = nil) async throws {
    let body: [String: JSONValue] =
      files.map { ["files": .array($0.map(JSONValue.string))] } ?? ["purge_everything": .bool(true)]
    let _: JSONValue = try await request("/zones/\(zoneID)/purge_cache", method: "POST", body: body)
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

  /// Lists Zone IP Access Rules (`firewall-services.read`).
  public func listIPAccessRules(zoneID: String, page: Int = 1, perPage: Int = 50) async throws
    -> Page<IPAccessRule>
  {
    try await list(
      "/zones/\(zoneID)/firewall/access_rules/rules",
      query: ["page": String(page), "per_page": String(perPage)])
  }

  /// Creates a Zone IP Access Rule (`firewall-services.write`).
  public func createIPAccessRule(zoneID: String, input: IPAccessRuleInput) async throws
    -> IPAccessRule
  {
    try await request(
      "/zones/\(zoneID)/firewall/access_rules/rules", method: "POST", body: input)
  }

  /// Deletes a Zone IP Access Rule (`firewall-services.write`).
  public func deleteIPAccessRule(zoneID: String, ruleID: String) async throws {
    let _: JSONValue = try await request(
      "/zones/\(zoneID)/firewall/access_rules/rules/\(ruleID)", method: "DELETE")
  }

  /// Lists Edge Certificate Packs for a zone (`ssl-and-certificates.read`).
  /// Defaults to `status=all` so pending/validating packs are visible too.
  public func listCertificatePacks(zoneID: String, status: String? = "all") async throws
    -> [SSLCertificatePack]
  {
    try await list(
      "/zones/\(zoneID)/ssl/certificate_packs",
      query: ["status": status, "per_page": "50"]
    ).items
  }
}
