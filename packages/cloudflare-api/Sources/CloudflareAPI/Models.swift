import Foundation

public enum JSONValue: Codable, Hashable, Sendable {
  case array([JSONValue])
  case bool(Bool)
  case null
  case number(Double)
  case object([String: JSONValue])
  case string(String)

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .array(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .null: try container.encodeNil()
    case .number(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    }
  }
}

public struct APIErrorItem: Codable, Error, Hashable, Sendable {
  public let code: Int
  public let message: String
}

public enum CloudflareAPIError: Error, LocalizedError, Sendable {
  case invalidResponse
  case oauth(String)
  case request(status: Int, errors: [APIErrorItem])
  case transport(String)

  public var errorDescription: String? {
    switch self {
    case .invalidResponse: "Cloudflare returned an invalid response."
    case .oauth(let message), .transport(let message): message
    case .request(let status, let errors): errors.first?.message ?? "HTTP \(status)"
    }
  }

  public var isUnauthorized: Bool {
    if case .request(let status, _) = self { return status == 401 }
    return false
  }

  public var isForbidden: Bool {
    if case .request(let status, _) = self { return status == 403 }
    return false
  }

  public var isPermissionDenied: Bool {
    if case .request(let status, _) = self { return status == 403 }
    return false
  }
}

public struct ResultInfo: Codable, Hashable, Sendable {
  public let page: Int?
  public let perPage: Int?
  public let totalCount: Int?
  public let cursor: String?

  enum CodingKeys: String, CodingKey {
    case page, cursor
    case perPage = "per_page"
    case totalCount = "total_count"
  }
}

public struct Page<Value: Sendable>: Sendable {
  public let items: [Value]
  public let resultInfo: ResultInfo?

  public init(items: [Value], resultInfo: ResultInfo? = nil) {
    self.items = items
    self.resultInfo = resultInfo
  }
}

public struct CursorPage<Value: Sendable>: Sendable {
  public let items: [Value]
  public let cursor: String?

  public init(items: [Value], cursor: String?) {
    self.items = items
    self.cursor = cursor
  }
}

struct APIEnvelope<Value: Decodable & Sendable>: Decodable, Sendable {
  let success: Bool
  let result: Value
  let errors: [APIErrorItem]?
  let resultInfo: ResultInfo?

  enum CodingKeys: String, CodingKey {
    case success, result, errors
    case resultInfo = "result_info"
  }
}

public struct TokenSet: Codable, Hashable, Sendable {
  public let accessToken: String
  public let expiresIn: Int?
  public let refreshToken: String?
  public let scope: String?
  public let tokenType: String?

  public init(
    accessToken: String, expiresIn: Int? = nil, refreshToken: String? = nil, scope: String? = nil,
    tokenType: String? = nil
  ) {
    self.accessToken = accessToken
    self.expiresIn = expiresIn
    self.refreshToken = refreshToken
    self.scope = scope
    self.tokenType = tokenType
  }

  enum CodingKeys: String, CodingKey {
    case scope
    case accessToken = "access_token"
    case expiresIn = "expires_in"
    case refreshToken = "refresh_token"
    case tokenType = "token_type"
  }
}

public protocol TokenStore: Sendable {
  func clear() async throws
  func getAccessToken() async throws -> String?
  func getRefreshToken() async throws -> String?
  func getGrantedScopes() async throws -> Set<String>?
  func setGrantedScopes(_ scopes: Set<String>) async throws
  func setTokens(_ tokens: TokenSet) async throws
}

extension TokenStore {
  public func getGrantedScopes() async throws -> Set<String>? { nil }
  public func setGrantedScopes(_: Set<String>) async throws {}
}

public protocol CloudflareResource: Codable, Identifiable, Sendable where ID == String {
  var id: String { get }
  var name: String { get }
}

