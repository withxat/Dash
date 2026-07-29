import Foundation

// Cloudflare Tunnel (Zero Trust), read-only.
//
// The OpenAPI schema types the results of `/cfd_tunnel`, `/connections`,
// `/teamnet/routes` and `/teamnet/virtual_networks` as
// `anyOf[object, array, string]` — Cloudflare publishes no typed contract for
// any of them. So: every field optional, every list element through
// `LossyElement`, and no Cloudflare enum decoded straight into a Swift enum.
// An unknown value from Cloudflare must degrade one row, never blank a screen.

// MARK: - Tunnel

/// Where a tunnel sits between "serving traffic" and "nobody is connected".
///
/// Cloudflare documents `healthy` / `degraded` / `down` / `inactive` today but
/// publishes no enum, so this is derived from the raw string and anything
/// unrecognised is `.unknown` — **never** `.healthy`. Guessing green is the
/// failure direction that matters: a tunnel Dash paints healthy while it is
/// down is worse than one badged "Unknown".
public enum TunnelHealth: Hashable, Sendable {
  case healthy
  case degraded
  case down
  case inactive
  case unknown

  public init(status: String?) {
    switch status?.lowercased() {
    case "healthy": self = .healthy
    case "degraded": self = .degraded
    case "down": self = .down
    case "inactive": self = .inactive
    default: self = .unknown
    }
  }
}

/// Whether a tunnel's ingress rules live in Cloudflare or in `cloudflared`'s
/// own configuration file on the origin machine.
///
/// This is the whole answer to the locally-vs-remotely-managed problem: Dash
/// only calls `GET /configurations` when this resolves to `.cloudflare`, so
/// that endpoint's local-tunnel response shape never has to be trusted.
public enum TunnelConfigSource: String, Codable, Sendable {
  case local
  case cloudflare

  /// `config_src` wins when it is one of the two documented values; otherwise
  /// the older `remote_config` boolean is consulted. Everything else falls to
  /// `.local`, which shows the honest "managed on the origin machine" card
  /// rather than an empty hostname list.
  public static func resolve(configSrc: String?, remoteConfig: Bool?) -> TunnelConfigSource {
    switch configSrc?.lowercased() {
    case "cloudflare": return .cloudflare
    case "local": return .local
    default: return remoteConfig == true ? .cloudflare : .local
    }
  }
}

/// One live `cloudflared` connection to a Cloudflare edge colo.
public struct TunnelConnection: Codable, Hashable, Sendable {
  public let id: String?
  public let clientID: String?
  public let clientVersion: String?
  public let coloName: String?
  public let openedAt: String?
  public let originIP: String?
  public let uuid: String?
  public let isPendingReconnect: Bool?

  enum CodingKeys: String, CodingKey {
    case id, uuid
    case clientID = "client_id"
    case clientVersion = "client_version"
    case coloName = "colo_name"
    case openedAt = "opened_at"
    case originIP = "origin_ip"
    case isPendingReconnect = "is_pending_reconnect"
  }
}

/// One `cloudflared` process serving a tunnel
/// (`GET /accounts/{id}/cfd_tunnel/{tunnel_id}/connections`).
public struct TunnelConnector: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let arch: String?
  public let version: String?
  public let runAt: String?
  public let configVersion: Int?
  public let features: [String]?
  public let conns: [TunnelConnection]?

  enum CodingKeys: String, CodingKey {
    case id, arch, version, features, conns
    case runAt = "run_at"
    case configVersion = "config_version"
  }
}

/// One Cloudflare Tunnel (`GET /accounts/{id}/cfd_tunnel`).
///
/// `tun_type` is kept faithful to the wire rather than filtered in the package:
/// the view drops everything that is not `cfd_tunnel` (magic / ip_sec / gre /
/// cni belong to Magic WAN), so a future WARP-Connector screen needs no change
/// down here.
public struct CloudflareTunnel: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let accountTag: String?
  public let name: String?
  public let createdAt: String?
  public let deletedAt: String?
  public let connsActiveAt: String?
  public let connsInactiveAt: String?
  /// `status` on the wire. Read it through `health`, never by comparing raw
  /// strings at a call site.
  public let statusRaw: String?
  /// `tun_type` on the wire. No enum — see the type note above.
  public let tunTypeRaw: String?
  /// `config_src` on the wire. Read it through `configSource`.
  public let configSrcRaw: String?
  public let remoteConfig: Bool?
  public let connections: [TunnelConnection]?

  public var health: TunnelHealth { TunnelHealth(status: statusRaw) }

  public var configSource: TunnelConfigSource {
    TunnelConfigSource.resolve(configSrc: configSrcRaw, remoteConfig: remoteConfig)
  }

  /// A deleted tunnel keeps answering on `GET /cfd_tunnel/{id}` forever, so the
  /// list query asks for live ones and this stays available for the detail path.
  public var isDeleted: Bool { deletedAt != nil }

  enum CodingKeys: String, CodingKey {
    case id, name, connections
    case accountTag = "account_tag"
    case createdAt = "created_at"
    case deletedAt = "deleted_at"
    case connsActiveAt = "conns_active_at"
    case connsInactiveAt = "conns_inactive_at"
    case statusRaw = "status"
    case tunTypeRaw = "tun_type"
    case configSrcRaw = "config_src"
    case remoteConfig = "remote_config"
  }
}

