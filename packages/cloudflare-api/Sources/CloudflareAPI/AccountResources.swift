import Foundation

public struct AccountUpdateInput: Encodable, Hashable, Sendable {
  public let name: String

  public init(name: String) {
    self.name = name
  }
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

public struct AccessPolicy: Codable, Identifiable, Hashable, Sendable {
  public let id: String
  public let name: String
  public let decision: String?
  /// The include rule union stays untyped; the app only builds a few shapes.
  public let include: [JSONValue]?
  public let reusable: Bool?
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

public struct LoadBalancerPool: CloudflareResource, Hashable {
  public let id: String
  public let name: String
  public let enabled: Bool?
}

extension CloudflareClient {
  @discardableResult
  public func updateAccount(accountID: String, input: AccountUpdateInput) async throws
    -> CloudflareAccount
  {
    try await request("/accounts/\(accountID)", method: "PUT", body: input)
  }

  public func listAccountMembers(accountID: String, page: Int = 1, perPage: Int = 25) async throws
    -> Page<AccountMember>
  {
    try await list(
      "/accounts/\(accountID)/members",
      query: ["page": String(page), "per_page": String(perPage)])
  }

  public func listRumSites(accountID: String) async throws -> [RumSite] {
    try await list("/accounts/\(accountID)/rum/site_info/list").items
  }
  public func listLoadBalancerPools(accountID: String) async throws -> [LoadBalancerPool] {
    try await list("/accounts/\(accountID)/load_balancers/pools").items
  }

  // MARK: Rulesets — basePath is "/accounts/{id}" or "/zones/{id}" so one
  // code path serves both scopes.

  public func getRuleset(basePath: String, id: String) async throws -> RulesetDetail {
    try await request("\(basePath)/rulesets/\(id)")
  }

  @discardableResult
  public func addRulesetRule(
    basePath: String, rulesetID: String, body: [String: JSONValue]
  ) async throws -> RulesetDetail {
    try await request("\(basePath)/rulesets/\(rulesetID)/rules", method: "POST", body: body)
  }

  @discardableResult
  public func patchRulesetRule(
    basePath: String, rulesetID: String, ruleID: String, body: [String: JSONValue]
  ) async throws -> RulesetDetail {
    try await request(
      "\(basePath)/rulesets/\(rulesetID)/rules/\(ruleID)", method: "PATCH", body: body)
  }

  // MARK: Account members

  public func listAccountRoles(accountID: String) async throws -> [AccountRole] {
    try await list("/accounts/\(accountID)/roles", query: ["per_page": "50"]).items
  }

  @discardableResult
  public func inviteAccountMember(
    accountID: String, email: String, roleIDs: [String]
  ) async throws -> AccountMember {
    try await request(
      "/accounts/\(accountID)/members", method: "POST",
      body: [
        "email": JSONValue.string(email),
        "roles": .array(roleIDs.map(JSONValue.string)),
      ])
  }

  // MARK: Access policies

  public func listAccessPolicies(accountID: String) async throws -> [AccessPolicy] {
    try await request("/accounts/\(accountID)/access/policies")
  }

  public func listAppPolicies(accountID: String, appID: String) async throws -> [AccessPolicy] {
    try await request("/accounts/\(accountID)/access/apps/\(appID)/policies")
  }

  @discardableResult
  public func createAccessPolicy(
    accountID: String, appID: String? = nil, body: [String: JSONValue]
  ) async throws -> AccessPolicy {
    let path =
      appID.map { "/accounts/\(accountID)/access/apps/\($0)/policies" }
      ?? "/accounts/\(accountID)/access/policies"
    return try await request(path, method: "POST", body: body)
  }
}