public struct CloudflareUser: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let email: String?
  public let firstName: String?
  public let lastName: String?
  public let createdOn: String?

  /// The person's actual name, or nil when Cloudflare has none on file —
  /// letting callers pick their own fallback instead of repeating the email.
  public var fullName: String? {
    [firstName, lastName].compactMap { $0 }.joined(separator: " ").nilIfEmpty
  }

  public var displayName: String {
    fullName ?? email ?? "User"
  }

  enum CodingKeys: String, CodingKey {
    case id, email
    case firstName = "first_name"
    case lastName = "last_name"
    case createdOn = "created_on"
  }
}

public struct CloudflareAccount: CloudflareResource, Hashable {
  public let id: String
  public let name: String
  public let type: String?
  public let createdOn: String?

  enum CodingKeys: String, CodingKey {
    case id, name, type
    case createdOn = "created_on"
  }
}

public struct Ruleset: CloudflareResource, Hashable {
  public let id: String
  public let name: String
  public let kind: String?
  public let phase: String?
  public let description: String?
}

public struct RulesetRule: Codable, Identifiable, Hashable, Sendable {
  public let id: String
  public let action: String?
  public let expression: String?
  public let description: String?
  public let enabled: Bool?
  public let ref: String?
}

public struct RulesetDetail: Codable, Hashable, Sendable {
  public let id: String
  public let name: String
  public let kind: String?
  public let phase: String?
  public let description: String?
  public let rules: [RulesetRule]?
}

public struct AccessApp: CloudflareResource, Hashable {
  public let id: String
  public let name: String
  public let domain: String?
  public let type: String?
}

public struct AccessPolicy: Codable, Identifiable, Hashable, Sendable {
  public let id: String
  public let name: String
  public let decision: String?
  /// The include rule union stays untyped; the app only builds a few shapes.
  public let include: [JSONValue]?
  public let reusable: Bool?
}

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

public struct ZoneAnalyticsDay: Codable, Hashable, Sendable {
  public let date: String
  public let requests: Int
  public let pageViews: Int
  public let threats: Int
  public let bytes: Int64
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
  public let comment: String?

  enum CodingKeys: String, CodingKey {
    case id, type, name, content, proxied, ttl, priority, comment
    case zoneID = "zone_id"
  }
}

public struct DNSRecordInput: Codable, Hashable, Sendable {
  public var type: String
  public var name: String
  public var content: String
  public var proxied: Bool?
  public var ttl: Int
  public var priority: Int?
  public var comment: String?

  public init(
    type: String, name: String, content: String, proxied: Bool? = nil, ttl: Int = 1,
    priority: Int? = nil, comment: String? = nil
  ) {
    self.type = type
    self.name = name
    self.content = content
    self.proxied = proxied
    self.ttl = ttl
    self.priority = priority
    self.comment = comment
  }
}

public struct WorkerScript: CloudflareResource, Hashable {
  public let id: String
  public var name: String { id }
  /// Immutable script tag — the `external_script_id` the Builds APIs key on.
  public let tag: String?
  public let modifiedOn: String?
  public let createdOn: String?

  enum CodingKeys: String, CodingKey {
    case id, tag
    case modifiedOn = "modified_on"
    case createdOn = "created_on"
  }
}

public struct WorkerSubdomainStatus: Codable, Hashable, Sendable {
  public let enabled: Bool
  public let previewsEnabled: Bool?

  enum CodingKeys: String, CodingKey {
    case enabled
    case previewsEnabled = "previews_enabled"
  }
}

/// Worker deployments arrive wrapped in an object, not as a bare result array.
public struct WorkerDeploymentsResult: Codable, Sendable {
  public let deployments: [GenericResource]
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
}

public struct PagesProject: CloudflareResource, Hashable {
  public let id: String
  public let name: String
  public let subdomain: String?
  public let createdOn: String?
  public let latestDeployment: PagesDeploymentSummary?

  enum CodingKeys: String, CodingKey {
    case id, name, subdomain
    case createdOn = "created_on"
    case latestDeployment = "latest_deployment"
  }
}

public struct PagesDeploymentSummary: Codable, Hashable, Sendable {
  public let latestStage: PagesDeploymentStage?

