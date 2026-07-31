import CloudflareAPI
import Foundation

// MARK: - Demo session plumbing

/// Token store for the read-only demo session: a static token the demo
/// backend never checks, so the client skips the real keychain and the
/// refresh path never runs.
struct DemoTokenStore: TokenStore {
  func clear() async throws {}
  func getAccessToken() async throws -> String? { "demo-token" }
  func getRefreshToken() async throws -> String? { nil }
  func setTokens(_ tokens: TokenSet) async throws {}
}

/// An in-process Cloudflare for the read-only demo session — App Review's
/// path past the OAuth wall (Guideline 2.1) and anyone's way to try Dash
/// without an account. The demo `CloudflareClient` gets a URLSession whose
/// only protocol handler is this class, so every request the app makes is
/// answered from the fixtures below: the real client, cache, and view code
/// run unchanged, pull-to-refresh included, with zero network and zero
/// credentials. Reads serve one small coherent world; writes return a
/// friendly read-only error.
final class DemoBackend: URLProtocol {
  /// The account a fresh demo session lands on. The demo user is a member of
  /// three of them (`DemoWorld.accounts`) — one person with a main workspace,
  /// a client account, and a hobby account, which is the shape Cloudflare's
  /// account switcher actually exists for. Every account-scoped fixture keys
  /// off the account in the path, so switching changes what each screen shows
  /// instead of relabelling one world.
  static let accountID = "demo-account"

