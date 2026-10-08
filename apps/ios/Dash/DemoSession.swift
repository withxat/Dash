import CloudflareAPI
import Foundation

/// Each URLSession retains its own world through its delegate. The registry holds
/// weak references only; a late request from an old session cannot touch a new one.
/// All state (including lazy fixture seeding) is serialized under the world's lock.
final class DemoSession: NSObject, URLSessionDelegate, @unchecked Sendable {
  private static let registry = Registry()
  private static let sessionHeader = "X-Dash-Demo-Session"
  private let lock = NSLock()
  private var collections: [String: [[String: Any]]] = [:]
  private var documents: [String: [String: Any]] = [:]
  private var blobs: [String: DemoBackend.Reply] = [:]

  private final class Registry: @unchecked Sendable {
    private struct Entry { weak var world: DemoSession? }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func insert(_ world: DemoSession, id: String) {
      lock.lock()
      defer { lock.unlock() }
      entries = entries.filter { $0.value.world != nil }
      entries[id] = Entry(world: world)
    }

    func world(id: String) -> DemoSession? {
      lock.lock()
      defer { lock.unlock() }
      return entries[id]?.world
    }
  }

  static func makeSession() -> URLSession {
    let world = DemoSession()
    let id = UUID().uuidString
    registry.insert(world, id: id)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DemoBackend.self]
    configuration.httpAdditionalHeaders = [sessionHeader: id]
    return URLSession(configuration: configuration, delegate: world, delegateQueue: nil)
  }

  static func respond(to request: URLRequest, body: Data?) -> DemoBackend.Reply {
    guard let id = request.value(forHTTPHeaderField: sessionHeader),
      let world = registry.world(id: id)
    else { return failure("The demo session has ended.", status: 410) }
    world.lock.lock()
    defer { world.lock.unlock() }
    return world.route(request, body: body)
  }

  static var unsupported: DemoBackend.Reply {
    failure("This operation is not simulated in the demo.", status: 400)
  }

  private static func failure(_ message: String, status: Int = 404) -> DemoBackend.Reply {
    json(
      [
        "success": false, "errors": [["code": 10061, "message": message]],
        "messages": [], "result": NSNull(),
      ], status: status)
  }

  private static func json(_ value: Any, status: Int = 200) -> DemoBackend.Reply {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    else {
      return DemoBackend.Reply(status: 500, json: "{}")
    }
    return DemoBackend.Reply(status: status, contentType: "application/json", data: data)
  }

  private func ok(_ result: Any, info: [String: Any] = [:]) -> DemoBackend.Reply {
    Self.json([
      "success": true, "errors": [], "messages": [], "result": result, "result_info": info,
    ])
  }

  private func seedReply(_ path: String) -> DemoBackend.Reply {
    var url = URLComponents(string: "https://api.cloudflare.com")!
    let split = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
    url.path = "/client/v4" + String(split[0])
    if split.count == 2 { url.percentEncodedQuery = String(split[1]) }
    return DemoBackend.fixtureReply(to: URLRequest(url: url.url!))
  }

  private func seed(_ path: String) -> Any? {
    (try? JSONSerialization.jsonObject(with: seedReply(path).body) as? [String: Any])?["result"]
  }

  private func rows(_ path: String, wrapper: String? = nil) -> [[String: Any]] {
    if let rows = collections[path] { return rows }
    let value = seed(path)
    let rows =
      (wrapper.flatMap { (value as? [String: Any])?[$0] } ?? value) as? [[String: Any]] ?? []
    collections[path] = rows
    return rows
  }

  private func document(_ path: String) -> [String: Any] {
    if let value = documents[path] { return value }
    let value = seed(path) as? [String: Any] ?? [:]
    documents[path] = value
    return value
  }

  private var now: String { ISO8601DateFormatter().string(from: Date()) }
  private var newID: String { "demo-" + UUID().uuidString.lowercased() }

  private func listing(_ rows: [[String: Any]], query: [String: String], defaultSize: Int = 50)
    -> DemoBackend.Reply
  {
    let size = min(max(Int(query["per_page"] ?? "") ?? defaultSize, 1), 1000)
    let page = max(Int(query["page"] ?? "") ?? 1, 1)
    let start = min((page - 1) * size, rows.count)
    let slice = Array(rows.dropFirst(start).prefix(size))
    return ok(
      slice,
      info: [
        "page": page, "per_page": size, "count": slice.count,
        "total_count": rows.count, "total_pages": max(1, (rows.count + size - 1) / size),
      ])
  }

  private func route(_ request: URLRequest, body: Data?) -> DemoBackend.Reply {
    guard let url = request.url else { return Self.unsupported }
    // URL.path removes a trailing slash; R2 folder markers need it verbatim.
    var path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path ?? url.path
    if path.hasPrefix("/client/v4") { path.removeFirst("/client/v4".count) }
    let parts = path.split(separator: "/").map(String.init)
    let method = request.httpMethod ?? "GET"
    let input =
      body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    let query = Dictionary(
      (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
        .compactMap { item in item.value.map { (item.name, $0) } },
      uniquingKeysWith: { _, last in last })
    if path == "/graphql" { return DemoBackend.fixtureReply(to: request, body: body) }
    if collections["/zones"] == nil { collections["/zones"] = DemoBackend.initialZones }

    if path == "/zones" {
      var zones = rows(path)
      if method == "POST" {
        guard let name = input["name"] as? String, !name.isEmpty,
          let account = input["account"] as? [String: Any],
          let accountID = account["id"] as? String,
          rows("/accounts").contains(where: { $0["id"] as? String == accountID })
        else { return Self.failure("Choose a demo account and a domain name.", status: 400) }
        guard !zones.contains(where: { ($0["name"] as? String)?.lowercased() == name.lowercased() })
        else {
          return Self.failure("This domain already exists in the demo.", status: 409)
        }
        let zone: [String: Any] = [
          "id": newID, "name": name.lowercased(), "account": account,
          "status": "active", "paused": false, "development_mode": 0,
          "name_servers": ["ada.ns.cloudflare.com", "bob.ns.cloudflare.com"],
          "plan": ["id": "free", "name": "Free Website"],
        ]
        zones.insert(zone, at: 0)
        collections[path] = zones
        return ok(zone)
      }
      if method == "GET" {
        if let account = query["account.id"] {
          zones = zones.filter { ($0["account"] as? [String: Any])?["id"] as? String == account }
        }
        if let name = query["name"] {
          zones = zones.filter {
            ($0["name"] as? String)?.localizedCaseInsensitiveContains(name) == true
          }
        }
        return listing(zones, query: query)
      }
    }
    if parts.first == "zones", parts.count >= 2 {
      guard let zone = rows("/zones").first(where: { $0["id"] as? String == parts[1] }) else {
        return Self.failure("Domain not found.")
      }
      let base = "/zones/" + parts[1]
      if parts.count == 2 {
        if method == "GET" { return ok(zone) }
        if method == "DELETE" {
          collections["/zones"] = rows("/zones").filter { $0["id"] as? String != parts[1] }
          removeResources(under: base)
          return ok(["id": parts[1]])
        }
      }
      if parts.count == 3, parts[2] == "activation_check", method == "PUT" {
        var updated = zone
        updated["status"] = "active"
        replace(updated, in: "/zones", id: "id")
        return ok(["id": parts[1]])
      }
      if parts.count >= 3, parts[2] == "dns_records" {
        return records(
          base + "/dns_records", tail: Array(parts.dropFirst(3)), method: method,
          input: input.merging(["zone_id": parts[1]], uniquingKeysWith: { _, new in new }),
          query: query)
      }
      if parts.count >= 3, parts[2] == "settings" {
        let settingsPath = base + "/settings"
        if collections[settingsPath] == nil,
          (seed(settingsPath) as? [[String: Any]])?.isEmpty != false
        {
          collections[settingsPath] = seed("/zones/zone-example/settings") as? [[String: Any]] ?? []
        }
        if parts.count == 4, method == "PATCH" {
          guard var setting = rows(settingsPath).first(where: { $0["id"] as? String == parts[3] }),
            setting["editable"] as? Bool != false, let value = input["value"]
          else { return Self.failure("This setting cannot be changed.", status: 400) }
          setting["value"] = value
          setting["modified_on"] = now
          replace(setting, in: settingsPath, id: "id")
          if parts[3] == "development_mode" {
            var updated = zone
            updated["development_mode"] = value as? String == "on" ? 10800 : 0
            replace(updated, in: "/zones", id: "id")
          }
          return ok(setting)
        }
        if parts.count == 3, method == "GET" { return ok(rows(settingsPath)) }
      }
      if parts.count >= 4, parts[2] == "email", parts[3] == "routing" {
        return email(
          base: base, zone: zone, tail: Array(parts.dropFirst(4)), method: method, input: input,
          query: query)
      }
    }
    if path == "/accounts", method == "GET" { return listing(rows(path), query: query) }
    if parts.first == "accounts", parts.count >= 2 {
      guard let account = rows("/accounts").first(where: { $0["id"] as? String == parts[1] }) else {
        return Self.failure("Account not found.")
      }
      let base = "/accounts/" + parts[1]
      if parts.count == 2 {
        if method == "GET" { return ok(account) }
        if method == "PUT", let name = input["name"] as? String, !name.isEmpty {
          var updated = account
          updated["name"] = name
          replace(updated, in: "/accounts", id: "id")
          return ok(updated)
        }
      }
      let tail = Array(parts.dropFirst(2))
      if tail.first == "storage" {
        return kv(base: base, path: path, tail: tail, method: method, body: body, query: query)
      }
      if tail.first == "r2" {
        return r2(
          base: base, path: path, tail: tail, request: request, body: body, input: input,
          query: query)
      }
      if tail.first == "workers" {
        return workers(
          base: base, path: path, tail: tail, request: request, body: body, input: input,
          query: query)
      }
      if tail.first == "pages" {
        return pages(base: base, path: path, tail: tail, method: method, input: input, query: query)
      }
      if tail.first == "registrar" {
        return registrar(base: base, tail: tail, method: method, input: input, query: query)
      }
      if tail.prefix(3) == ["email", "routing", "addresses"] {
        let addressesPath = base + "/email/routing/addresses"
        if collections[addressesPath] == nil {
          collections[addressesPath] =
            (seed(addressesPath) as? [[String: Any]] ?? [])
            + (seed(addressesPath + "?verified=false") as? [[String: Any]] ?? [])
        }
        // Verification is simulated locally; no email is sent.
        var value = input
        if method == "POST" {
          value.merge(
            ["verified": now, "created": now, "modified": now], uniquingKeysWith: { _, new in new })
        }
        return records(
          addressesPath, tail: Array(tail.dropFirst(3)), method: method, input: value, query: query)
      }
    }
    return method == "GET" ? DemoBackend.fixtureReply(to: request) : Self.unsupported
  }

  private func removeResources(under path: String) {
    let prefix = path + "/"
    collections = collections.filter { !$0.key.hasPrefix(prefix) }
    documents = documents.filter { !$0.key.hasPrefix(prefix) }
    blobs = blobs.filter { !$0.key.hasPrefix(prefix) }
  }

  private func replace(_ value: [String: Any], in path: String, id: String) {
    var list = rows(path)
    if let index = list.firstIndex(where: { $0[id] as? String == value[id] as? String }) {
      list[index] = value
    } else {
      list.insert(value, at: 0)
    }
    collections[path] = list
  }

  /// Shared collection semantics: edits preserve fixture fields; deleted resources
  /// stay missing; unknown IDs never become a successful no-op.
  private func records(
    _ path: String, tail: [String], method: String, input: [String: Any], query: [String: String],
    id: String = "id", createMethod: String = "POST"
  ) -> DemoBackend.Reply {
    var list = rows(path)
    if tail.isEmpty {
      if method == "GET" {
        if let search = query["search"] {
          list = list.filter { row in
            row.values.contains {
              ($0 as? String)?.localizedCaseInsensitiveContains(search) == true
            }
          }
        }
        if let type = query["type"] {
          list = list.filter { ($0["type"] as? String)?.uppercased() == type.uppercased() }
        }
        if let service = query["service"] {
          list = list.filter { $0["service"] as? String == service }
        }
        if let verified = query["verified"] {
          list = list.filter { ($0["verified"] is String) == (verified == "true") }
        }
        return listing(list, query: query)
      }
      if method == createMethod {
        var value = input
        value[id] = input[id] ?? newID
        if let key = value[id] as? String, list.contains(where: { $0[id] as? String == key }) {
          return Self.failure("This resource already exists.", status: 409)
        }
        list.insert(value, at: 0)
        collections[path] = list
        return ok(value)
      }
    }
    guard tail.count == 1, let index = list.firstIndex(where: { $0[id] as? String == tail[0] })
    else { return Self.failure("Resource not found.") }
    if method == "GET" { return ok(list[index]) }
    if method == "DELETE" {
      let removed = list.remove(at: index)
      collections[path] = list
      return ok(removed)
    }
    if method == "PUT" || method == "PATCH" {
      list[index].merge(input, uniquingKeysWith: { _, new in new })
      list[index][id] = tail[0]
      collections[path] = list
      return ok(list[index])
    }
    return Self.unsupported
  }

  private func email(
    base: String, zone: [String: Any], tail: [String], method: String, input: [String: Any],
    query: [String: String]
  ) -> DemoBackend.Reply {
    let path = base + "/email/routing"
    var settings = document(path)
    if settings.isEmpty {
      settings = [
        "id": newID, "name": zone["name"] ?? "", "enabled": false, "status": "unconfigured",
        "support_subaddress": false,
      ]
    }
    if tail.isEmpty {
      if method == "PATCH" { settings.merge(input, uniquingKeysWith: { _, new in new }) }
      guard method == "GET" || method == "PATCH" else { return Self.unsupported }
      documents[path] = settings
      return ok(settings)
    }
    if tail == ["dns"] {
      if method == "POST" || method == "DELETE" {
        settings["enabled"] = method == "POST"
        settings["status"] = method == "POST" ? "ready" : "unconfigured"
        documents[path] = settings
        let dnsPath = base + "/dns_records"
        var dns = rows(dnsPath).filter { row in
          let content = row["content"] as? String ?? ""
          return !content.hasSuffix(".mx.cloudflare.net")
            && !content.contains("include:_spf.mx.cloudflare.net")
        }
        var required: [[String: Any]] = []
        if method == "POST" {
          required = [
            [
              "type": "MX", "name": zone["name"] ?? "", "content": "route1.mx.cloudflare.net",
              "ttl": 1, "priority": 10,
            ],
            [
              "type": "MX", "name": zone["name"] ?? "", "content": "route2.mx.cloudflare.net",
              "ttl": 1, "priority": 20,
            ],
            [
              "type": "TXT", "name": zone["name"] ?? "",
              "content": "v=spf1 include:_spf.mx.cloudflare.net ~all", "ttl": 1,
            ],
          ]
          dns += required.map {
            $0.merging(
              ["id": newID, "zone_id": zone["id"] ?? "", "proxied": false],
              uniquingKeysWith: { _, new in new })
          }
        }
        collections[dnsPath] = dns
        documents[path + "/dns"] = ["record": required, "errors": []]
        return ok(settings)
      }
      if method == "GET" { return ok(document(path + "/dns")) }
    }
    if tail == ["rules", "catch_all"] {
      let catchPath = path + "/rules/catch_all"
      var value = document(catchPath)
      if value.isEmpty {
        value = [
          "id": newID, "name": "Catch all", "enabled": false, "matchers": [["type": "all"]],
          "actions": [["type": "drop"]],
        ]
      }
      if method == "PUT" { value.merge(input, uniquingKeysWith: { _, new in new }) }
      guard method == "GET" || method == "PUT" else { return Self.unsupported }
      documents[catchPath] = value
      return ok(value)
    }
    if tail.first == "rules" {
      return records(
        path + "/rules", tail: Array(tail.dropFirst()), method: method, input: input, query: query)
    }
    return Self.unsupported
  }

  private func kv(
    base: String, path: String, tail: [String], method: String, body: Data?, query: [String: String]
  ) -> DemoBackend.Reply {
    let namespaces = base + "/storage/kv/namespaces"
    guard tail.prefix(3) == ["storage", "kv", "namespaces"] else { return Self.unsupported }
    if tail.count == 3, method == "GET" { return listing(rows(namespaces), query: query) }
    guard tail.count >= 4,
      let namespace = rows(namespaces).first(where: { $0["id"] as? String == tail[3] })
    else { return Self.failure("Namespace not found.") }
    if tail.count == 4, method == "GET" { return ok(namespace) }
    let keysPath = namespaces + "/" + tail[3] + "/keys"
    if tail.count == 5, tail[4] == "keys", method == "GET" {
      let keys = rows(keysPath).filter {
        ($0["name"] as? String)?.hasPrefix(query["prefix"] ?? "") == true
      }
      return ok(keys, info: ["count": keys.count])
    }
    guard tail.count >= 6, tail[4] == "values" else { return Self.unsupported }
    let key = String(path.dropFirst((namespaces + "/" + tail[3] + "/values/").count))
    if method == "PUT" {
      blobs[path] = DemoBackend.Reply(contentType: "application/octet-stream", data: body ?? Data())
      replace(["name": key], in: keysPath, id: "name")
      return ok([:])
    }
    guard rows(keysPath).contains(where: { $0["name"] as? String == key }) else {
      return Self.failure("Key not found.")
    }
    if method == "DELETE" {
      collections[keysPath] = rows(keysPath).filter { $0["name"] as? String != key }
      blobs[path] = nil
      return ok([:])
    }
    return method == "GET" ? (blobs[path] ?? seedReply(path)) : Self.unsupported
  }

  private func r2(
    base: String, path: String, tail: [String], request: URLRequest, body: Data?,
    input: [String: Any], query: [String: String]
  ) -> DemoBackend.Reply {
    let method = request.httpMethod ?? "GET"
    let buckets = base + "/r2/buckets"
    guard tail.prefix(2) == ["r2", "buckets"] else { return Self.unsupported }
    _ = rows(buckets, wrapper: "buckets")
    if tail.count == 2 {
      if method == "GET" { return ok(["buckets": rows(buckets)]) }
      if method == "POST", let name = input["name"] as? String, !name.isEmpty {
        return records(
          buckets, tail: [], method: method, input: ["name": name, "creation_date": now],
          query: query, id: "name")
      }
    }
    guard tail.count >= 3, rows(buckets).contains(where: { $0["name"] as? String == tail[2] })
    else { return Self.failure("Bucket not found.") }
    let bucket = buckets + "/" + tail[2]
    let objects = bucket + "/objects"
    if tail.count == 3, method == "DELETE" {
      guard rows(objects).isEmpty else {
        return Self.failure("Empty this bucket before deleting it.", status: 409)
      }
      let reply = records(
        buckets, tail: [tail[2]], method: method, input: input, query: query, id: "name")
      removeResources(under: bucket)
      return reply
    }
    if tail.count >= 4, tail[3] == "objects" {
      if path == objects, method == "GET" {
        let prefix = query["prefix"] ?? ""
        let delimiter = query["delimiter"]
        let candidates = rows(objects).filter { ($0["key"] as? String)?.hasPrefix(prefix) == true }
          .sorted { ($0["key"] as? String ?? "") < ($1["key"] as? String ?? "") }
        var folders = Set<String>()
        var objects: [[String: Any]] = []
        for row in candidates {
          let key = row["key"] as? String ?? ""
          let remainder = key.dropFirst(prefix.count)
          if let delimiter, !delimiter.isEmpty, let range = remainder.range(of: delimiter) {
            folders.insert(prefix + remainder[..<range.lowerBound] + delimiter)
          } else {
            objects.append(row)
          }
        }
        // Include folders in the same cursor stream as objects so neither can
        // disappear when a page boundary lands in a large directory.
        let entries: [(key: String, object: [String: Any]?)] =
          (objects.map { ($0["key"] as? String ?? "", Optional($0)) } + folders.map { ($0, nil) })
          .sorted { $0.0 < $1.0 }
        let after = query["cursor"] ?? query["start_after"] ?? ""
        let size = min(max(Int(query["per_page"] ?? "100") ?? 100, 1), 1000)
        let remaining = entries.filter { $0.key > after }
        let page = Array(remaining.prefix(size))
        let truncated = remaining.count > page.count
        return ok(
          page.compactMap(\.object),
          info: [
            "is_truncated": truncated,
            "cursor": truncated ? (page.last?.key ?? "") : "",
            "delimited": page.filter { $0.object == nil }.map(\.key), "per_page": size,
          ])
      }
      guard path.hasPrefix(objects + "/") else { return Self.unsupported }
      let key = String(path.dropFirst(objects.count + 1))
      if method == "PUT" {
        let bytes = body ?? Data()
        let type = request.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
        blobs[path] = DemoBackend.Reply(contentType: type, data: bytes)
        let row: [String: Any] = [
          "key": key, "size": bytes.count, "etag": newID,
          "last_modified": now, "http_metadata": ["contentType": type],
        ]
        replace(row, in: objects, id: "key")
        return ok(row)
      }
      guard rows(objects).contains(where: { $0["key"] as? String == key }) else {
        return Self.failure("Object not found.")
      }
      if method == "DELETE" {
        collections[objects] = rows(objects).filter { $0["key"] as? String != key }
        blobs[path] = nil
        return ok([:])
      }
      if method == "GET" { return blobs[path] ?? seedReply(path) }
    }
    if tail.count >= 5, tail[3] == "domains" {
      if tail[4] == "managed", tail.count == 5 {
        var value = document(path)
        if value.isEmpty {
          value = ["bucketId": tail[2], "domain": "pub-\(tail[2]).r2.dev", "enabled": false]
        }
        if method == "PUT" { value["enabled"] = input["enabled"] ?? false }
        guard method == "GET" || method == "PUT" else { return Self.unsupported }
        documents[path] = value
        return ok(value)
      }
      if tail[4] == "custom" {
        let domains = bucket + "/domains/custom"
        _ = rows(domains, wrapper: "domains")
        if tail.count == 5, method == "GET" { return ok(["domains": rows(domains)]) }
        var value = input
        value["status"] = ["ownership": "active", "ssl": "active"]
        return records(
          domains, tail: Array(tail.dropFirst(5)), method: method, input: value, query: query,
          id: "domain")
      }
    }
    return Self.unsupported
  }

  private func workers(
    base: String, path: String, tail: [String], request: URLRequest, body: Data?,
    input: [String: Any], query: [String: String]
  ) -> DemoBackend.Reply {
    let method = request.httpMethod ?? "GET"
    if tail.count >= 2, tail[1] == "domains" {
      return records(
        base + "/workers/domains", tail: Array(tail.dropFirst(2)), method: method, input: input,
        query: query, createMethod: "PUT")
    }
    guard tail.count >= 2, tail[1] == "scripts" else {
      return method == "GET" ? DemoBackend.fixtureReply(to: request) : Self.unsupported
    }
    let scripts = base + "/workers/scripts"
    if tail.count == 2, method == "GET" {
      return listing(rows(scripts), query: query, defaultSize: 100)
    }
    guard tail.count >= 3,
      var script = rows(scripts).first(where: { $0["id"] as? String == tail[2] })
    else { return Self.failure("Worker not found.") }
    let scriptPath = scripts + "/" + tail[2]
    let deployments = scriptPath + "/deployments"
    if tail.count == 4, tail[3] == "deployments" {
      _ = rows(deployments, wrapper: "deployments")
      if method == "GET" { return ok(["deployments": rows(deployments)]) }
      if method == "POST", let versions = input["versions"] as? [[String: Any]],
        let version = versions.first?["version_id"] as? String,
        rows(deployments).contains(where: {
          ($0["versions"] as? [[String: Any]])?.contains(where: {
            $0["version_id"] as? String == version
          }) == true
        })
      {
        var value = input
        value.merge(
          ["id": newID, "created_on": now, "source": "api", "author_email": "demo@example.com"],
          uniquingKeysWith: { _, new in new })
        replace(value, in: deployments, id: "id")
        // Uploaded versions keep their source so a rollback restores the editor too.
        if let source = blobs[scriptPath + "/versions/" + version] {
          blobs[scriptPath + "/content/v2"] = source
        }
        script["modified_on"] = now
        replace(script, in: scripts, id: "id")
        return ok(value)
      }
    }
    if tail.count == 4, tail[3] == "subdomain" {
      var value = document(path)
      if method == "POST" { value["enabled"] = input["enabled"] ?? false }
      guard method == "GET" || method == "POST" else { return Self.unsupported }
      documents[path] = value
      return ok(value)
    }
    if tail.count >= 4, tail[3] == "content" {
      let sourcePath = scriptPath + "/content/v2"
      if method == "GET" { return blobs[sourcePath] ?? seedReply(sourcePath) }
      if method == "PUT", let body {
        let parts = MultipartDocument.parse(
          data: body, contentType: request.value(forHTTPHeaderField: "Content-Type") ?? "")
        guard let content = parts.first(where: { $0.name != "metadata" }) else {
          return Self.failure("The demo could not read this Worker source.", status: 400)
        }
        _ = rows(deployments, wrapper: "deployments")
        for deployment in rows(deployments) {
          for version in deployment["versions"] as? [[String: Any]] ?? [] {
            if let id = version["version_id"] as? String,
              blobs[scriptPath + "/versions/" + id] == nil
            {
              blobs[scriptPath + "/versions/" + id] = blobs[sourcePath] ?? seedReply(sourcePath)
            }
          }
        }
        let reply = DemoBackend.Reply(contentType: "application/javascript", data: content.body)
        blobs[sourcePath] = reply
        let version = newID
        blobs[scriptPath + "/versions/" + version] = reply
        let deployment: [String: Any] = [
          "id": newID, "created_on": now, "source": "api", "strategy": "percentage",
          "versions": [["version_id": version, "percentage": 100]],
          "annotations": ["workers/message": "Demo source update"],
          "author_email": "demo@example.com",
        ]
        replace(deployment, in: deployments, id: "id")
        script["modified_on"] = now
        replace(script, in: scripts, id: "id")
        return ok(script)
      }
    }
    return Self.unsupported
  }

  private func pages(
    base: String, path: String, tail: [String], method: String, input: [String: Any],
    query: [String: String]
  ) -> DemoBackend.Reply {
    let projects = base + "/pages/projects"
    guard tail.count >= 2, tail[1] == "projects" else { return Self.unsupported }
    // Old fixtures list every project in one response; this world honors pages.
    if tail.count == 2, method == "GET" {
      return listing(rows(projects), query: query, defaultSize: 10)
    }
    guard tail.count >= 3,
      var project = rows(projects).first(where: { $0["name"] as? String == tail[2] })
    else { return Self.failure("Project not found.") }
    let projectPath = projects + "/" + tail[2]
    if tail.count == 3, method == "GET" { return ok(project) }
    if tail.count >= 4, tail[3] == "domains" {
      var value = input
      if method == "POST" {
        value.merge(
          ["id": newID, "status": "active", "created_on": now], uniquingKeysWith: { _, new in new })
      }
      return records(
        projectPath + "/domains", tail: Array(tail.dropFirst(4)), method: method, input: value,
        query: query, id: "name")
    }
    if tail.count >= 4, tail[3] == "deployments" {
      let deployments = projectPath + "/deployments"
      if tail.count == 4, method == "GET" {
        return listing(rows(deployments), query: query, defaultSize: 25)
      }
      guard tail.count >= 5,
        var deployment = rows(deployments).first(where: { $0["id"] as? String == tail[4] })
      else { return Self.failure("Deployment not found.") }
      if tail.count == 5, method == "GET" { return ok(deployment) }
      if tail.contains("logs"), method == "GET" { return seedReply(path) }
      if tail.count == 6, ["retry", "rollback"].contains(tail[5]), method == "POST" {
        deployment["id"] = newID
        deployment["created_on"] = now
        deployment["modified_on"] = now
        deployment["latest_stage"] = [
          "name": "deploy", "status": "success", "started_on": now, "ended_on": now,
        ]
        replace(deployment, in: deployments, id: "id")
        project["latest_deployment"] = deployment
        project["canonical_deployment"] = deployment
        replace(project, in: projects, id: "name")
        return ok(deployment)
      }
    }
    return Self.unsupported
  }

  private func registrar(
    base: String, tail: [String], method: String, input: [String: Any], query: [String: String]
  ) -> DemoBackend.Reply {
    guard tail.count >= 2, ["domains", "registrations"].contains(tail[1]) else {
      return Self.unsupported
    }
    let registrations = base + "/registrar/registrations"
    let domains = base + "/registrar/domains"
    if tail.count == 3, tail[1] == "domains", method == "PUT" {
      guard
        var registration = rows(registrations).first(where: {
          $0["domain_name"] as? String == tail[2]
        }),
        var domain = rows(domains).first(where: { $0["id"] as? String == tail[2] })
      else { return Self.failure("Registration not found.") }
      // The write endpoint and the two read APIs use different field names.
      if let renew = input["auto_renew"] { registration["auto_renew"] = renew }
      if let locked = input["locked"] as? Bool {
        registration["locked"] = locked
        domain["locked"] = locked
        domain["registry_statuses"] =
          locked ? "clientTransferProhibited,clientUpdateProhibited" : "ok"
      }
      replace(registration, in: registrations, id: "domain_name")
      replace(domain, in: domains, id: "id")
      return ok(domain)
    }
    guard method == "GET" else { return Self.unsupported }
    return records(
      tail[1] == "domains" ? domains : registrations, tail: Array(tail.dropFirst(2)),
      method: method, input: input, query: query, id: tail[1] == "domains" ? "id" : "domain_name")
  }
}
