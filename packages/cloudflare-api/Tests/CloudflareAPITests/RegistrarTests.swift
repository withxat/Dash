import Foundation
import Testing

@testable import CloudflareAPI

// Cloudflare Registrar. Every test here lives in `NetworkTests` so it inherits
// the suite's `.serialized` trait — `MockURLProtocol` keeps `nonisolated(unsafe)
// static` state and a parallel suite would race it. Every function is prefixed
// `registrar` so `--filter registrar` selects exactly this file's 12 tests;
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

  // MARK: Legacy domains

  @Test func registrarLegacyDomainsPaginateByPageNumberAndDropUnnamedRows() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let recorder = RequestRecorder()
    let session = mockSession { request in
      #expect(request.url?.path == "/accounts/acct/registrar/domains")
      let query = registrarQuery(request)
      #expect(query["per_page"] == "2")
      let page = query["page"] ?? "1"
      recorder.record(page)
      let info = #""result_info":{"page":\#(page),"per_page":2,"total_pages":2,"total_count":3}"#
      switch page {
      case "1":
        let body = """
          {"success":true,"result":[\
          {"id":"example.com"},\
          {"id":"ea95132c15732412d22c1476fa83f27a"}\
          ],\(info)}
          """
        return (200, Data(body.utf8))
      case "2":
        let body = """
          {"success":true,"result":[{"id":"second.com"}],\(info)}
          """
        return (200, Data(body.utf8))
      default:
        Issue.record("unexpected page \(page)")
        return (500, Data())
      }
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let domains = try await client.listRegistrarDomainsLegacy(accountID: "acct", perPage: 2)

    #expect(recorder.paths == ["1", "2"])
    // The opaque-hex row is dropped: the identifier is the only name on the
    // object, and a row titled `ea95132c…` is worse than no row.
    #expect(domains.compactMap(\.identifier) == ["example.com", "second.com"])
  }

  @Test func registrarSplitsRegistryStatusesAndKeepsUnmodelledTransferValues() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.url?.path == "/accounts/acct/registrar/domains/example.com")
      let body = #"""
        {"success":true,"result":{
          "id":"example.com",
          "available":false,
          "can_register":false,
          "supported_tld":true,
          "locked":true,
          "created_at":"2025-01-15T10:00:00Z",
          "updated_at":"2026-01-15T10:00:00Z",
          "expires_at":"2027-01-15T10:00:00Z",
          "current_registrar":"Cloudflare",
          "registry_statuses":"clientTransferProhibited, serverTransferProhibited , ,ok",
          "registrant_contact":{"first_name":"Ada","country":"US"},
          "transfer_in":{"approve_transfer":"some_future_state","can_cancel_transfer":true}
        }}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let domain = try await client.getRegistrarDomain(accountID: "acct", domain: "example.com")

    #expect(
      domain.registryStatusList == ["clientTransferProhibited", "serverTransferProhibited", "ok"])
    #expect(domain.currentRegistrar == "Cloudflare")
    #expect(domain.supportedTLD == true)
    #expect(domain.canRegister == false)
    // A vocabulary Cloudflare has not published still has to reach the render step.
    #expect(domain.transferIn?.approveTransfer == "some_future_state")
    #expect(domain.transferIn?.canCancelTransfer == true)
    #expect(domain.transferIn?.unlockDomain == nil)
    // A partially redacted contact decodes; it does not throw.
    #expect(domain.registrantContact?.firstName == "Ada")
    #expect(domain.registrantContact?.country == "US")
    #expect(domain.registrantContact?.email == nil)
  }

  @Test func registrarDecodesADomainWithNoRegistrantContact() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { _ in
      (200, Data(#"{"success":true,"result":{"id":"example.com","locked":false}}"#.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let domain = try await client.getRegistrarDomain(accountID: "acct", domain: "example.com")

    // Redacted WHOIS is a settled answer, not a decode failure.
    #expect(domain.registrantContact == nil)
    #expect(domain.transferIn == nil)
    #expect(domain.registryStatusList.isEmpty)
    #expect(domain.locked == false)
  }

  // MARK: Update

  @Test func registrarSendsOnlyTheChangedFlagInTheUpdateBody() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let recorder = RequestRecorder()
    let session = mockSession { request in
      #expect(request.httpMethod == "PUT")
      #expect(request.url?.path == "/accounts/acct/registrar/domains/example.com")
      let data = requestBodyData(request) ?? Data()
      let decoded = (try? JSONDecoder().decode([String: Bool].self, from: data)) ?? [:]
      // Re-asserting auto_renew from a possibly-stale screen is how a lock
      // gets silently flipped back. Exactly one key.
      #expect(decoded == ["locked": false])
      recorder.record("put")
      return (200, Data(#"{"success":true,"result":null}"#.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    try await client.updateRegistrarDomain(
      accountID: "acct", domain: "example.com",
      settings: RegistrarDomainSettings(locked: false))

    #expect(recorder.paths == ["put"])
  }

  @Test func registrarUpdateAcceptsANullResult() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { _ in
      // The endpoint documents `result: unknown` and answers null in practice.
      (200, Data(#"{"success":true,"result":null}"#.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    try await client.updateRegistrarDomain(
      accountID: "acct", domain: "example.com",
      settings: RegistrarDomainSettings(autoRenew: true))
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
      try await client.updateRegistrarDomain(
        accountID: "acct", domain: "example.com",
        settings: RegistrarDomainSettings(locked: true))
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

// MARK: - Local helpers

private func registrarQuery(_ request: URLRequest) -> [String: String] {
  guard let url = request.url,
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
  else { return [:] }
  return Dictionary(
    items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
}
