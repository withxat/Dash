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

  public var isRateLimited: Bool {
    if case .request(let status, _) = self { return status == 429 }
    return false
  }

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
}

extension TokenStore {
  public func getGrantedScopes() async throws -> Set<String>? { nil }
  public func setGrantedScopes(_: Set<String>) async throws {}

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

/// One hour bucket of HTTP request totals; `datetime` is an ISO 8601 instant.
public struct ZoneAnalyticsPoint: Codable, Hashable, Sendable {
  public let datetime: String
  public let requests: Int
  public let pageViews: Int
  public let threats: Int
  public let bytes: Int64
  /// Unique visitors in this bucket. Deduplicated per bucket only — summing
  /// across buckets double counts anyone who came back.
  public let uniques: Int
  public let cachedRequests: Int
  public let cachedBytes: Int64

  public init(
    datetime: String, requests: Int, pageViews: Int, threats: Int, bytes: Int64, uniques: Int = 0,
    cachedRequests: Int = 0, cachedBytes: Int64 = 0
  ) {
    self.datetime = datetime
    self.requests = requests
    self.pageViews = pageViews
    self.threats = threats
    self.bytes = bytes
    self.uniques = uniques
    self.cachedRequests = cachedRequests
    self.cachedBytes = cachedBytes
  }
}

public struct ZoneAnalyticsDay: Codable, Hashable, Sendable {
  public let date: String
  public let requests: Int
  public let pageViews: Int
  public let threats: Int
  public let bytes: Int64
  /// Unique visitors that day. Deduplicated per day only — see
  /// ``ZoneAnalyticsPoint/uniques``.
  public let uniques: Int
  public let cachedRequests: Int
  public let cachedBytes: Int64

  public init(
    date: String, requests: Int, pageViews: Int, threats: Int, bytes: Int64, uniques: Int = 0,
    cachedRequests: Int = 0, cachedBytes: Int64 = 0
  ) {
    self.date = date
    self.requests = requests
    self.pageViews = pageViews
    self.threats = threats
    self.bytes = bytes
    self.uniques = uniques
    self.cachedRequests = cachedRequests
    self.cachedBytes = cachedBytes
  }
}

/// One Web Analytics (RUM) site. `ruleset.zoneTag` is what ties a site back to
/// a zone — the site itself is identified only by its own tag.
public struct RUMSite: Codable, Hashable, Sendable {
  public let siteTag: String
  public let siteToken: String?
  public let snippet: String?
  /// True when Cloudflare injects the beacon at the edge for a proxied zone,
  /// so the site needs no snippet in its HTML.
  public let autoInstall: Bool
  public let rules: [RUMRule]?
  public let ruleset: RUMRuleset?

  public var zoneTag: String? { ruleset?.zoneTag }
  /// Auto-install only counts when the injecting ruleset is switched on.
  public var isCollecting: Bool { !autoInstall || (ruleset?.enabled ?? false) }
  /// Human-readable site identity for account-wide analytics. Zone-backed sites
  /// name themselves through the ruleset; manually installed sites fall back to
  /// the first included host rule instead of exposing an opaque `siteTag`.
  public var analyticsName: String {
    if let name = ruleset?.zoneName, !name.isEmpty { return name }
    if let host = rules?.first(where: {
      $0.inclusive != false && $0.isPaused != true && !($0.host?.isEmpty ?? true)
    })?.host {
      return host
    }
    if let host = rules?.first(where: { !($0.host?.isEmpty ?? true) })?.host {
      return host
    }
    return siteTag
  }

  public init(
    siteTag: String, siteToken: String? = nil, snippet: String? = nil, autoInstall: Bool = false,
    rules: [RUMRule]? = nil, ruleset: RUMRuleset? = nil
  ) {
    self.siteTag = siteTag
    self.siteToken = siteToken
    self.snippet = snippet
    self.autoInstall = autoInstall
    self.rules = rules
    self.ruleset = ruleset
  }

  private enum CodingKeys: String, CodingKey {
    case siteTag = "site_tag"
    case siteToken = "site_token"
    case snippet
    case autoInstall = "auto_install"
    case rules
    case ruleset
  }
}

public struct RUMRule: Codable, Hashable, Sendable {
  public let host: String?
  public let inclusive: Bool?
  public let isPaused: Bool?

  public init(host: String? = nil, inclusive: Bool? = nil, isPaused: Bool? = nil) {
    self.host = host
    self.inclusive = inclusive
    self.isPaused = isPaused
  }

