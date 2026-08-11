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
}