  /// The session handed to the demo `CloudflareClient`. Nothing escapes to
  /// the network: this class claims every request in the session.
  static let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DemoBackend.self]
    return URLSession(configuration: configuration)
  }()

  override class func canInit(with _: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let reply = Self.respond(to: request, body: Self.drainBody(of: request))
    let response = HTTPURLResponse(
      url: request.url ?? URL(string: "https://api.cloudflare.com")!,
      statusCode: reply.status,
      httpVersion: nil,
      headerFields: ["Content-Type": reply.contentType])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: reply.body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  /// URLSession delivers POST bodies to protocol handlers as a stream.
  private static func drainBody(of request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let size = 4096
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
      let read = stream.read(buffer, maxLength: size)
      if read <= 0 { break }
      data.append(buffer, count: read)
    }
    return data
  }

  // MARK: - Router

  private struct Reply {
    var status: Int
    var contentType: String
    var body: Data

    init(status: Int = 200, contentType: String = "application/json", json: String) {
      self.status = status
      self.contentType = contentType
      body = Data(json.utf8)
    }

    init(status: Int = 200, contentType: String, data: Data) {
      self.status = status
      self.contentType = contentType
      body = data
    }
  }

  private static func ok(_ result: String, info: String? = nil) -> Reply {
    let tail = info.map { ",\"result_info\":\($0)" } ?? ""
    return Reply(json: #"{"success":true,"errors":[],"messages":[],"result":\#(result)\#(tail)}"#)
  }

  private static var readOnly: Reply {
    Reply(
      status: 400,
      json: #"""
        {"success":false,"errors":[{"code":10061,"message":"This demo is read-only. Return to Home and choose Connect your account to make changes."}],"messages":[],"result":null}
        """#)
  }

  private static func respond(to request: URLRequest, body: Data?) -> Reply {
    guard let url = request.url else { return ok("[]") }
    var path = url.path
    if path.hasPrefix("/client/v4") { path.removeFirst("/client/v4".count) }
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    func query(_ name: String) -> String? {
      items.first { $0.name == name }?.value?.nilIfEmptyDemo
    }
    let method = (request.httpMethod ?? "GET").uppercased()

    if path == "/graphql" {
      return graphQL(body: body)
    }
    guard method == "GET" else { return readOnly }

    switch path {
    case "/user":
      return ok(
        #"{"id":"demo-user","email":"demo@example.com","first_name":"Demo","last_name":"Explorer","created_on":"2024-03-01T09:00:00Z"}"#
      )
    case "/accounts":
      return ok(
        "[\(DemoWorld.accounts.map(\.json).joined(separator: ","))]",
        info:
          #"{"page":1,"per_page":50,"total_count":\#(DemoWorld.accounts.count)}"#)
    case "/zones":
      // Zones are the one list Cloudflare scopes by query parameter rather
      // than by path, so `account.id` is what makes Home, Domains, and search
      // show one account's domains instead of every domain the demo knows.
      let zones = DemoWorld.zones(accountID: query("account.id")).filter { zone in
        guard let needle = query("name")?.lowercased() else { return true }
        return zone.name.lowercased().contains(needle)
      }
      let page = max(Int(query("page") ?? "1") ?? 1, 1)
      let perPage = min(max(Int(query("per_page") ?? "50") ?? 50, 1), 50)
      let start = (page - 1) * perPage
      let slice =
        start < zones.count
        ? Array(zones[start..<min(start + perPage, zones.count)]) : []
      return ok(
        "[\(slice.map(\.json).joined(separator: ","))]",
        info:
          #"{"page":\#(page),"per_page":\#(perPage),"total_count":\#(zones.count),"count":\#(slice.count)}"#
      )
    default:
      break
    }

    let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

    // /zones/{id}/... — a zone id is unique across accounts, so this resolves
    // against every account's zones, exactly like Cloudflare does.
    if parts.count >= 2, parts[0] == "zones", let zone = DemoWorld.zone(id: parts[1]) {
      let rest = Array(parts.dropFirst(2))
      switch rest.first {
      case nil:
        return ok(zone.json)
      case "dns_records"?:
        var records = DemoWorld.dnsRecords(zone: zone)
        if let needle = query("search")?.lowercased() {
          records = records.filter {
            $0.lowercased().contains(needle)
          }
        }
        if let type = query("type")?.uppercased() {
          records = records.filter { $0.contains(#""type":"\#(type)""#) }
        }
        return ok(
          "[\(records.joined(separator: ","))]",
          info: #"{"page":1,"per_page":100,"total_count":\#(records.count)}"#)
      case "settings"?:
        return ok(DemoWorld.zoneSettings)
      case "workers"? where rest.count >= 2 && rest[1] == "routes":
        return ok("[\(DemoWorld.workerRoutes(zoneID: zone.id).joined(separator: ","))]")
      case "email"? where rest.count >= 2 && rest[1] == "routing":
        let emailRest = Array(rest.dropFirst(2))
        switch emailRest.first {
        case nil:
          switch zone.id {
          case "zone-example":
            return ok(
              #"""
              {"id":"email-zone-example","name":"example.com","enabled":true,"status":"ready","created":"2026-02-12T09:00:00Z","modified":"2026-07-26T08:30:00Z","skip_wizard":false,"support_subaddress":true,"tag":"demo-email-ready"}
              """#)
          case "zone-docs":
            return ok(
              #"""
              {"id":"email-zone-docs","name":"docs.example.com","enabled":true,"status":"misconfigured","created":"2026-03-04T10:15:00Z","modified":"2026-07-25T17:20:00Z","skip_wizard":false,"support_subaddress":false,"tag":"demo-email-misconfigured"}
              """#)
          default:
            return ok(
              #"""
              {"id":"email-\#(zone.id)","name":"\#(zone.name)","enabled":false,"status":"unconfigured","created":null,"modified":null,"skip_wizard":false,"support_subaddress":false,"tag":null}
              """#)
          }

        case "dns"?:
          if zone.id == "zone-docs" {
            return ok(
              #"""
              {"record":[
                {"type":"MX","name":"docs.example.com","content":"route1.mx.cloudflare.net","ttl":1,"priority":10},
                {"type":"MX","name":"docs.example.com","content":"route2.mx.cloudflare.net","ttl":1,"priority":20}
              ],"errors":[
                {"code":"missing_dns_record","missing":{"type":"TXT","name":"docs.example.com","content":"v=spf1 include:_spf.mx.cloudflare.net ~all","ttl":1}}
              ]}
              """#)
          }
          return ok(
            #"""
            {"record":[
              {"type":"MX","name":"example.com","content":"route1.mx.cloudflare.net","ttl":1,"priority":10},
              {"type":"MX","name":"example.com","content":"route2.mx.cloudflare.net","ttl":1,"priority":20},
              {"type":"TXT","name":"example.com","content":"v=spf1 include:_spf.mx.cloudflare.net ~all","ttl":1}
            ],"errors":[]}
            """#)

        case "rules"? where emailRest.count >= 2 && emailRest[1] == "catch_all":
          return ok(
            #"""
            {"id":"catch-all-\#(zone.id)","tag":"demo-catch-all","name":"Catch all","enabled":true,"source":"dashboard","matchers":[{"type":"all"}],"actions":[{"type":"drop"}]}
            """#)

        case "rules"?:
          let rules =
            zone.id == "zone-example"
            ? [
              #"""
              {"id":"route-disabled","tag":"demo-route-disabled","name":"Support","enabled":false,"priority":10,"source":"dashboard","matchers":[{"type":"literal","field":"to","value":"support@example.com"}],"actions":[{"type":"forward","value":["support@example.net"]}]}
              """#,
              #"""
              {"id":"route-unverified","tag":"demo-route-unverified","name":"Billing","enabled":true,"priority":20,"source":"dashboard","matchers":[{"type":"literal","field":"to","value":"billing@example.com"}],"actions":[{"type":"forward","value":["pending@example.net"]}]}
              """#,
            ] : []
          return ok(
            "[\(rules.joined(separator: ","))]",
            info:
              #"{"page":1,"per_page":50,"count":\#(rules.count),"total_count":\#(rules.count),"total_pages":1}"#
          )

        default:
          return ok("[]")
        }
      default:
        return ok("[]")
      }
    }

    guard parts.count >= 2, parts[0] == "accounts" else { return ok("[]") }
    guard let account = DemoWorld.account(id: parts[1]) else {
      // A bare lookup for an account this demo user is not in has to fail the
      // way Cloudflare fails it. `loadIdentity` reads 403/404 as proof that a
      // remembered account is gone and moves on; an empty array would come
      // back as a decode error instead and strand the whole session — which is
      // reachable now that the demo has an account you can switch away from.
      // Sub-resources still answer empty, so a request left in flight across a
      // switch cannot make a screen show an error for the account you left.
      guard parts.count == 2 else { return ok("[]") }
      return Reply(
        status: 404,
        json:
          #"{"success":false,"errors":[{"code":1003,"message":"Account not found."}],"messages":[],"result":null}"#
      )
    }
    let rest = Array(parts.dropFirst(2))

    switch rest.first {
    case nil:
      // GET /accounts/{id}: `loadIdentity` confirms a remembered account this
      // way when the list it just fetched does not contain it.
      return ok(account.json)
    case "workers"?:
      return workers(account: account, rest: Array(rest.dropFirst()))
    case "pages"?:
      return pages(account: account, rest: Array(rest.dropFirst()))
    case "r2"?:
      return r2(
        account: account, rest: Array(rest.dropFirst()), prefix: query("prefix"),
        delimiter: query("delimiter"))
    case "rum"?:
      // Configured sites let Domain detail resolve its RUM site tag while the
      // remaining demo zones still exercise the beacon-missing empty state.
      return ok(DemoWorld.rumSites(accountID: account.id))
    case "storage"?:
      return kv(account: account, rest: Array(rest.dropFirst()), prefix: query("prefix"))
    case "alerting"?:
      if rest.contains("available_alerts") { return ok("{}") }
      if rest.contains("history") { return ok(DemoWorld.alertHistory(accountID: account.id)) }
      return ok("[]")
    case "audit_logs"?:
      return ok(DemoWorld.auditLogs(accountID: account.id))
    case "logs"? where rest.count >= 2 && rest[1] == "audit":
      return ok(DemoWorld.auditLogs(accountID: account.id))
    case "cfd_tunnel"?:
      let tunnelRest = Array(rest.dropFirst())
      let remoteTunnel =
        #"""
        {"id":"tunnel-demo-remote","account_tag":"demo-account","name":"production-edge","created_at":"2026-01-10T08:00:00Z","deleted_at":null,"conns_active_at":"2026-07-29T06:30:00Z","conns_inactive_at":null,"status":"healthy","tun_type":"cfd_tunnel","config_src":"cloudflare","remote_config":true,"connections":[{"id":"connection-sin","client_id":"connector-singapore","client_version":"2026.7.1","colo_name":"SIN","opened_at":"2026-07-29T06:30:00Z","origin_ip":"203.0.113.10","uuid":"connection-sin","is_pending_reconnect":false},{"id":"connection-nrt","client_id":"connector-tokyo","client_version":"2026.7.1","colo_name":"NRT","opened_at":"2026-07-29T06:31:00Z","origin_ip":"203.0.113.11","uuid":"connection-nrt","is_pending_reconnect":false}]}
        """#
      let localTunnel =
        #"""
        {"id":"tunnel-demo-local","account_tag":"demo-account","name":"lab-origin","created_at":"2025-11-03T12:00:00Z","deleted_at":null,"conns_active_at":null,"conns_inactive_at":"2026-07-27T19:20:00Z","status":"inactive","tun_type":"cfd_tunnel","config_src":"local","remote_config":false,"connections":[]}
        """#

      switch tunnelRest.first {
      case nil:
        let rows = account.id == DemoBackend.accountID ? [remoteTunnel, localTunnel] : []
        return ok(
          "[\(rows.joined(separator: ","))]",
          info:
            #"{"page":1,"per_page":50,"count":\#(rows.count),"total_count":\#(rows.count),"total_pages":1}"#
        )

      case let tunnelID? where tunnelRest.count >= 2 && tunnelRest[1] == "connections":
        guard account.id == DemoBackend.accountID else {
          return ok(
            "[]",
            info: #"{"page":1,"per_page":50,"count":0,"total_count":0,"total_pages":1}"#)
        }
        let connectors: [String]
        if tunnelID == "tunnel-demo-remote" {
          connectors = [
            #"""
            {"id":"connector-singapore","arch":"arm64","version":"2026.7.1","run_at":"2026-07-29T06:30:00Z","config_version":12,"features":["quic"],"conns":[{"id":"connection-sin","client_id":"connector-singapore","client_version":"2026.7.1","colo_name":"SIN","opened_at":"2026-07-29T06:30:00Z","origin_ip":"203.0.113.10","uuid":"connection-sin","is_pending_reconnect":false}]}
            """#,
            #"""
            {"id":"connector-tokyo","arch":"amd64","version":"2026.7.1","run_at":"2026-07-29T06:31:00Z","config_version":12,"features":["quic"],"conns":[{"id":"connection-nrt","client_id":"connector-tokyo","client_version":"2026.7.1","colo_name":"NRT","opened_at":"2026-07-29T06:31:00Z","origin_ip":"203.0.113.11","uuid":"connection-nrt","is_pending_reconnect":false}]}
            """#,
          ]
        } else {
          connectors = []
        }
        return ok(
          "[\(connectors.joined(separator: ","))]",
          info:
            #"{"page":1,"per_page":50,"count":\#(connectors.count),"total_count":\#(connectors.count),"total_pages":1}"#
        )

      case let tunnelID? where tunnelRest.count >= 2 && tunnelRest[1] == "configurations":
        guard account.id == DemoBackend.accountID else {
          return Reply(
            status: 404,
            json:
              #"{"success":false,"errors":[{"code":1001,"message":"Tunnel configuration not found."}],"messages":[],"result":null}"#
          )
        }
        if tunnelID == "tunnel-demo-remote" {
          return ok(
            #"""
            {"tunnel_id":"tunnel-demo-remote","account_id":"demo-account","source":"cloudflare","created_at":"2026-07-24T10:00:00Z","version":12,"config":{"ingress":[{"hostname":"app.example.com","path":null,"service":"http://localhost:3000","originRequest":{"access":{"required":true,"teamName":"dash-demo","audTag":["demo-aud-app"]}}},{"hostname":"api.example.com","path":"/v1/*","service":"http://localhost:8787","originRequest":null},{"hostname":"ssh.example.com","path":null,"service":"ssh://localhost:22","originRequest":null},{"hostname":null,"path":null,"service":"http_status:404","originRequest":null}],"originRequest":{"access":{"required":false,"teamName":null,"audTag":[]}}}}
            """#)
        }
        if tunnelID == "tunnel-demo-local" {
          return ok(
            #"""
            {"tunnel_id":"tunnel-demo-local","account_id":"demo-account","source":"local","created_at":"2025-11-03T12:00:00Z","version":1,"config":null}
            """#)
        }
        return Reply(
          status: 404,
          json:
            #"{"success":false,"errors":[{"code":1001,"message":"Tunnel configuration not found."}],"messages":[],"result":null}"#
        )

      case let tunnelID? where tunnelRest.count == 1:
        guard account.id == DemoBackend.accountID else {
          return Reply(
            status: 404,
            json:
              #"{"success":false,"errors":[{"code":1001,"message":"Tunnel not found."}],"messages":[],"result":null}"#
          )
        }
        if tunnelID == "tunnel-demo-remote" { return ok(remoteTunnel) }
        if tunnelID == "tunnel-demo-local" { return ok(localTunnel) }
        return Reply(
          status: 404,
          json:
            #"{"success":false,"errors":[{"code":1001,"message":"Tunnel not found."}],"messages":[],"result":null}"#
        )

      default:
        return ok("[]")
      }
    case "teamnet"?:
      let teamnetRest = Array(rest.dropFirst())
      switch teamnetRest.first {
      case "routes"?:
        let includeRoute =
          account.id == DemoBackend.accountID
          && (query("tunnel_id") == nil || query("tunnel_id") == "tunnel-demo-remote")
        let routes =
          includeRoute
          ? [
            #"""
            {"id":"route-demo-private","network":"10.42.0.0/16","tunnel_id":"tunnel-demo-remote","tunnel_name":"production-edge","comment":"Production private network","created_at":"2026-04-18T09:00:00Z","deleted_at":null,"virtual_network_id":"vnet-demo-default"}
            """#
          ] : []
        return ok(
          "[\(routes.joined(separator: ","))]",
          info:
            #"{"page":1,"per_page":50,"count":\#(routes.count),"total_count":\#(routes.count),"total_pages":1}"#
        )

      case "virtual_networks"?:
        let networks =
          account.id == DemoBackend.accountID
          ? [
            #"""
            {"id":"vnet-demo-default","name":"Default","comment":"Default Zero Trust network","created_at":"2026-01-10T08:00:00Z","deleted_at":null,"is_default_network":true}
            """#
          ] : []
        return ok(
          "[\(networks.joined(separator: ","))]",
          info:
            #"{"page":1,"per_page":50,"count":\#(networks.count),"total_count":\#(networks.count),"total_pages":1}"#
        )

      default:
        return ok("[]")
      }
    case "access"? where rest.count >= 2 && rest[1] == "apps":
      let applications =
        account.id == DemoBackend.accountID
        ? [
          #"""
          {"id":"access-app-demo","name":"Demo app","domain":"app.example.com","type":"self_hosted","aud":"demo-aud-app","destinations":[{"type":"public","uri":"https://app.example.com"}]}
          """#
        ] : []
      return ok(
        "[\(applications.joined(separator: ","))]",
        info:
          #"{"page":1,"per_page":50,"count":\#(applications.count),"total_count":\#(applications.count),"total_pages":1}"#
      )
    case "registrar"?:
      let registrarRest = Array(rest.dropFirst())
      let registrations = [
        #"""
        {"domain_name":"example.com","status":"active","created_at":"2024-04-18T10:00:00Z","expires_at":"2027-04-18T10:00:00Z","auto_renew":true,"privacy_mode":"redaction","locked":true}
        """#,
        #"""
        {"domain_name":"acme-labs.dev","status":"registration_pending","created_at":"2026-07-27T14:30:00Z","expires_at":"2027-07-27T14:30:00Z","auto_renew":false,"privacy_mode":"redaction","locked":true}
        """#,
      ]
      let legacyDomains = [
        #"""
        {"id":"example.com","available":false,"can_register":false,"created_at":"2024-04-18T10:00:00Z","current_registrar":"Cloudflare, Inc.","expires_at":"2027-04-18T10:00:00Z","locked":true,"updated_at":"2026-07-20T08:00:00Z","registry_statuses":"clientTransferProhibited,clientUpdateProhibited","supported_tld":true,"registrant_contact":{"id":"contact-example","first_name":"Demo","last_name":"Explorer","organization":"Example Labs","address":"123 Demo Street","city":"Singapore","state":"Singapore","zip":"018956","country":"SG","phone":"+65.60000000","email":"owner@example.com"},"transfer_in":null}
        """#,
        #"""
        {"id":"acme-labs.dev","available":false,"can_register":false,"created_at":"2026-07-27T14:30:00Z","current_registrar":"Cloudflare, Inc.","expires_at":"2027-07-27T14:30:00Z","locked":true,"updated_at":"2026-07-27T14:30:00Z","registry_statuses":"pendingCreate","supported_tld":true,"registrant_contact":{"id":"contact-acme","first_name":"Avery","last_name":"Chen","organization":"Acme Labs","city":"Singapore","country":"SG","email":"domains@acme-labs.dev"},"transfer_in":null}
        """#,
      ]

      switch registrarRest.first {
      case "registrations"?:
        if registrarRest.count == 1 {
          let rows = account.id == DemoBackend.accountID ? registrations : []
          return ok(
            "[\(rows.joined(separator: ","))]",
            info:
              #"{"count":\#(rows.count),"per_page":50,"total_count":\#(rows.count),"cursor":""}"#
          )
        }
        guard account.id == DemoBackend.accountID else {
          return Reply(
            status: 404,
            json:
              #"{"success":false,"errors":[{"code":1001,"message":"Registration not found."}],"messages":[],"result":null}"#
          )
        }
        let domain = registrarRest[1].lowercased()
        if domain == "example.com" { return ok(registrations[0]) }
        if domain == "acme-labs.dev" { return ok(registrations[1]) }
        return Reply(
          status: 404,
          json:
            #"{"success":false,"errors":[{"code":1001,"message":"Registration not found."}],"messages":[],"result":null}"#
        )

      case "domains"?:
        if registrarRest.count == 1 {
          let rows = account.id == DemoBackend.accountID ? legacyDomains : []
          return ok(
            "[\(rows.joined(separator: ","))]",
            info:
              #"{"page":1,"per_page":50,"count":\#(rows.count),"total_count":\#(rows.count),"total_pages":1}"#
          )
        }
        guard account.id == DemoBackend.accountID else {
          return Reply(
            status: 404,
            json:
              #"{"success":false,"errors":[{"code":1001,"message":"Registrar domain not found."}],"messages":[],"result":null}"#
          )
        }
        let domain = registrarRest[1].lowercased()
        if domain == "example.com" { return ok(legacyDomains[0]) }
        if domain == "acme-labs.dev" { return ok(legacyDomains[1]) }
        return Reply(
          status: 404,
          json:
            #"{"success":false,"errors":[{"code":1001,"message":"Registrar domain not found."}],"messages":[],"result":null}"#
        )

      default:
        return ok("[]")
      }
    case "email"?
    where rest.count >= 3 && rest[1] == "routing" && rest[2] == "addresses":
      let addresses: [String]
      if account.id != DemoBackend.accountID {
        addresses = []
      } else if query("verified") == "false" {
        addresses = [
          #"""
          {"id":"email-address-pending","tag":"demo-address-pending","email":"pending@example.net","verified":null,"created":"2026-07-24T12:00:00Z","modified":"2026-07-24T12:00:00Z"}
          """#
        ]
      } else {
        addresses = [
          #"""
          {"id":"email-address-support","tag":"demo-address-support","email":"support@example.net","verified":"2026-02-12T09:30:00Z","created":"2026-02-12T09:10:00Z","modified":"2026-02-12T09:30:00Z"}
          """#,
          #"""
          {"id":"email-address-owner","tag":"demo-address-owner","email":"owner@example.com","verified":"2026-03-04T11:00:00Z","created":"2026-03-04T10:45:00Z","modified":"2026-03-04T11:00:00Z"}
          """#,
        ]
      }
      return ok(
        "[\(addresses.joined(separator: ","))]",
        info:
          #"{"page":1,"per_page":50,"count":\#(addresses.count),"total_count":\#(addresses.count),"total_pages":1}"#
      )
    default:
      return ok("[]")
    }
  }

  // MARK: Workers

  private static func workers(account: DemoWorld.Account, rest: [String]) -> Reply {
    // workers/subdomain | workers/scripts[/{name}/(deployments|subdomain|content/v2)] | workers/domains
    if rest.first == "subdomain" {
      return ok(#"{"subdomain":"\#(account.workersSubdomain)"}"#)
    }
    if rest.first == "domains" {
      return ok("[\(DemoWorld.workerDomains(accountID: account.id).joined(separator: ","))]")
    }
    guard rest.first == "scripts" else { return ok("[]") }
    let scripts = DemoWorld.workerScripts(accountID: account.id)
    if rest.count == 1 {
      return ok(
        "[\(scripts.joined(separator: ","))]",
        info: #"{"page":1,"per_page":100,"total_count":\#(scripts.count)}"#)
    }
    let name = rest[1]
    switch rest.dropFirst(2).first {
    case "deployments"?:
      return ok(DemoWorld.workerDeployments(name: name))
    case "subdomain"?:
      return ok(#"{"enabled":true,"previews_enabled":false}"#)
    case "content"?:
      return Reply(
        contentType: "application/javascript",
        data: Data(DemoWorld.workerScript(name: name).utf8))
    default:
      return ok("[]")
    }
  }

  // MARK: Pages

  private static func pages(account: DemoWorld.Account, rest: [String]) -> Reply {
    // pages/projects[/{name}[/deployments[/{id}[/history/logs]] | /domains]]
    guard rest.first == "projects" else { return ok("[]") }
    let projects = DemoWorld.pagesProjects(accountID: account.id)
    if rest.count == 1 {
      return ok(
        "[\(projects.map(DemoWorld.pagesProject(named:)).joined(separator: ","))]",
        info: #"{"page":1,"per_page":10,"total_count":\#(projects.count)}"#)
    }
    let name = rest[1]
    switch rest.dropFirst(2).first {
    case nil:
      return ok(DemoWorld.pagesProject(named: name))
    case "deployments":
      let deployments = DemoWorld.pagesDeployments(project: name)
      if rest.count >= 4 {
        if rest.contains("logs") { return ok(DemoWorld.pagesBuildLogs) }
        let id = rest[3]
        if let deployment = deployments.first(where: { $0.contains("\"\(id)\"") }) {
          return ok(deployment)
        }
        guard let newest = deployments.first else { return ok("[]") }
        return ok(newest)
      }
      return ok(
        "[\(deployments.joined(separator: ","))]",
        info: #"{"page":1,"per_page":25,"total_count":\#(deployments.count)}"#)
    case "domains"?:
      return ok("[\(DemoWorld.pagesDomains(project: name).joined(separator: ","))]")
    default:
      return ok("[]")
    }
  }

  // MARK: R2

  private static func r2(
    account: DemoWorld.Account, rest: [String], prefix: String?, delimiter: String?
  ) -> Reply {
    // r2/buckets[/{bucket}/(objects[/key…] | domains/(managed|custom))]
    guard rest.first == "buckets" else { return ok("[]") }
    let buckets = DemoWorld.r2Buckets(accountID: account.id)
    if rest.count == 1 {
      return ok(#"{"buckets":[\#(buckets.map(\.json).joined(separator: ","))]}"#)
    }
    let name = rest[1]
    let tail = Array(rest.dropFirst(2))
    // A bucket this account does not own answers like an empty one, so a
    // request left in flight across an account switch cannot 404 a screen.
    let bucket =
      buckets.first { $0.name == name }
      ?? DemoWorld.R2DemoBucket(
        name: name, creationDate: DemoClock.iso(hoursAgo: 720),
        r2DevDomain: "pub-\(name).r2.dev", r2DevEnabled: false, objects: [])
    switch tail.first {
    case "objects"?:
      let key = tail.dropFirst().joined(separator: "/")
      if key.isEmpty {
        return r2ObjectList(bucket: bucket, prefix: prefix ?? "", delimiter: delimiter)
      }
      guard let object = bucket.objects.first(where: { $0.key == key }) else {
        return Reply(
          status: 404,
          json:
            #"{"success":false,"errors":[{"code":10007,"message":"Object not found."}],"result":null}"#
        )
      }
      return Reply(contentType: object.contentType, data: object.body)
    case "domains"? where tail.count >= 2 && tail[1] == "managed":
      return ok(
        #"{"bucketId":"\#(bucket.name)","domain":"\#(bucket.r2DevDomain)","enabled":\#(bucket.r2DevEnabled)}"#
      )
    case "domains"?:
      return ok(#"{"domains":[]}"#)
    default:
      return ok("[]")
    }
  }

  private static func r2ObjectList(
    bucket: DemoWorld.R2DemoBucket, prefix: String, delimiter: String?
  ) -> Reply {
    let all = bucket.objects.filter { $0.key.hasPrefix(prefix) }
    var rows: [String] = []
    var folders: Set<String> = []
    for object in all {
      let remainder = object.key.dropFirst(prefix.count)
      if let delimiter, let slash = remainder.range(of: delimiter) {
        folders.insert(prefix + remainder[..<slash.lowerBound] + delimiter)
        continue
      }
      rows.append(object.listJSON)
    }
    let delimited = folders.sorted().map { #""\#($0)""# }.joined(separator: ",")
    return ok(
      "[\(rows.joined(separator: ","))]",
      info: #"{"is_truncated":false,"cursor":"","delimited":[\#(delimited)],"per_page":100}"#)
  }

  // MARK: KV

  private static func kv(account: DemoWorld.Account, rest: [String], prefix: String?) -> Reply {
    // storage/kv/namespaces[/{id}/(keys|values/{key})]
    guard rest.count >= 2, rest[0] == "kv", rest[1] == "namespaces" else { return ok("[]") }
    let namespaces = DemoWorld.kvNamespaces(accountID: account.id)
    let tail = Array(rest.dropFirst(2))
    if tail.isEmpty {
      return ok(
        "[\(namespaces.map(\.json).joined(separator: ","))]",
        info: #"{"page":1,"per_page":20,"total_count":\#(namespaces.count)}"#)
    }
    let namespace = tail[0]
    switch tail.dropFirst().first {
    case "keys"?:
      var keys = DemoWorld.kvKeys(in: namespace)
      if let prefix {
        keys = keys.filter { $0.contains(#""name":"\#(prefix)"#) }
      }
      return ok(
        "[\(keys.joined(separator: ","))]",
        info: #"{"count":\#(keys.count)}"#)
    case "values"?:
      let key = tail.dropFirst(2).joined(separator: "/")
      let value = DemoWorld.kvValue(namespace: namespace, key: key)
      return Reply(contentType: "application/json", data: Data(value.utf8))
    default:
      return ok("[]")
    }
  }

  // MARK: GraphQL

  private static func graphQL(body: Data?) -> Reply {
    let query = body.map { String(decoding: $0, as: UTF8.self) } ?? ""
    // Analytics carries its account (or zone) inside the document, not the
    // path, so the scale has to be read back out of the filter — otherwise
    // every account replays the flagship account's traffic.
    let scale = DemoWorld.trafficScale(
      accountID: tag("accountTag", in: query),
      zoneID: tag("zoneTag", in: query))
    // Account overview must win before the Workers / zone Adaptive matchers —
    // its document names both `httpRequestsOverviewAdaptiveGroups` and
    // `workersInvocationsAdaptive`, and Overview is not a substring of the
    // zone Adaptive node.
    if query.contains("httpRequestsOverviewAdaptiveGroups") {
      return Reply(json: DemoWorld.accountAnalyticsOverview(scale: scale))
    }
    if query.contains("workersInvocationsAdaptive") {
      return Reply(json: DemoWorld.workerAnalytics(scale: scale))
    }
    if query.contains("httpRequests1hGroups") {
      let hours = max((limit(in: query) ?? 25) - 1, 1)
      return Reply(json: DemoWorld.zoneAnalyticsHourly(hours: hours, scale: scale))
    }
    if query.contains("httpRequests1dGroups") {
      // The daily chart asks for 7 or 30 days through `limit:`; honor it so the
      // ranges are not identical fixtures.
      return Reply(json: DemoWorld.zoneAnalyticsDaily(days: limit(in: query) ?? 7, scale: scale))
    }
    if query.contains("httpRequestsAdaptiveGroups") {
      return Reply(json: DemoWorld.zoneRequestsHourly(scale: scale))
    }
    if query.contains("pageload: rumPageloadEventsAdaptiveGroups") {
      return Reply(json: DemoWorld.rumMetrics(days: limit(in: query) ?? 14, scale: scale))
    }
    if query.contains("rumPageloadEventsAdaptiveGroups") {
      return Reply(json: DemoWorld.rumPageviews(days: limit(in: query) ?? 7, scale: scale))
    }
    if query.contains("firewallEventsAdaptiveByTimeGroups")
      || query.contains("firewallEventsAdaptive")
    {
      return Reply(json: DemoWorld.firewallEvents(scale: scale))
    }
    return Reply(json: #"{"data":null,"errors":null}"#)
  }

  /// First `limit: N` in a GraphQL query, so fixtures can size themselves to
  /// the requested window instead of returning one fixed slice.
  private static func limit(in query: String) -> Int? {
    guard let marker = query.range(of: "limit:") else { return nil }
    let digits = query[marker.upperBound...].drop(while: { $0 == " " }).prefix(while: \.isNumber)
    return Int(digits)
  }

  /// First `name: "value"` filter tag in a GraphQL query — how an
  /// account-scoped or zone-scoped document says which world it is asking
  /// about.
  ///
  /// The document reaches us inside a JSON request body, so its quotes are
  /// escaped: the bytes read `accountTag: \"demo-account\"`, not
  /// `accountTag: "demo-account"`. Skipping the backslashes is the whole
  /// reason this is a parser and not a `contains` check.
  private static func tag(_ name: String, in query: String) -> String? {
    guard let marker = query.range(of: "\(name):") else { return nil }
    let opened = query[marker.upperBound...].drop { $0 == " " || $0 == "\\" }
    guard opened.first == "\"" else { return nil }
    let value = opened.dropFirst().prefix { $0 != "\"" && $0 != "\\" }
    return value.isEmpty ? nil : String(value)
  }
}

// MARK: - Fixture world

/// The demo's coherent world — core fixtures plus bulk lists for scroll /
/// pagination stress. Behavior stays in `DemoBackend`. Datetimes that feed
/// charts and "time ago" labels are generated relative to now so the demo
/// always looks alive.
///
/// Everything account-scoped is keyed by account id, because the demo user
/// belongs to three accounts. Switching has to change the domains, the
/// Workers, the buckets, the inbox, and the charts — an account switcher that
/// only changes a label teaches the wrong thing about the app.
private enum DemoWorld {

  // MARK: Accounts

  struct Account {
    let id: String
    let name: String
    let createdOn: String
    /// The `*.workers.dev` subdomain, so Worker URLs differ per account.
    let workersSubdomain: String
    /// Multiplies every generated series. A side-project account should draw
    /// a small chart, not the flagship account's chart with a new title.
    let trafficScale: Double

    var json: String {
      #"{"id":"\#(id)","name":"\#(name)","type":"standard","created_on":"\#(createdOn)"}"#
    }
  }

  /// One person, three Cloudflare accounts: the main workspace they live in,
  /// a client account they were invited to, and the account their weekend
  /// projects ended up in.
  static let accounts: [Account] = [
    Account(
      id: DemoBackend.accountID, name: "Demo Workspace",
      createdOn: "2024-03-01T09:00:00Z", workersSubdomain: "demo", trafficScale: 1),
    Account(
      id: "demo-account-studio", name: "Foxglove Studio",
      createdOn: "2025-02-17T14:20:00Z", workersSubdomain: "foxglove", trafficScale: 0.24),
    Account(
      id: "demo-account-side", name: "Side Projects",
      createdOn: "2026-05-06T18:45:00Z", workersSubdomain: "inkline", trafficScale: 0.06),
  ]

  static func account(id: String) -> Account? { accounts.first { $0.id == id } }

  static func trafficScale(accountID: String?, zoneID: String?) -> Double {
    if let accountID, let account = account(id: accountID) { return account.trafficScale }
    if let zoneID, let zone = zone(id: zoneID), let account = account(id: zone.accountID) {
      return account.trafficScale
    }
    return 1
  }

  /// Scales a generated volume, flooring at 1 so a quiet account reads as
  /// quiet rather than as a failed fetch.
  private static func scaled(_ value: Int, _ scale: Double) -> Int {
    guard scale < 1 else { return value }
    return max(1, Int((Double(value) * scale).rounded()))
  }

  /// Like `scaled`, but keeps zero at zero — error and threat counts have to
  /// be able to say "none".
  private static func scaledOrZero(_ value: Int, _ scale: Double) -> Int {
    guard scale < 1, value != 0 else { return value }
    return Int((Double(value) * scale).rounded())
  }

  /// A stable small integer for a name. `hashValue` is seeded per process, so
  /// deriving a pages.dev subdomain or an ETag from it would rename the demo's
  /// resources on every launch.
  static func seed(_ name: String) -> Int {
    name.unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) % 100_000 }
  }

  // MARK: Zones

  struct Zone {
    let id: String
    let name: String
    let accountID: String
    let json: String

    init(
      id: String, name: String, accountID: String, status: String = "active",
      plan: (id: String, name: String) = ("free", "Free Website")
    ) {
      self.id = id
      self.name = name
      self.accountID = accountID
      json =
        #"{"id":"\#(id)","name":"\#(name)","status":"\#(status)","paused":false,"development_mode":0,"name_servers":["ada.ns.cloudflare.com","bob.ns.cloudflare.com"],"plan":{"id":"\#(plan.id)","name":"\#(plan.name)","legacy_id":"\#(plan.id)"}}"#
    }
  }

  private static let pro = (id: "pro", name: "Pro Website")

  private static let coreZones: [Zone] = [
    Zone(id: "zone-example", name: "example.com", accountID: "demo-account", plan: pro),
    Zone(id: "zone-docs", name: "docs.example.com", accountID: "demo-account"),
    Zone(id: "zone-api", name: "api.example.net", accountID: "demo-account", status: "pending"),
    Zone(id: "zone-shop", name: "shop.example.org", accountID: "demo-account"),
  ]

  /// Varied labels so large-demo Domains cards don't hash into near-identical
  /// fills/avatars the way `app-01.bulk.example`…`app-56` did.
  private static let bulkZoneNames: [String] = [
    "northwind.io", "acme-labs.dev", "globex.app", "initech.co",
    "umbrella-corp.net", "stark-industries.com", "wayne-enterprises.org",
    "oscorp.io", "cyberdyne.ai", "tyrell.corp", "mass-effect.gg",
    "blue-origin.space", "redwood.studio", "copperhead.tools",
    "lumen-field.tv", "harbor-light.fm", "pebble-beach.golf",
    "cascade-peak.ski", "maple-grove.farm", "cedar-point.park",
    "aurora-borealis.photo", "quartz-canyon.guide", "silver-line.transit",
    "ironwood.forge", "paper-crane.press", "neon-harbor.club",
    "velvet-room.music", "pixel-orchard.games", "cloud-harbor.cdn",
    "signal-bridge.chat", "ledger-oak.finance", "mint-leaf.health",
    "amber-wave.energy", "coral-reef.ocean", "frost-peak.alpine",
    "solar-drift.space", "nova-kite.edu", "river-bend.library",
    "oak-street.bakery", "pine-cone.camping", "lotus-gate.temple",
    "echo-valley.radio", "brass-key.locksmith", "glass-house.design",
    "inkwell.blog", "compass-rose.maps", "tide-pool.marine",
    "ember-ash.pottery", "windmill.holland", "lantern-fish.deep",
    "honeycomb.apiary", "circuit-board.tech", "origami.fold",
    "sandstone.arch", "meadowlark.bird", "thunderhead.storm",
  ]

  /// The client account: a handful of domains, one of them still pending —
  /// the shape a small studio actually has.
  private static let studioZones: [Zone] = [
    Zone(
      id: "zone-studio-www", name: "foxglove.studio",
      accountID: "demo-account-studio", plan: pro),
    Zone(
      id: "zone-studio-clients", name: "clients.foxglove.studio",
      accountID: "demo-account-studio"),
    Zone(
      id: "zone-studio-preview", name: "preview.foxglove.studio",
      accountID: "demo-account-studio", status: "pending"),
  ]

  /// The hobby account: two domains and nothing else to speak of.
  private static let sideZones: [Zone] = [
    Zone(id: "zone-side-inkline", name: "inkline.dev", accountID: "demo-account-side"),
    Zone(id: "zone-side-notes", name: "notes.inkline.dev", accountID: "demo-account-side"),
  ]

  static var allZones: [Zone] {
    let bulk = bulkZoneNames.enumerated().map { offset, name -> Zone in
      let index = offset + 1
      return Zone(
        id: "zone-bulk-\(index)", name: name, accountID: "demo-account",
        status: index % 11 == 0 ? "pending" : "active")
    }
    return coreZones + bulk + studioZones + sideZones
  }

  /// `nil` means "every zone the demo knows" — only reachable if a caller
  /// stops scoping the list, which the client never does.
  static func zones(accountID: String?) -> [Zone] {
    guard let accountID else { return allZones }
    return allZones.filter { $0.accountID == accountID }
  }

  static func zone(id: String) -> Zone? { allZones.first { $0.id == id } }

  // MARK: Workers

  static func workerScripts(accountID: String) -> [String] {
    func script(id: String, tag: String, modifiedOn: String, createdOn: String) -> String {
      #"{"id":"\#(id)","tag":"\#(tag)","modified_on":"\#(modifiedOn)","created_on":"\#(createdOn)"}"#
    }
    switch accountID {
    case "demo-account":
      var scripts = [
        script(
          id: "api-worker", tag: "w-api-1", modifiedOn: "2026-07-20T03:04:05Z",
          createdOn: "2025-11-02T10:00:00Z"),
        script(
          id: "edge-cache", tag: "w-edge-2", modifiedOn: "2026-07-18T22:11:00Z",
          createdOn: "2026-02-14T08:30:00Z"),
      ]
      scripts += (1...38).map { index in
        script(
          id: "worker-\(String(format: "%02d", index))", tag: "w-bulk-\(index)",
          modifiedOn: DemoClock.iso(hoursAgo: index), createdOn: "2026-01-01T10:00:00Z")
      }
      return scripts
    case "demo-account-studio":
      return [
        script(
          id: "image-resizer", tag: "w-studio-1", modifiedOn: DemoClock.iso(hoursAgo: 9),
          createdOn: "2025-03-04T11:15:00Z"),
        script(
          id: "form-relay", tag: "w-studio-2", modifiedOn: DemoClock.iso(hoursAgo: 130),
          createdOn: "2025-06-21T16:40:00Z"),
      ]
    case "demo-account-side":
      return [
        script(
          id: "link-shortener", tag: "w-side-1", modifiedOn: DemoClock.iso(hoursAgo: 51),
          createdOn: "2026-05-09T20:05:00Z")
      ]
    default:
      return []
    }
  }

  static func workerDomains(accountID: String) -> [String] {
    switch accountID {
    case "demo-account":
      return [
        #"{"id":"wd-1","hostname":"api.example.net","service":"api-worker","zone_id":"zone-api","zone_name":"api.example.net","cert_id":"cert-1","environment":"production"}"#
      ]
    case "demo-account-studio":
      return [
        #"{"id":"wd-studio-1","hostname":"images.foxglove.studio","service":"image-resizer","zone_id":"zone-studio-www","zone_name":"foxglove.studio","cert_id":"cert-studio-1","environment":"production"}"#
      ]
    default:
      // The hobby account's Worker runs on workers.dev only — the empty
      // custom-domain state is the common one.
      return []
    }
  }

  static func workerRoutes(zoneID: String) -> [String] {
    switch zoneID {
    case "zone-example":
      return [#"{"id":"route-1","pattern":"example.com/api/*","script":"api-worker"}"#]
    case "zone-studio-www":
      return [
        #"{"id":"route-studio-1","pattern":"foxglove.studio/img/*","script":"image-resizer"}"#
      ]
    default:
      return []
    }
  }

  static func workerDeployments(name: String) -> String {
    let message =
      switch name {
      case "image-resizer": "Switch to AVIF where supported"
      case "form-relay": "Add the honeypot field"
      case "link-shortener": "Cache 301s at the edge"
      default: "Ship the new rate limiter"
      }
    return #"""
      {"deployments":[
        {"id":"deploy-live","created_on":"\#(DemoClock.iso(hoursAgo: 2))","source":"api","strategy":"percentage","versions":[{"version_id":"v-2001","percentage":100}],"annotations":{"workers/message":"\#(message)","workers/triggered_by":"deployment"},"author_email":"demo@example.com"},
        {"id":"deploy-prev","created_on":"\#(DemoClock.iso(hoursAgo: 74))","source":"wrangler","strategy":"percentage","versions":[{"version_id":"v-1994","percentage":100}],"author_email":"demo@example.com"}
      ]}
      """#
  }

  static func workerScript(name: String) -> String {
    switch name {
    case "image-resizer":
      return """
        export default {
          async fetch(request, env, ctx) {
            const url = new URL(request.url)
            const accepts = request.headers.get("Accept") ?? ""
            const format = accepts.includes("image/avif") ? "avif" : "webp"
            return fetch(request, {
              cf: { image: { format, width: Number(url.searchParams.get("w")) || 1200 } }
            })
          }
        }
        """
    case "form-relay":
      return """
        export default {
          async fetch(request, env) {
            if (request.method !== "POST") {
              return new Response("Method not allowed", { status: 405 })
            }
            const form = await request.formData()
            if (form.get("company")) {
              return new Response("ok")
            }
            await env.INBOX.send(Object.fromEntries(form))
            return Response.redirect("https://foxglove.studio/thanks", 303)
          }
        }
        """
    case "link-shortener":
      return """
        export default {
          async fetch(request, env) {
            const slug = new URL(request.url).pathname.slice(1)
            const target = await env.LINKS.get(slug)
            if (!target) {
              return new Response("Not found", { status: 404 })
            }
            return Response.redirect(target, 301)
          }
        }
        """
    default:
      return """
        export default {
          async fetch(request, env) {
            const url = new URL(request.url)
            if (url.pathname === "/health") {
              return new Response("ok")
            }
            const limited = await env.LIMITER.check(request)
            if (limited) {
              return new Response("Slow down", { status: 429 })
            }
            return fetch(request)
          }
        }
        """
    }
  }

  // MARK: Pages

  static func pagesProjects(accountID: String) -> [String] {
    switch accountID {
    case "demo-account":
      return ["marketing-site"] + (1...18).map { "site-\(String(format: "%02d", $0))" }
    case "demo-account-studio":
      return ["foxglove-www", "client-portal"]
    default:
      // Nothing on Pages: the hobby account is what the Pages empty state is
      // for, and every real user has an account like it.
      return []
    }
  }

  static func pagesProject(named name: String) -> String {
    let subdomain = pagesSubdomain(for: name)
    return #"""
      {"id":"pp-\#(name)","name":"\#(name)","subdomain":"\#(subdomain).pages.dev","created_on":"2026-01-08T12:00:00Z","latest_deployment":{"id":"pd-\#(name)-3","url":"https://\#(subdomain).pages.dev","environment":"production","created_on":"\#(DemoClock.iso(hoursAgo: 2))","latest_stage":{"name":"deploy","status":"success","started_on":"\#(DemoClock.iso(hoursAgo: 2))","ended_on":"\#(DemoClock.iso(hoursAgo: 2))"}}}
      """#
  }

  private static func pagesSubdomain(for project: String) -> String {
    let suffix = project == "marketing-site" ? "7ab" : String(format: "%03d", seed(project) % 1000)
    return "\(project)-\(suffix)"
  }

  static func pagesDomains(project: String) -> [String] {
    switch project {
    case "marketing-site":
      return [
        #"{"id":"pdom-1","name":"www.example.org","status":"active","created_on":"2026-01-09T08:00:00Z","zone_tag":"zone-shop"}"#
      ]
    case "foxglove-www":
      return [
        #"{"id":"pdom-studio-1","name":"www.foxglove.studio","status":"active","created_on":"2025-03-12T09:30:00Z","zone_tag":"zone-studio-www"}"#
      ]
    default:
      return []
    }
  }

  /// Deployment history for a project. The commit messages differ per project
  /// so a build screen in one account never looks like a build screen in
  /// another, and the middle build always failed — the failure row is half of
  /// what the Pages screen exists to show.
  static func pagesDeployments(project: String) -> [String] {
    let subdomain = pagesSubdomain(for: project)
    let commits: [(hash: String, message: String)] =
      switch project {
      case "foxglove-www":
        [
          ("4e77c02", "Refresh the case study grid"),
          ("b19d3fa", "Try the new image pipeline"),
          ("0a5c118", "Add the studio contact form"),
        ]
      case "client-portal":
        [
          ("d3a90b6", "Gate invoices behind Access"),
          ("62fe114", "Upgrade the PDF renderer"),
          ("18cc730", "Initial portal scaffold"),
        ]
      default:
        [
          ("9c2f4e1", "Polish the hero copy"),
          ("1d8ab90", "Bump dependencies"),
          ("77aa02e", "Launch the summer campaign"),
        ]
      }
    return [
      #"""
      {"id":"pd-3","short_id":"\#(commits[0].hash)","url":"https://\#(subdomain).pages.dev","environment":"production","created_on":"\#(DemoClock.iso(hoursAgo: 2))","modified_on":"\#(DemoClock.iso(hoursAgo: 2))","project_name":"\#(project)","is_skipped":false,"latest_stage":{"name":"deploy","status":"success","started_on":"\#(DemoClock.iso(hoursAgo: 2))","ended_on":"\#(DemoClock.iso(hoursAgo: 2))"},"deployment_trigger":{"type":"github:push","metadata":{"branch":"main","commit_hash":"\#(commits[0].hash)","commit_message":"\#(commits[0].message)"}},"aliases":\#(pagesAliases(project: project))}
      """#,
      #"""
      {"id":"pd-2","short_id":"\#(commits[1].hash)","url":"https://\#(commits[1].hash).\#(subdomain).pages.dev","environment":"production","created_on":"\#(DemoClock.iso(hoursAgo: 26))","modified_on":"\#(DemoClock.iso(hoursAgo: 26))","project_name":"\#(project)","is_skipped":false,"latest_stage":{"name":"build","status":"failure","started_on":"\#(DemoClock.iso(hoursAgo: 26))","ended_on":"\#(DemoClock.iso(hoursAgo: 26))"},"deployment_trigger":{"type":"github:push","metadata":{"branch":"main","commit_hash":"\#(commits[1].hash)","commit_message":"\#(commits[1].message)"}},"aliases":null}
      """#,
      #"""
      {"id":"pd-1","short_id":"\#(commits[2].hash)","url":"https://\#(commits[2].hash).\#(subdomain).pages.dev","environment":"production","created_on":"\#(DemoClock.iso(hoursAgo: 96))","modified_on":"\#(DemoClock.iso(hoursAgo: 96))","project_name":"\#(project)","is_skipped":false,"latest_stage":{"name":"deploy","status":"success","started_on":"\#(DemoClock.iso(hoursAgo: 96))","ended_on":"\#(DemoClock.iso(hoursAgo: 96))"},"deployment_trigger":{"type":"github:push","metadata":{"branch":"main","commit_hash":"\#(commits[2].hash)","commit_message":"\#(commits[2].message)"}},"aliases":null}
      """#,
    ]
  }

  /// The newest production deployment answers on the project's custom domain
  /// when it has one — that alias is what the deployment screen shows instead
  /// of the pages.dev hash.
  private static func pagesAliases(project: String) -> String {
    switch project {
    case "marketing-site": #"["https://www.example.org"]"#
    case "foxglove-www": #"["https://www.foxglove.studio"]"#
    default: "null"
    }
  }

  static let pagesBuildLogs = #"""
    {"total":6,"includes_container_logs":false,"data":[
      {"ts":"\#(DemoClock.iso(hoursAgo: 2))","line":"Cloning repository..."},
      {"ts":"\#(DemoClock.iso(hoursAgo: 2))","line":"Installing dependencies with pnpm"},
      {"ts":"\#(DemoClock.iso(hoursAgo: 2))","line":"Running build command: pnpm build"},
      {"ts":"\#(DemoClock.iso(hoursAgo: 2))","line":"Compiled 42 routes in 8.3s"},
      {"ts":"\#(DemoClock.iso(hoursAgo: 2))","line":"Uploading build output (3.2 MB)"},
      {"ts":"\#(DemoClock.iso(hoursAgo: 2))","line":"Success: deployment is live"}
    ]}
    """#

  // MARK: R2

  struct R2DemoObject {
    let key: String
    let contentType: String
    let body: Data

    var listJSON: String {
      #"{"key":"\#(key)","size":\#(body.count),"etag":"demo-\#(DemoWorld.seed(key))","last_modified":"\#(DemoClock.iso(hoursAgo: 30))","http_metadata":{"contentType":"\#(contentType)"}}"#
    }
  }

  struct R2DemoBucket {
    let name: String
    let creationDate: String
    let r2DevDomain: String
    let r2DevEnabled: Bool
    let objects: [R2DemoObject]

    var json: String {
      #"{"name":"\#(name)","creation_date":"\#(creationDate)"}"#
    }
  }

  /// A 1×1 transparent PNG — real bytes so thumbnails and previews work.
  static let tinyPNG = Data(
    base64Encoded:
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
  )!

  static func r2Buckets(accountID: String) -> [R2DemoBucket] {
    switch accountID {
    case "demo-account":
      return [
        R2DemoBucket(
          name: "assets", creationDate: "2026-01-15T12:00:00Z",
          r2DevDomain: "pub-dash-demo.r2.dev", r2DevEnabled: true, objects: assetsObjects),
        R2DemoBucket(
          name: "backups", creationDate: "2025-09-01T12:00:00Z",
          r2DevDomain: "pub-dash-backups.r2.dev", r2DevEnabled: false, objects: backupsObjects),
      ]
    case "demo-account-studio":
      return [
        R2DemoBucket(
          name: "studio-media", creationDate: "2025-03-08T10:30:00Z",
          r2DevDomain: "pub-foxglove-media.r2.dev", r2DevEnabled: true, objects: studioMediaObjects)
      ]
    case "demo-account-side":
      return [
        R2DemoBucket(
          name: "uploads", creationDate: "2026-05-11T21:10:00Z",
          r2DevDomain: "pub-inkline-uploads.r2.dev", r2DevEnabled: false, objects: uploadsObjects)
      ]
    default:
      return []
    }
  }

  private static var assetsObjects: [R2DemoObject] {
    var objects = [
      R2DemoObject(
        key: "readme.md", contentType: "text/markdown",
        body: Data(
          """
          # Assets bucket

          Static files served through the `assets` R2 bucket.

          - `styles.css` — the marketing site stylesheet
          - `images/` — logos and icons
          - `notes.txt` — deploy checklist
          """.utf8)),
      R2DemoObject(
        key: "styles.css", contentType: "text/css",
        body: Data(
          """
          :root {
            --brand: #f6821f;
            --ink: #1d1d1f;
          }

          body {
            font-family: -apple-system, sans-serif;
            color: var(--ink);
          }
          """.utf8)),
      R2DemoObject(
        key: "notes.txt", contentType: "text/plain",
        body: Data(
          """
          Deploy checklist
          1. pnpm build
          2. wrangler pages deploy
          3. purge the cache
          """.utf8)),
      R2DemoObject(
        key: "data.json", contentType: "application/json",
        body: Data(#"{"regions":["iad","lhr","hkg"],"buildID":"9c2f4e1"}"#.utf8)),
      R2DemoObject(key: "images/logo.png", contentType: "image/png", body: tinyPNG),
      R2DemoObject(key: "images/favicon.png", contentType: "image/png", body: tinyPNG),
    ]
    for folder in ["media", "docs", "build", "archive"] {
      for index in 1...24 {
        let key = "\(folder)/file-\(String(format: "%03d", index)).txt"
        objects.append(
          R2DemoObject(
            key: key, contentType: "text/plain",
            body: Data("bulk demo object \(key)\n".utf8)))
      }
    }
    return objects
  }

  private static var backupsObjects: [R2DemoObject] {
    var objects = [
      R2DemoObject(
        key: "kv-export-2026-07-20.json", contentType: "application/json",
        body: Data(#"{"exported":"2026-07-20T04:00:00Z","keys":3}"#.utf8)),
      R2DemoObject(
        key: "dns-snapshot.txt", contentType: "text/plain",
        body: Data("example.com A 203.0.113.10\nwww CNAME example.com\n".utf8)),
    ]
    objects += (1...40).map { index in
      R2DemoObject(
        key: "snapshots/day-\(String(format: "%03d", index)).json",
        contentType: "application/json",
        body: Data(#"{"day":\#(index),"ok":true}"#.utf8))
    }
    return objects
  }

  private static var studioMediaObjects: [R2DemoObject] {
    var objects = [
      R2DemoObject(
        key: "brand-guide.md", contentType: "text/markdown",
        body: Data(
          """
          # Foxglove Studio brand

          - Logo lockups live in `logos/`
          - Client shoots live in `clients/`
          - Never re-export the wordmark below 240px wide
          """.utf8)),
      R2DemoObject(key: "logos/foxglove-mark.png", contentType: "image/png", body: tinyPNG),
      R2DemoObject(key: "logos/foxglove-wordmark.png", contentType: "image/png", body: tinyPNG),
      R2DemoObject(
        key: "rate-card.json", contentType: "application/json",
        body: Data(#"{"currency":"EUR","dayRate":980,"retainerMonths":6}"#.utf8)),
    ]
    for client in ["northgate", "sundial", "verity"] {
      for index in 1...8 {
        objects.append(
          R2DemoObject(
            key: "clients/\(client)/shot-\(String(format: "%02d", index)).png",
            contentType: "image/png", body: tinyPNG))
      }
    }
    return objects
  }

  private static var uploadsObjects: [R2DemoObject] {
    [
      R2DemoObject(
        key: "og-image.png", contentType: "image/png", body: tinyPNG),
      R2DemoObject(
        key: "resume.md", contentType: "text/markdown",
        body: Data("# Résumé\n\nStill a work in progress.\n".utf8)),
      R2DemoObject(
        key: "links.json", contentType: "application/json",
        body: Data(#"{"dash":"https://dash.xat.sh","notes":"https://notes.inkline.dev"}"#.utf8)),
    ]
  }

  // MARK: KV

  struct KVDemoNamespace {
    let id: String
    let title: String

    var json: String { #"{"id":"\#(id)","title":"\#(title)"}"# }
  }

  static func kvNamespaces(accountID: String) -> [KVDemoNamespace] {
    switch accountID {
    case "demo-account":
      return [
        KVDemoNamespace(id: "kv-prod", title: "production-config"),
        KVDemoNamespace(id: "kv-cache", title: "edge-cache"),
      ]
    case "demo-account-studio":
      return [KVDemoNamespace(id: "kv-studio", title: "studio-settings")]
    default:
      // Namespaces cannot be created in Dash, so the hobby account is also
      // how the KV empty state gets seen at all.
      return []
    }
  }

  static func kvKeys(in namespace: String) -> [String] {
    switch namespace {
    case "kv-prod":
      var keys = [
        #"{"name":"config:homepage"}"#,
        #"{"name":"feature-flags"}"#,
        #"{"name":"session:8f3a2c","expiration":1795000000}"#,
      ]
      // After \#(...), keep a content quote before } — otherwise `"#` steals it
      // and the JSON string never closes (`{"name":"bulk:item-001}`).
      keys += (1...96).map { index in
        let name = String(format: "bulk:item-%03d", index)
        return #"{"name":"\#(name)"}"#
      }
      return keys
    case "kv-cache":
      var keys = [
        #"{"name":"cache:hero-image"}"#,
        #"{"name":"cache:pricing-table"}"#,
      ]
      keys += (1...48).map { index in
        let name = String(format: "cache:page-%03d", index)
        return #"{"name":"\#(name)"}"#
      }
      return keys
    case "kv-studio":
      return [
        #"{"name":"site:nav"}"#,
        #"{"name":"site:theme"}"#,
        #"{"name":"redirects"}"#,
      ]
    default:
      return []
    }
  }

  static func kvValue(namespace: String, key: String) -> String {
    switch (namespace, key) {
    case ("kv-prod", "config:homepage"):
      return #"{"title":"Example, Inc.","heroImage":"/images/logo.png","cacheSeconds":300}"#
    case ("kv-prod", "feature-flags"):
      return #"{"newDashboard":true,"betaBanner":false,"maxUploadMB":100}"#
    case ("kv-prod", "session:8f3a2c"):
      return #"{"userID":"u-1042","createdAt":"\#(DemoClock.iso(hoursAgo: 4))"}"#
    case ("kv-cache", "cache:hero-image"):
      return #"{"etag":"9c2f4e1","bytes":48213}"#
    case ("kv-cache", "cache:pricing-table"):
      return #"{"etag":"77aa02e","bytes":9120}"#
    case ("kv-studio", "site:nav"):
      return #"{"items":[{"label":"Work","href":"/work"},{"label":"Studio","href":"/studio"}]}"#
    case ("kv-studio", "site:theme"):
      // Extra `#` on the delimiters: a hex colour puts `"#` right after the
      // key's colon, which would otherwise close a `#"…"#` string early.
      return ##"{"accent":"#7a4fbf","radius":18,"grain":true}"##
    case ("kv-studio", "redirects"):
      return #"{"/portfolio":"/work","/about":"/studio"}"#
    default:
      if key.hasPrefix("bulk:") || key.hasPrefix("cache:page-") {
        return #"{"key":"\#(key)","demo":true}"#
      }
      return "{}"
    }
  }

  // MARK: Web Analytics sites

  static func rumSites(accountID: String) -> String {
    let sites: [String] =
      switch accountID {
      case "demo-account":
        [
          #"{"site_tag":"demo-site","site_token":"demo-token","auto_install":true,"ruleset":{"id":"demo-ruleset","zone_tag":"zone-example","zone_name":"example.com","enabled":true}}"#,
          #"{"site_tag":"docs-site","site_token":"docs-token","auto_install":true,"ruleset":{"id":"docs-ruleset","zone_tag":"zone-docs","zone_name":"docs.example.com","enabled":true}}"#,
          #"{"site_tag":"api-site","site_token":"api-token","auto_install":true,"ruleset":{"id":"api-ruleset","zone_tag":"zone-api","zone_name":"api.example.net","enabled":false}}"#,
          #"{"site_tag":"shop-site","site_token":"shop-token","auto_install":true,"ruleset":{"id":"shop-ruleset","zone_tag":"zone-shop","zone_name":"shop.example.org","enabled":true}}"#,
          #"{"site_tag":"northwind-site","site_token":"northwind-token","auto_install":true,"ruleset":{"id":"northwind-ruleset","zone_tag":"zone-bulk-1","zone_name":"northwind.io","enabled":true}}"#,
        ]
      case "demo-account-studio":
        [
          #"{"site_tag":"foxglove-site","site_token":"foxglove-token","auto_install":true,"ruleset":{"id":"foxglove-ruleset","zone_tag":"zone-studio-www","zone_name":"foxglove.studio","enabled":true}}"#
        ]
      default:
        []
      }
    return "[\(sites.joined(separator: ","))]"
  }

  // MARK: Alerts / audit

  static func alertHistory(accountID: String) -> String {
    let entries: [String] =
      switch accountID {
      case "demo-account":
        [
          #"{"id":"hist-tunnel-1","policy_id":"pol-1","name":"Tunnel health","alert_type":"tunnel_health_event","mechanism":"email","alert_body":"homelab-01 disconnected from Cloudflare","sent":"\#(DemoClock.iso(hoursAgo: 6))"}"#,
          #"{"id":"hist-pages-1","policy_id":"pol-2","name":"Pages build alerts","alert_type":"pages_event_alert","mechanism":"email","alert_body":"marketing-site: production build failed","sent":"\#(DemoClock.iso(hoursAgo: 26))"}"#,
        ]
      case "demo-account-studio":
        [
          #"{"id":"hist-studio-ssl","policy_id":"pol-studio-1","name":"Universal SSL","alert_type":"universal_ssl_event_type","mechanism":"email","alert_body":"preview.foxglove.studio: certificate validation is pending","sent":"\#(DemoClock.iso(hoursAgo: 11))"}"#,
          #"{"id":"hist-studio-origin","policy_id":"pol-studio-2","name":"Origin errors","alert_type":"http_alert_origin_error","mechanism":"email","alert_body":"clients.foxglove.studio: origin returned 5xx for 4% of requests","sent":"\#(DemoClock.iso(hoursAgo: 40))"}"#,
        ]
      default:
        // Nothing has ever gone wrong here, which is its own thing to see:
        // an empty Watchtower inbox and no badge on the tab.
        []
      }
    return "[\(entries.joined(separator: ","))]"
  }

  static func auditLogs(accountID: String) -> String {
    let entries: [String] =
      switch accountID {
      case "demo-account":
        [
          #"{"id":"log-1","action":{"type":"rollback","description":"Rolled back Worker deployment","result":"success","time":"\#(DemoClock.iso(hoursAgo: 5))"},"actor":{"email":"demo@example.com","type":"user"},"resource":{"type":"script","product":"workers","id":"api-worker"},"when":"\#(DemoClock.iso(hoursAgo: 5))"}"#,
          #"{"id":"log-2","action":{"type":"add","description":"Created DNS record","result":"success","time":"\#(DemoClock.iso(hoursAgo: 22))"},"actor":{"email":"demo@example.com","type":"user"},"resource":{"type":"dns_record","product":"dns","id":"dns-caa"},"when":"\#(DemoClock.iso(hoursAgo: 22))"}"#,
          #"{"id":"log-3","action":{"type":"purge","description":"Purged zone cache","result":"success","time":"\#(DemoClock.iso(hoursAgo: 49))"},"actor":{"email":"demo@example.com","type":"user"},"resource":{"type":"zone","product":"caching","id":"zone-example"},"when":"\#(DemoClock.iso(hoursAgo: 49))"}"#,
        ]
      case "demo-account-studio":
        [
          #"{"id":"log-studio-1","action":{"type":"add","description":"Added custom domain to Worker","result":"success","time":"\#(DemoClock.iso(hoursAgo: 9))"},"actor":{"email":"demo@example.com","type":"user"},"resource":{"type":"worker_domain","product":"workers","id":"images.foxglove.studio"},"when":"\#(DemoClock.iso(hoursAgo: 9))"}"#,
          #"{"id":"log-studio-2","action":{"type":"add","description":"Added domain","result":"success","time":"\#(DemoClock.iso(hoursAgo: 64))"},"actor":{"email":"demo@example.com","type":"user"},"resource":{"type":"zone","product":"zones","id":"zone-studio-preview"},"when":"\#(DemoClock.iso(hoursAgo: 64))"}"#,
        ]
      default:
        [
          #"{"id":"log-side-1","action":{"type":"add","description":"Created R2 bucket","result":"success","time":"\#(DemoClock.iso(hoursAgo: 120))"},"actor":{"email":"demo@example.com","type":"user"},"resource":{"type":"bucket","product":"r2","id":"uploads"},"when":"\#(DemoClock.iso(hoursAgo: 120))"}"#
        ]
      }
    return "[\(entries.joined(separator: ","))]"
  }

  // MARK: Zone fixtures

  static func dnsRecords(zone: Zone) -> [String] {
    guard zone.id == "zone-example" else {
      return [
        #"{"id":"dns-\#(zone.id)-a","zone_id":"\#(zone.id)","type":"A","name":"\#(zone.name)","content":"203.0.113.24","proxied":true,"ttl":1}"#,
        #"{"id":"dns-\#(zone.id)-www","zone_id":"\#(zone.id)","type":"CNAME","name":"www.\#(zone.name)","content":"\#(zone.name)","proxied":true,"ttl":1}"#,
      ]
    }
    return [
      #"{"id":"dns-a-root","zone_id":"zone-example","type":"A","name":"example.com","content":"203.0.113.10","proxied":true,"ttl":1,"comment":"Origin server"}"#,
      #"{"id":"dns-a-www","zone_id":"zone-example","type":"A","name":"www.example.com","content":"203.0.113.10","proxied":true,"ttl":1}"#,
      #"{"id":"dns-aaaa","zone_id":"zone-example","type":"AAAA","name":"example.com","content":"2001:db8::10","proxied":true,"ttl":1}"#,
      #"{"id":"dns-cname-docs","zone_id":"zone-example","type":"CNAME","name":"docs.example.com","content":"example.com","proxied":false,"ttl":300}"#,
      #"{"id":"dns-mx","zone_id":"zone-example","type":"MX","name":"example.com","content":"route1.mx.cloudflare.net","proxied":false,"ttl":300,"priority":5}"#,
      #"{"id":"dns-txt-spf","zone_id":"zone-example","type":"TXT","name":"example.com","content":"v=spf1 include:_spf.mx.cloudflare.net ~all","proxied":false,"ttl":300}"#,
      #"{"id":"dns-srv","zone_id":"zone-example","type":"SRV","name":"_sip._tcp.example.com","content":"10 5 5060 sip.example.com","proxied":false,"ttl":300,"data":{"priority":10,"weight":5,"port":5060,"target":"sip.example.com"}}"#,
      #"{"id":"dns-caa","zone_id":"zone-example","type":"CAA","name":"example.com","content":"0 issue \"letsencrypt.org\"","proxied":false,"ttl":300,"data":{"flags":0,"tag":"issue","value":"letsencrypt.org"}}"#,
    ]
  }

  static let zoneSettings = #"""
    [
      {"id":"security_level","value":"medium","editable":true},
      {"id":"development_mode","value":"off","editable":true},
      {"id":"ssl","value":"full","editable":true},
      {"id":"always_online","value":"on","editable":true},
      {"id":"always_use_https","value":"on","editable":true},
      {"id":"advanced_ddos","value":"on","editable":false},
      {"id":"min_tls_version","value":"1.2","editable":true},
      {"id":"browser_cache_ttl","value":14400,"editable":true}
    ]
    """#

  // MARK: GraphQL payloads

  /// Deterministic traffic wave: a day-shaped curve so charts look alive
  /// without randomness (pull-to-refresh should not rewrite history).
  private static func wave(_ index: Int, base: Int, swing: Int) -> Int {
    let phase = Double(index) * .pi / 12
    return base + Int(Double(swing) * (0.5 + 0.5 * sin(phase - .pi / 2)))
  }

  static func zoneAnalyticsHourly(hours: Int = 24, scale: Double) -> String {
    let count = max(hours, 1)
    func rows(previous: Bool) -> [String] {
      (0..<count).map { hour -> String in
        let rawRequests = wave(hour, base: 620, swing: 1400)
        let requests = scaled(previous ? rawRequests * 84 / 100 : rawRequests, scale)
        let hoursAgo = (previous ? count * 2 - 1 : count - 1) - hour
        return
          #"{"dimensions":{"datetime":"\#(DemoClock.isoHour(hoursAgo: hoursAgo))"},"sum":{"requests":\#(requests),"pageViews":\#(requests * 3 / 5),"threats":\#(hour % 7 == 0 ? scaledOrZero(previous ? 2 : 3, scale) : 0),"bytes":\#(requests * 11800),"cachedRequests":\#(requests * (previous ? 76 : 82) / 100),"cachedBytes":\#(requests * 11800 * (previous ? 68 : 74) / 100)},"uniq":{"uniques":\#(requests / 7)}}"#
      }
    }
    let current = rows(previous: false).joined(separator: ",")
    let previous = rows(previous: true).joined(separator: ",")
    return #"""
      {"data":{"viewer":{"zones":[{
        "current":[\#(current)],
        "previous":[\#(previous)],
        "httpRequests1hGroups":[\#(current)]
      }]}},"errors":null}
      """#
  }

  static func zoneRequestsHourly(scale: Double) -> String {
    let rows = (0..<24).map { hour -> String in
      let requests = scaled(wave(hour, base: 620, swing: 1400), scale)
      return
        #"{"count":\#(requests),"dimensions":{"datetimeHour":"\#(DemoClock.isoHour(hoursAgo: 23 - hour))"}}"#
    }
    return
      #"{"data":{"viewer":{"zones":[{"httpRequestsAdaptiveGroups":[\#(rows.joined(separator: ","))]}]}},"errors":null}"#
  }

  static func zoneAnalyticsDaily(days: Int = 7, scale: Double) -> String {
    let count = max(days, 1)
    func rows(previous: Bool) -> [String] {
      (0..<count).map { day -> String in
        let rawRequests = 18_500 + wave(day, base: 0, swing: 9000)
        let requests = scaled(previous ? rawRequests * 88 / 100 : rawRequests, scale)
        let daysAgo = (previous ? count + 1 : 1) + day
        return
          #"{"dimensions":{"date":"\#(DemoClock.isoDay(daysAgo: daysAgo))"},"sum":{"requests":\#(requests),"pageViews":\#(requests * 3 / 5),"threats":\#(scaledOrZero(day % 3 == 0 ? (previous ? 10 : 14) : 2, scale)),"bytes":\#(requests * 11800),"cachedRequests":\#(requests * (previous ? 73 : 79) / 100),"cachedBytes":\#(requests * 11800 * (previous ? 65 : 71) / 100)},"uniq":{"uniques":\#(requests / 9)}}"#
      }
    }
    let current = rows(previous: false).joined(separator: ",")
    let previous = rows(previous: true).joined(separator: ",")
    return #"""
      {"data":{"viewer":{"zones":[{
        "current":[\#(current)],
        "previous":[\#(previous)],
        "httpRequests1dGroups":[\#(current)]
      }]}},"errors":null}
      """#
  }

  static func rumPageviews(days: Int, scale: Double) -> String {
    let rows = (0..<max(days, 1)).map { day -> String in
      let views = scaled(640 + wave(day, base: 0, swing: 420), scale)
      return
        #"{"count":\#(views),"dimensions":{"date":"\#(DemoClock.isoDay(daysAgo: days - 1 - day))"}}"#
    }
    return
      #"{"data":{"viewer":{"accounts":[{"rumPageloadEventsAdaptiveGroups":[\#(rows.joined(separator: ","))]}]}},"errors":null}"#
  }

  static func rumMetrics(days: Int, scale: Double) -> String {
    let count = max(days, 1)
    let pageload = (0..<count).map { day -> String in
      // Floor at 2 so the `visits` share below never rounds down to zero — a
      // demo chart with a zero row reads as a broken fetch, not as low traffic.
      let views = max(2, scaled(640 + wave(day, base: 0, swing: 420), scale))
      return
        #"{"count":\#(views),"sum":{"visits":\#(max(1, views * 47 / 100))},"dimensions":{"date":"\#(DemoClock.isoDay(daysAgo: count - day))"}}"#
    }
    let performanceValues = (0..<count).map { day -> Int in
      // Latency is not volume: a quiet account is not a faster one.
      680 + wave(day, base: 0, swing: 260)
    }
    let performance = performanceValues.enumerated().map { day, p50 -> String in
      return
        #"{"quantiles":{"pageLoadTimeP50":\#(p50)},"dimensions":{"date":"\#(DemoClock.isoDay(daysAgo: count - day))"}}"#
    }
    let window = max(count / 2, 1)
    let currentP50 =
      performanceValues.suffix(window).reduce(0, +) / min(window, performanceValues.count)
    let previousValues = performanceValues.prefix(max(performanceValues.count - window, 0))
    let previousP50 =
      previousValues.isEmpty
      ? currentP50
      : previousValues.reduce(0, +) / previousValues.count
    // Web Vitals arrive in microseconds for LCP / INP; CLS is unitless.
    let vitals = (0..<count).map { day -> String in
      let lcp = (1_800_000 + wave(day, base: 0, swing: 400_000))
      let inp = (120_000 + wave(day, base: 0, swing: 40_000))
      let cls = String(format: "%.3f", 0.08 + Double(wave(day, base: 0, swing: 6)) / 100)
      return
        #"{"quantiles":{"largestContentfulPaintP75":\#(lcp),"interactionToNextPaintP75":\#(inp),"cumulativeLayoutShiftP75":\#(cls)},"dimensions":{"date":"\#(DemoClock.isoDay(daysAgo: count - day))"}}"#
    }
    return #"""
      {"data":{"viewer":{"accounts":[{
        "pageload":[\#(pageload.joined(separator: ","))],
        "performance":[\#(performance.joined(separator: ","))],
        "vitals":[\#(vitals.joined(separator: ","))],
        "currentPerformanceTotals":[{"quantiles":{"pageLoadTimeP50":\#(currentP50)}}],
        "previousPerformanceTotals":[{"quantiles":{"pageLoadTimeP50":\#(previousP50)}}],
        "currentVitalsTotals":[{"quantiles":{"largestContentfulPaintP75":2100000,"interactionToNextPaintP75":140000,"cumulativeLayoutShiftP75":0.09}}],
        "previousVitalsTotals":[{"quantiles":{"largestContentfulPaintP75":2300000,"interactionToNextPaintP75":160000,"cumulativeLayoutShiftP75":0.11}}]
      }]}},"errors":null}
      """#
  }

  static func workerAnalytics(scale: Double) -> String {
    let samples = (0..<12).map { slot -> (json: String, requests: Int, errors: Int) in
      let requests = scaled(wave(slot, base: 80, swing: 160), scale)
      let errors = slot == 7 ? scaledOrZero(3, scale) : 0
      let cpu = Double(wave(slot, base: 640, swing: 420)) + (slot == 7 ? 380.0 : 0.0)
      return (
        #"{"sum":{"requests":\#(requests),"errors":\#(errors)},"quantiles":{"cpuTimeP50":\#(cpu)},"dimensions":{"datetimeFiveMinutes":"\#(DemoClock.isoFiveMinutes(slotsAgo: 11 - slot))","status":"success"}}"#,
        requests,
        errors
      )
    }
    let currentRequests = samples.reduce(0) { $0 + $1.requests }
    let currentErrors = samples.reduce(0) { $0 + $1.errors }
    let previousRequests = currentRequests * 81 / 100
    let previousErrors = max(0, currentErrors - 1)
    return #"""
      {"data":{"viewer":{"accounts":[{
        "currentTotals":[{"sum":{"requests":\#(currentRequests),"errors":\#(currentErrors)},"quantiles":{"cpuTimeP50":1040.0}}],
        "previousTotals":[{"sum":{"requests":\#(previousRequests),"errors":\#(previousErrors)},"quantiles":{"cpuTimeP50":870.0}}],
        "workersInvocationsAdaptive":[\#(samples.map(\.json).joined(separator: ","))]
      }]}},"errors":null}
      """#
  }

  /// Account overview + series for Watchtower's 24h / 7d / 30d ranges.
  /// Hourly stamps for short windows; the client also accepts `date` buckets.
  static func accountAnalyticsOverview(scale: Double) -> String {
    let httpSeries = (0..<24).map { slot -> String in
      let requests = scaled(wave(slot, base: 420, swing: 280), scale)
      let bytes = requests * 48_000
      let cache = 0.55 + Double(slot % 5) * 0.03
      let encrypted = 0.94 + Double(slot % 3) * 0.01
      let status4xx = slot == 11 ? 0.08 : 0.015
      return #"""
        {"sum":{"requests":\#(requests),"bytes":\#(bytes)},"ratio":{"cachedRequests":\#(cache),"encryptedRequests":\#(encrypted),"encryptedBytes":\#(encrypted - 0.02),"status4xx":\#(status4xx)},"dimensions":{"datetimeHour":"\#(DemoClock.isoHour(hoursAgo: 23 - slot))"}}
        """#
    }
    let workerSeries = (0..<24).map { slot -> String in
      let requests = scaled(wave(slot, base: 160, swing: 90), scale)
      let errors = slot == 11 ? scaledOrZero(4, scale) : 0
      let cpu = Double(wave(slot, base: 900, swing: 500))
      return #"""
        {"sum":{"requests":\#(requests),"errors":\#(errors)},"quantiles":{"cpuTimeP90":\#(cpu)},"dimensions":{"datetimeHour":"\#(DemoClock.isoHour(hoursAgo: 23 - slot))"}}
        """#
    }
    let webRequests = scaled(12_840, scale)
    let bytes = scaled(52_428_800, scale)
    return #"""
      {"data":{"viewer":{"accounts":[{
        "overview":[{
          "sum":{"requests":\#(webRequests),"bytes":\#(bytes)},
          "ratio":{"cachedRequests":0.62,"encryptedRequests":0.97,"encryptedBytes":0.94,"status4xx":0.018}
        }],
        "previousOverview":[{
          "sum":{"requests":\#(scaled(11_240, scale)),"bytes":\#(scaled(46_350_000, scale))},
          "ratio":{"cachedRequests":0.57,"encryptedRequests":0.95,"encryptedBytes":0.91,"status4xx":0.024}
        }],
        "httpSeries":[\#(httpSeries.joined(separator: ","))],
        "workers":[{
          "sum":{"requests":\#(scaled(4820, scale)),"errors":\#(scaledOrZero(12, scale))},
          "quantiles":{"cpuTimeP90":1260.0}
        }],
        "previousWorkers":[{
          "sum":{"requests":\#(scaled(4310, scale)),"errors":\#(scaledOrZero(19, scale))},
          "quantiles":{"cpuTimeP90":1490.0}
        }],
        "workerSeries":[\#(workerSeries.joined(separator: ","))]
      }]}},"errors":null}
      """#
  }

  /// WAF summary fixture: hourly ByTimeGroups totals plus Adaptive samples for
  /// country / rule tops. Counts stay small so the demo payload stays light.
  static func firewallEvents(scale: Double) -> String {
    let us = max(scaled(8, scale), 1)
    let cn = max(scaled(5, scale), 1)
    let ru = max(scaled(3, scale), 1)
    let br = max(scaled(2, scale), 1)
    var events: [String] = []
    events += Array(
      repeating: #"{"clientCountryName":"US","ruleId":"rate-limit-login"}"#, count: us)
    events += Array(repeating: #"{"clientCountryName":"CN","ruleId":"block-bad-bots"}"#, count: cn)
    events += Array(
      repeating: #"{"clientCountryName":"RU","ruleId":"rate-limit-login"}"#, count: ru)
    events += Array(repeating: #"{"clientCountryName":"BR","ruleId":"block-bad-bots"}"#, count: br)
    let total = us + cn + ru + br
    let series = (0..<24).reversed().map { hour -> String in
      let count = hour == 0 ? total : max(total / 8, 1)
      return
        #"{"count":\#(count),"dimensions":{"datetimeHour":"\#(DemoClock.isoHour(hoursAgo: hour))"}}"#
    }
    return #"""
      {"data":{"viewer":{"zones":[{
        "byTime":[\#(series.joined(separator: ","))],
        "samples":[\#(events.joined(separator: ","))]
      }]}},"errors":null}
      """#
  }
}

// MARK: - Relative clock

/// ISO 8601 stamps relative to now, so "time ago" labels and charts stay
/// believable no matter when the demo runs.
private enum DemoClock {
  // Formatters are documented thread-safe; Sendable just cannot see it.
  nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter
  }()

  private static let dayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter
  }()

  static func iso(hoursAgo: Int) -> String {
    formatter.string(from: Date().addingTimeInterval(-TimeInterval(hoursAgo) * 3600))
  }

  static func isoHour(hoursAgo: Int) -> String {
    let now = Date().timeIntervalSince1970
    let aligned = (now - Double(hoursAgo) * 3600).rounded(.down)
    let hourAligned = aligned - aligned.truncatingRemainder(dividingBy: 3600)
    return formatter.string(from: Date(timeIntervalSince1970: hourAligned))
  }

  static func isoFiveMinutes(slotsAgo: Int) -> String {
    let now = Date().timeIntervalSince1970
    let aligned = now - now.truncatingRemainder(dividingBy: 300)
    return formatter.string(from: Date(timeIntervalSince1970: aligned - Double(slotsAgo) * 300))
  }

  static func isoDay(daysAgo: Int) -> String {
    dayFormatter.string(from: Date().addingTimeInterval(-TimeInterval(daysAgo) * 86400))
  }
}

extension String {
  fileprivate var nilIfEmptyDemo: String? { isEmpty ? nil : self }
}