  private enum CodingKeys: String, CodingKey {
    case host, inclusive
    case isPaused = "is_paused"
  }
}

public struct RUMRuleset: Codable, Hashable, Sendable {
  public let id: String?
  public let zoneTag: String?
  public let zoneName: String?
  public let enabled: Bool

  public init(id: String? = nil, zoneTag: String? = nil, zoneName: String? = nil, enabled: Bool) {
    self.id = id
    self.zoneTag = zoneTag
    self.zoneName = zoneName
    self.enabled = enabled
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case zoneTag = "zone_tag"
    case zoneName = "zone_name"
    case enabled
  }
}

/// One bucket of RUM page loads. `count` is beacon-reported page loads — a
/// different measurement from the edge's HTML-response `pageViews`.
public struct RUMPageviewsDay: Codable, Hashable, Sendable {
  public let date: String
  public let pageviews: Int

  public init(date: String, pageviews: Int) {
    self.date = date
    self.pageviews = pageviews
  }
}

/// One day of Web Analytics (RUM) beacon metrics for a site, matching the three
/// headline figures on Cloudflare's Web Analytics dashboard. `pageviews` and
/// `visits` come from the pageload dataset; `pageLoadTimeP50Ms` is the median
/// page-load time in milliseconds from the separate performance dataset, and is
/// `nil` on days that reported no Performance-API timings.
public struct RUMDailyMetrics: Codable, Hashable, Sendable {
  public let date: String
  public let pageviews: Int
  public let visits: Int
  public let pageLoadTimeP50Ms: Int?

  public init(date: String, pageviews: Int, visits: Int, pageLoadTimeP50Ms: Int?) {
    self.date = date
    self.pageviews = pageviews
    self.visits = visits
    self.pageLoadTimeP50Ms = pageLoadTimeP50Ms
  }
}

/// Aggregated firewall / WAF activity for a zone over a short window.
public struct FirewallEventsSummary: Codable, Hashable, Sendable {
  public let hours: Int
  public let blocked: Int
  public let countries: [FirewallEventsBucket]
  public let rules: [FirewallEventsBucket]

  public init(
    hours: Int, blocked: Int, countries: [FirewallEventsBucket] = [],
    rules: [FirewallEventsBucket] = []
  ) {
    self.hours = hours
    self.blocked = blocked
    self.countries = countries
    self.rules = rules
  }
}

public struct FirewallEventsBucket: Codable, Hashable, Identifiable, Sendable {
  public var id: String { label }
  public let label: String
  public let count: Int

  public init(label: String, count: Int) {
    self.label = label
    self.count = count
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

/// Custom hostname routed to a Worker via `/accounts/.../workers/domains`.
/// OpenAPI `x-api-token-group` is Workers Scripts Read/Write — same scopes as
/// script management, not `workers-routes.*`.
public struct WorkerDomain: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let hostname: String
  public let service: String
  public let zoneID: String
  public let zoneName: String
  public let certID: String?
  public let environment: String?

  enum CodingKeys: String, CodingKey {
    case id, hostname, service, environment
    case zoneID = "zone_id"
    case zoneName = "zone_name"
    case certID = "cert_id"
  }

  public init(
    id: String, hostname: String, service: String, zoneID: String, zoneName: String,
    certID: String? = nil, environment: String? = nil
  ) {
    self.id = id
    self.hostname = hostname
    self.service = service
    self.zoneID = zoneID
    self.zoneName = zoneName
    self.certID = certID
    self.environment = environment
  }
}

/// Zone-scoped route pattern mapped to a Worker via `/zones/.../workers/routes`.
/// The second way a hostname reaches a Worker besides `WorkerDomain`; wrangler
/// `routes` entries without `custom_domain = true` land here. OpenAPI
/// `x-api-token-group` is Workers Routes — `workers-routes.*`, not the
/// script-management scopes. `script` is nil when the route is disabled.
public struct WorkerRoute: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let pattern: String
  public let script: String?

