import Foundation

// MARK: - Settings

/// Zone-level Email Routing settings (`GET /zones/{id}/email/routing`).
///
/// `status` stays a raw string. Cloudflare documents a value list but ships new
/// ones without notice, and a screen that renders "Ready" for something it has
/// never seen is worse than one that renders "Unknown" — the same rule
/// `WorkerBuild.phase` follows one layer up.
public struct EmailRoutingSettings: Codable, Hashable, Sendable {
  public let id: String
  public let name: String
  public let enabled: Bool
  public let status: String?
  public let created: String?
  public let modified: String?
  public let skipWizard: Bool?
  public let supportSubaddress: Bool?
  public let tag: String?

  enum CodingKeys: String, CodingKey {
    case id, name, enabled, status, created, modified, tag
    case skipWizard = "skip_wizard"
    case supportSubaddress = "support_subaddress"
  }

  public init(
    id: String, name: String, enabled: Bool, status: String? = nil, created: String? = nil,
    modified: String? = nil, skipWizard: Bool? = nil, supportSubaddress: Bool? = nil,
    tag: String? = nil
  ) {
    self.id = id
    self.name = name
    self.enabled = enabled
    self.status = status
    self.created = created
    self.modified = modified
    self.skipWizard = skipWizard
    self.supportSubaddress = supportSubaddress
    self.tag = tag
  }
}

/// The documented values of `EmailRoutingSettings.status`. Never decoded
/// directly — it is resolved from the raw string so an unrecognised value is
/// `nil` ("Cloudflare said something new") instead of failing the decode.
public enum EmailRoutingStatus: String, Sendable {
  case ready
  case unconfigured
  case misconfigured
  case misconfiguredLocked = "misconfigured/locked"
  case unlocked
}

extension EmailRoutingSettings {
  /// `nil` means the status string is one this app has never seen. Render it as
  /// unknown; never as ready.
  public var routingStatus: EmailRoutingStatus? {
    status.flatMap(EmailRoutingStatus.init(rawValue:))
  }
}

// MARK: - Rules

/// One `matchers` entry on a routing rule. `type` is `"literal"` (with
/// `field` / `value`) or `"all"` (catch-all).
public struct EmailRoutingRuleMatcher: Codable, Hashable, Sendable {
  public var type: String
  public var field: String?
  public var value: String?

  public init(type: String, field: String? = nil, value: String? = nil) {
    self.type = type
    self.field = field
    self.value = value
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // A matcher missing `type` degrades one row; throwing would drop the whole
    // rule (in a list) or the whole catch-all (on its own endpoint).
    type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
    field = try container.decodeIfPresent(String.self, forKey: .field)
    value = try container.decodeIfPresent(String.self, forKey: .value)
  }
}

/// One `actions` entry on a routing rule. `type` is `"forward"`, `"drop"` or
/// `"worker"`; the server caps `value` at a single element for `forward`.
public struct EmailRoutingRuleAction: Codable, Hashable, Sendable {
  public var type: String
  public var value: [String]?

  public var forwardTarget: String? { type == "forward" ? value?.first : nil }

  public init(type: String, value: [String]? = nil) {
    self.type = type
    self.value = value
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
    // Documented as an array of strings. A bare string is accepted rather than
    // failing the whole rule over a shape Cloudflare could widen at any time.
    if let list = try? container.decode([String].self, forKey: .value) {
      value = list
    } else if let single = try? container.decode(String.self, forKey: .value) {
      value = [single]
    } else {
      value = nil
    }
  }
}

