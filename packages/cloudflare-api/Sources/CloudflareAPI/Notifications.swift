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

  public var asEntry: AuditLogEntry {
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
    // Prefer Audit Logs v2; fall back to v1 when the account lacks access —
    // an account without v2 answers 403 or 404, and both mean "ask v1". The
    // catch stays narrow on purpose: a bare one turns a cancelled task or a
    // malformed v2 body into a second, pointless request whose empty result
    // hides the real failure.
    do {
      return try await listAuditLogsV2(accountID: accountID, limit: perPage)
    } catch let error as CloudflareAPIError where error.isForbidden || error.isNotFound {
      return try await list(
        "/accounts/\(accountID)/audit_logs",
        query: ["direction": "desc", "per_page": String(perPage)]
      ).items
    }
  }

  public func listAuditLogsV2(accountID: String, limit: Int = 10) async throws -> [AuditLogEntry] {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    let since = formatter.string(from: Date().addingTimeInterval(-7 * 24 * 3600))
    let before = formatter.string(from: Date().addingTimeInterval(24 * 3600))
    let entries: [AuditLogV2Entry] = try await list(
      "/accounts/\(accountID)/logs/audit",
      query: [
        "direction": "desc",
        "limit": String(limit),
        "since": since,
        "before": before,
      ]
    ).items
    return entries.map(\.asEntry)
  }
}