  public init(id: String, pattern: String, script: String? = nil) {
    self.id = id
    self.pattern = pattern
    self.script = script
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

/// What a Workers Build was built from — branch, commit, and the commands the
/// trigger ran.
public struct WorkerBuildTriggerMetadata: Codable, Hashable, Sendable {
  public let branch: String?
  public let commitHash: String?
  public let commitMessage: String?
  public let author: String?
  public let buildCommand: String?
  public let deployCommand: String?
  public let buildTriggerSource: String?

  /// Seven characters, the length every git UI settled on.
  public var shortCommit: String? {
    commitHash.map { String($0.prefix(7)) }
  }

  enum CodingKeys: String, CodingKey {
    case branch, author
    case commitHash = "commit_hash"
    case commitMessage = "commit_message"
    case buildCommand = "build_command"
    case deployCommand = "deploy_command"
    case buildTriggerSource = "build_trigger_source"
  }
}

/// One build from Workers Builds
/// (`GET /accounts/{id}/builds/workers/{external_script_id}/builds`).
///
/// Every field is optional because Cloudflare's schema marks every field
/// optional — including `status` and `build_uuid`. Nothing here may assume a
/// field arrived.
public struct WorkerBuild: Codable, Hashable, Identifiable, Sendable {
  public let buildUUID: String?
  /// Cloudflare documents no enum for this. Read it through `phase`, never by
  /// comparing raw strings at a call site.
  public let status: String?
  public let buildOutcome: String?
  public let createdOn: String?
  public let initializingOn: String?
  public let runningOn: String?
  public let stoppedOn: String?
  public let modifiedOn: String?
  public let buildTriggerMetadata: WorkerBuildTriggerMetadata?

  public var id: String { buildUUID ?? createdOn ?? UUID().uuidString }

  public var shortID: String {
    buildUUID.map { String($0.prefix(8)) } ?? "—"
  }

  enum CodingKeys: String, CodingKey {
    case status
    case buildUUID = "build_uuid"
    case buildOutcome = "build_outcome"
    case createdOn = "created_on"
    case initializingOn = "initializing_on"
    case runningOn = "running_on"
    case stoppedOn = "stopped_on"
    case modifiedOn = "modified_on"
    case buildTriggerMetadata = "build_trigger_metadata"
  }
}

extension WorkerBuild {
  /// Where a build sits in its lifecycle.
  public enum Phase: Equatable, Sendable {
    case queued
    case initializing
    case running
    case finished
  }

  /// Cloudflare publishes no enum for `status`, so this reads the lifecycle from
  /// the *timestamps*, which are unambiguous, and uses `status` only to spot a
  /// queued build that has no timestamp yet.
  ///
  /// The bias is deliberate: anything not positively recognised as in-flight
  /// counts as `finished`. A Live Activity that fails to start is a missing
  /// nicety; one pinned to the Lock Screen by an unrecognised status is a bug
  /// the user can only clear by force-quitting the app.
  public var phase: Phase {
    if stoppedOn != nil || buildOutcome != nil { return .finished }
    if runningOn != nil { return .running }
    if initializingOn != nil { return .initializing }
    guard let status = status?.lowercased() else { return .finished }
    // Only these two are known-live without a timestamp to prove it.
    return status == "queued" || status == "pending" ? .queued : .finished
  }

  public var isInProgress: Bool { phase != .finished }

  /// True only when Cloudflare said the build failed. An absent outcome is
  /// unknown, not success — a build can stop without one.
  public var didFail: Bool {
    guard let outcome = buildOutcome?.lowercased() else { return false }
    return outcome != "success"
  }
}

/// `GET /accounts/{id}/builds/builds/latest?external_script_ids=…` returns the
/// newest build per script, keyed by script tag.
public struct WorkerLatestBuilds: Codable, Sendable {
  public let builds: [String: WorkerBuild]?
}

public struct WorkerSubdomainStatus: Codable, Hashable, Sendable {
  public let enabled: Bool
  public let previewsEnabled: Bool?

  enum CodingKeys: String, CodingKey {
    case enabled
    case previewsEnabled = "previews_enabled"
  }
}

/// Account-wide `workers.dev` label from
/// `GET /accounts/{account_id}/workers/subdomain`. Script URLs are composed as
/// `{scriptName}.{subdomain}.workers.dev` — Cloudflare never returns the full
/// hostname for a Worker.
public struct WorkersAccountSubdomain: Codable, Hashable, Sendable {
  public let subdomain: String

  public init(subdomain: String) {
    self.subdomain = subdomain
  }

  public func hostname(forScript name: String) -> String {
    "\(name).\(subdomain).workers.dev"
  }
}

/// Worker deployments arrive wrapped in an object, not as a bare result array.
public struct WorkerDeploymentsResult: Codable, Sendable {
  public let deployments: [GenericResource]
}

public struct WorkerDeploymentVersion: Codable, Hashable, Sendable {
  public let versionID: String
  public let percentage: Double

  enum CodingKeys: String, CodingKey {
    case percentage
    case versionID = "version_id"
  }
}

public struct WorkerDeploymentAnnotations: Codable, Hashable, Sendable {
  public let message: String?
  public let triggeredBy: String?

  enum CodingKeys: String, CodingKey {
    case message = "workers/message"
    case triggeredBy = "workers/triggered_by"
  }
}

/// Typed deployment data for the operational Worker detail surface. The API
/// returns newest first, with the first deployment actively serving traffic.
public struct WorkerDeploymentSummary: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let createdOn: String
  public let source: String
  public let strategy: String?
  private let storedVersions: [WorkerDeploymentVersion]?
  public let annotations: WorkerDeploymentAnnotations?
  public let authorEmail: String?

  public var versions: [WorkerDeploymentVersion] { storedVersions ?? [] }

  enum CodingKeys: String, CodingKey {
    case id, source, strategy, annotations
    case storedVersions = "versions"
    case createdOn = "created_on"
    case authorEmail = "author_email"
  }

  public init(
    id: String, createdOn: String, source: String, strategy: String? = nil,
    versions: [WorkerDeploymentVersion] = [], annotations: WorkerDeploymentAnnotations? = nil,
    authorEmail: String? = nil
  ) {
    self.id = id
    self.createdOn = createdOn
    self.source = source
    self.strategy = strategy
    self.storedVersions = versions.isEmpty ? nil : versions
    self.annotations = annotations
    self.authorEmail = authorEmail
  }
}

public struct WorkerDeploymentListResult: Decodable, Sendable {
  public let deployments: [WorkerDeploymentSummary]

