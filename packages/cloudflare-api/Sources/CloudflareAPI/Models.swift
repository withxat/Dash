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

  public init(code: Int, message: String) {
    self.code = code
    self.message = message
  }
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

  /// One derivation for every status rule. `isForbidden` and
  /// `isPermissionDenied` used to be two independently written 403 checks —
  /// twins like that survive only until an edit moves one of them.
  public func hasStatus(_ status: Int) -> Bool {
    if case .request(let responseStatus, _) = self { return responseStatus == status }
    return false
  }

  public var isUnauthorized: Bool { hasStatus(401) }

  public var isForbidden: Bool { hasStatus(403) }

  /// Cloudflare answers a missing OAuth scope with 403, so a permission check
  /// and a forbidden check are the same question spelled two ways.
  public var isPermissionDenied: Bool { isForbidden }

  public var isNotFound: Bool { hasStatus(404) }

  public var isRateLimited: Bool { hasStatus(429) }

  public var isTransport: Bool {
    if case .transport = self { return true }
    return false
  }

  public var isInvalidGrant: Bool {
    if case .oauth(let message) = self { return message == "invalid_grant" }
    return false
  }
}

public struct ResultInfo: Codable, Hashable, Sendable {
  public let page: Int?
  public let perPage: Int?
  public let totalCount: Int?
  public let totalPages: Int?
  public let cursor: String?
  public let delimited: [String]?
  public let isTruncated: Bool?

  public init(
    page: Int? = nil, perPage: Int? = nil, totalCount: Int? = nil, totalPages: Int? = nil,
    cursor: String? = nil, delimited: [String]? = nil, isTruncated: Bool? = nil
  ) {
    self.page = page
    self.perPage = perPage
    self.totalCount = totalCount
    self.totalPages = totalPages
    self.cursor = cursor
    self.delimited = delimited
    self.isTruncated = isTruncated
  }

  enum CodingKeys: String, CodingKey {
    case page, cursor, delimited
    case perPage = "per_page"
    case totalCount = "total_count"
    case totalPages = "total_pages"
    case isTruncated = "is_truncated"
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

/// One bad array element becomes `nil` instead of failing the whole decode.
/// Used by `CloudflareClient.list` so a single malformed row cannot blank a screen.
struct LossyElement<Value: Decodable & Sendable>: Decodable, Sendable {
  let value: Value?

  init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    value = try? container.decode(Value.self)
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
  func replaceTokens(
    _ tokens: TokenSet,
    ifCurrentAccessToken expectedAccessToken: String?,
    refreshToken expectedRefreshToken: String?
  ) async throws -> Bool
  func clearTokens(
    ifCurrentAccessToken expectedAccessToken: String?,
    refreshToken expectedRefreshToken: String?
  ) async throws -> Bool
  /// Runs `body` while holding this credential's refresh lock.
  ///
  /// Cloudflare rotates the refresh token on use, so two *processes* that share
  /// one credential — the app, the share extension, a File Provider — must not
  /// both POST it. `CloudflareClient`'s single-flight is per client instance and
  /// cannot see another process at all; this is the seam that can.
  ///
  /// `isExclusive` reports whether exclusivity was actually obtained. A store
  /// that is not shared across processes always reports `true`: it is the only
  /// writer. A shared store reports `false` when it cannot prove exclusivity.
  /// The body must then fail closed without POSTing the rotating token; a
  /// compare-and-swap cannot repair the race if this caller consumes the token
  /// before the actual lock holder does.
  func withExclusiveRefreshAccess<T: Sendable>(
    _ body: @Sendable (_ isExclusive: Bool) async throws -> T
  ) async throws -> T
}

extension TokenStore {
  public func getGrantedScopes() async throws -> Set<String>? { nil }
  public func setGrantedScopes(_: Set<String>) async throws {}

  /// A store with no cross-process sharing needs no coordination: the caller is
  /// the only writer, so the body runs straight away and is exclusive by
  /// construction. Keeps every existing conformer — the demo store, the test
  /// doubles — source-compatible, and keeps this package dependency-free.
  public func withExclusiveRefreshAccess<T: Sendable>(
    _ body: @Sendable (_ isExclusive: Bool) async throws -> T
  ) async throws -> T {
    try await body(true)
  }

  /// Stores that cannot provide an atomic compare-and-swap still get a
  /// fail-closed default. Credential stores used by the app override this so
  /// an OAuth replacement cannot race an already-started refresh.
  public func replaceTokens(
    _ tokens: TokenSet,
    ifCurrentAccessToken expectedAccessToken: String?,
    refreshToken expectedRefreshToken: String?
  ) async throws -> Bool {
    guard
      try await getAccessToken() == expectedAccessToken,
      try await getRefreshToken() == expectedRefreshToken
    else {
      return false
    }
    try await setTokens(tokens)
    return true
  }

  public func clearTokens(
    ifCurrentAccessToken expectedAccessToken: String?,
    refreshToken expectedRefreshToken: String?
  ) async throws -> Bool {
    guard
      try await getAccessToken() == expectedAccessToken,
      try await getRefreshToken() == expectedRefreshToken
    else {
      return false
    }
    try await clear()
    return true
  }
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

extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}
