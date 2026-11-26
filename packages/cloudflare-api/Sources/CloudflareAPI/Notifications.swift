import Foundation

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
  public let zoneName: String?
  public let zoneID: String?
  public let interfaceName: String?
  public let method: String?
  public let uri: String?
  public let statusCode: Int?
  public let rayID: String?
  public let oldValue: String?
  public let newValue: String?

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
    case zoneName = "zone_name"
    case zoneID = "zone_id"
    case interfaceName = "interface"
    case method, uri
    case statusCode = "status_code"
    case rayID = "ray_id"
    case oldValue, newValue
  }

  public init(
    logID: String?, action: AuditLogAction?, actor: AuditLogActor?, resource: AuditLogResource?,
    occurredAt: String? = nil,
    zoneName: String? = nil,
    zoneID: String? = nil,
    interfaceName: String? = nil,
    method: String? = nil,
    uri: String? = nil,
    statusCode: Int? = nil,
    rayID: String? = nil,
    oldValue: String? = nil,
    newValue: String? = nil
  ) {
    self.logID = logID
    self.action = action
    self.actor = actor
    self.resource = resource
    self.occurredAt = occurredAt
    self.zoneName = zoneName
    self.zoneID = zoneID
    self.interfaceName = interfaceName
    self.method = method
    self.uri = uri
    self.statusCode = statusCode
    self.rayID = rayID
    self.oldValue = oldValue
    self.newValue = newValue
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

  enum CodingKeys: String, CodingKey {
    case type, description, result, time
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    type = try container.decodeIfPresent(String.self, forKey: .type)
    description = try container.decodeIfPresent(String.self, forKey: .description)
    time = try container.decodeIfPresent(String.self, forKey: .time)
    if let stringResult = try? container.decodeIfPresent(String.self, forKey: .result) {
      result = stringResult
    } else if let boolResult = try? container.decodeIfPresent(Bool.self, forKey: .result) {
      result = boolResult ? "success" : "failure"
    } else {
      result = nil
    }
  }
}

public struct AuditLogActor: Codable, Hashable, Sendable {
  public let email: String?
  public let type: String?
  public let id: String?
  public let ipAddress: String?
  public let context: String?
  public let tokenName: String?

  public init(
    email: String?,
    type: String?,
    id: String? = nil,
    ipAddress: String? = nil,
    context: String? = nil,
    tokenName: String? = nil
  ) {
    self.email = email
    self.type = type
    self.id = id
    self.ipAddress = ipAddress
    self.context = context
    self.tokenName = tokenName
  }

  enum CodingKeys: String, CodingKey {
    case email, type, id, context
    case ipAddress = "ip_address"
    case legacyIP = "ip"
    case tokenName = "token_name"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    email = try container.decodeIfPresent(String.self, forKey: .email)
    type = try container.decodeIfPresent(String.self, forKey: .type)
    id = try container.decodeIfPresent(String.self, forKey: .id)
    context = try container.decodeIfPresent(String.self, forKey: .context)
    tokenName = try container.decodeIfPresent(String.self, forKey: .tokenName)
    ipAddress =
      try container.decodeIfPresent(String.self, forKey: .ipAddress)?.nilIfEmpty
      ?? container.decodeIfPresent(String.self, forKey: .legacyIP)?.nilIfEmpty
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(email, forKey: .email)
    try container.encodeIfPresent(type, forKey: .type)
    try container.encodeIfPresent(id, forKey: .id)
    try container.encodeIfPresent(ipAddress, forKey: .ipAddress)
    try container.encodeIfPresent(context, forKey: .context)
    try container.encodeIfPresent(tokenName, forKey: .tokenName)
  }
}

public struct AuditLogResource: Codable, Hashable, Sendable {
  public let type: String?
  public let product: String?
  public let id: String?
  public let scope: String?