  enum CodingKeys: String, CodingKey {
    case deployments
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let lossy = try container.decode(
      [LossyElement<WorkerDeploymentSummary>].self, forKey: .deployments)
    deployments = lossy.compactMap(\.value)
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

/// Compact deployment embedded on a project list row. Full history uses
/// `PagesDeployment`.
public struct PagesDeploymentSummary: Codable, Hashable, Sendable {
  public let id: String?
  public let url: String?
  public let environment: String?
  public let createdOn: String?
  public let latestStage: PagesDeploymentStage?

  enum CodingKeys: String, CodingKey {
    case id, url, environment
    case createdOn = "created_on"
    case latestStage = "latest_stage"
  }
}

public struct PagesDeploymentStage: Codable, Hashable, Sendable {
  public let name: String?
  public let status: String?
  public let startedOn: String?
  public let endedOn: String?

  enum CodingKeys: String, CodingKey {
    case name, status
    case startedOn = "started_on"
    case endedOn = "ended_on"
  }

  public init(
    name: String? = nil, status: String? = nil, startedOn: String? = nil, endedOn: String? = nil
  ) {
    self.name = name
    self.status = status
    self.startedOn = startedOn
    self.endedOn = endedOn
  }

  /// True while Cloudflare is still working this deployment.
  public var isInProgress: Bool {
    switch status?.lowercased() {
    case "active", "idle": true
    default: false
    }
  }
}

public struct PagesDeployment: Decodable, Hashable, Identifiable, Sendable {
  public let id: String
  public let shortID: String?
  public let url: String?
  public let environment: String?
  public let createdOn: String?
  public let modifiedOn: String?
  public let projectName: String?
  public let isSkipped: Bool?
  public let latestStage: PagesDeploymentStage?
  public let stages: [PagesDeploymentStage]?
  public let deploymentTrigger: PagesDeploymentTrigger?
  public let aliases: [String]?

  enum CodingKeys: String, CodingKey {
    case id, url, environment, stages, aliases
    case shortID = "short_id"
    case createdOn = "created_on"
    case modifiedOn = "modified_on"
    case projectName = "project_name"
    case isSkipped = "is_skipped"
    case latestStage = "latest_stage"
    case deploymentTrigger = "deployment_trigger"
  }

  public var statusLabel: String {
    latestStage?.status?.capitalized ?? (isSkipped == true ? "Skipped" : "Unknown")
  }

  public var branch: String? { deploymentTrigger?.metadata?.branch }
  public var commitMessage: String? { deploymentTrigger?.metadata?.commitMessage }

