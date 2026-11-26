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

  @Test func getWorkerBuildReadsOneBuildWithoutAScriptTag() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.url?.path == "/accounts/acc/builds/builds/b-1")
      return (
        200,
        Data(
          #"""
          {"success":true,"errors":[],"messages":[],"result":
            {"build_uuid":"b-1","status":"stopped","build_outcome":"fail",
             "created_on":"2026-07-27T10:00:00Z","initializing_on":"2026-07-27T10:00:03Z",
             "running_on":"2026-07-27T10:00:12Z","stopped_on":"2026-07-27T10:01:04Z",
             "build_trigger_metadata":{"branch":"main","commit_hash":"0123456789abcdef",
               "build_trigger_source":"push","repo_name":"api-gateway",
               "provider_account_name":"acme","provider_type":"github",
               "root_directory":"/","environment_variables":{"K":{"is_secret":true}}}}}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let build = try await client.getWorkerBuild(accountID: "acc", buildUUID: "b-1")
    #expect(build.outcome == .failed)
    #expect(build.duration == 64)
    #expect(build.buildTriggerMetadata?.source == .push)
    #expect(build.buildTriggerMetadata?.repository == "acme/api-gateway")
    #expect(
      build.buildTriggerMetadata?.commitURL?.absoluteString
        == "https://github.com/acme/api-gateway/commit/0123456789abcdef")
  }

  @Test func workerBuildLogFollowsTheCursorUntilThePageIsNoLongerTruncated() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.url?.path == "/accounts/acc/builds/builds/b-1/logs")
      let query = request.url?.query ?? ""
      if query.contains("cursor=c1") {
        return (
          200,
          Data(
            #"""
            {"success":true,"errors":[],"messages":[],"result":
              {"cursor":"c2","truncated":false,"lines":[[1785146403000,"third"]]}}
            """#.utf8)
        )
      }
      #expect(!query.contains("cursor"))
      return (
        200,
        Data(
          #"""
          {"success":true,"errors":[],"messages":[],"result":
            {"cursor":"c1","truncated":true,
             "lines":[[1785146401000,"first"],[1785146402,"second"]]}}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let log = try await client.getWorkerBuildLog(accountID: "acc", buildUUID: "b-1")
    #expect(log.lines.map(\.text) == ["first", "second", "third"])
    #expect(!log.truncated)
    // Milliseconds and seconds name the same second, one apart.
    #expect(log.lines[0].timestamp == Date(timeIntervalSince1970: 1_785_146_401))
    #expect(log.lines[1].timestamp == Date(timeIntervalSince1970: 1_785_146_402))
  }

  @Test func workerBuildLogStopsAtItsPageBoundWhenTheServerNeverFinishes() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let requests = RequestCounter()
    let session = mockSession { _ in
      let page = requests.next()
      return (
        200,
        Data(
          """
          {"success":true,"errors":[],"messages":[],"result":
            {"cursor":"c\(page)","truncated":true,"lines":[[1785146401000,"line \(page)"]]}}
          """.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let log = try await client.getWorkerBuildLog(accountID: "acc", buildUUID: "b-1", maxPages: 3)
    #expect(log.lines.count == 3)
    // The bound ended the read, not the log — the caller must be able to say so.
    #expect(log.truncated)
  }
}

private final class RequestCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  func next() -> Int {
    lock.lock()
    defer { lock.unlock() }
    count += 1
    return count
  }
}

@Test func workerBuildLogLinesSurviveShapesTheDocsDoNotPromise() throws {
  func lines(_ json: String) throws -> [WorkerBuildLogLine] {
    try JSONDecoder().decode(WorkerBuildLogs.self, from: Data(json.utf8)).lines
  }

  // Tuple order reversed, a bare string, a null stamp, and an empty tuple: each
  // still yields its line, and none of them costs the lines around it.
  let odd = try lines(
    #"{"lines":[["text first",1785146401000],"bare",[null,"no stamp"],[],[1785146401000,"ok"]]}"#)
  #expect(odd.map(\.text) == ["text first", "bare", "no stamp", "", "ok"])
  #expect(odd[0].timestamp != nil)
  #expect(odd[1].timestamp == nil)
  #expect(odd[2].timestamp == nil)
  // A missing `lines` is an empty log, not a decode failure.
  #expect(try lines(#"{"truncated":false}"#).isEmpty)
}

@Test func workerBuildTimelinePutsTheOutcomeOnTheStepTheBuildStoppedIn() throws {
  func build(_ json: String) throws -> WorkerBuild {
    try JSONDecoder().decode(WorkerBuild.self, from: Data(json.utf8))
  }
  func states(_ build: WorkerBuild) -> [WorkerBuild.Step.State] { build.timeline.map(\.state) }

  // Failed while building: the two steps before it ran clean.
  let failed = try build(
    #"""
    {"build_outcome":"fail","created_on":"2026-07-27T10:00:00Z",
     "initializing_on":"2026-07-27T10:00:03Z","running_on":"2026-07-27T10:00:12Z",
     "stopped_on":"2026-07-27T10:01:04Z"}
    """#)
  #expect(states(failed) == [.done, .done, .failed])
  #expect(failed.timeline.map(\.duration) == [3, 9, 52])

  // Failed while initializing: it never built, so Building is not "failed".
  let early = try build(
    #"""
    {"build_outcome":"fail","created_on":"2026-07-27T10:00:00Z",
     "initializing_on":"2026-07-27T10:00:03Z","stopped_on":"2026-07-27T10:00:08Z"}
    """#)
  #expect(states(early) == [.done, .failed, .notReached])
  #expect(early.timeline[1].duration == 5)

  // In flight: the current step is active with no duration yet, the rest wait.
  let running = try build(
    #"{"status":"running","created_on":"2026-07-27T10:00:00Z","initializing_on":"2026-07-27T10:00:03Z"}"#
  )
  #expect(states(running) == [.done, .active, .pending])
  #expect(running.timeline[1].duration == nil)
  #expect(running.outcome == nil)

  // Stopped with no outcome: Cloudflare did not say, so neither does the rail.
  let silent = try build(
    #"{"created_on":"2026-07-27T10:00:00Z","stopped_on":"2026-07-27T10:00:02Z"}"#)
  #expect(states(silent) == [.ended, .notReached, .notReached])
  #expect(silent.outcome == nil)

  let cancelled = try build(
    #"{"build_outcome":"canceled","created_on":"2026-07-27T10:00:00Z","running_on":"2026-07-27T10:00:05Z","stopped_on":"2026-07-27T10:00:09Z"}"#
  )
  // Initializing was skipped over, so Queued runs until Building began.
  #expect(states(cancelled) == [.done, .notReached, .stopped])
  #expect(cancelled.timeline[0].duration == 5)
}

@Test func workerBuildMetadataExtrasNeverCostTheBuild() throws {
  // `repo_name` as a number is not a shape Cloudflare documents; it must cost
  // the repository row and nothing else.
  let build = try JSONDecoder().decode(
    WorkerBuild.self,
    from: Data(
      #"{"build_uuid":"b","build_trigger_metadata":{"branch":"main","repo_name":7,"provider_type":"gitlab_internal","commit_hash":"abc"}}"#
        .utf8))
  #expect(build.buildTriggerMetadata?.branch == "main")
  #expect(build.buildTriggerMetadata?.repository == nil)
  // A self-managed host has no URL this client can name.
  #expect(build.buildTriggerMetadata?.commitURL == nil)
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
