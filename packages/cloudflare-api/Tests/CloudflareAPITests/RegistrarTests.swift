import Foundation
import Testing

@testable import CloudflareAPI

// Cloudflare Registrar. Every test here lives in `NetworkTests` so it inherits
// the suite's `.serialized` trait — `MockURLProtocol` keeps `nonisolated(unsafe)
// static` state and a parallel suite would race it. Every function is prefixed
// `registrar` so `--filter registrar` selects exactly this file's 10 tests;
// `--filter` matches function names, not files, and a zero-match filter is a
// vacuous pass.
extension NetworkTests {

  // MARK: Registration decode

  @Test func registrarDecodesSnakeCaseRegistrationFields() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.url?.path == "/accounts/acct/registrar/registrations/example.com")
      let body = #"""
        {"success":true,"result":{
          "domain_name":"example.com",
          "status":"active",
          "created_at":"2025-01-15T10:00:00Z",
          "expires_at":"2027-01-15T10:00:00Z",
          "auto_renew":true,
          "privacy_mode":"redaction",
          "locked":true
        }}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let registration = try await client.getRegistrarRegistration(
      accountID: "acct", domain: "example.com")

    #expect(registration.id == "example.com")
    #expect(registration.domainName == "example.com")
    #expect(registration.status == "active")
    #expect(registration.createdAt == "2025-01-15T10:00:00Z")
    #expect(registration.expiresAt == "2027-01-15T10:00:00Z")
    #expect(registration.autoRenew == true)
    #expect(registration.privacyMode == "redaction")
    #expect(registration.locked == true)
  }

  /// The shape that used to throw the whole detail screen's decode: a
  /// registration carrying nothing but its name.
  @Test func registrarDecodesARegistrationCarryingOnlyItsDomainName() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { _ in
      (200, Data(#"{"success":true,"result":{"domain_name":"example.com"}}"#.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let registration = try await client.getRegistrarRegistration(
      accountID: "acct", domain: "example.com")

    #expect(registration.id == "example.com")
    #expect(registration.status == nil)
    #expect(registration.createdAt == nil)
    #expect(registration.expiresAt == nil)
    #expect(registration.autoRenew == nil)
    #expect(registration.privacyMode == nil)
    #expect(registration.locked == nil)
  }

  // MARK: Cursor pagination

  @Test func registrarFollowsTheCursorUntilItIsExhausted() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let recorder = RequestRecorder()
    let session = mockSession { request in
      let query = registrarQuery(request)
      #expect(query["per_page"] == "50")
      #expect(query["sort_by"] == "registry_expires_at")
      #expect(query["direction"] == "asc")
      let cursor = query["cursor"] ?? "-"
      recorder.record(cursor)
      switch cursor {
      case "-":
        let body = #"""
          {"success":true,"result":[{"domain_name":"first.com"}],
           "result_info":{"cursor":"c1"}}
          """#
        return (200, Data(body.utf8))
      case "c1":
        let body = #"""
          {"success":true,"result":[{"domain_name":"second.com"}],"result_info":{}}
          """#
        return (200, Data(body.utf8))
      default:
        Issue.record("unexpected cursor \(cursor)")
        return (500, Data())
      }
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let registrations = try await client.listRegistrarRegistrations(accountID: "acct")

    #expect(registrations.map(\.domainName) == ["first.com", "second.com"])
    #expect(recorder.paths == ["-", "c1"])
  }

  /// A server that echoes its own cursor must not spin. The loop is bounded by
  /// the repeated cursor first and `maxPages` second.
  @Test func registrarStopsOnARepeatedCursor() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let recorder = RequestRecorder()
    let session = mockSession { request in
      let cursor = registrarQuery(request)["cursor"] ?? "-"
      recorder.record(cursor)
      let name = cursor == "-" ? "first.com" : "later\(recorder.paths.count).com"
      let body = """
        {"success":true,"result":[{"domain_name":"\(name)"}],\
        "result_info":{"cursor":"same-cursor"}}
        """
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let registrations = try await client.listRegistrarRegistrations(
      accountID: "acct", perPage: 50, maxPages: 20)

    #expect(recorder.paths == ["-", "same-cursor"])
    #expect(registrations.count == 2)
  }

  /// One malformed element costs one row, never the list. `domain_name` is the
  /// single strict field, so an element without it is what "malformed" means.
  @Test func registrarDropsOneMalformedRegistrationAndKeepsTheRest() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { _ in
      let body = #"""
        {"success":true,"result":[
          {"domain_name":"first.com"},
          {"status":"active"},
          {"domain_name":"third.com","auto_renew":false}
        ],"result_info":{}}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let registrations = try await client.listRegistrarRegistrations(accountID: "acct")

    #expect(registrations.map(\.domainName) == ["first.com", "third.com"])
    #expect(registrations.last?.autoRenew == false)
  }

  // MARK: Update

  @Test func registrarPatchesOnlyAutoRenewOnTheRegistration() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let recorder = RequestRecorder()
    let session = mockSession { request in
      #expect(request.httpMethod == "PATCH")
      #expect(request.url?.path == "/accounts/acct/registrar/registrations/example.com")
      let data = requestBodyData(request) ?? Data()
      let decoded = (try? JSONDecoder().decode([String: Bool].self, from: data)) ?? [:]
      // `auto_renew` is the only field the endpoint accepts.
      #expect(decoded == ["auto_renew": false])
      recorder.record("patch")
      let body = #"""
        {"success":true,"result":{"completed":true,"state":"succeeded",
         "context":{"domain_name":"example.com"}}}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    try await client.updateRegistrarAutoRenew(
      accountID: "acct", domain: "example.com", autoRenew: false)

    #expect(recorder.paths == ["patch"])
  }

  /// `202` is an accepted workflow that has not finished yet: not a failure.
  @Test func registrarAcceptsAnUpdateWorkflowThatIsStillRunning() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { _ in
      let body = #"""
        {"success":true,"result":{"completed":false,"state":"in_progress"}}
        """#
      return (202, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    try await client.updateRegistrarAutoRenew(
      accountID: "acct", domain: "example.com", autoRenew: true)
  }

  /// A failed workflow arrives inside a successful envelope. Reading only the
  /// HTTP status would report a renewal setting that never changed as saved.
  @Test func registrarThrowsTheMessageOfAFailedUpdateWorkflow() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { _ in
      let body = #"""
        {"success":true,"result":{"completed":true,"state":"failed",
         "error":{"code":"registry_rejected","message":"The registry rejected the update."}}}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    do {
      try await client.updateRegistrarAutoRenew(
        accountID: "acct", domain: "example.com", autoRenew: true)
      Issue.record("expected a throw")
    } catch let error as CloudflareAPIError {
      #expect(error.errorDescription == "The registry rejected the update.")
      #expect(!error.isPermissionDenied)
    }
  }

  // MARK: Failure paths

  @Test func registrarSurfacesCloudflaresMessageFromASuccessFalseEnvelope() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { _ in
      let body = #"""
        {"success":false,"result":null,
         "errors":[{"code":1004,"message":"Domain is not registered with Cloudflare Registrar"}]}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    do {
      try await client.updateRegistrarAutoRenew(
        accountID: "acct", domain: "example.com", autoRenew: true)
      Issue.record("expected a throw")
    } catch let error as CloudflareAPIError {
      guard case .request(let status, let errors) = error else {
        Issue.record("expected .request, got \(error)")
        return
      }
      #expect(status == 200)
      #expect(errors.first?.code == 1004)
      #expect(error.errorDescription == "Domain is not registered with Cloudflare Registrar")
    }
  }

  @Test func registrarReportsPermissionDeniedOnForbidden() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { _ in
      let body = #"""
        {"success":false,"result":null,
         "errors":[{"code":9109,"message":"Unauthorized to access requested resource"}]}
        """#
      return (403, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    do {
      _ = try await client.getRegistrarRegistration(accountID: "acct", domain: "example.com")
      Issue.record("expected a throw")
    } catch let error as CloudflareAPIError {
      // A 403 is the missing-scope answer and must stay distinguishable from
      // "this account owns no registered domains".
      #expect(error.isPermissionDenied)
      #expect(!error.isNotFound)
      #expect(error.errorDescription == "Unauthorized to access requested resource")
    }
  }
}

extension NetworkTests {
  @Test func rdapParsesRegistrarAndExpiry() throws {
    let body = #"""
      {
        "ldhName": "example.com",
        "status": ["client transfer prohibited"],
        "events": [
          {"eventAction": "registration", "eventDate": "1995-08-14T04:00:00Z"},
          {"eventAction": "expiration", "eventDate": "2027-08-13T04:00:00Z"}
        ],
        "nameservers": [{"ldhName": "a.iana-servers.net"}],
        "entities": [{
          "roles": ["registrar"],
          "vcardArray": ["vcard", [["version", {}, "text", "4.0"], ["fn", {}, "text", "RESERVED"]]]
        }]
      }
      """#
    let registration = try #require(
      RdapClient.parse(Data(body.utf8), fallbackDomain: "example.com"))
    #expect(registration.registrar == "RESERVED")
    #expect(registration.expiresOn == "2027-08-13T04:00:00Z")
    #expect(registration.nameservers == ["a.iana-servers.net"])
  }

  @Test func rdapStripsRootDotFromNameservers() throws {
    // bbc.co.uk answers RDAP with fully-qualified nameservers; the relay's WHOIS
    // leg returns them bare. Both feed the same zone card, so they must agree.
    let body = #"""
      {
        "ldhName": "bbc.co.uk",
        "nameservers": [{"ldhName": "ddns0.bbc.co.uk."}, {"ldhName": "dns0.bbc.com."}]
      }
      """#
    let registration = try #require(
      RdapClient.parse(Data(body.utf8), fallbackDomain: "bbc.co.uk"))
    #expect(registration.nameservers == ["ddns0.bbc.co.uk", "dns0.bbc.com"])
  }

  @Test func rdapPrefersRegistrarNameOverIanaHandle() throws {
    // Verisign answers .com with handle "1910" *and* the name. Showing the
    // handle put a bare IANA registrar id on the zone card.
    let body = #"""
      {
        "ldhName": "cloudflare.com",
        "nameservers": [{"ldhName": "NS3.CLOUDFLARE.COM."}],
        "entities": [{
          "roles": ["registrar"],
          "handle": "1910",
          "publicIds": [{"type": "IANA Registrar ID", "identifier": "1910"}],
          "vcardArray": ["vcard", [["version", {}, "text", "4.0"],
                                   ["fn", {}, "text", "Cloudflare, Inc."]]]
        }]
      }
      """#
    let registration = try #require(
      RdapClient.parse(Data(body.utf8), fallbackDomain: "cloudflare.com"))
    #expect(registration.registrar == "Cloudflare, Inc.")
    // Same normalization as the relay: lowercased, root dot stripped.
    #expect(registration.nameservers == ["ns3.cloudflare.com"])
  }

  @Test func rdapFallsBackToHandleWhenNoVCardName() throws {
    let body = #"""
      {"ldhName": "example.test",
       "entities": [{"roles": ["registrar"], "handle": "Registry Operator"}]}
      """#
    let registration = try #require(
      RdapClient.parse(Data(body.utf8), fallbackDomain: "example.test"))
    #expect(registration.registrar == "Registry Operator")
  }

  @Test func rdapLookupDecodesRelaySnapshot() async throws {
    let session = mockSession { request in
      #expect(request.url?.path == "/api/registration/xat.sh")
      return (
        200,
        Data(
          #"""
          {"domain":"xat.sh","status":["clientTransferProhibited"],
           "registrar":"Cloudflare, Inc",
           "registeredOn":"2024-10-23T06:49:51Z",
           "expiresOn":"2027-10-23T06:49:51Z",
           "updatedOn":"2026-05-05T02:33:29Z",
           "nameservers":["jason.ns.cloudflare.com","nola.ns.cloudflare.com"]}
          """#.utf8)
      )
    }
    let registration = try #require(
      try await RdapClient.lookup(
        domain: "xat.sh",
        relayBaseURL: URL(string: "https://dash.example.test")!,
        session: session))
    #expect(registration.registrar == "Cloudflare, Inc")
    #expect(registration.expiresOn == "2027-10-23T06:49:51Z")
    #expect(registration.nameservers.count == 2)
  }
}

// MARK: - Local helpers

private func registrarQuery(_ request: URLRequest) -> [String: String] {
  guard let url = request.url,
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
  else { return [:] }
  return Dictionary(
    items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
}