/// A routing rule. `id` is required on purpose: `CloudflareClient.list` wraps
/// every element in `LossyElement`, so a rule with no id is dropped from the
/// page rather than rendered as a row that cannot be edited or deleted.
public struct EmailRoutingRule: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let tag: String?
  public let name: String?
  public let enabled: Bool?
  public let priority: Int?
  public let source: String?
  public let matchers: [EmailRoutingRuleMatcher]
  public let actions: [EmailRoutingRuleAction]

  /// Declared in a Worker's `wrangler.jsonc`. Editing it in Dash would be
  /// overwritten on the next deploy, so these rules open read-only.
  public var isWranglerManaged: Bool { source == "wrangler" }

  /// The address this rule matches, when it is a literal `to:` match.
  public var matchedAddress: String? {
    matchers.first { $0.type == "literal" }?.value
  }

  public init(
    id: String, tag: String? = nil, name: String? = nil, enabled: Bool? = nil,
    priority: Int? = nil, source: String? = nil, matchers: [EmailRoutingRuleMatcher] = [],
    actions: [EmailRoutingRuleAction] = []
  ) {
    self.id = id
    self.tag = tag
    self.name = name
    self.enabled = enabled
    self.priority = priority
    self.source = source
    self.matchers = matchers
    self.actions = actions
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    tag = try container.decodeIfPresent(String.self, forKey: .tag)
    name = try container.decodeIfPresent(String.self, forKey: .name)
    enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
    priority = try container.decodeIfPresent(Int.self, forKey: .priority)
    source = try container.decodeIfPresent(String.self, forKey: .source)
    matchers =
      try container.decodeIfPresent([EmailRoutingRuleMatcher].self, forKey: .matchers) ?? []
    actions = try container.decodeIfPresent([EmailRoutingRuleAction].self, forKey: .actions) ?? []
  }
}

/// The catch-all rule. Structurally a rule **without** `priority` — which is
/// the entire reason it is a separate type: round-tripping a phantom priority
/// through `PUT .../rules/catch_all` is a write Cloudflare never asked for.
public struct EmailRoutingCatchAllRule: Codable, Hashable, Sendable {
  public let id: String?
  public let tag: String?
  public let name: String?
  public let enabled: Bool?
  public let source: String?
  public let matchers: [EmailRoutingRuleMatcher]
  public let actions: [EmailRoutingRuleAction]

  public init(
    id: String? = nil, tag: String? = nil, name: String? = nil, enabled: Bool? = nil,
    source: String? = nil, matchers: [EmailRoutingRuleMatcher] = [],
    actions: [EmailRoutingRuleAction] = []
  ) {
    self.id = id
    self.tag = tag
    self.name = name
    self.enabled = enabled
    self.source = source
    self.matchers = matchers
    self.actions = actions
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(String.self, forKey: .id)
    tag = try container.decodeIfPresent(String.self, forKey: .tag)
    name = try container.decodeIfPresent(String.self, forKey: .name)
    enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
    source = try container.decodeIfPresent(String.self, forKey: .source)
    matchers =
      try container.decodeIfPresent([EmailRoutingRuleMatcher].self, forKey: .matchers) ?? []
    actions = try container.decodeIfPresent([EmailRoutingRuleAction].self, forKey: .actions) ?? []
  }
}

/// Create / update body for a routing rule.
///
/// Deliberately carries no `source` and no `owner_worker_tag`: Dash must never
/// claim a rule as wrangler-managed, and a rule it did not create must not be
/// re-parented to a Worker by a round-trip.
public struct EmailRoutingRuleInput: Codable, Hashable, Sendable {
  public var matchers: [EmailRoutingRuleMatcher]
  public var actions: [EmailRoutingRuleAction]
  public var enabled: Bool?
  public var name: String?
  /// Hidden in the v1 UI, but round-tripped verbatim from the fetched rule so
  /// an edit never silently reorders the user's rules.
  public var priority: Int?

  public init(
    matchers: [EmailRoutingRuleMatcher], actions: [EmailRoutingRuleAction],
    enabled: Bool? = nil, name: String? = nil, priority: Int? = nil
  ) {
    self.matchers = matchers
    self.actions = actions
    self.enabled = enabled
    self.name = name
    self.priority = priority
  }
}

/// Update body for the catch-all rule. No `priority`, by design.
public struct EmailRoutingCatchAllInput: Codable, Hashable, Sendable {
  /// Always `[.init(type: "all")]` — the catch-all matches everything else.
  public var matchers: [EmailRoutingRuleMatcher]
  public var actions: [EmailRoutingRuleAction]
  public var enabled: Bool?
  public var name: String?

  public init(
    matchers: [EmailRoutingRuleMatcher] = [EmailRoutingRuleMatcher(type: "all")],
    actions: [EmailRoutingRuleAction], enabled: Bool? = nil, name: String? = nil
  ) {
    self.matchers = matchers
    self.actions = actions
    self.enabled = enabled
    self.name = name
  }
}

// MARK: - Destination addresses

