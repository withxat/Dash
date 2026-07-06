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
  func setTokens(_ tokens: TokenSet) async throws
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

  public var displayName: String {
    [firstName, lastName].compactMap { $0 }.joined(separator: " ").nilIfEmpty ?? email ?? "User"
  }

  enum CodingKeys: String, CodingKey {
    case id, email
    case firstName = "first_name"
    case lastName = "last_name"
  }
}

public struct CloudflareAccount: CloudflareResource, Hashable {
  public let id: String
  public let name: String
  public let type: String?
}

public struct CloudflareZone: CloudflareResource, Hashable {
  public let id: String
  public let name: String
  public let status: String?
  public let paused: Bool?
  public let developmentMode: Int?
  public let nameServers: [String]?

  enum CodingKeys: String, CodingKey {
    case id, name, status, paused
    case developmentMode = "development_mode"
    case nameServers = "name_servers"
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
  public let modifiedOn: String?
  public let createdOn: String?

  enum CodingKeys: String, CodingKey {
    case id
    case modifiedOn = "modified_on"
    case createdOn = "created_on"
  }
}

public struct PagesProject: CloudflareResource, Hashable {
  public let id: String
  public let name: String
  public let subdomain: String?
  public let createdOn: String?

  enum CodingKeys: String, CodingKey {
    case id, name, subdomain
    case createdOn = "created_on"
  }
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

public struct GenericResource: CloudflareResource, Hashable {
  public let id: String
  public let name: String
  public let detail: String?
  public let raw: [String: JSONValue]

  public init(from decoder: any Decoder) throws {
    let raw = try [String: JSONValue](from: decoder)
    self.raw = raw
    id =
      raw.string(for: ["id", "uuid", "tag", "sitekey", "key", "name"])
      ?? UUID().uuidString
    name =
      raw.string(for: ["name", "title", "hostname", "email", "id", "uuid"])
      ?? "Cloudflare resource"
    detail = raw.string(for: ["status", "type", "state", "description"])
  }

  public func encode(to encoder: any Encoder) throws { try raw.encode(to: encoder) }
}

extension Dictionary where Key == String, Value == JSONValue {
  func string(for keys: [String]) -> String? {
    for key in keys {
      if case .string(let value)? = self[key] { return value }
      if case .number(let value)? = self[key] { return String(value) }
    }
    return nil
  }
}

extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}