  public var isInProgress: Bool { latestStage?.isInProgress == true }
}

public struct PagesDeploymentTrigger: Codable, Hashable, Sendable {
  public let type: String?
  public let metadata: PagesDeploymentTriggerMetadata?
}

public struct PagesDeploymentTriggerMetadata: Codable, Hashable, Sendable {
  public let branch: String?
  public let commitHash: String?
  public let commitMessage: String?

  enum CodingKeys: String, CodingKey {
    case branch
    case commitHash = "commit_hash"
    case commitMessage = "commit_message"
  }
}

public struct PagesDeploymentLogs: Decodable, Hashable, Sendable {
  public let total: Int
  public let includesContainerLogs: Bool?
  public let data: [PagesDeploymentLogLine]

  enum CodingKeys: String, CodingKey {
    case total, data
    case includesContainerLogs = "includes_container_logs"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    total = try container.decodeIfPresent(Int.self, forKey: .total) ?? 0
    includesContainerLogs = try container.decodeIfPresent(Bool.self, forKey: .includesContainerLogs)
    data = try container.decodeIfPresent([PagesDeploymentLogLine].self, forKey: .data) ?? []
  }
}

public struct PagesDeploymentLogLine: Codable, Hashable, Identifiable, Sendable {
  public var id: String { "\(ts ?? "")|\(line)" }
  public let line: String
  public let ts: String?

  public init(line: String, ts: String? = nil) {
    self.line = line
    self.ts = ts
  }
}

/// Custom hostname attached to a Pages project. OpenAPI token group is
/// Pages Read / Pages Write (`page.read` / `page.write`).
public struct PagesDomain: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let name: String
  public let status: String?
  public let createdOn: String?
  public let zoneTag: String?

  enum CodingKeys: String, CodingKey {
    case id, name, status
    case createdOn = "created_on"
    case zoneTag = "zone_tag"
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
  public let httpMetadata: HTTPMetadata?

  public var contentType: String? { httpMetadata?.contentType }

  public struct HTTPMetadata: Codable, Hashable, Sendable {
    public let contentType: String?
  }

  enum CodingKeys: String, CodingKey {
    case key, size, etag
    case uploaded = "last_modified"
    case httpMetadata = "http_metadata"
  }
}

public struct R2ObjectPage: Sendable {
  public let objects: [R2Object]
  public let commonPrefixes: [String]
  public let cursor: String?
  public let isTruncated: Bool

  public init(
    objects: [R2Object], commonPrefixes: [String], cursor: String?, isTruncated: Bool
  ) {
    self.objects = objects
    self.commonPrefixes = commonPrefixes
    self.cursor = cursor
    self.isTruncated = isTruncated
  }
}

/// The bucket's r2.dev managed domain. Unlike the objects list, the domain
/// endpoints speak camelCase, so these models need no key mapping.
public struct R2ManagedDomain: Codable, Hashable, Sendable {
  public let bucketId: String
  public let domain: String
  public let enabled: Bool

  // Memberwise inits are internal; test fixtures need this one.
  public init(bucketId: String, domain: String, enabled: Bool) {
    self.bucketId = bucketId
    self.domain = domain
    self.enabled = enabled
  }
}

/// One custom domain attached to an R2 bucket. `status` is present on list and
/// get responses but absent from the create response, so it stays optional.
public struct R2CustomDomain: Codable, Hashable, Identifiable, Sendable {
  public var id: String { domain }
  public let domain: String
  public let enabled: Bool
  public let status: Status?
  public let minTLS: String?
  public let zoneId: String?
  public let zoneName: String?

  public struct Status: Codable, Hashable, Sendable {
    public let ownership: String?
    public let ssl: String?
  }
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

public struct NotificationMechanismTarget: Codable, Hashable, Sendable {
  public var id: String

  public init(id: String) {
    self.id = id
  }
}

public struct NotificationMechanisms: Codable, Hashable, Sendable {
  public var email: [NotificationMechanismTarget]?
  public var pagerduty: [NotificationMechanismTarget]?
  public var webhooks: [NotificationMechanismTarget]?

  public init(
    email: [NotificationMechanismTarget]? = nil,
    pagerduty: [NotificationMechanismTarget]? = nil,
    webhooks: [NotificationMechanismTarget]? = nil
  ) {
    self.email = email
    self.pagerduty = pagerduty
    self.webhooks = webhooks
  }
}

public struct NotificationPolicy: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let name: String?
  public let description: String?
  public let alertType: String?
  public let enabled: Bool?
  public let alertInterval: String?
  public let filters: [String: [String]]?
  public let mechanisms: NotificationMechanisms?

