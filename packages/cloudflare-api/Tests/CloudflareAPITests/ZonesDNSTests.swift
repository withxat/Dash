import Foundation
import Testing

@testable import CloudflareAPI

@Test func decodesPaginatedZoneEnvelope() throws {
  let data = Data(
    #"{"success":true,"result":[{"id":"zone","name":"example.com","status":"active"}],"result_info":{"page":1,"per_page":50,"total_count":1}}"#
      .utf8)
  let envelope = try JSONDecoder().decode(APIEnvelope<[CloudflareZone]>.self, from: data)
  #expect(envelope.result.first?.name == "example.com")
  #expect(envelope.resultInfo?.totalCount == 1)
}

@Test func decodesZonePlan() throws {
  let data = Data(
    #"{"id":"zone","name":"example.com","status":"active","plan":{"id":"p","name":"Free Website","legacy_id":"free"}}"#
      .utf8)
  let zone = try JSONDecoder().decode(CloudflareZone.self, from: data)
  #expect(zone.plan?.legacyId == "free")
  #expect(zone.plan?.name == "Free Website")
}

extension NetworkTests {
  @Test func createZonePostsNameAndAccountAndDecodesNameServers() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.httpMethod == "POST")
      #expect(request.url?.path == "/zones")
      let stream = request.httpBodyStream.map { stream -> Data in
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
          let read = stream.read(buffer, maxLength: size)
          if read <= 0 { break }
          data.append(buffer, count: read)
        }
        return data
      }
      if let stream,
        let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: stream)
      {
        #expect(decoded["name"] == .string("new.example"))
        #expect(decoded["account"] == .object(["id": .string("acct")]))
      }
      let body = #"""
        {"success":true,"result":{"id":"z-new","name":"new.example","status":"pending",
        "name_servers":["ada.ns.cloudflare.com","bob.ns.cloudflare.com"]}}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let zone = try await client.createZone(name: "new.example", accountID: "acct")

    #expect(zone.id == "z-new")
    #expect(zone.status == "pending")
    #expect(zone.nameServers == ["ada.ns.cloudflare.com", "bob.ns.cloudflare.com"])
  }

  @Test func activationCheckPutsToActivationCheckPath() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.httpMethod == "PUT")
      #expect(request.url?.path == "/zones/z1/activation_check")
      return (200, Data(#"{"success":true,"result":{"id":"z1"}}"#.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    try await client.triggerZoneActivationCheck(zoneID: "z1")
  }

  @Test func deleteZoneDeletesZonePath() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.httpMethod == "DELETE")
      #expect(request.url?.path == "/zones/z1")
      return (200, Data(#"{"success":true,"result":{"id":"z1"}}"#.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    try await client.deleteZone(zoneID: "z1")
  }

  @Test func activationCheckSurfacesRateLimitMessage() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { _ in
      let body = #"""
        {"success":false,"result":null,
        "errors":[{"code":1224,"message":"You may only perform this action once per hour"}]}
        """#
      return (400, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    do {
      try await client.triggerZoneActivationCheck(zoneID: "z1")
      Issue.record("activation check should throw on a failed envelope")
    } catch let error as CloudflareAPIError {
      guard case .request(let status, let errors) = error else {
        Issue.record("expected .request, got \(error)")
        return
      }
      #expect(status == 400)
      #expect(errors.first?.code == 1224)
    }
  }

  @Test func createZoneSurfacesEnvelopeFailureAsRequestError() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { _ in
      let body = #"""
        {"success":false,"result":null,
        "errors":[{"code":1061,"message":"taken.example already exists."}]}
        """#
      return (400, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    do {
      _ = try await client.createZone(name: "taken.example", accountID: "acct")
      Issue.record("createZone should throw on a failed envelope")
    } catch let error as CloudflareAPIError {
      guard case .request(let status, let errors) = error else {
        Issue.record("expected .request, got \(error)")
        return
      }
      #expect(status == 400)
      #expect(errors.first?.code == 1061)
    }
  }

  @Test func listSkipsMalformedElementsInsteadOfFailingThePage() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.url?.path == "/zones")
      let body = #"""
        {"success":true,"result":[
          {"id":"zone-1","name":"one.example","status":"active"},
          {"id":"zone-broken","status":"active"},
          {"id":"zone-2","name":"two.example","status":"pending"}
        ]}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let zones = try await client.listZones(accountID: "account")

    #expect(zones.items.map(\.id) == ["zone-1", "zone-2"])
  }

  @Test func listDNSRecordsForwardsSearchAndType() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
      let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
      #expect(values["search"] == "mail")
      #expect(values["type"] == "MX")
      return (
        200,
        Data(
          #"""
          {"success":true,"result":[{
            "id":"rec-1","type":"MX","name":"example.com","content":"mail.example.com",
            "ttl":1,"priority":10
          }],"result_info":{"page":1,"per_page":100,"count":1,"total_count":1}}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let page = try await client.listDNSRecords(
      zoneID: "zone", search: "mail", type: "MX")
    #expect(page.items.count == 1)
    #expect(page.items[0].priority == 10)
  }

  @Test func dnsRecordInputEncodesSRVDataWithoutContent() throws {
    let input = DNSRecordInput(
      type: "SRV", name: "_xmpp._tcp.example.com",
      data: DNSRecordData(priority: 10, weight: 5, port: 5223, target: "server.example.com"))
    let data = try JSONEncoder().encode(input)
    let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(object["content"] == nil)
    let payload = object["data"] as! [String: Any]
    #expect(payload["priority"] as? Int == 10)
    #expect(payload["weight"] as? Int == 5)
    #expect(payload["port"] as? Int == 5223)
    #expect(payload["target"] as? String == "server.example.com")
  }

  @Test func dnsRecordInputEncodesCAADataWithoutContent() throws {
    let input = DNSRecordInput(
      type: "CAA", name: "example.com",
      data: DNSRecordData(flags: 0, tag: "issue", value: "letsencrypt.org"))
    let data = try JSONEncoder().encode(input)
    let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(object["content"] == nil)
    #expect(object["priority"] == nil)
    let payload = object["data"] as! [String: Any]
    #expect(payload["flags"] as? Int == 0)
    #expect(payload["tag"] as? String == "issue")
    #expect(payload["value"] as? String == "letsencrypt.org")
    #expect(payload["priority"] == nil)
    #expect(payload["target"] == nil)
  }
}
