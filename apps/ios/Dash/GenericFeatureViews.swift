import CloudflareAPI
import SwiftUI

extension Error {
  var dashActionableMessage: String {
    if let apiError = self as? CloudflareAPIError, apiError.isUnauthorized {
      return "Your Cloudflare session is no longer valid. Sign in again."
    }
    if let apiError = self as? CloudflareAPIError, apiError.isRateLimited {
      return "Rate limited by Cloudflare — wait a moment and try again."
    }
    if let apiError = self as? CloudflareAPIError, apiError.isForbidden {
      return (apiError.errorDescription ?? "Permission denied")
        + "\n\nThe granted scopes cover this module, so the account may not include this product or resource."
    }
    return localizedDescription
  }
}

struct GenericFeatureView: View {
  @Environment(AppModel.self) private var model
  let feature: FeatureID
  var body: some View {
    GenericResourcesView(title: feature.title, path: path)
  }

  private var path: String {
    let account = model.activeAccountID ?? ""
    return (FeatureCatalog.descriptor(for: feature).genericPath ?? "/accounts/{account}")
      .replacingOccurrences(of: "{account}", with: account)
  }
}

// MARK: - Generic editability

/// One field in a generic create form; `options` renders a menu instead of text.
struct GenericCreateField {
  let key: String
  let label: String
  var options: [String]?
  var optional = false

  init(_ key: String, _ label: String, options: [String]? = nil, optional: Bool = false) {
    self.key = key
    self.label = label
    self.options = options
    self.optional = optional
  }
}

struct GenericCreateSpec {
  let title: String
  let fields: [GenericCreateField]
  /// Builds the POST body from the entered field values.
  let body: ([String: String]) -> [String: JSONValue]
  /// When set, a successful create keeps the sheet open and shows this text
  /// (e.g. a one-time secret) instead of dismissing straight away.
  var revealResult: ((JSONValue) -> String?)?
}

/// A write on a single row (enable/disable, lock/unlock), rendered as a pill
/// under the row's detail fields. Set `confirmMessage` for high-impact toggles
/// that need a second tap; leave it nil for low-risk reversible writes.
struct GenericRowUpdate: Identifiable {
  let id: String
  let title: (GenericResource) -> String
  let method: String
  /// Builds the request path from the list's base path and the row.
  let path: (String, GenericResource) -> String
  let body: (GenericResource) -> [String: JSONValue]
  /// When set, the first tap shows this message and a Confirm button.
  var confirmMessage: ((GenericResource) -> String)? = nil
}

/// Exactly one focused decision inside a generic resource tray.
enum GenericDetailPhase: Equatable, Sendable {
  case details
  case delete
  case update(id: String)

  func title(for resourceName: String) -> String {
    switch self {
    case .details: resourceName
    case .delete: "Delete"
    case .update: "Confirm"
    }
  }
}

/// A high-risk action on the whole screen (header more-menu), e.g. redeploy or
/// delete-project on a Pages deployments list.
struct GenericScreenAction {
  let title: String
  var icon: String = SolarAsset.trash
  let message: String
  let method: String
  /// Builds the request path from the list's base path.
  let path: (String) -> String
  var dismissesAfter = false
}

/// What the generic resource screen can write for a given REST path. Every write
/// here rides an OAuth scope the app already requests — extend this registry as
/// more resources gain write support.
struct GenericResourceCapabilities {
  var create: GenericCreateSpec?
  /// Overrides the create POST path when it deviates from the list's base
  /// path (e.g. certificate packs order at `{base}/order`).
  var createPath: ((String) -> String)?
  /// Confirmation message for deleting a row; nil leaves the resource read-only.
  var deleteMessage: ((GenericResource) -> String)?
  /// Overrides the delete request path for endpoints that delete by something
  /// other than `{base}/{id}` (e.g. Pipelines delete by name).
  var deletePath: ((String, GenericResource) -> String)?
  var updates: [GenericRowUpdate] = []
  var screenActions: [GenericScreenAction] = []