/// An account-level destination address mail can be forwarded to.
///
/// `verified` is a **nullable ISO8601 timestamp, not a Bool** — null means the
/// user has not clicked the confirmation link yet, and mail to an unverified
/// address is dropped.
public struct EmailDestinationAddress: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let tag: String?
  public let email: String
  public let verified: String?
  public let created: String?
  public let modified: String?

  public var isVerified: Bool { verified != nil }

  public init(
    id: String, tag: String? = nil, email: String, verified: String? = nil,
    created: String? = nil, modified: String? = nil
  ) {
    self.id = id
    self.tag = tag
    self.email = email
    self.verified = verified
    self.created = created
    self.modified = modified
  }
}

// MARK: - DNS plan

/// One record in the DNS plan Email Routing needs on the zone apex.
public struct EmailRoutingDNSRecord: Codable, Hashable, Sendable {
  public let type: String?
  public let name: String?
  public let content: String?
  /// The schema types this as `number`; format at render (`1` -> "Automatic").
  public let ttl: Double?
  public let priority: Int?

  public init(
    type: String? = nil, name: String? = nil, content: String? = nil, ttl: Double? = nil,
    priority: Int? = nil
  ) {
    self.type = type
    self.name = name
    self.content = content
    self.ttl = ttl
    self.priority = priority
  }
}

/// The records Cloudflare will add (`records`) and the ones it reports absent
/// from the zone today (`missing`).
///
/// `GET /zones/{id}/email/routing/dns` is a `oneOf`: `result` is either a bare
/// array of records **or** `{ "errors": [{ "code", "missing" }], "record": [...] }`.
/// Both shapes decode. **Anything else throws** — it must not degrade to empty
/// arrays. An empty plan renders "Records Cloudflare will add: (nothing)" beside
/// an armed hold-to-confirm that replaces the zone's apex MX, and the
/// client-side conflict check compares against the plan, so an empty plan flags
/// either nothing or everything. Empty and failed are different answers.
public struct EmailRoutingDNSPlan: Decodable, Hashable, Sendable {
  public let records: [EmailRoutingDNSRecord]
  public let missing: [EmailRoutingDNSRecord]

  /// Nothing to show. A caller that reached this from a successful fetch still
  /// must not arm a destructive confirm on it.
  public var isEmpty: Bool { records.isEmpty && missing.isEmpty }

  public init(records: [EmailRoutingDNSRecord], missing: [EmailRoutingDNSRecord] = []) {
    self.records = records
    self.missing = missing
  }

  enum CodingKeys: String, CodingKey {
    case record, errors
  }

  public init(from decoder: any Decoder) throws {
    if let container = try? decoder.singleValueContainer(),
      let rows = try? container.decode([LossyElement<EmailRoutingDNSRecord>].self)
    {
      records = rows.compactMap(\.value)
      missing = []
      return
    }

    let container = try decoder.container(keyedBy: CodingKeys.self)
    let rows = try? container.decode([LossyElement<EmailRoutingDNSRecord>].self, forKey: .record)
    let errors = try? container.decode([LossyElement<PlanError>].self, forKey: .errors)
    guard rows != nil || errors != nil else {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(
          codingPath: container.codingPath,
          debugDescription:
            "Email Routing DNS plan was neither an array of records nor an object carrying "
            + "`record` or `errors`."))
    }
    records = (rows ?? []).compactMap(\.value)
    missing = (errors ?? []).compactMap(\.value).compactMap(\.missing)
  }

  struct PlanError: Decodable, Hashable, Sendable {
    // `code` has changed shape across examples and is not needed to render the
    // plan. Leaving it undecoded keeps a numeric legacy value or a future
    // structured value from dropping the load-bearing `missing` record.
    let missing: EmailRoutingDNSRecord?
  }
}

// MARK: - Endpoints

extension CloudflareClient {
  /// Zone Email Routing settings. Read scope: `zone-settings.read`.
  public func getEmailRoutingSettings(zoneID: String) async throws -> EmailRoutingSettings {
    try await request("/zones/\(zoneID)/email/routing")
  }

  /// Toggles plus addressing (`user+tag@example.com`).
  ///
  /// The body carries `support_subaddress` and nothing else: Cloudflare
  /// documents `enabled` on this PATCH as a **no-op**, and sending a no-op flag
  /// alongside a real one is how a screen ends up believing it turned routing
  /// off.
  @discardableResult
  public func updateEmailRoutingSubaddressing(zoneID: String, enabled: Bool) async throws
    -> EmailRoutingSettings
  {
    try await request(
      "/zones/\(zoneID)/email/routing", method: "PATCH", body: ["support_subaddress": enabled])
  }

