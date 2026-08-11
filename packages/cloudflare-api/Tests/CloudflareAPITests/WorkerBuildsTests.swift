import Foundation
import Testing

@testable import CloudflareAPI

extension NetworkTests {
  @Test func listWorkerBuildsKeysOnTheScriptTagNotTheName() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      // The whole point of the tag: `/builds/workers/{external_script_id}/builds`
      // 404s if a Worker's *name* is sent here.
      #expect(request.url?.path == "/accounts/acc/builds/workers/tag-uuid/builds")
      #expect(request.url?.query?.contains("per_page=20") == true)
      return (
        200,
        Data(
          #"""
          {"success":true,"errors":[],"messages":[],"result":[
            {"build_uuid":"b-1","status":"running","created_on":"2026-07-27T10:00:00Z",
             "initializing_on":"2026-07-27T10:00:05Z","running_on":"2026-07-27T10:00:20Z",
             "build_trigger_metadata":{"branch":"main","commit_hash":"0123456789abcdef",
               "commit_message":"fix the thing","author":"xat","build_command":"npm run build"}},
            {"build_uuid":"b-0","status":"stopped","build_outcome":"success",
             "created_on":"2026-07-26T10:00:00Z","stopped_on":"2026-07-26T10:03:00Z"}
          ]}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let page = try await client.listWorkerBuilds(accountID: "acc", scriptTag: "tag-uuid")
    #expect(page.items.count == 2)
    #expect(page.items[0].isInProgress)
    #expect(page.items[0].phase == .running)
    #expect(page.items[0].buildTriggerMetadata?.branch == "main")
    #expect(page.items[0].buildTriggerMetadata?.shortCommit == "0123456")
    #expect(!page.items[1].isInProgress)
    #expect(!page.items[1].didFail)
  }

  @Test func latestWorkerBuildsBatchesTagsAndIsKeyedByTag() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.url?.path == "/accounts/acc/builds/builds/latest")
      #expect(request.url?.query?.contains("external_script_ids=tag-a,tag-b") == true)
      return (
        200,
        Data(
          #"""
          {"success":true,"errors":[],"messages":[],"result":{"builds":{
            "tag-a":{"build_uuid":"b-a","status":"queued","created_on":"2026-07-27T10:00:00Z"},
            "tag-b":{"build_uuid":"b-b","build_outcome":"failure","stopped_on":"2026-07-27T09:00:00Z"}
          }}}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let builds = try await client.latestWorkerBuilds(
      accountID: "acc", scriptTags: ["tag-a", "tag-b"])
    #expect(builds["tag-a"]?.phase == .queued)
    #expect(builds["tag-b"]?.phase == .finished)
    #expect(builds["tag-b"]?.didFail == true)
  }

  @Test func latestWorkerBuildsSkipsTheRequestWhenThereIsNothingToAsk() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { _ in
      Issue.record("no request should be sent for an empty tag list")
      return (200, Data("{}".utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    #expect(try await client.latestWorkerBuilds(accountID: "acc", scriptTags: []).isEmpty)
  }

  @Test func cancelWorkerBuildPutsAndIgnoresAnUndocumentedBody() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.httpMethod == "PUT")
      #expect(request.url?.path == "/accounts/acc/builds/builds/b-1/cancel")
      // Shape is undocumented; a cancel that worked must not read as a failure.
      return (200, Data(#"{"success":true,"errors":[],"messages":[],"result":{"weird":1}}"#.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    try await client.cancelWorkerBuild(accountID: "acc", buildUUID: "b-1")
  }
}

@Test func workerBuildPhaseReadsTimestampsNotTheUndocumentedStatusString() throws {
  // Cloudflare publishes no enum for `status`. A build carrying a status this
  // app has never seen must still resolve — and must resolve to finished, so an
  // unknown value can never pin a Live Activity to the Lock Screen forever.
  func build(_ json: String) throws -> WorkerBuild {
    try JSONDecoder().decode(WorkerBuild.self, from: Data(json.utf8))
  }

  #expect(try build(#"{"status":"some_future_state"}"#).phase == .finished)
  #expect(try build(#"{}"#).phase == .finished)
  // A terminal signal always wins, whatever the status says.
  #expect(
    try build(#"{"status":"running","running_on":"t","stopped_on":"t2"}"#).phase == .finished)
  #expect(try build(#"{"status":"running","build_outcome":"success"}"#).phase == .finished)
  // Live states.
  #expect(try build(#"{"status":"queued"}"#).phase == .queued)
  #expect(try build(#"{"status":"anything","initializing_on":"t"}"#).phase == .initializing)
  #expect(try build(#"{"status":"anything","running_on":"t"}"#).phase == .running)
}

@Test func workerBuildTreatsAMissingOutcomeAsUnknownRatherThanSuccess() throws {
  let stopped = try JSONDecoder().decode(
    WorkerBuild.self, from: Data(#"{"build_uuid":"b","stopped_on":"t"}"#.utf8))
  #expect(stopped.phase == .finished)
  // No outcome means Cloudflare did not say; claiming failure would be a lie
  // in the other direction.
  #expect(!stopped.didFail)

  let failed = try JSONDecoder().decode(
    WorkerBuild.self, from: Data(#"{"build_uuid":"b","build_outcome":"failure"}"#.utf8))
  #expect(failed.didFail)
}
