import Foundation

// Zone rulesets: read a phase's rules, and turn one rule on or off.
//
// Dash does not edit rules. The only write is `enabled`, and it goes through
// the single-rule PATCH rather than a PUT of the whole entry point: a PUT
// replaces every rule in the phase, so a toggle would silently undo whatever
// someone changed in the dashboard since this screen loaded.

/// The two phases Dash shows. Each answers to its own permission — Single
/// Redirects to Dynamic URL Redirects, custom rules to Zone WAF.
public enum RulesetPhase: String, CaseIterable, Hashable, Sendable {
  case dynamicRedirect = "http_request_dynamic_redirect"
  case customFirewall = "http_request_firewall_custom"
}

/// One rule, kept exactly as Cloudflare returned it.
///
/// The single-rule PATCH is a replacement, not a merge: a field left out of the
/// body is a field removed from the rule. So the rule carries its whole JSON
/// object — action parameters, rate limits, logging, and any field this client
/// has never heard of — and `updateBody(enabled:)` sends all of it back with
/// one value changed.
public struct RulesetRule: Codable, Hashable, Identifiable, Sendable {
  public let fields: [String: JSONValue]

  public init(fields: [String: JSONValue]) {
    self.fields = fields
  }

  public init(from decoder: any Decoder) throws {
    fields = try decoder.singleValueContainer().decode([String: JSONValue].self)
    guard case .string = fields["id"] else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "A ruleset rule needs an id."))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(fields)
  }

  public var id: String { string("id") ?? "" }
  public var action: String? { string("action") }
  public var expression: String? { string("expression") }
  public var lastUpdated: String? { string("last_updated") }

  /// The name the dashboard shows. The API calls it `description`.
  public var name: String? {
    guard let text = string("description")?.trimmingCharacters(in: .whitespacesAndNewlines),
      !text.isEmpty
    else { return nil }
    return text
  }

  /// Cloudflare omits `enabled` for a rule that is on.
  public var isEnabled: Bool {
    if case .bool(let value) = fields["enabled"] { return value }
    return true
  }

  /// A redirect rule's target: a fixed URL, or the expression that builds one.
  public var redirectTarget: (value: String, isExpression: Bool)? {
    guard case .object(let target) = fromValue?["target_url"] else { return nil }
    if case .string(let url) = target["value"] { return (url, false) }
    if case .string(let expression) = target["expression"] { return (expression, true) }
    return nil
  }

  public var redirectStatusCode: Int? {
    guard case .number(let code) = fromValue?["status_code"] else { return nil }
    return Int(code)
  }

  /// The same rule with `enabled` set — what the screen shows while the
  /// request is in flight.
  public func settingEnabled(_ enabled: Bool) -> RulesetRule {
    var fields = fields
    fields["enabled"] = .bool(enabled)
    return RulesetRule(fields: fields)
  }

  /// The PATCH body: everything Cloudflare returned, minus the two fields it
  /// computes itself, with `enabled` set.
  public func updateBody(enabled: Bool) -> [String: JSONValue] {
    var body = fields
    for key in Self.serverOwnedFields { body.removeValue(forKey: key) }
    body["enabled"] = .bool(enabled)
    return body
  }

  static let serverOwnedFields: Set<String> = ["version", "last_updated"]

  private func string(_ key: String) -> String? {
    if case .string(let value) = fields[key] { return value }
    return nil
  }

  private var fromValue: [String: JSONValue]? {
    guard case .object(let parameters) = fields["action_parameters"],
      case .object(let fromValue) = parameters["from_value"]
    else { return nil }
    return fromValue
  }
}

/// A phase's entry point ruleset.
public struct ZoneRuleset: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let name: String?
  public let phase: String?
  public let version: String?
  public let rules: [RulesetRule]

  public init(
    id: String, name: String? = nil, phase: String? = nil, version: String? = nil,
    rules: [RulesetRule] = []
  ) {
    self.id = id
    self.name = name
    self.phase = phase
    self.version = version
    self.rules = rules
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, phase, version, rules
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    name = try container.decodeIfPresent(String.self, forKey: .name)
    phase = try container.decodeIfPresent(String.self, forKey: .phase)
    version = try container.decodeIfPresent(String.self, forKey: .version)
    // Cloudflare omits `rules` for an entry point that has none.
    rules = try container.decodeIfPresent([RulesetRule].self, forKey: .rules) ?? []
  }
}

extension CloudflareClient {
  /// The zone's entry point ruleset for a phase, or nil when the zone has none
  /// — Cloudflare answers 404 until the first rule is created, which is an
  /// answer ("no rules"), not a failure.
  public func getZoneEntrypointRuleset(zoneID: String, phase: RulesetPhase) async throws
    -> ZoneRuleset?
  {
    do {
      return try await request(
        "/zones/\(zoneID)/rulesets/phases/\(phase.rawValue)/entrypoint")
    } catch CloudflareAPIError.request(status: 404, _) {
      return nil
    }
  }

  /// Turns one rule on or off and returns the ruleset as Cloudflare now has it.
  public func setZoneRulesetRuleEnabled(
    zoneID: String, rulesetID: String, rule: RulesetRule, enabled: Bool
  ) async throws -> ZoneRuleset {
    try await request(
      "/zones/\(zoneID)/rulesets/\(rulesetID)/rules/\(rule.id)",
      method: "PATCH",
      body: rule.updateBody(enabled: enabled))
  }
}