  public var title: String {
    name ?? alertType?.replacingOccurrences(of: "_", with: " ") ?? id
  }

  /// Read-modify-write helper for PUTs that must preserve mechanisms/filters.
  public func input(enabled: Bool? = nil) -> NotificationPolicyInput {
    NotificationPolicyInput(
      name: name ?? title,
      alertType: alertType ?? "",
      enabled: enabled ?? self.enabled ?? true,
      description: description,
      alertInterval: alertInterval,
      filters: filters,
      mechanisms: mechanisms
    )
  }

  enum CodingKeys: String, CodingKey {
    case id, name, description, enabled, filters, mechanisms
    case alertType = "alert_type"
    case alertInterval = "alert_interval"
  }
}

public struct NotificationPolicyInput: Codable, Hashable, Sendable {
  public var name: String
  public var alertType: String
  public var enabled: Bool
  public var description: String?
  public var alertInterval: String?
  public var filters: [String: [String]]?
  public var mechanisms: NotificationMechanisms?

  public init(
    name: String,
    alertType: String,
    enabled: Bool = true,
    description: String? = nil,
    alertInterval: String? = nil,
    filters: [String: [String]]? = nil,
    mechanisms: NotificationMechanisms? = nil
  ) {
    self.name = name
    self.alertType = alertType
    self.enabled = enabled
    self.description = description
    self.alertInterval = alertInterval
    self.filters = filters
    self.mechanisms = mechanisms
  }

  enum CodingKeys: String, CodingKey {
    case name, description, enabled, filters, mechanisms
    case alertType = "alert_type"
    case alertInterval = "alert_interval"
  }
}

public struct NotificationWebhook: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let name: String?
  public let url: String?
  public let type: String?
  public let createdAt: String?
  public let lastFailure: String?
  public let lastSuccess: String?

  enum CodingKeys: String, CodingKey {
    case id, name, url, type
    case createdAt = "created_at"
    case lastFailure = "last_failure"
    case lastSuccess = "last_success"
  }
}

public struct NotificationWebhookInput: Codable, Hashable, Sendable {
  public var name: String
  public var url: String
  public var secret: String?

  public init(name: String, url: String, secret: String? = nil) {
    self.name = name
    self.url = url
    self.secret = secret
  }
}

/// One alert type from `GET …/available_alerts` (flattened from the category map).
public struct AvailableAlert: Codable, Hashable, Sendable, Identifiable {
  public let description: String?
  public let displayName: String?
  public let type: String?

  public var id: String { type ?? displayName ?? description ?? UUID().uuidString }
  public var title: String {
    displayName ?? type?.replacingOccurrences(of: "_", with: " ") ?? "Alert"
  }

  enum CodingKeys: String, CodingKey {
    case description, type
    case displayName = "display_name"
  }
}

/// One product's worth of alert types, as Cloudflare groups them.
public struct AvailableAlertGroup: Hashable, Identifiable, Sendable {
  public let category: String
  public let alerts: [AvailableAlert]

  public var id: String { category }

  public init(category: String, alerts: [AvailableAlert]) {
    self.category = category
    self.alerts = alerts
  }
}

public struct NotificationHistoryEntry: Codable, Hashable, Identifiable, Sendable {
  /// Cloudflare history UUID when the API returns one.
  public let historyID: String?
  public let policyID: String?
  public let name: String?
  public let alertType: String?
  public let mechanism: String?
  public let alertBody: String?
  public let description: String?
  public let sent: String?

  public init(
    historyID: String? = nil,
    policyID: String? = nil,
    name: String? = nil,
    alertType: String? = nil,
    mechanism: String? = nil,
    alertBody: String? = nil,
    description: String? = nil,
    sent: String? = nil
  ) {
    self.historyID = historyID
    self.policyID = policyID
    self.name = name
    self.alertType = alertType
    self.mechanism = mechanism
    self.alertBody = alertBody
    self.description = description
    self.sent = sent
  }

  public var id: String {
    historyID
      ?? [policyID, sent, name, alertType].compactMap { $0 }.joined(separator: "|").nilIfEmpty
      ?? "notification-history"
  }
  public var title: String {
    name ?? alertType?.replacingOccurrences(of: "_", with: " ") ?? "Notification"
  }
  public var subtitle: String? { alertBody ?? mechanism ?? description }

