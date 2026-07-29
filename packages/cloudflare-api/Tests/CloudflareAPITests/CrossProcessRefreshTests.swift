import Foundation
import Testing

@testable import CloudflareAPI

/// Cross-process token refresh.
///
/// Cloudflare rotates the refresh token on use, and Dash shares one keychain
/// credential between the app, DashShare and (next) a File Provider. Two
/// processes that 401 at the same instant must not both spend it: the first
/// rotates it, the second is told `invalid_grant`, and the loser used to be
/// able to wipe a keychain the winner had not written back to yet — leaving
/// both signed out with only a full re-OAuth to recover. `refresh()` now runs
/// inside `TokenStore.withExclusiveRefreshAccess` and re-reads the credential
/// on the other side of it.
///
/// Every test here lives in `extension NetworkTests` so it inherits that
/// suite's `.serialized` trait — `MockURLProtocol` keeps its handler in
/// `nonisolated(unsafe) static` state, and a second suite would race it. Every
/// function is prefixed `crossProcessRefresh…` so `--filter crossProcessRefresh`
/// selects the whole set (`--filter` matches test function names, not files).
extension NetworkTests {

  // MARK: - The lock

  /// The headline property: with two clients on one shared store, the rotating
  /// refresh token is POSTed **once** and both clients end up authenticated on
  /// the winner's new pair. The loser must never be signed out.
  ///
  /// `settles` bounds the rendezvous and the time limit backstops the two task
  /// awaits after it, so a `refresh()` that stops entering the exclusive
  /// section fails this test instead of hanging the suite.
  @Test(.timeLimit(.minutes(1)))
  func crossProcessRefreshSpendsTheRotatingTokenOnce() async throws {
    let recorder = RequestRecorder()
    let store = SharedRefreshTokenStore(access: "at1", refresh: "rt1", pausesFirstHolder: true)
    let session = mockSession { request in
      if request.url?.path == "/token" {
        recorder.recordRefresh()
        return (200, Data(#"{"access_token":"at2","refresh_token":"rt2"}"#.utf8))
      }
      if request.value(forHTTPHeaderField: "Authorization") == "Bearer at2" {
        return (200, Data(#"{"success":true,"result":[{"id":"account","name":"Example"}]}"#.utf8))
      }
      return (401, Data(#"{"success":false,"errors":[{"code":1000,"message":"expired"}]}"#.utf8))
    }
    let app = SharedRefreshTokenStore.client(store: store, session: session)
    let shareExtension = SharedRefreshTokenStore.client(store: store, session: session)

    let winner = Task { try await app.listAccounts() }
    // Hold the lock until the second "process" is provably queued behind it,
    // which is the interleaving that used to destroy the credential.
    #expect(await settles { await store.isHolding() }, "refresh never took the lock")
    let loser = Task { try await shareExtension.listAccounts() }
    #expect(await settles { await store.sawContention() }, "the second client never queued")
    await store.releaseHolder()

    let winnerAccounts = try await winner.value
    let loserAccounts = try await loser.value
    #expect(winnerAccounts.map(\.name) == ["Example"])
    #expect(loserAccounts.map(\.name) == ["Example"])
    #expect(recorder.refreshCount == 1)
    #expect(await store.getAccessToken() == "at2")
    #expect(await store.getRefreshToken() == "rt2")
  }

  /// Having waited for the lock, a caller must notice the winner's write and
  /// adopt it. Spending its own copy of the refresh token would be spending a
  /// token Cloudflare has already retired.
  @Test func crossProcessRefreshSkipsThePostWhenAnotherProcessAlreadyRotated() async throws {
    let recorder = RequestRecorder()
    let store = SharedRefreshTokenStore(
      access: "at1", refresh: "rt1",
      rotationOnLock: TokenSet(accessToken: "at2", refreshToken: "rt2"))
    let session = mockSession { request in
      if request.url?.path == "/token" {
        recorder.recordRefresh()
        return (200, Data(#"{"access_token":"at3","refresh_token":"rt3"}"#.utf8))
      }
      let authorization = request.value(forHTTPHeaderField: "Authorization") ?? "missing"
      recorder.record(authorization)
      if authorization == "Bearer at2" {
        return (200, Data(#"{"success":true,"result":[{"id":"account","name":"Example"}]}"#.utf8))
      }
      return (401, Data(#"{"success":false,"errors":[{"code":1000,"message":"expired"}]}"#.utf8))
    }
    let client = SharedRefreshTokenStore.client(store: store, session: session)

    let accounts = try await client.listAccounts()

    #expect(accounts.map(\.name) == ["Example"])
    #expect(recorder.refreshCount == 0)
    #expect(recorder.paths == ["Bearer at1", "Bearer at2"])
    #expect(await store.getAccessToken() == "at2")
    #expect(await store.getRefreshToken() == "rt2")
  }

  // MARK: - invalid_grant

  /// The winner's write lands while our own POST is in flight, so the answer is
  /// `invalid_grant` even though a perfectly good credential now exists. The
  /// old code cleared here, which also cost the winner its write: its
  /// compare-and-swap then missed and it discarded a freshly issued pair.
  @Test func crossProcessRefreshAdoptsTheWinnersTokenInsteadOfClearingOnInvalidGrant()
    async throws
  {
    let store = SharedRefreshTokenStore(
      access: "at1", refresh: "rt1",
      rotationOnRefreshTokenRead: TokenSet(accessToken: "at2", refreshToken: "rt2"))
    let session = mockSession { request in
      if request.url?.path == "/token" {
        return (400, Data(#"{"error":"invalid_grant"}"#.utf8))
      }
      if request.value(forHTTPHeaderField: "Authorization") == "Bearer at2" {
        return (200, Data(#"{"success":true,"result":[{"id":"account","name":"Example"}]}"#.utf8))
      }
      return (401, Data(#"{"success":false,"errors":[{"code":1000,"message":"expired"}]}"#.utf8))
    }
    let client = SharedRefreshTokenStore.client(store: store, session: session)

    let accounts = try await client.listAccounts()

    #expect(accounts.map(\.name) == ["Example"])
    #expect(await store.clearTokensCalls() == 0)
    #expect(await store.getAccessToken() == "at2")
    #expect(await store.getRefreshToken() == "rt2")
  }

  /// Lock timeout. We know another process is mid-rotation and we know nothing
  /// about what it will write, so this caller must not POST the rotating token
  /// at all. A transport-shaped error asks the caller to retry without turning
  /// temporary lock contention into an unauthorized sign-out.
  @Test func crossProcessRefreshWithoutTheLockNeverPostsOrWipesTheCredential() async throws {
    let recorder = RequestRecorder()
    let store = SharedRefreshTokenStore(access: "at1", refresh: "rt1", exclusivity: .denied)
    let session = mockSession { request in
      if request.url?.path == "/token" {
        recorder.recordRefresh()
        return (400, Data(#"{"error":"invalid_grant"}"#.utf8))
      }
      return (401, Data(#"{"success":false,"errors":[{"code":1000,"message":"expired"}]}"#.utf8))
    }
    let client = SharedRefreshTokenStore.client(store: store, session: session)

    do {
      _ = try await client.listAccounts()
      Issue.record("lock contention should surface as a retryable transport error")
    } catch let error as CloudflareAPIError {
      #expect(error.isTransport)
    }

    #expect(recorder.refreshCount == 0)
    #expect(await store.clearTokensCalls() == 0)
    #expect(await store.getAccessToken() == "at1")
    #expect(await store.getRefreshToken() == "rt1")
  }

  /// The other half of the rule above: holding the lock means nobody else can
  /// be rotating, so a genuinely revoked grant must still clear. Without this
  /// the "never wipe" guard would quietly disable sign-out.
  @Test func crossProcessRefreshStillClearsARevokedGrantWhileHoldingTheLock() async throws {
    let store = SharedRefreshTokenStore(access: "at1", refresh: "revoked")
    let session = mockSession { request in
      if request.url?.path == "/token" {
        return (400, Data(#"{"error":"invalid_grant"}"#.utf8))
      }
      return (401, Data(#"{"success":false,"errors":[{"code":1000,"message":"expired"}]}"#.utf8))
    }
    let client = SharedRefreshTokenStore.client(store: store, session: session)

    do {
      _ = try await client.listAccounts()
      Issue.record("a revoked refresh token should surface as unauthorized")
    } catch let error as CloudflareAPIError {
      #expect(error.isUnauthorized)
    }

    #expect(await store.clearTokensCalls() == 1)
    #expect(await store.getAccessToken() == nil)
    #expect(await store.getRefreshToken() == nil)
  }

  // MARK: - Unchanged policy

  /// The new awaits in the refresh path must not turn a long `Retry-After` into
  /// a stall. A server-requested wait past `maxAutoRetryDelay` still surfaces
  /// immediately as a 429 instead of sleeping a minute inside the client.
  @Test func crossProcessRefreshLeavesTheLongRetryAfterPolicyAlone() async throws {
    let recorder = RequestRecorder()
    let store = SharedRefreshTokenStore(access: "at1", refresh: "rt1")
    let session = mockSession { request in
      if request.url?.path == "/token" {
        recorder.recordRefresh()
        return (200, Data(#"{"access_token":"at2","refresh_token":"rt2"}"#.utf8))
      }
      let authorization = request.value(forHTTPHeaderField: "Authorization") ?? "missing"
      recorder.record(authorization)
      if authorization == "Bearer at2" {
        return (
          429, Data(#"{"success":false,"errors":[{"code":971,"message":"rate limited"}]}"#.utf8)
        )
      }
      return (401, Data(#"{"success":false,"errors":[{"code":1000,"message":"expired"}]}"#.utf8))
    }
    MockURLProtocol.responseHeaders = ["Retry-After": "60"]
    defer { MockURLProtocol.responseHeaders = nil }
    let client = SharedRefreshTokenStore.client(store: store, session: session)

    let started = ContinuousClock.now
    do {
      _ = try await client.listAccounts()
      Issue.record("expected the rate limit to surface")
    } catch let error as CloudflareAPIError {
      guard case .request(let status, _) = error else {
        Issue.record("expected a request error, got \(error)")
        return
      }
      #expect(status == 429)
    }

    #expect(ContinuousClock.now - started < .seconds(5))
    #expect(recorder.refreshCount == 1)
    #expect(recorder.paths == ["Bearer at1", "Bearer at2"])
  }
}

/// Stands in for the keychain item two processes share: real mutual exclusion
/// around refresh, plus the hooks needed to stage interleavings that only exist
/// while the *other* process is mid-rotation.
private actor SharedRefreshTokenStore: TokenStore {
  /// Whether the cross-process lock is obtainable. `.denied` is
  /// `KeychainTokenStore` giving up on `flock`: the body still runs, it is just
  /// told it holds no exclusivity.
  enum Exclusivity: Sendable { case granted, denied }

  private var access: String?
  private var refresh: String?
  private let exclusivity: Exclusivity
  /// Installed the moment the lock is taken — the winner having already
  /// finished before this caller got in.
  private let rotationOnLock: TokenSet?
  /// Installed just after this caller reads the refresh token — the winner
  /// landing while this caller's POST is still in flight.
  private let rotationOnRefreshTokenRead: TokenSet?
  private let pausesFirstHolder: Bool

  private var held = false
  private var turnWaiters: [CheckedContinuation<Void, Never>] = []
  private var hasRotatedOnRefreshTokenRead = false
  private var hasPausedOnce = false
  private var isHolderPaused = false
  private var holderReleased = false
  private var contentionCount = 0
  private var clearTokensCallCount = 0

  init(
    access: String?,
    refresh: String?,
    exclusivity: Exclusivity = .granted,
    rotationOnLock: TokenSet? = nil,
    rotationOnRefreshTokenRead: TokenSet? = nil,
    pausesFirstHolder: Bool = false
  ) {
    self.access = access
    self.refresh = refresh
    self.exclusivity = exclusivity
    self.rotationOnLock = rotationOnLock
    self.rotationOnRefreshTokenRead = rotationOnRefreshTokenRead
    self.pausesFirstHolder = pausesFirstHolder
  }

  static func client(store: SharedRefreshTokenStore, session: URLSession) -> CloudflareClient {
    CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session, tokenURL: URL(string: "https://auth.example.test/token")!)
  }

  // MARK: TokenStore

  func clear() {
    access = nil
    refresh = nil
  }

  func getAccessToken() -> String? { access }

  func getRefreshToken() -> String? {
    defer {
      if let rotation = rotationOnRefreshTokenRead, !hasRotatedOnRefreshTokenRead {
        hasRotatedOnRefreshTokenRead = true
        install(rotation)
      }
    }
    return refresh
  }

  func setTokens(_ tokens: TokenSet) { install(tokens) }

  func replaceTokens(
    _ tokens: TokenSet,
    ifCurrentAccessToken expectedAccessToken: String?,
    refreshToken expectedRefreshToken: String?
  ) -> Bool {
    guard access == expectedAccessToken, refresh == expectedRefreshToken else { return false }
    install(tokens)
    return true
  }

  func clearTokens(
    ifCurrentAccessToken expectedAccessToken: String?,
    refreshToken expectedRefreshToken: String?
  ) -> Bool {
    clearTokensCallCount += 1
    guard access == expectedAccessToken, refresh == expectedRefreshToken else { return false }
    access = nil
    refresh = nil
    return true
  }

  func withExclusiveRefreshAccess<T: Sendable>(
    _ body: @Sendable (_ isExclusive: Bool) async throws -> T
  ) async throws -> T {
    if held { noteContention() }
    // Re-check on wake: a caller that barged in between a resume and its waiter
    // running simply sends that waiter back to sleep.
    while held {
      await withCheckedContinuation { continuation in
        turnWaiters.append(continuation)
      }
    }
    held = true
    defer { releaseTurn() }
    if pausesFirstHolder, !hasPausedOnce {
      hasPausedOnce = true
      await pauseHolder()
    }
    if let rotationOnLock { install(rotationOnLock) }
    return try await body(exclusivity == .granted)
  }

  // MARK: Test hooks

  func clearTokensCalls() -> Int { clearTokensCallCount }

  /// True once a caller is parked inside the exclusive section.
  func isHolding() -> Bool { isHolderPaused }

  /// True once a second caller has found the lock taken.
  func sawContention() -> Bool { contentionCount > 0 }

  func releaseHolder() { holderReleased = true }

  // MARK: Internals

  private func install(_ tokens: TokenSet) {
    access = tokens.accessToken
    refresh = tokens.refreshToken
  }

  private func releaseTurn() {
    held = false
    let waiters = turnWaiters
    turnWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }

  private func noteContention() { contentionCount += 1 }

  /// Polls rather than parking on a continuation, and gives up on its own. A
  /// test double that can wait forever turns a regression into a hung suite.
  private func pauseHolder() async {
    isHolderPaused = true
    let deadline = ContinuousClock.now + .seconds(10)
    while !holderReleased, ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(2))
    }
  }
}

/// Bounded rendezvous for the two-process test. `condition` is polled instead
/// of signalled so a `refresh()` that never enters the exclusive section fails
/// the test in seconds instead of hanging the suite forever — Swift Testing's
/// `.timeLimit` cancels the task, and a parked continuation does not answer
/// cancellation.
private func settles(
  within seconds: Double = 5, _ condition: @Sendable () async -> Bool
) async -> Bool {
  let deadline = ContinuousClock.now + .seconds(seconds)
  while ContinuousClock.now < deadline {
    if await condition() { return true }
    try? await Task.sleep(for: .milliseconds(2))
  }
  return false
}