  enum CodingKeys: String, CodingKey {
    case latestStage = "latest_stage"
  }
}

public struct PagesDeploymentStage: Codable, Hashable, Sendable {
  public let status: String?
}

public struct R2Bucket: CloudflareResource, Hashable {
  public var id: String { name }
  public let name: String
  public let creationDate: String?

  enum CodingKeys: String, CodingKey {
    case name
    case creationDate = "creation_date"
  }
}

public struct R2Object: Codable, Hashable, Identifiable, Sendable {
  public var id: String { key }
  public let key: String
  public let size: Int?
  public let etag: String?
  public let uploaded: String?
}

public struct KVNamespace: CloudflareResource, Hashable {
  public let id: String
  public let title: String
  public var name: String { title }
}

public struct KVKey: Codable, Hashable, Identifiable, Sendable {
  public var id: String { name }
  public let name: String
  public let expiration: Int?
  public let metadata: JSONValue?
}

public struct D1Database: CloudflareResource, Hashable {
  public let uuid: String
  public let name: String
  public let version: String?
  public let numTables: Int?
  public let fileSize: Int?
  public var id: String { uuid }

  enum CodingKeys: String, CodingKey {
    case uuid, name, version
    case numTables = "num_tables"
    case fileSize = "file_size"
  }
}

public struct D1QueryResult: Codable, Hashable, Sendable {
  public let results: [[String: JSONValue]]?
  public let success: Bool?
  public let meta: [String: JSONValue]?
}

public struct CloudflareImage: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let filename: String?
  public let uploaded: String?
  public let requireSignedURLs: Bool?

  public var name: String { filename ?? id }
}

public struct StreamVideo: Codable, Hashable, Identifiable, Sendable {
  public let uid: String
  public let created: String?
  public let meta: StreamVideoMeta?

  public var id: String { uid }
  public var name: String { meta?.name ?? uid }
}

public struct StreamVideoMeta: Codable, Hashable, Sendable {
  public let name: String?
}

public struct AccountMember: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let user: AccountMemberUser?
  public let roles: [AccountMemberRole]?

  public var displayName: String {
    let parts = [user?.firstName, user?.lastName].compactMap { $0 }.filter { !$0.isEmpty }
    let full = parts.joined(separator: " ")
    return full.nilIfEmpty ?? user?.email ?? "Member"
  }

  public var roleSummary: String? {
    roles?.compactMap(\.name).joined(separator: ", ").nilIfEmpty
  }
}

public struct AccountMemberUser: Codable, Hashable, Sendable {
  public let email: String?
  public let firstName: String?
  public let lastName: String?

  enum CodingKeys: String, CodingKey {
    case email
    case firstName = "first_name"
    case lastName = "last_name"
  }
}

public struct AccountMemberRole: Codable, Hashable, Sendable {
  public let id: String?
  public let name: String?
}

public struct AccountRole: CloudflareResource, Hashable {
  public let id: String
  public let name: String
  public let description: String?
}

public struct RumSite: Codable, Hashable, Identifiable, Sendable {
  public let siteTag: String?
  public let host: String?

  public var id: String { siteTag ?? host ?? UUID().uuidString }
  public var name: String { host ?? siteTag ?? "Site" }

  enum CodingKeys: String, CodingKey {
    case host
    case siteTag = "site_tag"
  }
}

public struct NotificationPolicy: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let name: String?
  public let alertType: String?
  public let enabled: Bool?

  public var title: String {
    name ?? alertType?.replacingOccurrences(of: "_", with: " ") ?? id
  }

  enum CodingKeys: String, CodingKey {
    case id, name, enabled
    case alertType = "alert_type"
  }
}

public struct NotificationHistoryEntry: Codable, Hashable, Identifiable, Sendable {
  public let policyID: String?
  public let name: String?
  public let alertType: String?
  public let mechanism: String?
  public let alertBody: String?
  public let description: String?
  public let sent: String?