  enum CodingKeys: String, CodingKey {
    case name, mechanism, description, sent
    case historyID = "id"
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
  public let occurredAt: String?

  public var title: String {
    action?.description ?? action?.type ?? "Action"
  }
  public var subtitle: String? {
    [actor?.email ?? actor?.type, resource?.product ?? resource?.type, occurredAt]
      .compactMap { $0 }.joined(separator: " · ")
      .nilIfEmpty
  }

  enum CodingKeys: String, CodingKey {
    case logID = "id"
    case action, actor, resource
    case occurredAt = "when"
  }

  public init(
    logID: String?, action: AuditLogAction?, actor: AuditLogActor?, resource: AuditLogResource?,
    occurredAt: String? = nil
  ) {
    self.logID = logID
    self.action = action
    self.actor = actor
    self.resource = resource
    self.occurredAt = occurredAt
  }
}

extension AuditLogEntry: Identifiable {
  public var id: String {
    logID ?? [title, subtitle].compactMap { $0 }.joined(separator: "|")
  }
}

public struct AuditLogAction: Codable, Hashable, Sendable {
  public let type: String?
  public let description: String?
  public let result: String?
  public let time: String?

  public init(type: String?, description: String? = nil, result: String? = nil, time: String? = nil)
  {
    self.type = type
    self.description = description
    self.result = result
    self.time = time
  }
}

public struct AuditLogActor: Codable, Hashable, Sendable {
  public let email: String?
  public let type: String?

  public init(email: String?, type: String?) {
    self.email = email
    self.type = type
  }
}

public struct AuditLogResource: Codable, Hashable, Sendable {
  public let type: String?
  public let product: String?
  public let id: String?

  public init(type: String?, product: String? = nil, id: String? = nil) {
    self.type = type
    self.product = product
    self.id = id
  }
}

/// Audit Logs API v2 row — mapped into `AuditLogEntry` for shared UI.
public struct AuditLogV2Entry: Codable, Hashable, Sendable {
  public let id: String?
  public let action: AuditLogV2Action?
  public let actor: AuditLogV2Actor?
  public let resource: AuditLogV2Resource?

  public var asLegacyEntry: AuditLogEntry {
    AuditLogEntry(
      logID: id,
      action: AuditLogAction(
        type: action?.type, description: action?.description, result: action?.result,
        time: action?.time),
      actor: AuditLogActor(email: actor?.email, type: actor?.type),
      resource: AuditLogResource(
        type: resource?.type, product: resource?.product, id: resource?.id),
      occurredAt: action?.time
    )
  }
}

public struct AuditLogV2Action: Codable, Hashable, Sendable {
  public let description: String?
  public let result: String?
  public let time: String?
  public let type: String?
}

public struct AuditLogV2Actor: Codable, Hashable, Sendable {
  public let email: String?
  public let type: String?
}

public struct AuditLogV2Resource: Codable, Hashable, Sendable {
  public let id: String?
  public let product: String?
  public let type: String?
}

public struct WorkerAnalyticsPayload: Hashable, Sendable {
  public var requests: Int
  public var errors: Int
  public var cpuTimeP50Us: Double
  public var points: [WorkerAnalyticsBucket]

  public init(requests: Int, errors: Int, cpuTimeP50Us: Double, points: [WorkerAnalyticsBucket]) {
    self.requests = requests
    self.errors = errors
    self.cpuTimeP50Us = cpuTimeP50Us
    self.points = points
  }
}

/// Account-scoped overview tiles for a rolling window (Watchtower).
/// HTTP fields come from `httpRequestsOverviewAdaptiveGroups`; Workers fields
/// from a single-bucket `workersInvocationsAdaptive` (P90 over the whole window).
public struct AccountAnalyticsOverview: Hashable, Sendable {
  public var webRequests: Int
  public var bytes: Int64
  public var cacheRate: Double
  public var clientErrorRate: Double
  public var encryptedRequestRate: Double
  public var encryptedBytes: Int64
  public var workerInvocations: Int
  public var workerErrors: Int
  public var cpuTimeP90Us: Double
  public var hours: Int