// MARK: - Remote configuration

/// The Access requirement `cloudflared` enforces in front of an origin.
///
/// These keys are **already camelCase on the wire**: this object is
/// `cloudflared`'s own config vocabulary, not Cloudflare's REST snake_case.
/// Do not add a converter.
public struct TunnelAccessRequirement: Codable, Hashable, Sendable {
  public let required: Bool?
  public let teamName: String?
  public let audTag: [String]?
}

/// Only the one key Dash reads. The other ~14 `originRequest` keys are origin
/// tuning (timeouts, TLS, HTTP host header) that no screen shows, and decoding
/// them would be surface with no reader.
public struct TunnelOriginRequest: Codable, Hashable, Sendable {
  public let access: TunnelAccessRequirement?
}

/// One ingress rule from a remotely-managed tunnel's configuration document.
public struct TunnelIngressRule: Codable, Hashable, Sendable {
  public let hostname: String?
  public let path: String?
  public let service: String?
  public let originRequest: TunnelOriginRequest?

  /// `cloudflared` requires a final rule with no hostname; it is the "everything
  /// else" fallback, not a public hostname.
  public var isCatchAll: Bool { (hostname ?? "").isEmpty }
}

/// `warp-routing` is deliberately not modelled: it is deprecated, `readOnly`,
/// and ignored by `cloudflared` since 2023.10.0.
public struct TunnelConfigBody: Codable, Hashable, Sendable {
  public let ingress: [TunnelIngressRule]?
  public let originRequest: TunnelOriginRequest?
}

/// `GET /accounts/{id}/cfd_tunnel/{tunnel_id}/configurations`.
///
/// `config` **must** stay optional: a locally-managed tunnel answers
/// `{"source":"local","config":null}` with a 200, and a non-optional `config`
/// would turn that into a decode failure on a perfectly healthy tunnel.
public struct TunnelConfiguration: Codable, Hashable, Sendable {
  public let tunnelID: String?
  public let accountID: String?
  /// `source` on the wire. Read it through `configSource`.
  public let sourceRaw: String?
  public let createdAt: String?
  public let version: Int?
  public let config: TunnelConfigBody?

  public var configSource: TunnelConfigSource {
    TunnelConfigSource.resolve(configSrc: sourceRaw, remoteConfig: nil)
  }

  enum CodingKeys: String, CodingKey {
    case version, config
    case tunnelID = "tunnel_id"
    case accountID = "account_id"
    case sourceRaw = "source"
    case createdAt = "created_at"
  }
}

// MARK: - Private networks

/// One private-network route advertised through a tunnel
/// (`GET /accounts/{id}/teamnet/routes`).
public struct TunnelRoute: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let network: String?
  public let tunnelID: String?
  public let tunnelName: String?
  public let comment: String?
  public let createdAt: String?
  public let deletedAt: String?
  public let virtualNetworkID: String?

  enum CodingKeys: String, CodingKey {
    case id, network, comment
    case tunnelID = "tunnel_id"
    case tunnelName = "tunnel_name"
    case createdAt = "created_at"
    case deletedAt = "deleted_at"
    case virtualNetworkID = "virtual_network_id"
  }
}

/// A Zero Trust virtual network, used only to name a route's VNET when the
/// account has more than one.
public struct TunnelVirtualNetwork: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let name: String?
  public let comment: String?
  public let createdAt: String?
  public let deletedAt: String?
  public let isDefaultNetwork: Bool?

  enum CodingKeys: String, CodingKey {
    case id, name, comment
    case createdAt = "created_at"
    case deletedAt = "deleted_at"
    case isDefaultNetwork = "is_default_network"
  }
}

// MARK: - Access

