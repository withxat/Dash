import Foundation
import Testing

@testable import CloudflareAPI

/// Zero Trust / Cloudflare Tunnel, read-only.
///
/// Every test here lives in `extension NetworkTests` so it inherits that
/// suite's `.serialized` trait — `MockURLProtocol` keeps its handler in
/// `nonisolated(unsafe) static` state, and a second suite would race it. Every
/// function is prefixed `tunnel…` so `--filter tunnel` selects the whole set
/// (`--filter` matches test function names, not file names).
extension NetworkTests {

  // MARK: - Listing

  @Test func tunnelListSendsIsDeletedFalseAndStopsOnTotalCount() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let recorder = RequestRecorder()
    let session = mockSession { request in
      let query = tunnelQuery(request)
      recorder.record(query["page"] ?? "?")
      // Deleted tunnels keep answering forever; the default is to include them.
      #expect(query["is_deleted"] == "false")
      #expect(request.url?.path == "/accounts/acc/cfd_tunnel")
      if query["page"] == "1" {
        return (
          200,
          Data(
            #"""
            {"success":true,"result":[
              {"id":"t1","name":"office","status":"healthy","tun_type":"cfd_tunnel",
               "config_src":"cloudflare","remote_config":true,
               "created_at":"2026-01-02T03:04:05Z","conns_active_at":"2026-07-01T00:00:00Z",
               "connections":[{"id":"c1","colo_name":"IAD","origin_ip":"203.0.113.10",
                               "client_version":"2026.6.1","is_pending_reconnect":false}]},
              {"id":"t2","name":"lab","status":"degraded","tun_type":"cfd_tunnel"}
            ],"result_info":{"page":1,"per_page":2,"total_count":3}}
            """#.utf8)
        )
      }
      return (
        200,
        Data(
          #"""
          {"success":true,"result":[
            {"id":"t3","name":"magic","status":"inactive","tun_type":"magic"}
          ],"result_info":{"page":2,"per_page":2,"total_count":3}}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let tunnels = try await client.listTunnels(accountID: "acc", perPage: 2)

    #expect(recorder.paths == ["1", "2"])
    #expect(tunnels.map(\.id) == ["t1", "t2", "t3"])
    // The package stays faithful to the wire: filtering `tun_type` is the
    // view's job, so a future WARP-Connector screen needs no change here.
    #expect(tunnels.map(\.tunTypeRaw) == ["cfd_tunnel", "cfd_tunnel", "magic"])
    #expect(tunnels[0].health == .healthy)
    #expect(tunnels[0].configSource == .cloudflare)
    #expect(tunnels[0].connections?.first?.coloName == "IAD")
    #expect(tunnels[0].connections?.first?.originIP == "203.0.113.10")
    #expect(tunnels[0].connsActiveAt == "2026-07-01T00:00:00Z")
    #expect(tunnels[1].health == .degraded)
    #expect(!tunnels[0].isDeleted)
  }

  @Test func tunnelListStopsAtMaxPagesWhenResultInfoNeverTerminates() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let recorder = RequestRecorder()
    let session = mockSession { request in
      let query = tunnelQuery(request)
      let page = query["page"] ?? "1"
      recorder.record(page)
      // A full page, fresh ids, and a `result_info` that never admits an end:
      // only `maxPages` can stop this.
      return (
        200,
        Data(
          #"""
          {"success":true,"result":[
            {"id":"t\#(page)a","name":"a","status":"healthy"},
            {"id":"t\#(page)b","name":"b","status":"healthy"}
          ],"result_info":{"page":\#(page),"per_page":2}}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let tunnels = try await client.listTunnels(accountID: "acc", perPage: 2, maxPages: 3)

    #expect(recorder.paths == ["1", "2", "3"])
    #expect(tunnels.count == 6)
  }

  // MARK: - Vendor strings that carry no enum

  @Test func tunnelUnknownStatusAndTypeDecodeAsUnknownHealth() throws {
    // Cloudflare publishes no enum for `status` or `tun_type`. An unrecognised
    // value must degrade one badge, never blank the screen — and it must never
    // resolve to `.healthy`, which is the direction that lies to the user.
    let tunnel = try JSONDecoder().decode(
      CloudflareTunnel.self,
      from: Data(
        #"{"id":"t1","status":"provisioning","tun_type":"quantum"}"#.utf8))

    #expect(tunnel.health == .unknown)
    #expect(tunnel.statusRaw == "provisioning")
    #expect(tunnel.tunTypeRaw == "quantum")
    #expect(tunnel.name == nil)
    // No `config_src`, no `remote_config` — the honest local card, not an
    // empty hostname list.
    #expect(tunnel.configSource == .local)

    #expect(TunnelHealth(status: nil) == .unknown)
    #expect(TunnelHealth(status: "HEALTHY") == .healthy)
    #expect(TunnelHealth(status: "down") == .down)
    #expect(TunnelHealth(status: "inactive") == .inactive)
  }

  @Test func tunnelConfigSourceResolvesFourWays() {
    #expect(TunnelConfigSource.resolve(configSrc: "cloudflare", remoteConfig: false) == .cloudflare)
    #expect(TunnelConfigSource.resolve(configSrc: "local", remoteConfig: true) == .local)
    #expect(TunnelConfigSource.resolve(configSrc: nil, remoteConfig: true) == .cloudflare)
    #expect(TunnelConfigSource.resolve(configSrc: "mystery", remoteConfig: nil) == .local)
  }

  // MARK: - Configuration document

  @Test func tunnelConfigurationDecodesNullConfigForLocalTunnel() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.url?.path == "/accounts/acc/cfd_tunnel/t1/configurations")
      // A locally-managed tunnel answers 200 with a null config. A
      // non-optional `config` would turn a healthy tunnel into a decode error.
      return (200, Data(#"{"success":true,"result":{"source":"local","config":null}}"#.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let configuration = try await client.getTunnelConfiguration(accountID: "acc", tunnelID: "t1")

    #expect(configuration.config == nil)
    #expect(configuration.sourceRaw == "local")
    #expect(configuration.configSource == .local)
  }

  @Test func tunnelIngressKeepsAccessRequirementBesideUnmodelledOriginRequestKeys() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { _ in
      // `originRequest` carries ~15 origin-tuning keys Dash does not model, and
      // its keys are already camelCase on the wire — this is cloudflared's own
      // config vocabulary, not Cloudflare's REST snake_case.
      (
        200,
        Data(
          #"""
          {"success":true,"result":{"tunnel_id":"t1","version":7,"source":"cloudflare",
           "config":{"ingress":[
             {"hostname":"app.example.com","path":"/api","service":"http://localhost:8080",
              "originRequest":{"connectTimeout":30,"noTLSVerify":true,
                               "access":{"required":true,"teamName":"acme",
                                         "audTag":["aud-1","aud-2"]}}},
             {"service":"http_status:404"}
           ],"warp-routing":{"enabled":true}}}}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let configuration = try await client.getTunnelConfiguration(accountID: "acc", tunnelID: "t1")
    let ingress = try #require(configuration.config?.ingress)

    #expect(configuration.configSource == .cloudflare)
    #expect(ingress.count == 2)
    #expect(ingress[0].hostname == "app.example.com")
    #expect(ingress[0].path == "/api")
    #expect(ingress[0].service == "http://localhost:8080")
    #expect(!ingress[0].isCatchAll)
    #expect(ingress[0].originRequest?.access?.required == true)
    #expect(ingress[0].originRequest?.access?.teamName == "acme")
    #expect(ingress[0].originRequest?.access?.audTag == ["aud-1", "aud-2"])
    // cloudflared requires a final hostname-less rule; it is "everything else",
    // not a public hostname.
    #expect(ingress[1].isCatchAll)
    #expect(ingress[1].originRequest == nil)
  }

  // MARK: - Connectors and routes

  @Test func tunnelConnectorsDecodeArchRunAtAndConnections() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.url?.path == "/accounts/acc/cfd_tunnel/t1/connections")
      return (
        200,
        Data(
          #"""
          {"success":true,"result":[
            {"id":"conn-1","arch":"linux_amd64","version":"2026.6.1",
             "run_at":"2026-07-20T09:00:00Z","config_version":12,
             "features":["ha-origin","serialized_headers"],
             "conns":[{"id":"c1","colo_name":"IAD","origin_ip":"203.0.113.10",
                       "opened_at":"2026-07-20T09:00:01Z","is_pending_reconnect":false},
                      {"id":"c2","colo_name":"SJC","origin_ip":"203.0.113.10"}]}
          ]}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let connectors = try await client.listTunnelConnectors(accountID: "acc", tunnelID: "t1")
    let connector = try #require(connectors.first)

    #expect(connectors.count == 1)
    #expect(connector.id == "conn-1")
    #expect(connector.arch == "linux_amd64")
    #expect(connector.version == "2026.6.1")
    #expect(connector.runAt == "2026-07-20T09:00:00Z")
    #expect(connector.configVersion == 12)
    #expect(connector.features == ["ha-origin", "serialized_headers"])
    #expect(connector.conns?.map(\.coloName) == ["IAD", "SJC"])
    #expect(connector.conns?.first?.openedAt == "2026-07-20T09:00:01Z")
  }

  @Test func tunnelRoutesSendTunnelIDAndIsDeletedFalse() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      let query = tunnelQuery(request)
      #expect(request.url?.path == "/accounts/acc/teamnet/routes")
      #expect(query["tunnel_id"] == "t1")
      #expect(query["is_deleted"] == "false")
      #expect(query["per_page"] == "50")
      return (
        200,
        Data(
          #"""
          {"success":true,"result":[
            {"id":"r1","network":"10.0.0.0/24","tunnel_id":"t1","tunnel_name":"office",
             "comment":"HQ subnet","virtual_network_id":"vnet-1",
             "created_at":"2026-02-01T00:00:00Z"}
          ],"result_info":{"page":1,"per_page":50,"total_count":1}}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let routes = try await client.listTunnelRoutes(accountID: "acc", tunnelID: "t1")

    #expect(routes.map(\.network) == ["10.0.0.0/24"])
    #expect(routes.first?.tunnelName == "office")
    #expect(routes.first?.comment == "HQ subnet")
    #expect(routes.first?.virtualNetworkID == "vnet-1")
    #expect(routes.first?.deletedAt == nil)
  }

  // MARK: - Access

  @Test func tunnelAccessApplicationsDropMalformedRows() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.url?.path == "/accounts/acc/access/apps")
      // The second row has no `id`. `LossyElement` must drop that one row
      // rather than fail the whole list — a badge is not worth a blank screen.
      return (
        200,
        Data(
          #"""
          {"success":true,"result":[
            {"id":"app-1","name":"Internal app","domain":"app.example.com",
             "type":"self_hosted","aud":"aud-1",
             "destinations":[{"type":"public","uri":"app.example.com"}],
             "policies":[{"id":"p1","decision":"allow"}]},
            {"name":"no id here","domain":"broken.example.com"}
          ]}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let apps = try await client.listAccessApplications(accountID: "acc")

    #expect(apps.map(\.id) == ["app-1"])
    #expect(apps.first?.domain == "app.example.com")
    #expect(apps.first?.aud == "aud-1")
    #expect(apps.first?.destinations?.first?.uri == "app.example.com")
  }

  @Test func tunnelAccessApplicationsCollectEveryPage() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let recorder = RequestRecorder()
    let session = mockSession { request in
      #expect(request.url?.path == "/accounts/acc/access/apps")
      let query = tunnelQuery(request)
      recorder.record(query["page"] ?? "missing")
      #expect(query["per_page"] == "1")
      if query["page"] == "2" {
        return (
          200,
          Data(
            #"""
            {"success":true,"result":[
              {"id":"app-2","name":"Second app","domain":"second.example.com"}
            ],"result_info":{"page":2,"per_page":1,"total_count":2,"total_pages":2}}
            """#.utf8)
        )
      }
      return (
        200,
        Data(
          #"""
          {"success":true,"result":[
            {"id":"app-1","name":"First app","domain":"first.example.com"}
          ],"result_info":{"page":1,"per_page":1,"total_count":2,"total_pages":2}}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let apps = try await client.listAccessApplications(accountID: "acc", perPage: 1)

    #expect(recorder.paths == ["1", "2"])
    #expect(apps.map(\.id) == ["app-1", "app-2"])
  }

  // MARK: - Unprovisioned / unscoped

  @Test func tunnelForbiddenBodyBecomesRequestError() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { _ in
      // No Zero Trust on the account, or no `argotunnel.read` in the grant.
      // Either way it must surface as an actionable 403, not a decode failure.
      (
        403,
        Data(
          #"""
          {"success":false,"result":null,
           "errors":[{"code":10000,"message":"Authentication error"}]}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    do {
      _ = try await client.listTunnels(accountID: "acc")
      Issue.record("a 403 from /cfd_tunnel should throw")
    } catch let error as CloudflareAPIError {
      guard case .request(let status, let errors) = error else {
        Issue.record("expected .request, got \(error)")
        return
      }
      #expect(status == 403)
      #expect(errors.first?.code == 10000)
      #expect(error.isForbidden)
    }
  }
}

private func tunnelQuery(_ request: URLRequest) -> [String: String] {
  let items =
    URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
  return Dictionary(
    items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
}