  public var id: String {
    [policyID, sent, name, alertType].compactMap { $0 }.joined(separator: "|").nilIfEmpty
      ?? UUID().uuidString
  }
  public var title: String {
    name ?? alertType?.replacingOccurrences(of: "_", with: " ") ?? "Notification"
  }
  public var subtitle: String? { alertBody ?? mechanism ?? description }

  enum CodingKeys: String, CodingKey {
    case name, mechanism, description, sent
    case policyID = "policy_id"
    case alertType = "alert_type"
    case alertBody = "alert_body"
  }
}

public struct AuditLogEntry: Codable, Hashable, Sendable {
  public let logID: String?
  public let action: AuditLogAction?
  public let actor: AuditLogActor?
  public let resource: AuditLogResource?

  public var title: String { action?.type ?? "Action" }
  public var subtitle: String? {
    [actor?.email ?? actor?.type, resource?.type].compactMap { $0 }.joined(separator: " · ")
      .nilIfEmpty
  }

  enum CodingKeys: String, CodingKey {
    case logID = "id"
    case action, actor, resource
  }
}

extension AuditLogEntry: Identifiable {
  public var id: String {
    logID ?? [title, subtitle].compactMap { $0 }.joined(separator: "|")
  }
}

public struct AuditLogAction: Codable, Hashable, Sendable {
  public let type: String?
}

public struct AuditLogActor: Codable, Hashable, Sendable {
  public let email: String?
  public let type: String?
}

public struct AuditLogResource: Codable, Hashable, Sendable {
  public let type: String?
}

public struct CloudflareTunnel: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let name: String?
  public let status: String?
}

public struct LoadBalancerPool: CloudflareResource, Hashable {
  public let id: String
  public let name: String
  public let enabled: Bool?
}

public struct RegistrarDomain: CloudflareResource, Hashable {
  public let id: String
  public let name: String
  public let expiresAt: String?

  enum CodingKeys: String, CodingKey {
    case id, name
    case expiresAt = "expires_at"
  }
}

public struct CertificatePack: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let status: String
  public let certificates: [CertificatePackCertificate]?

  enum CodingKeys: String, CodingKey {
    case id, status, certificates
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
    status = try container.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
    certificates = try container.decodeIfPresent(
      [CertificatePackCertificate].self, forKey: .certificates)
  }
}

public struct CertificatePackCertificate: Codable, Hashable, Sendable {
  public let expiresOn: String?

  enum CodingKeys: String, CodingKey {
    case expiresOn = "expires_on"
  }
}

public struct Healthcheck: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let name: String?
  public let status: String?

  enum CodingKeys: String, CodingKey {
    case id, name, status
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
    name = try container.decodeIfPresent(String.self, forKey: .name)
    status = try container.decodeIfPresent(String.self, forKey: .status)
  }
}

public struct GenericResource: CloudflareResource, Hashable {
  public let id: String
  public let name: String
  public let detail: String?
  public let raw: [String: JSONValue]

  public init(from decoder: any Decoder) throws {
    let raw = try [String: JSONValue](from: decoder)
    self.raw = raw
    id =
      raw.string(for: [
        "id", "uuid", "build_uuid", "tag", "sitekey", "key", "queue_id", "snippet_name", "slug",
        "name",
      ])
      ?? UUID().uuidString
    name =
      raw.string(for: [
        "name", "title", "hostname", "email", "pattern", "queue_name", "snippet_name", "url",
        "network", "slug", "id", "uuid", "branch", "build_uuid",
      ])
      ?? "Cloudflare resource"
    detail = raw.string(for: ["status", "type", "state", "description"])
  }

  public func encode(to encoder: any Encoder) throws { try raw.encode(to: encoder) }
}

extension Dictionary where Key == String, Value == JSONValue {
  func string(for keys: [String]) -> String? {
    for key in keys {
      if case .string(let value)? = self[key] { return value }
      if case .number(let value)? = self[key] {
        // Integral ids (e.g. Logpush job ids) must not render as "123.0" —
        // they feed straight into request paths.
        return value.rounded() == value ? String(Int64(value)) : String(value)
      }
    }
    return nil
  }
}

extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}
