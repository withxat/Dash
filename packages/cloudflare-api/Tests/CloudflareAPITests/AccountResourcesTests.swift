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
}