  public init(
    webRequests: Int,
    bytes: Int64,
    cacheRate: Double,
    clientErrorRate: Double,
    encryptedRequestRate: Double,
    encryptedBytes: Int64,
    workerInvocations: Int,
    workerErrors: Int,
    cpuTimeP90Us: Double,
    hours: Int
  ) {
    self.webRequests = webRequests
    self.bytes = bytes
    self.cacheRate = cacheRate
    self.clientErrorRate = clientErrorRate
    self.encryptedRequestRate = encryptedRequestRate
    self.encryptedBytes = encryptedBytes
    self.workerInvocations = workerInvocations
    self.workerErrors = workerErrors
    self.cpuTimeP90Us = cpuTimeP90Us
    self.hours = hours
  }
}

/// One bucket in an account HTTP or Workers series.
///
/// HTTP rows fill traffic / bandwidth / ratio fields; Workers rows fill
/// invocations / errors / CPU. Unused fields stay zero.
public struct AccountAnalyticsPoint: Hashable, Sendable, Identifiable {
  public var id: String { datetime }
  public var datetime: String
  public var requests: Int
  public var bytes: Int64
  public var errors: Int
  public var cacheRate: Double
  public var clientErrorRate: Double
  public var encryptedRequestRate: Double
  public var encryptedBytes: Int64
  public var cpuTimeP90Us: Double

  public init(
    datetime: String,
    requests: Int,
    bytes: Int64 = 0,
    errors: Int = 0,
    cacheRate: Double = 0,
    clientErrorRate: Double = 0,
    encryptedRequestRate: Double = 0,
    encryptedBytes: Int64 = 0,
    cpuTimeP90Us: Double = 0
  ) {
    self.datetime = datetime
    self.requests = requests
    self.bytes = bytes
    self.errors = errors
    self.cacheRate = cacheRate
    self.clientErrorRate = clientErrorRate
    self.encryptedRequestRate = encryptedRequestRate
    self.encryptedBytes = encryptedBytes
    self.cpuTimeP90Us = cpuTimeP90Us
  }
}

/// Totals plus HTTP / Workers time series for one Watchtower range.
public struct AccountAnalyticsSnapshot: Hashable, Sendable {
  public var overview: AccountAnalyticsOverview
  public var httpPoints: [AccountAnalyticsPoint]
  public var workerPoints: [AccountAnalyticsPoint]
  /// Wall-clock time the snapshot was fetched; used for “Updated …” chrome.
  public var fetchedAt: Date

  public init(
    overview: AccountAnalyticsOverview,
    httpPoints: [AccountAnalyticsPoint],
    workerPoints: [AccountAnalyticsPoint],
    fetchedAt: Date = .now
  ) {
    self.overview = overview
    self.httpPoints = httpPoints
    self.workerPoints = workerPoints
    self.fetchedAt = fetchedAt
  }
}

public struct WorkerAnalyticsBucket: Hashable, Sendable, Identifiable {
  public var id: String { datetime }
  public var datetime: String
  public var requests: Int
  public var errors: Int
  public var cpuTimeP50Us: Double

  public init(datetime: String, requests: Int, errors: Int, cpuTimeP50Us: Double = 0) {
    self.datetime = datetime
    self.requests = requests
    self.errors = errors
    self.cpuTimeP50Us = cpuTimeP50Us
  }
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
  private let storedID: String?
  private let storedName: String?
  public let expiresAt: String?

  public var id: String { storedID?.nilIfEmpty ?? storedName?.nilIfEmpty ?? "" }
  public var name: String { storedName?.nilIfEmpty ?? storedID?.nilIfEmpty ?? "" }
  public var hasIdentity: Bool {
    storedID?.nilIfEmpty != nil || storedName?.nilIfEmpty != nil
  }

  enum CodingKeys: String, CodingKey {
    case storedID = "id"
    case storedName = "name"
    case expiresAt = "expires_at"
  }
}

/// Canonical registration state returned by `/registrar/registrations/{domain}`.
public struct RegistrarRegistration: Codable, Hashable, Identifiable, Sendable {
  public var id: String { domainName }
  public let domainName: String
  public let status: String
  public let createdAt: String?
  public let expiresAt: String?
  public let autoRenew: Bool
  public let privacyMode: String
  public let locked: Bool

  enum CodingKeys: String, CodingKey {
    case status, locked
    case domainName = "domain_name"
    case createdAt = "created_at"
    case expiresAt = "expires_at"
    case autoRenew = "auto_renew"
    case privacyMode = "privacy_mode"
  }
}

public struct CertificatePack: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let status: String
  public let certificates: [CertificatePackCertificate]?
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