  static func forPath(_ fullPath: String) -> GenericResourceCapabilities {
    let path = String(fullPath.split(separator: "?", maxSplits: 1)[0])
    var caps = GenericResourceCapabilities()

    if path.hasSuffix("/workers/routes") {
      caps.create = GenericCreateSpec(
        title: "New route",
        fields: [
          GenericCreateField("pattern", "Route pattern"),
          GenericCreateField("script", "Worker script"),
        ],
        body: { values in
          [
            "pattern": .string(values["pattern"] ?? ""),
            "script": .string(values["script"] ?? ""),
          ]
        })
      caps.deleteMessage = { "Permanently delete the route \($0.name)." }
    } else if path.hasSuffix("/firewall/access_rules/rules") {
      caps.create = GenericCreateSpec(
        title: "New access rule",
        fields: [
          GenericCreateField(
            "mode", "Action",
            options: ["block", "challenge", "js_challenge", "managed_challenge", "whitelist"]),
          GenericCreateField("value", "IP or CIDR"),
          GenericCreateField("notes", "Note", optional: true),
        ],
        body: { values in
          let value = values["value"] ?? ""
          var body: [String: JSONValue] = [
            "mode": .string(values["mode"] ?? "block"),
            "configuration": .object([
              "target": .string(value.contains("/") ? "ip_range" : "ip"),
              "value": .string(value),
            ]),
          ]
          if let notes = values["notes"], !notes.isEmpty { body["notes"] = .string(notes) }
          return body
        })
      caps.deleteMessage = { _ in "Permanently delete this access rule." }
    } else if path.hasSuffix("/email/routing/rules") {
      caps.create = GenericCreateSpec(
        title: "New forward rule",
        fields: [
          GenericCreateField("to", "Match address"),
          GenericCreateField("forward", "Forward to"),
        ],
        body: { values in
          let to = values["to"] ?? ""
          let forward = values["forward"] ?? ""
          return [
            "name": .string("Forward \(to)"),
            "enabled": .bool(true),
            "matchers": .array([
              .object([
                "type": .string("literal"), "field": .string("to"), "value": .string(to),
              ])
            ]),
            "actions": .array([
              .object(["type": .string("forward"), "value": .array([.string(forward)])])
            ]),
          ]
        })
      caps.deleteMessage = { "Permanently delete the rule \($0.name)." }
    } else if path.hasSuffix("/email/routing/addresses") {
      caps.create = GenericCreateSpec(
        title: "New address",
        fields: [GenericCreateField("email", "Email address")],
        body: { values in ["email": .string(values["email"] ?? "")] })
      caps.deleteMessage = { "Remove \($0.name) from destination addresses." }
    } else if path.hasSuffix("/load_balancers/pools") {
      caps.updates = [
        GenericRowUpdate(
          id: "toggle-enabled",
          title: { $0.bool("enabled") == false ? "Enable pool" : "Disable pool" },
          method: "PATCH",
          path: { "\($0)/\($1.id)" },
          body: { ["enabled": .bool(!($0.bool("enabled") ?? true))] },
          confirmMessage: {
            $0.bool("enabled") == false
              ? "Enable pool \($0.name)? Traffic can start routing to its origins."
              : "Disable pool \($0.name)? Load balancers stop using its origins."
          })
      ]
      caps.deleteMessage = {
        "Permanently delete the pool \($0.name). Load balancers stop using its origins."
      }
    } else if path.hasSuffix("/pagerules") {
      caps.updates = [
        GenericRowUpdate(
          id: "toggle-status",
          title: { $0.string("status") == "active" ? "Disable rule" : "Enable rule" },
          method: "PATCH",
          path: { "\($0)/\($1.id)" },
          body: {
            ["status": .string($0.string("status") == "active" ? "disabled" : "active")]
          },
          confirmMessage: {
            $0.string("status") == "active"
              ? "Disable this page rule? Matching requests stop applying its actions."
              : "Enable this page rule? Matching requests will apply its actions."
          })
      ]
      caps.deleteMessage = { _ in "Permanently delete this page rule." }
    } else if path.hasSuffix("/registrar/domains") {
      // Registrar updates go by domain name, not id, and only accept PUT.
      caps.updates = [
        GenericRowUpdate(
          id: "toggle-auto-renew",
          title: { $0.bool("auto_renew") == true ? "Disable auto-renew" : "Enable auto-renew" },
          method: "PUT",
          path: { "\($0)/\($1.name)" },
          body: { ["auto_renew": .bool(!($0.bool("auto_renew") ?? false))] }),
        GenericRowUpdate(
          id: "toggle-locked",
          title: { $0.bool("locked") == true ? "Unlock transfers" : "Lock transfers" },
          method: "PUT",
          path: { "\($0)/\($1.name)" },
          body: { ["locked": .bool(!($0.bool("locked") ?? false))] }),
      ]
    } else if path.hasSuffix("/cfd_tunnel") {
      caps.create = GenericCreateSpec(
        title: "New tunnel",
        fields: [GenericCreateField("name", "Tunnel name")],
        body: { values in
          // config_src cloudflare = remotely managed; no tunnel secret to mint.
          ["name": .string(values["name"] ?? ""), "config_src": .string("cloudflare")]
        })
      caps.deleteMessage = {
        "Permanently delete the tunnel \($0.name). Its connectors disconnect."
      }
    } else if path.hasSuffix("/challenges/widgets") {
      caps.create = GenericCreateSpec(
        title: "New widget",
        fields: [
          GenericCreateField("name", "Widget name"),
          GenericCreateField("domains", "Domains (comma-separated)"),
          GenericCreateField(
            "mode", "Mode", options: ["managed", "non-interactive", "invisible"]),
        ],
        body: { values in
          let domains = (values["domains"] ?? "")
            .split(separator: ",")
            .map { JSONValue.string($0.trimmingCharacters(in: .whitespaces)) }
          return [
            "name": .string(values["name"] ?? ""),
            "domains": .array(domains),
            "mode": .string(values["mode"] ?? "managed"),
          ]
        })
      caps.deleteMessage = {
        "Permanently delete the widget \($0.name). Its sitekey stops working."
      }
    } else if path.hasSuffix("/healthchecks") {
      caps.create = GenericCreateSpec(
        title: "New health check",
        fields: [
          GenericCreateField("name", "Name"),
          GenericCreateField("address", "Hostname or IP"),
          GenericCreateField("type", "Type", options: ["HTTPS", "HTTP", "TCP"]),
        ],
        body: { values in
          [
            "name": .string(values["name"] ?? ""),
            "address": .string(values["address"] ?? ""),
            "type": .string(values["type"] ?? "HTTPS"),
          ]
        })
      caps.updates = [
        GenericRowUpdate(
          id: "toggle-suspended",
          title: { $0.bool("suspended") == true ? "Resume checks" : "Suspend checks" },
          method: "PATCH",
          path: { "\($0)/\($1.id)" },
          body: { ["suspended": .bool(!($0.bool("suspended") ?? false))] },
          confirmMessage: {
            $0.bool("suspended") == true
              ? "Resume health checks for \($0.name)?"
              : "Suspend health checks for \($0.name)? Monitoring for this target pauses."
          })
      ]
      caps.deleteMessage = { "Permanently delete the health check \($0.name)." }
    } else if path.hasSuffix("/waiting_rooms") {
      caps.create = GenericCreateSpec(
        title: "New waiting room",
        fields: [
          GenericCreateField("name", "Name"),
          GenericCreateField("host", "Hostname"),
          GenericCreateField("total_active_users", "Total active users"),
          GenericCreateField("new_users_per_minute", "New users per minute"),
        ],
        body: { values in
          [
            "name": .string(values["name"] ?? ""),
            "host": .string(values["host"] ?? ""),
            "total_active_users": .number(Double(values["total_active_users"] ?? "") ?? 200),
            "new_users_per_minute": .number(Double(values["new_users_per_minute"] ?? "") ?? 200),
          ]
        })
      caps.updates = [
        GenericRowUpdate(
          id: "toggle-suspended",
          title: { $0.bool("suspended") == true ? "Resume room" : "Suspend room" },
          method: "PATCH",
          path: { "\($0)/\($1.id)" },
          body: { ["suspended": .bool(!($0.bool("suspended") ?? false))] },
          confirmMessage: {
            $0.bool("suspended") == true
              ? "Resume waiting room \($0.name)?"
              : "Suspend waiting room \($0.name)? Visitors stop entering the queue."
          })
      ]
      caps.deleteMessage = { "Permanently delete the waiting room \($0.name)." }
    } else if path.hasSuffix("/load_balancers") {
      caps.updates = [
        GenericRowUpdate(
          id: "toggle-enabled",
          title: { $0.bool("enabled") == false ? "Enable load balancer" : "Disable load balancer" },
          method: "PATCH",
          path: { "\($0)/\($1.id)" },
          body: { ["enabled": .bool(!($0.bool("enabled") ?? true))] },
          confirmMessage: {
            $0.bool("enabled") == false
              ? "Enable load balancer \($0.name)? Traffic starts following its pools."
              : "Disable load balancer \($0.name)? Traffic falls back to DNS."
          })
      ]
      caps.deleteMessage = {
        "Permanently delete the load balancer \($0.name). Traffic falls back to DNS."
      }
    } else if path.hasSuffix("/access/apps") {
      caps.create = GenericCreateSpec(
        title: "New Access app",
        fields: [
          GenericCreateField("name", "Application name"),
          GenericCreateField("domain", "Domain (e.g. app.example.com)"),
        ],
        body: { values in
          [
            "name": .string(values["name"] ?? ""),
            "domain": .string(values["domain"] ?? ""),
            "type": .string("self_hosted"),
          ]
        })
      caps.deleteMessage = {
        "Permanently delete the Access application \($0.name) and its policies."
      }
    } else if path.hasSuffix("/vectorize/v2/indexes") {
      caps.create = GenericCreateSpec(
        title: "New index",
        fields: [
          GenericCreateField("name", "Index name"),
          GenericCreateField("dimensions", "Dimensions"),
          GenericCreateField("metric", "Metric", options: ["cosine", "euclidean", "dot-product"]),
        ],
        body: { values in
          [
            "name": .string(values["name"] ?? ""),
            "config": .object([
              "dimensions": .number(Double(values["dimensions"] ?? "") ?? 768),
              "metric": .string(values["metric"] ?? "cosine"),
            ]),
          ]
        })
      caps.deleteMessage = { "Permanently delete the index \($0.name) and its vectors." }
    } else if path.hasSuffix("/secrets_store/stores") {
      caps.create = GenericCreateSpec(
        title: "New store",
        fields: [GenericCreateField("name", "Store name")],
        body: { values in ["name": .string(values["name"] ?? "")] })
      caps.deleteMessage = { "Permanently delete the store \($0.name) and its secrets." }
    } else if path.hasSuffix("/ai-gateway/gateways") {
      caps.create = GenericCreateSpec(
        title: "New gateway",
        fields: [GenericCreateField("id", "Gateway name")],
        body: { values in
          [
            "id": .string(values["id"] ?? ""),
            "collect_logs": .bool(true),
            "cache_invalidate_on_update": .bool(true),
            "cache_ttl": .number(0),
          ]
        })
      caps.deleteMessage = { "Permanently delete the gateway \($0.name) and its logs." }
    } else if path.hasSuffix("/hyperdrive/configs") {
      caps.deleteMessage = {
        "Permanently delete the Hyperdrive config \($0.name). Workers bound to it lose their connection."
      }
    } else if path.hasSuffix("/pipelines") {
      caps.deleteMessage = { "Permanently delete the pipeline \($0.name)." }
    } else if path.hasSuffix("/logpush/jobs") {
      caps.updates = [
        GenericRowUpdate(
          id: "toggle-enabled",
          title: { $0.bool("enabled") == false ? "Enable job" : "Disable job" },
          method: "PUT",
          path: { "\($0)/\($1.id)" },
          body: { ["enabled": .bool(!($0.bool("enabled") ?? true))] },
          confirmMessage: {
            $0.bool("enabled") == false
              ? "Enable this Logpush job (\($0.name))?"
              : "Disable this Logpush job (\($0.name))? Log delivery pauses."
          })
      ]
      caps.deleteMessage = { "Permanently delete this Logpush job (\($0.name))." }
    } else if path.hasSuffix("/dns_firewall") {
      caps.create = GenericCreateSpec(
        title: "New DNS Firewall cluster",
        fields: [
          GenericCreateField("name", "Cluster name"),
          GenericCreateField("upstreams", "Upstream IPs (comma-separated)"),
        ],
        body: { values in
          let upstreams = (values["upstreams"] ?? "")
            .split(separator: ",")
            .map { JSONValue.string($0.trimmingCharacters(in: .whitespaces)) }
          return [
            "name": .string(values["name"] ?? ""),
            "upstream_ips": .array(upstreams),
          ]
        })
      caps.deleteMessage = { "Permanently delete the DNS Firewall cluster \($0.name)." }
    } else if path.hasSuffix("/access/groups") {
      caps.deleteMessage = {
        "Permanently delete the Access group \($0.name). Policies referencing it stop matching."
      }
    } else if path.hasSuffix("/access/service_tokens") {
      caps.create = GenericCreateSpec(
        title: "New service token",
        fields: [GenericCreateField("name", "Token name")],
        body: { values in ["name": .string(values["name"] ?? "")] },
        revealResult: { result in
          guard case .object(let object) = result,
            case .string(let clientID)? = object["client_id"],
            case .string(let secret)? = object["client_secret"]
          else { return nil }
          return "CF-Access-Client-Id: \(clientID)\nCF-Access-Client-Secret: \(secret)"
        })
      caps.deleteMessage = {
        "Permanently delete the service token \($0.name). Clients using it lose access."
      }
    } else if path.hasSuffix("/gateway/rules") {
      caps.deleteMessage = { "Permanently delete the Gateway policy \($0.name)." }
    } else if path.hasSuffix("/rules/lists") {
      caps.create = GenericCreateSpec(
        title: "New list",
        fields: [
          GenericCreateField("name", "List name (letters, digits, _)"),
          GenericCreateField("kind", "Kind", options: ["ip", "hostname", "asn", "redirect"]),
        ],
        body: { values in
          [
            "name": .string(values["name"] ?? ""),
            "kind": .string(values["kind"] ?? "ip"),
          ]
        })
      caps.deleteMessage = { "Permanently delete the list \($0.name) and its items." }
    } else if path.hasSuffix("/snippets") {
      caps.deleteMessage = { "Permanently delete the snippet \($0.name)." }
    } else if path.hasSuffix("/web3/hostnames") {
      caps.create = GenericCreateSpec(
        title: "New Web3 gateway",
        fields: [
          GenericCreateField("name", "Hostname"),
          GenericCreateField("target", "Target", options: ["ipfs", "ethereum"]),
        ],
        body: { values in
          [
            "name": .string(values["name"] ?? ""),
            "target": .string(values["target"] ?? "ipfs"),
          ]
        })
      caps.deleteMessage = { "Permanently delete the Web3 gateway \($0.name)." }
    } else if path.hasSuffix("/queues") {
      caps.create = GenericCreateSpec(
        title: "New queue",
        fields: [GenericCreateField("name", "Queue name")],
        body: { values in ["queue_name": .string(values["name"] ?? "")] })
      caps.deleteMessage = { "Permanently delete the queue \($0.name) and its messages." }
    } else if path.hasSuffix("/dns_settings/views") {
      caps.create = GenericCreateSpec(
        title: "New DNS view",
        fields: [GenericCreateField("name", "View name")],
        body: { values in ["name": .string(values["name"] ?? ""), "zones": .array([])] })
      caps.deleteMessage = { "Permanently delete the DNS view \($0.name)." }
    } else if path.hasSuffix("/custom_hostnames") {
      caps.create = GenericCreateSpec(
        title: "New custom hostname",
        fields: [GenericCreateField("hostname", "Hostname")],
        body: { values in
          [
            "hostname": .string(values["hostname"] ?? ""),
            "ssl": .object([
              "method": .string("http"),
              "type": .string("dv"),
            ]),
          ]
        })
      caps.deleteMessage = {
        "Permanently delete the custom hostname \($0.name) and its certificate."
      }
    } else if path.hasSuffix("/custom_certificates") {
      caps.deleteMessage = { _ in
        "Permanently delete this custom certificate. Traffic falls back to universal SSL."
      }
    } else if path.hasSuffix("/ssl/certificate_packs") {
      caps.create = GenericCreateSpec(
        title: "Order certificate pack",
        fields: [
          GenericCreateField("hosts", "Hosts (comma-separated, must include the zone apex)"),
          GenericCreateField(
            "certificate_authority", "Certificate authority",
            options: ["lets_encrypt", "google", "ssl_com"]),
          GenericCreateField(
            "validation_method", "Validation method", options: ["txt", "http", "email"]),
          GenericCreateField(
            "validity_days", "Validity (days)", options: ["90", "30", "14", "365"]),
        ],
        body: { values in
          let hosts = (values["hosts"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
          return [
            "type": .string("advanced"),
            "hosts": .array(hosts.map(JSONValue.string)),
            "certificate_authority": .string(values["certificate_authority"] ?? "lets_encrypt"),
            "validation_method": .string(values["validation_method"] ?? "txt"),
            "validity_days": .number(Double(values["validity_days"] ?? "90") ?? 90),
          ]
        },
        revealResult: { result in
          guard case .object(let object) = result else { return nil }
          var lines: [String] = []
          if case .string(let id)? = object["id"] { lines.append("Order ID: \(id)") }
          if case .string(let status)? = object["status"] { lines.append("Status: \(status)") }
          return lines.isEmpty ? nil : lines.joined(separator: "\n")
        })
      caps.createPath = { "\($0)/order" }
      caps.deleteMessage = {
        "Permanently delete the certificate pack \($0.id). Hosts covered only by it lose HTTPS."
      }
    } else if path.hasSuffix("/calls/apps") {
      caps.create = GenericCreateSpec(
        title: "New app",
        fields: [GenericCreateField("name", "App name")],
        body: { values in ["name": .string(values["name"] ?? "")] })
      caps.deleteMessage = { "Permanently delete the Calls app \($0.name) and its tokens." }
    } else if path.hasSuffix("/calls/turn_keys") {
      caps.create = GenericCreateSpec(
        title: "New TURN key",
        fields: [GenericCreateField("name", "Key name")],
        body: { values in ["name": .string(values["name"] ?? "")] })
      caps.deleteMessage = {
        "Permanently delete the TURN key \($0.name). Clients using it lose TURN access."
      }
    } else if path.hasSuffix("/moq/relays") {
      caps.deleteMessage = { "Permanently delete the MoQ relay \($0.name)." }
    } else if path.hasSuffix("/warp_connector") {
      caps.deleteMessage = { "Permanently delete the WARP connector tunnel \($0.name)." }
    } else if path.hasSuffix("/teamnet/routes") {
      caps.deleteMessage = {
        "Permanently delete the route \($0.name). Traffic to it stops flowing through the tunnel."
      }
    } else if path.hasSuffix("/teamnet/virtual_networks") {
      caps.create = GenericCreateSpec(
        title: "New virtual network",
        fields: [
          GenericCreateField("name", "Network name"),
          GenericCreateField("comment", "Comment", optional: true),
        ],
        body: { values in
          var body: [String: JSONValue] = ["name": .string(values["name"] ?? "")]
          if let comment = values["comment"], !comment.isEmpty {
            body["comment"] = .string(comment)
          }
          return body
        })
      caps.deleteMessage = { "Permanently delete the virtual network \($0.name)." }
    } else if path.hasSuffix("/workers/observability/queries") {
      caps.deleteMessage = { "Permanently delete the saved query \($0.name)." }
    } else if path.hasSuffix("/workers/observability/destinations") {
      // Destinations delete by slug, not id.
      caps.deleteMessage = { "Permanently delete the destination \($0.name)." }
      caps.deletePath = { base, resource in
        "\(base)/\(resource.string("slug") ?? resource.id)"
      }
    } else if path.hasSuffix("/containers/applications") {
      caps.deleteMessage = {
        "Permanently delete the application \($0.name) and stop its instances."
      }
    } else if path.hasSuffix("/r2-catalog") {
      caps.updates = [
        GenericRowUpdate(
          id: "toggle-catalog",
          title: { $0.string("status") == "active" ? "Disable catalog" : "Enable catalog" },
          method: "POST",
          path: { "\($0)/\($1.name)/\($1.string("status") == "active" ? "disable" : "enable")" },
          body: { _ in [:] })
      ]
    } else if path.hasSuffix("/dex/devices/dex_tests") {
      caps.deleteMessage = { "Permanently delete the DEX test \($0.name)." }
    } else if path.hasSuffix("/email/sending/suppression") {
      caps.create = GenericCreateSpec(
        title: "New suppression",
        fields: [GenericCreateField("email", "Email address")],
        body: { values in ["email": .string(values["email"] ?? "")] })
      caps.deleteMessage = { "Remove \($0.name) from the suppression list." }
    } else if path.contains("/pages/projects/"), path.hasSuffix("/deployments") {
      caps.screenActions = [
        GenericScreenAction(
          title: "Redeploy latest",
          icon: SolarAsset.upload,
          message: "Start a new production deployment from the latest build.",
          method: "POST",
          path: { $0 }),
        GenericScreenAction(
          title: "Delete project",
          message: "Permanently delete this Pages project and all its deployments.",
          method: "DELETE",
          path: { String($0.dropLast("/deployments".count)) },
          dismissesAfter: true),
      ]
    }
    return caps
  }
}

extension GenericResource {
  fileprivate func bool(_ key: String) -> Bool? {
    if case .bool(let value)? = raw[key] { return value }
    return nil
  }

  fileprivate func string(_ key: String) -> String? {
    if case .string(let value)? = raw[key] { return value }
    return nil
  }
}

/// Declarative create form for a generic resource. When the spec asks to
/// reveal the result (one-time secrets), the sheet stays open showing it.
private struct GenericCreateSheet: View {
  let spec: GenericCreateSpec
  let onCreate: ([String: JSONValue]) async throws -> JSONValue
  @Environment(\.dashTrayDismiss) private var dismiss
  @State private var values: [String: String] = [:]
  @State private var error: String?
  @State private var saving = false
  @State private var revealed: String?

  private var canSave: Bool {
    spec.fields.allSatisfy { field in
      field.optional || !(values[field.key] ?? "").isEmpty
    }
  }

  var body: some View {
    if let revealed {
      VStack(alignment: .leading, spacing: 16) {
        DashNotice(
          kind: .warning,
          message: "Copy this now — Cloudflare will not show it again.")
        DashCodeBlock(text: revealed)
        DashTrayPillButton(title: "Copy and close") {
          UIPasteboard.general.string = revealed
          dismiss()
        }
      }
    } else {
      DashFormSheet(
        saveTitle: "Create",
        isSaving: saving,
        canSave: canSave,
        onSave: { Task { await save() } },
        content: {
          VStack(spacing: 14) {
            ForEach(spec.fields, id: \.key) { field in
              if let options = field.options {
                DashFormMenuField(
                  label: field.label,
                  selection: Binding(
                    get: { values[field.key] ?? options[0] },
                    set: { values[field.key] = $0 }),
                  options: options)
              } else {
                DashFormField(
                  label: field.label,
                  text: Binding(
                    get: { values[field.key] ?? "" },
                    set: { values[field.key] = $0 }))
              }
            }
            if let error {
              DashNotice(kind: .error, message: error)
            }
          }
        }
      )
      .onAppear {
        for field in spec.fields where values[field.key] == nil {
          if let options = field.options { values[field.key] = options[0] }
        }
      }
    }
  }

  private func save() async {
    saving = true
    error = nil
    do {
      let result = try await onCreate(spec.body(values))
      UINotificationFeedbackGenerator().notificationOccurred(.success)
      if let reveal = spec.revealResult, let text = reveal(result) {
        revealed = text
      } else {
        dismiss()
      }
    } catch { self.error = error.dashActionableMessage }
    saving = false
  }
}

struct GenericResourcesView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismissScreen
  @Environment(\.featureAllowsWrites) private var featureAllowsWrites
  let title: String
  let path: String
  @State private var resources: [GenericResource] = []
  @State private var selected: GenericResource?
  @State private var error: String?
  @State private var loading = true
  @State private var loadingMore = false
  @State private var pageInfo: ResultInfo?
  @State private var creates = false
  @State private var deleting = false
  @State private var deleteError: String?
  @State private var showsMore = false
  @State private var updatingID: String?
  @State private var updateError: String?
  @State private var detailPhase: GenericDetailPhase = .details

  private var capabilities: GenericResourceCapabilities {
    var capabilities = GenericResourceCapabilities.forPath(path)
    if !featureAllowsWrites {
      capabilities.create = nil
      capabilities.createPath = nil
      capabilities.deleteMessage = nil
      capabilities.deletePath = nil
      capabilities.updates = []
      capabilities.screenActions = []
    }
    return capabilities
  }
  private var basePath: String { String(path.split(separator: "?", maxSplits: 1)[0]) }

  /// Pagination stays strictly result_info-driven: the first load never sends
  /// page params, and Load more appears only when the endpoint reported
  /// page/per_page/total_count and more rows remain.
  private var canLoadMore: Bool {
    guard let info = pageInfo, let total = info.totalCount,
      info.page != nil, info.perPage != nil
    else { return false }
    return resources.count < total
  }

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      hasContent: !resources.isEmpty,
      retry: { Task { await load() } }
    ) {
      if resources.isEmpty {
        DashEmptyState(
          icon: SolarAsset.inbox,
          title: "Nothing here yet",
          message: capabilities.create != nil
            ? "Create one with the add button."
            : "Cloudflare returned no resources for this account."
        )
      } else {
        DashListCard {
          DashListCardRows(items: resources) { resource in
            Button {
              updateError = nil
              deleteError = nil
              selected = resource
            } label: {
              DashListRow(
                title: resource.name,
                subtitle: resource.detail,
                icon: SolarAsset.cloud,
                showsChevron: false
              )
            }
            .buttonStyle(DashPressButtonStyle())
          }
        }
      }
      if canLoadMore {
        DashLoadMoreFooter(
          loaded: resources.count,
          total: pageInfo?.totalCount,
          noun: "resources",
          isLoading: loadingMore
        ) { Task { await loadMore() } }
      }
    }
    .navigationTitle(title)
    .toolbar {
      if let create = capabilities.create {
        ToolbarItem(placement: .topBarTrailing) {
          DashToolbarIconButton(asset: SolarAsset.plus, accessibilityLabel: create.title) {
            creates = true
          }
        }
        .dashSeparateToolbarBackground()
      }
      if !capabilities.screenActions.isEmpty {
        ToolbarItem(placement: .topBarTrailing) {
          DashMoreButton(isPresented: $showsMore)
        }
        .dashSeparateToolbarBackground()
      }
    }
    .dashTray(
      item: $selected,
      title: { $0.name },
      content: { resource in
        genericDetailTray(resource)
          .dashTrayTitle(detailPhase.title(for: resource.name))
      }
    )
    .onChange(of: selected?.id) { _, _ in
      detailPhase = .details
      updateError = nil
      deleteError = nil
    }
    .dashTray(isPresented: $creates, title: capabilities.create?.title ?? "New") {
      if let spec = capabilities.create {
        GenericCreateSheet(spec: spec) { body in
          let target = capabilities.createPath?(basePath) ?? basePath
          let result = try await model.client.mutate(path: target, method: "POST", body: body)
          await invalidateAndReload()
          return result
        }
      }
    }
    .dashMoreMenu(
      isPresented: $showsMore,
      title: title,
      actions: capabilities.screenActions.map { action in
        DashDangerAction(title: action.title, icon: action.icon, message: action.message) {
          try await perform(action)
        }
      }
    )
    .refreshable { await load(force: true) }.task { await load() }
  }

  @ViewBuilder
  private func genericDetailTray(_ resource: GenericResource) -> some View {
    let deleteMessage = capabilities.deleteMessage?(resource)
    let confirming = detailPhase != .details
    let confirmMessage: String? = {
      switch detailPhase {
      case .details: nil
      case .delete: deleteMessage
      case .update(let id):
        capabilities.updates.first { $0.id == id }?.confirmMessage?(resource)
      }
    }()

    DashConfirmMorph(
      confirming: Binding(
        get: { confirming },
        set: { active in
          if !active {
            withAnimation(DashTheme.Motion.morph) { detailPhase = .details }
          }
        }
      ),
      message: confirmMessage,
      isBusy: deleting || updatingID != nil,
      actionTitle: nil,
      confirmingActionTitle: {
        switch detailPhase {
        case .update(let id):
          capabilities.updates.first { $0.id == id }?.title(resource) ?? "Confirm"
        case .delete: "Delete"
        case .details: "Confirm"
        }
      }(),
      confirmingActionRole: .destructive,
      actionEnabled: true,
      errorMessage: {
        switch detailPhase {
        case .delete: deleteError
        case .update: updateError
        case .details: nil
        }
      }(),
      action: {
        switch detailPhase {
        case .delete:
          Task { await delete(resource) }
        case .update(let id):
          if let update = capabilities.updates.first(where: { $0.id == id }) {
            Task { await perform(update, on: resource) }
          }
        case .details:
          break
        }
      },
      headerDelete: false
    ) {
      VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(resource.detailFields.enumerated()), id: \.offset) { index, field in
            detailFieldRow(field)
            if index < resource.detailFields.count - 1 { DashListGroupDivider() }
          }
        }

        if !capabilities.updates.isEmpty {
          VStack(spacing: 10) {
            ForEach(capabilities.updates) { update in
              DashTrayPillButton(
                title: update.title(resource),
                isLoading: updatingID == update.id
              ) {
                if update.confirmMessage != nil {
                  updateError = nil
                  UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                  withAnimation(DashTheme.Motion.morph) { detailPhase = .update(id: update.id) }
                } else {
                  Task { await perform(update, on: resource) }
                }
              }
            }
          }
          .padding(.top, 12)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .dashTrayHeaderAction(
      deleteMessage != nil && detailPhase == .details
        ? DashSheetHeaderAction(
          id: "delete", icon: SolarAsset.trash, accessibilityLabel: "Delete"
        ) {
          deleteError = nil
          UIImpactFeedbackGenerator(style: .medium).impactOccurred()
          withAnimation(DashTheme.Motion.morph) { detailPhase = .delete }
        }
        : nil
    )
  }

  private func detailFieldRow(_ field: DashDetailField) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(field.label)
        .dashTextStyle(.footnoteSemibold)
        .foregroundStyle(DashTheme.subtle)
      Text(field.value)
        .dashTextStyle(field.mono ? .code : .supporting)
        .foregroundStyle(DashTheme.text)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func delete(_ resource: GenericResource) async {
    deleting = true
    deleteError = nil
    let path = capabilities.deletePath?(basePath, resource) ?? "\(basePath)/\(resource.id)"
    do {
      _ = try await model.client.mutate(path: path, method: "DELETE")
      UINotificationFeedbackGenerator().notificationOccurred(.success)
      selected = nil
      await invalidateAndReload()
    } catch {
      deleteError = error.dashActionableMessage
      UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
    deleting = false
  }

  private func perform(_ update: GenericRowUpdate, on resource: GenericResource) async {
    updatingID = update.id
    updateError = nil
    do {
      _ = try await model.client.mutate(
        path: update.path(basePath, resource), method: update.method,
        body: update.body(resource))
      UINotificationFeedbackGenerator().notificationOccurred(.success)
      detailPhase = .details
      selected = nil
      await invalidateAndReload()
    } catch {
      updateError = error.dashActionableMessage
      UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
    updatingID = nil
  }

  private func perform(_ action: GenericScreenAction) async throws {
    _ = try await model.client.mutate(path: action.path(basePath), method: action.method)
    UINotificationFeedbackGenerator().notificationOccurred(.success)
    if action.dismissesAfter {
      model.featureCache.remove(FeatureCacheKey.generic(path: path))
      dismissScreen()
    } else {
      await invalidateAndReload()
    }
  }

  private func invalidateAndReload() async {
    model.featureCache.remove(FeatureCacheKey.generic(path: path))
    await load(force: true)
  }

  private func load(force: Bool = false) async {
    let key = FeatureCacheKey.generic(path: path)
    if !force, let cached: [GenericResource] = model.featureCache.get(key) {
      resources = cached
      loading = false
      error = nil
      return
    }
    if resources.isEmpty { loading = true }
    error = nil
    do {
      pageInfo = nil
      let result = try await model.client.listResources(
        path: basePath, query: embeddedQuery())
      resources = result.items
      pageInfo = result.resultInfo
      model.featureCache.set(key, resources)
    } catch {
      self.error = error.dashActionableMessage
    }
    loading = false
  }

  private func loadMore() async {
    guard !loadingMore, let info = pageInfo, let page = info.page, let perPage = info.perPage
    else { return }
    loadingMore = true
    defer { loadingMore = false }
    do {
      var query = embeddedQuery()
      query["page"] = String(page + 1)
      query["per_page"] = String(perPage)
      let result = try await model.client.listResources(path: basePath, query: query)
      resources += result.items
      // A page without result_info ends pagination instead of re-looping it.
      pageInfo = result.resultInfo
      model.featureCache.set(FeatureCacheKey.generic(path: path), resources)
      error = nil
    } catch {
      self.error = error.dashActionableMessage
    }
  }

  private func embeddedQuery() -> [String: String?] {
    let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
    var query: [String: String?] = [:]
    if parts.count == 2, let queryItems = URLComponents(string: "?\(parts[1])")?.queryItems {
      for item in queryItems { query[item.name] = item.value }
    }
    return query
  }
}