/// One Access application (`GET /accounts/{id}/access/apps`).
///
/// `policies` is intentionally not decoded — that omission is what keeps this
/// call cheap. Dash reads exactly one thing from it: whether a tunnel hostname
/// sits behind Access, which is a positive-only claim.
public struct AccessApplication: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let name: String?
  public let domain: String?
  public let type: String?
  public let aud: String?
  public let destinations: [AccessDestination]?
}

public struct AccessDestination: Codable, Hashable, Sendable {
  public let type: String?
  public let uri: String?
}

// MARK: - Endpoints

extension CloudflareClient {
  /// Tunnels for an account, live ones only.
  ///
  /// `is_deleted=false` is sent explicitly because the endpoint's default
  /// returns deleted tunnels too. The loop stops on `total_count`,
  /// `total_pages`, a short or empty page, a page that adds nothing new, or
  /// `maxPages` — the last of which bounds a broken `result_info` at
  /// `perPage × maxPages` rows instead of looping forever.
  public func listTunnels(
    accountID: String, perPage: Int = 50, maxPages: Int = 5
  ) async throws -> [CloudflareTunnel] {
    var tunnels: [CloudflareTunnel] = []
    var seenIDs: Set<String> = []
    var pageNumber = 1

    while pageNumber <= max(maxPages, 1) {
      let page: Page<CloudflareTunnel> = try await list(
        "/accounts/\(accountID)/cfd_tunnel",
        query: [
          "is_deleted": "false",
          "page": String(pageNumber),
          "per_page": String(perPage),
        ])
      let newItems = page.items.filter { seenIDs.insert($0.id).inserted }
      tunnels.append(contentsOf: newItems)

      if page.items.isEmpty || newItems.isEmpty { break }
      if let totalCount = page.resultInfo?.totalCount, tunnels.count >= totalCount { break }
      if let totalPages = page.resultInfo?.totalPages, pageNumber >= totalPages { break }
      if page.items.count < (page.resultInfo?.perPage ?? perPage) { break }
      pageNumber += 1
    }

    return tunnels
  }

  /// One tunnel by id, for a detail screen opened without a cached list entry
  /// (a deep link, or a list the cache has since dropped).
  public func getTunnel(accountID: String, tunnelID: String) async throws -> CloudflareTunnel {
    try await request("/accounts/\(accountID)/cfd_tunnel/\(tunnelID)")
  }

  /// The `cloudflared` processes currently serving a tunnel. The endpoint
  /// returns the whole set in one body; there is nothing to paginate.
  public func listTunnelConnectors(accountID: String, tunnelID: String) async throws
    -> [TunnelConnector]
  {
    try await list("/accounts/\(accountID)/cfd_tunnel/\(tunnelID)/connections").items
  }

  /// The remotely-managed configuration document.
  ///
  /// Call this **only** when `TunnelConfigSource.resolve(…) == .cloudflare`. A
  /// locally-managed tunnel answers 200 with `config: null`, which decodes
  /// fine but says nothing — the honest card is the right answer there, not an
  /// empty hostname list.
  public func getTunnelConfiguration(accountID: String, tunnelID: String) async throws
    -> TunnelConfiguration
  {
    try await request("/accounts/\(accountID)/cfd_tunnel/\(tunnelID)/configurations")
  }

  /// Private-network routes, optionally narrowed to one tunnel. Deleted routes
  /// are excluded server-side.
  public func listTunnelRoutes(
    accountID: String, tunnelID: String? = nil, perPage: Int = 50
  ) async throws -> [TunnelRoute] {
    try await listAllPages(
      "/accounts/\(accountID)/teamnet/routes",
      query: ["is_deleted": "false", "tunnel_id": tunnelID],
      perPage: perPage)
  }

  /// Virtual networks for the account. One page is deliberate: this list exists
  /// only to name a route's VNET when there is more than one, and an account
  /// with over 50 virtual networks loses a subtitle, not a screen.
  public func listTunnelVirtualNetworks(accountID: String) async throws
    -> [TunnelVirtualNetwork]
  {
    try await list(
      "/accounts/\(accountID)/teamnet/virtual_networks",
      query: ["is_deleted": "false", "per_page": "50"]
    ).items
  }

  /// Access applications, used for the positive-only `Protected` badge on a
  /// tunnel's public hostnames.
  public func listAccessApplications(accountID: String, perPage: Int = 50) async throws
    -> [AccessApplication]
  {
    try await listAllPages(
      "/accounts/\(accountID)/access/apps",
      perPage: perPage)
  }
}
