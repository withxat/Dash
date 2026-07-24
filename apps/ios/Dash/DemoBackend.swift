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
        #"[{"id":"demo-account","name":"Demo Workspace","type":"standard","created_on":"2024-03-01T09:00:00Z"}]"#,
        info: #"{"page":1,"per_page":20,"total_count":1}"#)
    case "/zones":
      let zones = DemoWorld.zones.filter { zone in
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

    // /zones/{id}/...
    if parts.count >= 2, parts[0] == "zones", let zone = DemoWorld.zone(id: parts[1]) {
      let rest = Array(parts.dropFirst(2))
      switch rest.first {
      case nil:
        return ok(zone.json)
      case "dns_records"?:
        var records = DemoWorld.dnsRecords(zoneID: zone.id)
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
        let routes =
          zone.id == "zone-example"
          ? #"[{"id":"route-1","pattern":"example.com/api/*","script":"api-worker"}]"# : "[]"
        return ok(routes)
      case "ssl"? where rest.count >= 2 && rest[1] == "certificate_packs":
        return ok(
          #"[{"id":"cp-\#(zone.id)","status":"active","certificates":[{"expires_on":"2026-10-05T12:00:00Z"}]}]"#
        )
      case "healthchecks"?:
        return ok("[]")
      default:
        return ok("[]")
      }
    }

    // /accounts/demo-account/...
    guard parts.count >= 2, parts[0] == "accounts", parts[1] == accountID else {
      return ok("[]")
    }
    let rest = Array(parts.dropFirst(2))

    switch rest.first {
    case "workers"?:
      return workers(rest: Array(rest.dropFirst()))
    case "pages"?:
      return pages(rest: Array(rest.dropFirst()))
    case "r2"?:
      return r2(
        rest: Array(rest.dropFirst()), prefix: query("prefix"), delimiter: query("delimiter"))
    case "rum"?:
      // Only zone-example carries a Web Analytics site, so the demo shows both
      // the populated screen and the beacon-missing empty state.
      return ok(DemoWorld.rumSites)
    case "storage"?:
      return kv(rest: Array(rest.dropFirst()), prefix: query("prefix"))
    case "cfd_tunnel"?:
      return ok(
        #"[{"id":"tunnel-1","name":"homelab-01","status":"down"},{"id":"tunnel-2","name":"office-gateway","status":"healthy"}]"#
      )
    case "load_balancers"?:
      return ok("[]")
    case "registrar"?:
      return ok(#"[{"id":"example.com","name":"example.com","expires_at":"2027-05-12T00:00:00Z"}]"#)
    case "alerting"?:
      if rest.contains("available_alerts") { return ok("{}") }
      if rest.contains("history") { return ok(DemoWorld.alertHistory) }
      return ok("[]")
    case "audit_logs"?:
      return ok(DemoWorld.auditLogs)
    case "logs"? where rest.count >= 2 && rest[1] == "audit":
      return ok(DemoWorld.auditLogs)
    default:
      return ok("[]")
    }
  }

  // MARK: Workers

  private static func workers(rest: [String]) -> Reply {
    // workers/subdomain | workers/scripts[/{name}/(deployments|subdomain|content/v2)] | workers/domains
    if rest.first == "subdomain" {
      return ok(#"{"subdomain":"demo"}"#)
    }
    if rest.first == "domains" {
      return ok(
        #"[{"id":"wd-1","hostname":"api.example.net","service":"api-worker","zone_id":"zone-api","zone_name":"api.example.net","cert_id":"cert-1","environment":"production"}]"#
      )
    }
    guard rest.first == "scripts" else { return ok("[]") }
    if rest.count == 1 {
      return ok(
        "[\(DemoWorld.workerScripts.joined(separator: ","))]",
        info: #"{"page":1,"per_page":100,"total_count":\#(DemoWorld.workerScripts.count)}"#)
    }
    switch rest.dropFirst(2).first {
    case "deployments"?:
      return ok(
        #"""
        {"deployments":[
          {"id":"deploy-live","created_on":"\#(DemoClock.iso(hoursAgo: 2))","source":"api","strategy":"percentage","versions":[{"version_id":"v-2001","percentage":100}],"annotations":{"workers/message":"Ship the new rate limiter","workers/triggered_by":"deployment"},"author_email":"demo@example.com"},
          {"id":"deploy-prev","created_on":"\#(DemoClock.iso(hoursAgo: 74))","source":"wrangler","strategy":"percentage","versions":[{"version_id":"v-1994","percentage":100}],"author_email":"demo@example.com"}
        ]}
        """#)
    case "subdomain"?:
      return ok(#"{"enabled":true,"previews_enabled":false}"#)
    case "content"?:
      return Reply(
        contentType: "application/javascript",
        data: Data(DemoWorld.workerScript.utf8))
    default:
      return ok("[]")
    }
  }

  // MARK: Pages

  private static func pages(rest: [String]) -> Reply {
    // pages/projects[/{name}[/deployments[/{id}[/history/logs]] | /domains]]
    guard rest.first == "projects" else { return ok("[]") }
    if rest.count == 1 {
      return ok(
        "[\(DemoWorld.pagesProjects.joined(separator: ","))]",
        info:
          #"{"page":1,"per_page":25,"total_count":\#(DemoWorld.pagesProjects.count)}"#)
    }
    switch rest.dropFirst(2).first {
    case nil:
      let name = rest[1]
      return ok(DemoWorld.pagesProject(named: name))
    case "deployments":
      if rest.count >= 4 {
        if rest.contains("logs") { return ok(DemoWorld.pagesBuildLogs) }
        let id = rest[3]
        if let deployment = DemoWorld.pagesDeployments.first(where: { $0.contains("\"\(id)\"") }) {
          return ok(deployment)
        }
        return ok(DemoWorld.pagesDeployments[0])
      }
      return ok(
        "[\(DemoWorld.pagesDeployments.joined(separator: ","))]",
        info: #"{"page":1,"per_page":25,"total_count":\#(DemoWorld.pagesDeployments.count)}"#)
    case "domains"?:
      return ok(
        #"[{"id":"pdom-1","name":"www.example.org","status":"active","created_on":"2026-01-09T08:00:00Z","zone_tag":"zone-shop"}]"#
      )
    default:
      return ok("[]")
    }
  }

  // MARK: R2

  private static func r2(rest: [String], prefix: String?, delimiter: String?) -> Reply {
    // r2/buckets[/{bucket}/(objects[/key…] | domains/(managed|custom))]
    guard rest.first == "buckets" else { return ok("[]") }
    if rest.count == 1 {
      return ok(
        #"{"buckets":[{"name":"assets","creation_date":"2026-01-15T12:00:00Z"},{"name":"backups","creation_date":"2025-09-01T12:00:00Z"}]}"#
      )
    }
    let bucket = rest[1]
    let tail = Array(rest.dropFirst(2))
    switch tail.first {
    case "objects"?:
      let key = tail.dropFirst().joined(separator: "/")
      if key.isEmpty {
        return r2ObjectList(bucket: bucket, prefix: prefix ?? "", delimiter: delimiter)
      }
      guard let object = DemoWorld.r2Objects(in: bucket).first(where: { $0.key == key }) else {
        return Reply(
          status: 404,
          json:
            #"{"success":false,"errors":[{"code":10007,"message":"Object not found."}],"result":null}"#
        )
      }
      return Reply(contentType: object.contentType, data: object.body)
    case "domains"? where tail.count >= 2 && tail[1] == "managed":
      let domain = bucket == "assets" ? "pub-dash-demo.r2.dev" : "pub-dash-backups.r2.dev"
      let enabled = bucket == "assets"
      return ok(#"{"bucketId":"\#(bucket)","domain":"\#(domain)","enabled":\#(enabled)}"#)
    case "domains"?:
      return ok(#"{"domains":[]}"#)
    default:
      return ok("[]")
    }
  }

  private static func r2ObjectList(bucket: String, prefix: String, delimiter: String?) -> Reply {
    let all = DemoWorld.r2Objects(in: bucket).filter { $0.key.hasPrefix(prefix) }
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

  private static func kv(rest: [String], prefix: String?) -> Reply {
    // storage/kv/namespaces[/{id}/(keys|values/{key})]
    guard rest.count >= 2, rest[0] == "kv", rest[1] == "namespaces" else { return ok("[]") }
    let tail = Array(rest.dropFirst(2))
    if tail.isEmpty {
      return ok(
        #"[{"id":"kv-prod","title":"production-config"},{"id":"kv-cache","title":"edge-cache"}]"#,
        info: #"{"page":1,"per_page":20,"total_count":2}"#)
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
    // Account overview must win before the Workers / zone Adaptive matchers —
    // its document names both `httpRequestsOverviewAdaptiveGroups` and
    // `workersInvocationsAdaptive`, and Overview is not a substring of the
    // zone Adaptive node.
    if query.contains("httpRequestsOverviewAdaptiveGroups") {
      return Reply(json: DemoWorld.accountAnalyticsOverview())
    }
    if query.contains("workersInvocationsAdaptive") {
      return Reply(json: DemoWorld.workerAnalytics())
    }
    if query.contains("httpRequests1hGroups") {
      return Reply(json: DemoWorld.zoneAnalyticsHourly())
    }
    if query.contains("httpRequests1dGroups") {
      // The daily chart asks for 7 or 30 days through `limit:`; honor it so the
      // ranges are not identical fixtures.
      return Reply(json: DemoWorld.zoneAnalyticsDaily(days: limit(in: query) ?? 7))
    }
    if query.contains("httpRequestsAdaptiveGroups") {
      return Reply(json: DemoWorld.zoneRequestsHourly())
    }
    if query.contains("rumPageloadEventsAdaptiveGroups") {
      return Reply(json: DemoWorld.rumPageviews(days: limit(in: query) ?? 7))
    }
    if query.contains("firewallEventsAdaptiveGroups") {
      return Reply(json: DemoWorld.firewallEvents())
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
}

// MARK: - Fixture world

/// The demo's coherent world — core fixtures plus bulk lists for scroll /
/// pagination stress. Behavior stays in `DemoBackend`. Datetimes that feed
/// charts and "time ago" labels are generated relative to now so the demo
/// always looks alive.
private enum DemoWorld {
  struct Zone {
    let id: String
    let name: String
    let json: String
  }

  private static let coreZones: [Zone] = [
    Zone(
      id: "zone-example", name: "example.com",
      json:
        #"{"id":"zone-example","name":"example.com","status":"active","paused":false,"development_mode":0,"name_servers":["ada.ns.cloudflare.com","bob.ns.cloudflare.com"],"plan":{"id":"pro","name":"Pro Website","legacy_id":"pro"}}"#
    ),
    Zone(
      id: "zone-docs", name: "docs.example.com",
      json:
        #"{"id":"zone-docs","name":"docs.example.com","status":"active","paused":false,"development_mode":0,"name_servers":["ada.ns.cloudflare.com","bob.ns.cloudflare.com"],"plan":{"id":"free","name":"Free Website","legacy_id":"free"}}"#
    ),
    Zone(
      id: "zone-api", name: "api.example.net",
      json:
        #"{"id":"zone-api","name":"api.example.net","status":"pending","paused":false,"development_mode":0,"name_servers":["ada.ns.cloudflare.com","bob.ns.cloudflare.com"],"plan":{"id":"free","name":"Free Website","legacy_id":"free"}}"#
    ),
    Zone(
      id: "zone-shop", name: "shop.example.org",
      json:
        #"{"id":"zone-shop","name":"shop.example.org","status":"active","paused":false,"development_mode":0,"name_servers":["ada.ns.cloudflare.com","bob.ns.cloudflare.com"],"plan":{"id":"free","name":"Free Website","legacy_id":"free"}}"#
    ),
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

  static var zones: [Zone] {
    let bulk = bulkZoneNames.enumerated().map { offset, name -> Zone in
      let index = offset + 1
      let id = "zone-bulk-\(index)"
      let status = index % 11 == 0 ? "pending" : "active"
      return Zone(
        id: id, name: name,
        json:
          #"{"id":"\#(id)","name":"\#(name)","status":"\#(status)","paused":false,"development_mode":0,"name_servers":["ada.ns.cloudflare.com","bob.ns.cloudflare.com"],"plan":{"id":"free","name":"Free Website","legacy_id":"free"}}"#
      )
    }
    return coreZones + bulk
  }

  static func zone(id: String) -> Zone? { zones.first { $0.id == id } }

  static var workerScripts: [String] {
    var scripts = [
      #"{"id":"api-worker","tag":"w-api-1","modified_on":"2026-07-20T03:04:05Z","created_on":"2025-11-02T10:00:00Z"}"#,
      #"{"id":"edge-cache","tag":"w-edge-2","modified_on":"2026-07-18T22:11:00Z","created_on":"2026-02-14T08:30:00Z"}"#,
    ]
    scripts += (1...38).map { index in
      let id = "worker-\(String(format: "%02d", index))"
      return
        #"{"id":"\#(id)","tag":"w-bulk-\#(index)","modified_on":"\#(DemoClock.iso(hoursAgo: index))","created_on":"2026-01-01T10:00:00Z"}"#
    }
    return scripts
  }

  static var pagesProjects: [String] {
    var projects = [pagesProject(named: "marketing-site")]
    projects += (1...18).map { index in
      pagesProject(named: "site-\(String(format: "%02d", index))")
    }
    return projects
  }

  static func pagesProject(named name: String) -> String {
    let seed = name == "marketing-site" ? "7ab" : String(name.hashValue.magnitude % 1000)
    return #"""
      {"id":"pp-\#(name)","name":"\#(name)","subdomain":"\#(name)-\#(seed).pages.dev","created_on":"2026-01-08T12:00:00Z","latest_deployment":{"id":"pd-\#(name)-3","url":"https://\#(name)-\#(seed).pages.dev","environment":"production","created_on":"\#(DemoClock.iso(hoursAgo: 2))","latest_stage":{"name":"deploy","status":"success","started_on":"\#(DemoClock.iso(hoursAgo: 2))","ended_on":"\#(DemoClock.iso(hoursAgo: 2))"}}}
      """#
  }

  static func dnsRecords(zoneID: String) -> [String] {
    guard zoneID == "zone-example" else {
      return [
        #"{"id":"dns-\#(zoneID)-a","zone_id":"\#(zoneID)","type":"A","name":"@","content":"203.0.113.24","proxied":true,"ttl":1}"#,
        #"{"id":"dns-\#(zoneID)-www","zone_id":"\#(zoneID)","type":"CNAME","name":"www","content":"example.com","proxied":true,"ttl":1}"#,
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

  static let workerScript = """
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

  static let pagesDeployments: [String] = [
    #"""
    {"id":"pd-3","short_id":"7ab12cd","url":"https://marketing-site-7ab.pages.dev","environment":"production","created_on":"\#(DemoClock.iso(hoursAgo: 2))","modified_on":"\#(DemoClock.iso(hoursAgo: 2))","project_name":"marketing-site","is_skipped":false,"latest_stage":{"name":"deploy","status":"success","started_on":"\#(DemoClock.iso(hoursAgo: 2))","ended_on":"\#(DemoClock.iso(hoursAgo: 2))"},"deployment_trigger":{"type":"github:push","metadata":{"branch":"main","commit_hash":"9c2f4e1","commit_message":"Polish the hero copy"}},"aliases":["https://www.example.org"]}
    """#,
    #"""
    {"id":"pd-2","short_id":"5fe98ba","url":"https://5fe98ba.marketing-site-7ab.pages.dev","environment":"production","created_on":"\#(DemoClock.iso(hoursAgo: 26))","modified_on":"\#(DemoClock.iso(hoursAgo: 26))","project_name":"marketing-site","is_skipped":false,"latest_stage":{"name":"build","status":"failure","started_on":"\#(DemoClock.iso(hoursAgo: 26))","ended_on":"\#(DemoClock.iso(hoursAgo: 26))"},"deployment_trigger":{"type":"github:push","metadata":{"branch":"main","commit_hash":"1d8ab90","commit_message":"Bump dependencies"}},"aliases":null}
    """#,
    #"""
    {"id":"pd-1","short_id":"20cc1f0","url":"https://20cc1f0.marketing-site-7ab.pages.dev","environment":"production","created_on":"\#(DemoClock.iso(hoursAgo: 96))","modified_on":"\#(DemoClock.iso(hoursAgo: 96))","project_name":"marketing-site","is_skipped":false,"latest_stage":{"name":"deploy","status":"success","started_on":"\#(DemoClock.iso(hoursAgo: 96))","ended_on":"\#(DemoClock.iso(hoursAgo: 96))"},"deployment_trigger":{"type":"github:push","metadata":{"branch":"main","commit_hash":"77aa02e","commit_message":"Launch the summer campaign"}},"aliases":null}
    """#,
  ]

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

  // MARK: R2 objects

  struct R2DemoObject {
    let key: String
    let contentType: String
    let body: Data

    var listJSON: String {
      #"{"key":"\#(key)","size":\#(body.count),"etag":"demo-\#(key.hashValue.magnitude)","last_modified":"\#(DemoClock.iso(hoursAgo: 30))","http_metadata":{"contentType":"\#(contentType)"}}"#
    }
  }

  /// A 1×1 transparent PNG — real bytes so thumbnails and previews work.
  static let tinyPNG = Data(
    base64Encoded:
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
  )!

  static func r2Objects(in bucket: String) -> [R2DemoObject] {
    switch bucket {
    case "assets":
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
    case "backups":
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
    default:
      return []
    }
  }

  // MARK: KV

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
    default:
      if key.hasPrefix("bulk:") || key.hasPrefix("cache:page-") {
        return #"{"key":"\#(key)","demo":true}"#
      }
      return "{}"
    }
  }

  // MARK: Alerts / audit

  static var alertHistory: String {
    #"""
    [
      {"id":"hist-tunnel-1","policy_id":"pol-1","name":"Tunnel health","alert_type":"tunnel_health_event","mechanism":"email","alert_body":"homelab-01 disconnected from Cloudflare","sent":"\#(DemoClock.iso(hoursAgo: 6))"},
      {"id":"hist-pages-1","policy_id":"pol-2","name":"Pages build alerts","alert_type":"pages_event_alert","mechanism":"email","alert_body":"marketing-site: production build failed","sent":"\#(DemoClock.iso(hoursAgo: 26))"}
    ]
    """#
  }

  static var auditLogs: String {
    #"""
    [
      {"id":"log-1","action":{"type":"rollback","description":"Rolled back Worker deployment","result":"success","time":"\#(DemoClock.iso(hoursAgo: 5))"},"actor":{"email":"demo@example.com","type":"user"},"resource":{"type":"script","product":"workers","id":"api-worker"},"when":"\#(DemoClock.iso(hoursAgo: 5))"},
      {"id":"log-2","action":{"type":"add","description":"Created DNS record","result":"success","time":"\#(DemoClock.iso(hoursAgo: 22))"},"actor":{"email":"demo@example.com","type":"user"},"resource":{"type":"dns_record","product":"dns","id":"dns-caa"},"when":"\#(DemoClock.iso(hoursAgo: 22))"},
      {"id":"log-3","action":{"type":"purge","description":"Purged zone cache","result":"success","time":"\#(DemoClock.iso(hoursAgo: 49))"},"actor":{"email":"demo@example.com","type":"user"},"resource":{"type":"zone","product":"caching","id":"zone-example"},"when":"\#(DemoClock.iso(hoursAgo: 49))"}
    ]
    """#
  }

  // MARK: GraphQL payloads

  /// Deterministic traffic wave: a day-shaped curve so charts look alive
  /// without randomness (pull-to-refresh should not rewrite history).
  private static func wave(_ index: Int, base: Int, swing: Int) -> Int {
    let phase = Double(index) * .pi / 12
    return base + Int(Double(swing) * (0.5 + 0.5 * sin(phase - .pi / 2)))
  }

  static func zoneAnalyticsHourly() -> String {
    let rows = (0..<24).map { hour -> String in
      let requests = wave(hour, base: 620, swing: 1400)
      return
        #"{"dimensions":{"datetime":"\#(DemoClock.isoHour(hoursAgo: 23 - hour))"},"sum":{"requests":\#(requests),"pageViews":\#(requests * 3 / 5),"threats":\#(hour % 7 == 0 ? 3 : 0),"bytes":\#(requests * 11800),"cachedRequests":\#(requests * 82 / 100),"cachedBytes":\#(requests * 11800 * 74 / 100)},"uniq":{"uniques":\#(requests / 7)}}"#
    }
    return
      #"{"data":{"viewer":{"zones":[{"httpRequests1hGroups":[\#(rows.joined(separator: ","))]}]}},"errors":null}"#
  }

  static func zoneRequestsHourly() -> String {
    let rows = (0..<24).map { hour -> String in
      let requests = wave(hour, base: 620, swing: 1400)
      return
        #"{"count":\#(requests),"dimensions":{"datetimeHour":"\#(DemoClock.isoHour(hoursAgo: 23 - hour))"}}"#
    }
    return
      #"{"data":{"viewer":{"zones":[{"httpRequestsAdaptiveGroups":[\#(rows.joined(separator: ","))]}]}},"errors":null}"#
  }

  static func zoneAnalyticsDaily(days: Int = 7) -> String {
    let rows = (0..<max(days, 1)).map { day -> String in
      let requests = 18_500 + wave(day, base: 0, swing: 9000)
      return
        #"{"dimensions":{"date":"\#(DemoClock.isoDay(daysAgo: day))"},"sum":{"requests":\#(requests),"pageViews":\#(requests * 3 / 5),"threats":\#(day % 3 == 0 ? 14 : 2),"bytes":\#(requests * 11800),"cachedRequests":\#(requests * 79 / 100),"cachedBytes":\#(requests * 11800 * 71 / 100)},"uniq":{"uniques":\#(requests / 9)}}"#
    }
    return
      #"{"data":{"viewer":{"zones":[{"httpRequests1dGroups":[\#(rows.joined(separator: ","))]}]}},"errors":null}"#
  }

  static let rumSites =
    #"""
    [{"site_tag":"demo-site","site_token":"demo-token","auto_install":true,\#
    "ruleset":{"id":"demo-ruleset","zone_tag":"zone-example","zone_name":"example.com",\#
    "enabled":true}}]
    """#

  static func rumPageviews(days: Int) -> String {
    let rows = (0..<max(days, 1)).map { day -> String in
      let views = 640 + wave(day, base: 0, swing: 420)
      return
        #"{"count":\#(views),"dimensions":{"date":"\#(DemoClock.isoDay(daysAgo: days - 1 - day))"}}"#
    }
    return
      #"{"data":{"viewer":{"accounts":[{"rumPageloadEventsAdaptiveGroups":[\#(rows.joined(separator: ","))]}]}},"errors":null}"#
  }

  static func workerAnalytics() -> String {
    let rows = (0..<12).map { slot -> String in
      let requests = wave(slot, base: 80, swing: 160)
      let errors = slot == 7 ? 3 : 0
      let cpu = Double(wave(slot, base: 640, swing: 420)) + (slot == 7 ? 380.0 : 0.0)
      return
        #"{"sum":{"requests":\#(requests),"errors":\#(errors)},"quantiles":{"cpuTimeP50":\#(cpu)},"dimensions":{"datetimeFiveMinutes":"\#(DemoClock.isoFiveMinutes(slotsAgo: 11 - slot))","status":"success"}}"#
    }
    return
      #"{"data":{"viewer":{"accounts":[{"workersInvocationsAdaptive":[\#(rows.joined(separator: ","))]}]}},"errors":null}"#
  }

  /// Account overview + series for Watchtower's 24h / 7d / 30d ranges.
  /// Hourly stamps for short windows; the client also accepts `date` buckets.
  static func accountAnalyticsOverview() -> String {
    let httpSeries = (0..<24).map { slot -> String in
      let requests = wave(slot, base: 420, swing: 280)
      let bytes = requests * 48_000
      let cache = 0.55 + Double(slot % 5) * 0.03
      let encrypted = 0.94 + Double(slot % 3) * 0.01
      let status4xx = slot == 11 ? 0.08 : 0.015
      return #"""
        {"sum":{"requests":\#(requests),"bytes":\#(bytes)},"ratio":{"cachedRequests":\#(cache),"encryptedRequests":\#(encrypted),"encryptedBytes":\#(encrypted - 0.02),"status4xx":\#(status4xx)},"dimensions":{"datetimeHour":"\#(DemoClock.isoHour(hoursAgo: 23 - slot))"}}
        """#
    }
    let workerSeries = (0..<24).map { slot -> String in
      let requests = wave(slot, base: 160, swing: 90)
      let errors = slot == 11 ? 4 : 0
      let cpu = Double(wave(slot, base: 900, swing: 500))
      return #"""
        {"sum":{"requests":\#(requests),"errors":\#(errors)},"quantiles":{"cpuTimeP90":\#(cpu)},"dimensions":{"datetimeHour":"\#(DemoClock.isoHour(hoursAgo: 23 - slot))"}}
        """#
    }
    let webRequests = 12_840
    let bytes = 52_428_800
    return #"""
      {"data":{"viewer":{"accounts":[{
        "overview":[{
          "sum":{"requests":\#(webRequests),"bytes":\#(bytes)},
          "ratio":{"cachedRequests":0.62,"encryptedRequests":0.97,"encryptedBytes":0.94,"status4xx":0.018}
        }],
        "httpSeries":[\#(httpSeries.joined(separator: ","))],
        "workers":[{
          "sum":{"requests":4820,"errors":12},
          "quantiles":{"cpuTimeP90":1260.0}
        }],
        "workerSeries":[\#(workerSeries.joined(separator: ","))]
      }]}},"errors":null}
      """#
  }

  static func firewallEvents() -> String {
    #"""
    {"data":{"viewer":{"zones":[{
      "blocked":[{"count":152}],
      "byCountry":[
        {"count":64,"dimensions":{"clientCountryName":"US"}},
        {"count":38,"dimensions":{"clientCountryName":"CN"}},
        {"count":21,"dimensions":{"clientCountryName":"RU"}},
        {"count":12,"dimensions":{"clientCountryName":"BR"}}
      ],
      "byRule":[
        {"count":98,"dimensions":{"ruleId":"rate-limit-login"}},
        {"count":54,"dimensions":{"ruleId":"block-bad-bots"}}
      ]
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