  public init(
    type: String?, product: String? = nil, id: String? = nil, scope: String? = nil
  ) {
    self.type = type
    self.product = product
    self.id = id
    self.scope = scope
  }
}

/// Audit Logs API v2 row — mapped into `AuditLogEntry` for shared UI.
public struct AuditLogV2Entry: Codable, Hashable, Sendable {
  public let id: String?
  public let action: AuditLogV2Action?
  public let actor: AuditLogV2Actor?
  public let resource: AuditLogV2Resource?
  public let zone: AuditLogV2Zone?
  public let raw: AuditLogV2Raw?

  public var asEntry: AuditLogEntry {
    AuditLogEntry(
      logID: id?.nilIfEmpty,
      action: AuditLogAction(
        type: action?.type?.nilIfEmpty,
        description: action?.description?.nilIfEmpty,
        result: action?.result?.nilIfEmpty,
        time: action?.time?.nilIfEmpty),
      actor: AuditLogActor(
        email: actor?.email?.nilIfEmpty,
        type: actor?.type?.nilIfEmpty,
        id: actor?.id?.nilIfEmpty,
        ipAddress: actor?.ipAddress?.nilIfEmpty,
        context: actor?.context?.nilIfEmpty,
        tokenName: actor?.tokenName?.nilIfEmpty),
      resource: AuditLogResource(
        type: resource?.type?.nilIfEmpty,
        product: resource?.product?.nilIfEmpty,
        id: resource?.id?.nilIfEmpty,
        scope: resource?.scope?.nilIfEmpty),
      occurredAt: action?.time?.nilIfEmpty,
      zoneName: zone?.name?.nilIfEmpty,
      zoneID: zone?.id?.nilIfEmpty,
      method: raw?.method?.nilIfEmpty,
      uri: raw?.uri?.nilIfEmpty,
      statusCode: raw?.statusCode,
      rayID: raw?.cfRayID?.nilIfEmpty
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
  public let id: String?
  public let email: String?
  public let type: String?
  public let ipAddress: String?
  public let context: String?
  public let tokenName: String?

  enum CodingKeys: String, CodingKey {
    case id, email, type, context
    case ipAddress = "ip_address"
    case tokenName = "token_name"
  }
}

public struct AuditLogV2Resource: Codable, Hashable, Sendable {
  public let id: String?
  public let product: String?
  public let type: String?
  public let scope: String?
}

public struct AuditLogV2Zone: Codable, Hashable, Sendable {
  public let id: String?
  public let name: String?
}

public struct AuditLogV2Raw: Codable, Hashable, Sendable {
  public let cfRayID: String?
  public let method: String?
  public let statusCode: Int?
  public let uri: String?

  enum CodingKeys: String, CodingKey {
    case method, uri
    case cfRayID = "cf_ray_id"
    case statusCode = "status_code"
  }
}

/// Continuation token for `listAuditLogsPage`, keeping v2 cursor pagination
/// (with a pinned date window) and v1 page-number pagination on one type.
public enum AuditLogPageToken: Hashable, Sendable {
  case v2(cursor: String, since: String, before: String)
  case v1(page: Int)
}

public struct AuditLogPage: Sendable {
  public let entries: [AuditLogEntry]
  public let nextPage: AuditLogPageToken?

  public init(entries: [AuditLogEntry], nextPage: AuditLogPageToken? = nil) {
    self.entries = entries
    self.nextPage = nextPage
  }
}

extension CloudflareClient {
  public func listNotificationHistory(accountID: String, perPage: Int = 10) async throws
    -> [NotificationHistoryEntry]
  {
    let data = try await raw(
      "/accounts/\(accountID)/alerting/v3/history", query: ["per_page": String(perPage)])
    let envelope = try JSONDecoder().decode(
      APIEnvelope<[NotificationHistoryEntry]?>.self, from: data)
    guard envelope.success else {
      throw CloudflareAPIError.request(status: 200, errors: envelope.errors ?? [])
    }
    return envelope.result ?? []
  }

  public func listAuditLogs(accountID: String, perPage: Int = 10) async throws -> [AuditLogEntry] {
    try await listAuditLogsPage(accountID: accountID, perPage: perPage).entries
  }

  /// Paginated audit log fetch. Starts on Audit Logs v2 (cursor-based) and
  /// falls back to v1 (page-based) only when the account lacks v2 access (403
  /// or 404). Subsequent pages follow the token returned by the first page so
  /// the API version and v2 date window stay consistent across pages.
  public func listAuditLogsPage(
    accountID: String,
    perPage: Int = 50,
    page: AuditLogPageToken? = nil
  ) async throws -> AuditLogPage {
    switch page {
    case nil:
      do {
        return try await listAuditLogsV2Page(accountID: accountID, limit: perPage)
      } catch let error as CloudflareAPIError where error.isForbidden || error.isNotFound {
        return try await listAuditLogsV1Page(accountID: accountID, page: 1, perPage: perPage)
      }
    case .v2(let cursor, let since, let before):
      return try await listAuditLogsV2Page(
        accountID: accountID, limit: perPage, cursor: cursor, since: since, before: before)
    case .v1(let pageNumber):
      return try await listAuditLogsV1Page(
        accountID: accountID, page: pageNumber, perPage: perPage)
    }
  }

  /// Excludes `view` entries. Since 2026-10-13 v2 returns every read as one,
  /// Dash's own requests included, so an unfiltered first page is mostly the
  /// app watching itself instead of the changes the list is for.
  public func listAuditLogsV2(accountID: String, limit: Int = 10) async throws -> [AuditLogEntry] {
    try await listAuditLogsV2Page(accountID: accountID, limit: limit).entries
  }

  private func listAuditLogsV2Page(
    accountID: String,
    limit: Int,
    cursor: String? = nil,
    since: String? = nil,
    before: String? = nil
  ) async throws -> AuditLogPage {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    let resolvedSince =
      since ?? formatter.string(from: Date().addingTimeInterval(-7 * 24 * 3600))
    let resolvedBefore =
      before ?? formatter.string(from: Date().addingTimeInterval(24 * 3600))
    let response: Page<AuditLogV2Entry> = try await list(
      "/accounts/\(accountID)/logs/audit",
      query: [
        "direction": "desc",
        "limit": String(limit),
        "action_type.not": "view",
        "since": resolvedSince,
        "before": resolvedBefore,
        "cursor": cursor,
      ]
    )
    let entries = response.items.map(\.asEntry)
    let nextCursor = response.resultInfo?.cursor?.nilIfEmpty
    let nextPage: AuditLogPageToken? =
      if !entries.isEmpty, let nextCursor, nextCursor != cursor {
        .v2(cursor: nextCursor, since: resolvedSince, before: resolvedBefore)
      } else {
        nil
      }
    return AuditLogPage(entries: entries, nextPage: nextPage)
  }

  private func listAuditLogsV1Page(
    accountID: String,
    page: Int,
    perPage: Int
  ) async throws -> AuditLogPage {
    let response: Page<AuditLogEntry> = try await list(
      "/accounts/\(accountID)/audit_logs",
      query: [
        "direction": "desc",
        "page": String(page),
        "per_page": String(perPage),
      ]
    )
    let entries = response.items
    let hasMore: Bool
    if entries.isEmpty {
      hasMore = false
    } else if let totalPages = response.resultInfo?.totalPages {
      hasMore = page < totalPages
    } else if let totalCount = response.resultInfo?.totalCount {
      let effectivePerPage = response.resultInfo?.perPage ?? perPage
      hasMore = page * effectivePerPage < totalCount
    } else {
      hasMore = entries.count >= (response.resultInfo?.perPage ?? perPage)
    }
    return AuditLogPage(entries: entries, nextPage: hasMore ? .v1(page: page + 1) : nil)
  }
}
