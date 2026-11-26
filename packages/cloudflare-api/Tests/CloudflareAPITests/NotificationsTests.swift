import Foundation
import Testing

@testable import CloudflareAPI

extension NetworkTests {
  @Test func treatsNullNotificationHistoryAsEmpty() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.url?.path == "/accounts/acct/alerting/v3/history")
      #expect(
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
          .queryItems?.first { $0.name == "per_page" }?.value == "10")
      return (200, Data(#"{"success":true,"result":null}"#.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let history = try await client.listNotificationHistory(accountID: "acct")

    #expect(history.isEmpty)
  }

  @Test func notificationHistoryPrefersAPIIdentifier() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { _ in
      let body = #"""
        {"success":true,"result":[{
          "id":"f174e90afafe4643bbbc4a0ed4fc8415",
          "policy_id":"pol-1",
          "name":"SSL",
          "alert_type":"universal_ssl_event_type",
          "alert_body":"expired",
          "sent":"2021-10-08T17:52:17.571336Z"
        }]}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let history = try await client.listNotificationHistory(accountID: "acct")
    #expect(history.count == 1)
    #expect(history.first?.historyID == "f174e90afafe4643bbbc4a0ed4fc8415")
    #expect(history.first?.id == "f174e90afafe4643bbbc4a0ed4fc8415")
  }

  @Test func auditLogsFallBackToV1OnlyWhenV2IsForbidden() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let recorder = RequestRecorder()
    let session = mockSession { request in
      let path = request.url?.path ?? ""
      recorder.record(path)
      if path.hasSuffix("/logs/audit") {
        return (
          403,
          Data(
            #"{"success":false,"result":[],"errors":[{"code":1000,"message":"forbidden"}]}"#.utf8)
        )
      }
      #expect(path == "/accounts/acct/audit_logs")
      return (200, Data(#"{"success":true,"result":[]}"#.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let entries = try await client.listAuditLogs(accountID: "acct")

    #expect(entries.isEmpty)
    #expect(recorder.paths == ["/accounts/acct/logs/audit", "/accounts/acct/audit_logs"])
  }

  /// Cloudflare's SDKs encode nested filters with dots (`action_type.not`).
  @Test func auditLogsV2LeaveOutViewActions() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      let items =
        request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
        .queryItems ?? []
      #expect(items.contains(URLQueryItem(name: "action_type.not", value: "view")))
      return (200, Data(#"{"success":true,"result":[]}"#.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    _ = try await client.listAuditLogsV2(accountID: "acct")
  }

  @Test func auditLogsFallBackToV1WhenV2IsNotFound() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let recorder = RequestRecorder()
    let session = mockSession { request in
      let path = request.url?.path ?? ""
      recorder.record(path)
      if path.hasSuffix("/logs/audit") {
        return (
          404,
          Data(
            #"{"success":false,"result":[],"errors":[{"code":7003,"message":"not found"}]}"#.utf8)
        )
      }
      #expect(path == "/accounts/acct/audit_logs")
      return (200, Data(#"{"success":true,"result":[]}"#.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let entries = try await client.listAuditLogs(accountID: "acct")

    #expect(entries.isEmpty)
    #expect(recorder.paths == ["/accounts/acct/logs/audit", "/accounts/acct/audit_logs"])
  }

  /// The transport failing the v2 request with a cancellation is the shape a
  /// bare `catch` mishandles: the surrounding task is still alive, so it would
  /// happily issue v1 and answer an aborted read with an empty log.
  @Test func auditLogsDoNotTurnCancellationIntoAV1Request() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let recorder = RequestRecorder()
    let session = mockSession { request in
      let path = request.url?.path ?? ""
      recorder.record(path)
      if path.hasSuffix("/logs/audit") {
        throw URLError(.cancelled)
      }
      return (200, Data(#"{"success":true,"result":[]}"#.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    await #expect(throws: CancellationError.self) {
      try await client.listAuditLogs(accountID: "acct")
    }
    #expect(recorder.paths == ["/accounts/acct/logs/audit"])
  }

  @Test func auditLogsDoNotHideMalformedV2ResponsesBehindV1() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let recorder = RequestRecorder()
    let session = mockSession { request in
      let path = request.url?.path ?? ""
      recorder.record(path)
      if path.hasSuffix("/logs/audit") {
        return (200, Data(#"{"success":true,"result":"not-an-array"}"#.utf8))
      }
      return (200, Data(#"{"success":true,"result":[]}"#.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    await #expect(throws: DecodingError.self) {
      try await client.listAuditLogs(accountID: "acct")
    }
    #expect(recorder.paths == ["/accounts/acct/logs/audit"])
  }

  @Test func auditLogsV2DecodesDetailFieldsAndPaginatesWithCursor() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let recorder = RequestRecorder()
    let session = mockSession { request in
      let url = request.url!
      recorder.record(url.absoluteString)
      let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
      let cursor = items.first { $0.name == "cursor" }?.value
      if cursor == nil {
        let body = #"""
          {
            "success": true,
            "result": [{
              "id": "evt-1",
              "action": {"type": "purge", "description": "Purged zone cache", "result": "success", "time": "2026-11-25T10:00:00Z"},
              "actor": {"id": "usr-1", "email": "ops@example.com", "type": "user", "ip_address": "198.51.100.4", "context": "api_token", "token_name": "CI Deploy"},
              "resource": {"id": "zone-1", "product": "caching", "type": "zone", "scope": "zones"},
              "zone": {"id": "zone-1", "name": "example.com"},
              "raw": {"cf_ray_id": "8f1234567890abcd-SIN", "method": "POST", "status_code": 200, "uri": "/client/v4/zones/zone-1/purge_cache"}
            }],
            "result_info": {"cursor": "next-cursor-1"}
          }
          """#
        return (200, Data(body.utf8))
      }
      #expect(cursor == "next-cursor-1")
      let body = #"""
        {
          "success": true,
          "result": [{
            "id": "evt-2",
            "action": {"type": "delete", "description": "Deleted DNS record", "result": "failure", "time": "2026-11-25T09:00:00Z"},
            "actor": {"email": "ops@example.com", "type": "user"},
            "resource": {"id": "rec-9", "product": "dns", "type": "dns_record"}
          }],
          "result_info": {"cursor": "next-cursor-1"}
        }
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let first = try await client.listAuditLogsPage(accountID: "acct", perPage: 25)
    #expect(first.entries.count == 1)
    let entry = try #require(first.entries.first)
    #expect(entry.actor?.ipAddress == "198.51.100.4")
    #expect(entry.actor?.tokenName == "CI Deploy")
    #expect(entry.actor?.context == "api_token")
    #expect(entry.resource?.scope == "zones")
    #expect(entry.zoneName == "example.com")
    #expect(entry.method == "POST")
    #expect(entry.uri == "/client/v4/zones/zone-1/purge_cache")
    #expect(entry.statusCode == 200)
    #expect(entry.rayID == "8f1234567890abcd-SIN")
    let token = try #require(first.nextPage)

    // Round-trip through JSON to verify cache persistence keeps all new fields.
    let roundTripped = try JSONDecoder().decode(
      AuditLogEntry.self, from: JSONEncoder().encode(entry))
    #expect(roundTripped == entry)

    let second = try await client.listAuditLogsPage(accountID: "acct", perPage: 25, page: token)
    #expect(second.entries.map(\.logID) == ["evt-2"])
    // Echoed cursor must terminate pagination instead of looping forever.
    #expect(second.nextPage == nil)
    #expect(recorder.paths.count == 2)
  }

  @Test func auditLogsV1FallbackDecodesLegacyFieldsAndPaginatesByPage() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      let path = request.url?.path ?? ""
      if path.hasSuffix("/logs/audit") {
        return (
          403,
          Data(
            #"{"success":false,"result":[],"errors":[{"code":1000,"message":"forbidden"}]}"#.utf8)
        )
      }
      let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
      let page = items.first { $0.name == "page" }?.value
      if page == "1" {
        let body = #"""
          {
            "success": true,
            "result": [{
              "id": "v1-1",
              "action": {"type": "update", "result": true},
              "actor": {"id": "u1", "email": "legacy@example.com", "ip": "203.0.113.8", "type": "user"},
              "resource": {"id": "r1", "type": "zone"},
              "interface": "UI",
              "oldValue": "off",
              "newValue": "on",
              "when": "2026-11-25T08:00:00Z"
            }],
            "result_info": {"page": 1, "per_page": 1, "total_pages": 2, "total_count": 2}
          }
          """#
        return (200, Data(body.utf8))
      }
      #expect(page == "2")
      let body = #"""
        {
          "success": true,
          "result": [{
            "id": "v1-2",
            "action": {"type": "delete", "result": false},
            "actor": {"email": "legacy@example.com", "type": "user"},
            "resource": {"id": "r2", "type": "zone"},
            "when": "2026-11-25T07:00:00Z"
          }],
          "result_info": {"page": 2, "per_page": 1, "total_pages": 2, "total_count": 2}
        }
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let first = try await client.listAuditLogsPage(accountID: "acct", perPage: 1)
    let entry = try #require(first.entries.first)
    #expect(entry.action?.result == "success")
    #expect(entry.actor?.ipAddress == "203.0.113.8")
    #expect(entry.interfaceName == "UI")
    #expect(entry.oldValue == "off")
    #expect(entry.newValue == "on")
    #expect(first.nextPage == .v1(page: 2))

    let second = try await client.listAuditLogsPage(
      accountID: "acct", perPage: 1, page: first.nextPage)
    #expect(second.entries.first?.action?.result == "failure")
    #expect(second.nextPage == nil)
  }
}
