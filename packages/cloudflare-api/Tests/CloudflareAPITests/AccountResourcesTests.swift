import Foundation
import Testing

@testable import CloudflareAPI

extension NetworkTests {
  @Test func listAccountsCollectsEveryPage() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let recorder = RequestRecorder()
    let session = mockSession { request in
      let query = Dictionary(
        uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
          .queryItems ?? []).map {
            ($0.name, $0.value ?? "")
          })
      let page = query["page"] ?? "1"
      recorder.record(page)
      #expect(query["per_page"] == "50")
      if page == "1" {
        return (
          200,
          Data(
            #"""
            {"success":true,"result":[
              {"id":"account-1","name":"First"},
              {"id":"account-2","name":"Second"}
            ],"result_info":{"page":1,"per_page":2,"total_count":3}}
            """#.utf8)
        )
      }
      #expect(page == "2")
      return (
        200,
        Data(
          #"""
          {"success":true,"result":[
            {"id":"saved-account","name":"Saved"}
          ],"result_info":{"page":2,"per_page":2,"total_count":3}}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let accounts = try await client.listAccounts()

    #expect(accounts.map(\.id) == ["account-1", "account-2", "saved-account"])
    #expect(recorder.paths == ["1", "2"])
  }

  @Test func getAccountTargetsThePersistedAccountDirectly() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.url?.path == "/accounts/saved-account")
      return (
        200,
        Data(
          #"{"success":true,"result":{"id":"saved-account","name":"Saved"}}"#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let account = try await client.getAccount("saved-account")

    #expect(account.id == "saved-account")
    #expect(account.name == "Saved")
  }

  @Test func updateAccountSendsTypedPutAndDecodesAccount() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.httpMethod == "PUT")
      #expect(request.url?.path == "/accounts/account-1")
      let body = try #require(requestBodyObject(request))
      #expect(Set(body.keys) == Set(["name"]))
      #expect(body["name"] as? String == "Renamed account")
      return (
        200,
        Data(
          #"{"success":true,"result":{"id":"account-1","name":"Renamed account","type":"standard","created_on":"2026-08-10T08:00:00Z"}}"#
            .utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let account = try await client.updateAccount(
      accountID: "account-1",
      input: AccountUpdateInput(name: "Renamed account"))

    #expect(account.id == "account-1")
    #expect(account.name == "Renamed account")
    #expect(account.type == "standard")
    #expect(account.createdOn == "2026-08-10T08:00:00Z")
  }

  @Test func decodesRulesetDetail() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { _ in
      let body = #"""
        {"success":true,"result":{"id":"rs1","name":"Custom rules","kind":"custom",
        "phase":"http_request_firewall_custom","rules":[
        {"id":"r1","action":"block","expression":"ip.src eq 1.2.3.4","enabled":true}
        ]}}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let detail = try await client.getRuleset(basePath: "/accounts/account", id: "rs1")
    #expect(detail.rules?.first?.action == "block")
    #expect(detail.rules?.first?.enabled == true)
  }

  @Test func patchRulesetRuleTargetsRulePathWithBody() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.httpMethod == "PATCH")
      #expect(request.url?.path == "/zones/zone/rulesets/rs1/rules/r1")
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
        #expect(decoded["enabled"] == .bool(false))
      }
      let body = #"""
        {"success":true,"result":{"id":"rs1","name":"Custom rules","kind":"zone",
        "phase":"http_request_firewall_custom","rules":[
        {"id":"r1","action":"block","expression":"ip.src eq 1.2.3.4","enabled":false}
        ]}}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let detail = try await client.patchRulesetRule(
      basePath: "/zones/zone", rulesetID: "rs1", ruleID: "r1",
      body: ["enabled": .bool(false)])
    #expect(detail.rules?.first?.enabled == false)
  }

  @Test func createAccessPolicyTargetsReusableOrAppPath() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let recorder = RequestRecorder()
    let session = mockSession { request in
      recorder.record(request.url?.path ?? "")
      let body = #"""
        {"success":true,"result":{"id":"p1","name":"Allow team","decision":"allow",
        "include":[{"email_domain":{"domain":"xat.sh"}}]}}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let body: [String: JSONValue] = [
      "name": .string("Allow team"),
      "decision": .string("allow"),
      "include": .array([.object(["email_domain": .object(["domain": .string("xat.sh")])])]),
    ]
    let reusable = try await client.createAccessPolicy(accountID: "account", body: body)
    #expect(reusable.decision == "allow")
    _ = try await client.createAccessPolicy(accountID: "account", appID: "app1", body: body)
    #expect(
      recorder.paths == [
        "/accounts/account/access/policies",
        "/accounts/account/access/apps/app1/policies",
      ])
  }

  @Test func inviteAccountMemberSendsEmailAndRoleIDs() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.httpMethod == "POST")
      #expect(request.url?.path == "/accounts/account/members")
      let body = #"""
        {"success":true,"result":{"id":"m1","status":"pending",
        "user":{"email":"new@xat.sh"},"roles":[{"id":"r1","name":"Administrator Read Only"}]}}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let member = try await client.inviteAccountMember(
      accountID: "account", email: "new@xat.sh", roleIDs: ["r1"])
    #expect(member.id == "m1")
    #expect(member.roles?.first?.id == "r1")
  }
}