  /// The MX / TXT records Email Routing needs, plus the ones Cloudflare reports
  /// missing from the zone today.
  public func getEmailRoutingDNSPlan(zoneID: String) async throws -> EmailRoutingDNSPlan {
    try await request("/zones/\(zoneID)/email/routing/dns")
  }

  /// Turns Email Routing on by letting Cloudflare add its DNS records.
  ///
  /// This replaces the zone's apex MX set. `POST .../enable` is deprecated;
  /// `/dns` is the documented path.
  @discardableResult
  public func enableEmailRouting(zoneID: String) async throws -> EmailRoutingSettings {
    try await request("/zones/\(zoneID)/email/routing/dns", method: "POST")
  }

  /// Turns Email Routing off by removing the records it added. Mail bounces
  /// until MX records point somewhere else; rules and addresses are kept.
  public func disableEmailRouting(zoneID: String) async throws {
    let _: JSONValue = try await request(
      "/zones/\(zoneID)/email/routing/dns", method: "DELETE")
  }

  /// One page of routing rules. A rule missing `id` is dropped by
  /// `LossyElement` rather than failing the page.
  public func listEmailRoutingRules(zoneID: String, page: Int = 1, perPage: Int = 50) async throws
    -> Page<EmailRoutingRule>
  {
    try await list(
      "/zones/\(zoneID)/email/routing/rules",
      query: ["page": String(page), "per_page": String(perPage)])
  }

  @discardableResult
  public func createEmailRoutingRule(zoneID: String, input: EmailRoutingRuleInput) async throws
    -> EmailRoutingRule
  {
    try await request("/zones/\(zoneID)/email/routing/rules", method: "POST", body: input)
  }

  @discardableResult
  public func updateEmailRoutingRule(
    zoneID: String, ruleID: String, input: EmailRoutingRuleInput
  ) async throws -> EmailRoutingRule {
    try await request("/zones/\(zoneID)/email/routing/rules/\(ruleID)", method: "PUT", body: input)
  }

  public func deleteEmailRoutingRule(zoneID: String, ruleID: String) async throws {
    let _: JSONValue = try await request(
      "/zones/\(zoneID)/email/routing/rules/\(ruleID)", method: "DELETE")
  }

  public func getEmailRoutingCatchAll(zoneID: String) async throws -> EmailRoutingCatchAllRule {
    try await request("/zones/\(zoneID)/email/routing/rules/catch_all")
  }

  @discardableResult
  public func updateEmailRoutingCatchAll(zoneID: String, input: EmailRoutingCatchAllInput)
    async throws -> EmailRoutingCatchAllRule
  {
    try await request(
      "/zones/\(zoneID)/email/routing/rules/catch_all", method: "PUT", body: input)
  }

  /// Every destination address on the account, verified or not.
  ///
  /// The endpoint's `verified` query parameter documents `default: true`, so a
  /// single naive GET can return only verified addresses — precisely the set
  /// this screen must not be limited to, since an unverified address is the one
  /// the user needs to be told about. Two sweeps, unioned by id, are correct
  /// under either reading of the parameter. `per_page` maxes at 50 here, not
  /// the usual 100.
  public func listEmailDestinationAddresses(accountID: String) async throws
    -> [EmailDestinationAddress]
  {
    let path = "/accounts/\(accountID)/email/routing/addresses"
    async let verified: [EmailDestinationAddress] = self.listAllPages(
      path, query: ["verified": "true"], perPage: 50)
    async let unverified: [EmailDestinationAddress] = self.listAllPages(
      path, query: ["verified": "false"], perPage: 50)

    let combined = try await verified + unverified
    var seen: Set<String> = []
    return combined.filter { seen.insert($0.id).inserted }
  }

  /// Adds a destination address. Cloudflare emails it a confirmation link; the
  /// address stays unverified — and drops mail — until that link is clicked.
  @discardableResult
  public func createEmailDestinationAddress(accountID: String, email: String) async throws
    -> EmailDestinationAddress
  {
    try await request(
      "/accounts/\(accountID)/email/routing/addresses", method: "POST", body: ["email": email])
  }
}
