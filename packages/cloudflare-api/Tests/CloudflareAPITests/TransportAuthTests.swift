import CryptoKit
import Foundation
import Testing

@testable import CloudflareAPI

@Test func pkceUsesURLSafeSHA256Challenge() {
  let pair = PKCEPair.generate()
  #expect(pair.verifier.count >= 43)
  #expect(!pair.challenge.contains("+"))
  #expect(!pair.challenge.contains("/"))
  #expect(!pair.challenge.contains("="))
  let expected = Data(SHA256.hash(data: Data(pair.verifier.utf8))).base64EncodedString()
    .replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_")
    .replacingOccurrences(of: "=", with: "")
  #expect(pair.challenge == expected)
}

@Test func authorizationURLContainsRequiredOAuthParameters() throws {
  let url = OAuth.authorizationURL(
    clientID: "client", redirectURI: "https://relay.example/oauth/callback", callbackState: "state",
    pkce: PKCEPair(verifier: "verifier", challenge: "challenge"), scopes: ["zone.read"]
  )
  let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
  let values = Dictionary(
    uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
  #expect(values["client_id"] == "client")
  #expect(values["state"] == "state")
  #expect(values["code_challenge_method"] == "S256")
  #expect(values["scope"] == "zone.read")
}

@Test func authorizationURLDropsMisspelledAndOAuthUnsupportedScopes() throws {
  let misspelled = "ai-search.meatadata_read"
  let url = OAuth.authorizationURL(
    clientID: "client",
    redirectURI: "https://relay.example/oauth/callback",
    callbackState: "state",
    pkce: PKCEPair(verifier: "verifier", challenge: "challenge"),
    scopes: ["ai-search.read", misspelled, "d1.metadata_read", "d1.read"]
  )
  let values = Dictionary(
    uniqueKeysWithValues:
      URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map {
        ($0.name, $0.value ?? "")
      }
  )
  #expect(values["scope"] == "ai-search.read d1.read")
  #expect(CloudflareScopes.invalid(in: [misspelled]) == [misspelled])
  #expect(CloudflareScopes.invalid(in: CloudflareScopes.all).isEmpty)
}

@Test func generatedCatalogCoversOfficialOAuthScopes() {
  #expect(OAuthScopeCatalog.all.count == 379)
  #expect(Set(OAuthScopeCatalog.allIDs).count == OAuthScopeCatalog.all.count)
  #expect(OAuthScopeCatalog.byID["query-cache.read"]?.name == "Hyperdrive Read")
  #expect(CloudflareScopes.invalid(in: CloudflareScopes.published).isEmpty)
  #expect(Set(CloudflareScopes.required).isSubset(of: Set(CloudflareScopes.published)))
  #expect(!CloudflareScopes.published.contains("ai-search.metadata_read"))
  #expect(CloudflareScopes.published.count == 370)
  #expect(CloudflareScopes.unsupportedByOAuthClient.count == 10)
  #expect(
    CloudflareScopes.unsupported(in: CloudflareScopes.all)
      == CloudflareScopes.unsupportedByOAuthClient
  )
}

@Test func authenticationAndAuthorizationErrorsAreDistinct() {
  let unauthorized = CloudflareAPIError.request(status: 401, errors: [])
  let forbidden = CloudflareAPIError.request(status: 403, errors: [])
  let notFound = CloudflareAPIError.request(status: 404, errors: [])
  #expect(unauthorized.isUnauthorized)
  #expect(!unauthorized.isPermissionDenied)
  #expect(forbidden.isForbidden)
  #expect(forbidden.isPermissionDenied)
  #expect(notFound.isNotFound)
  #expect(!notFound.isForbidden)
  #expect(!forbidden.isNotFound)
}

@Test func transportAndRateLimitErrorsAreDistinguishable() {
  let offline = CloudflareAPIError.transport("offline")
  let rateLimited = CloudflareAPIError.request(status: 429, errors: [])
  let unauthorized = CloudflareAPIError.request(status: 401, errors: [])
  #expect(offline.isTransport)
  #expect(!offline.isRateLimited)
  #expect(rateLimited.isRateLimited)
  #expect(!rateLimited.isTransport)
  #expect(!unauthorized.isTransport)
  #expect(!unauthorized.isRateLimited)
}

@Test func retryDelayHonorsRetryAfterHeader() {
  #expect(CloudflareClient.retryDelay(retryAfter: nil) == 1)
  #expect(CloudflareClient.retryDelay(retryAfter: "not-a-number") == 1)
  #expect(CloudflareClient.retryDelay(retryAfter: "0") == 0)
  #expect(CloudflareClient.retryDelay(retryAfter: "3") == 3)
  #expect(CloudflareClient.retryDelay(retryAfter: "5") == 5)
  #expect(CloudflareClient.retryDelay(retryAfter: "6") == nil)
  #expect(CloudflareClient.retryDelay(retryAfter: "120") == nil)
  #expect(CloudflareClient.retryDelay(retryAfter: "-2") == 0)
}

extension NetworkTests {
  @Test func refreshesExpiredTokenFromGraphQLUnauthorizedEnvelope() async throws {
    let recorder = RequestRecorder()
    let store = MemoryTokenStore(access: "old", refresh: "refresh")
    let session = mockSession { request in
      if request.url?.path == "/token" {
        recorder.recordRefresh()
        return (200, Data(#"{"access_token":"new","refresh_token":"refresh"}"#.utf8))
      }
      if request.value(forHTTPHeaderField: "Authorization") == "Bearer new" {
        let body = #"""
          {"data":{"viewer":{"zones":[{"current":[
          {"dimensions":{"datetime":"2026-07-14T08:00:00Z"},"sum":{"requests":10,"pageViews":4,"threats":1,"bytes":2048}}
          ]}]}},"errors":null}
          """#
        return (200, Data(body.utf8))
      }
      return (200, Data(#"{"data":null,"errors":[{"message":"Unauthorized"}]}"#.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session, tokenURL: URL(string: "https://auth.example.test/token")!)

    let points = try await client.zoneAnalyticsHourly(zoneID: "zone")

    #expect(points.first?.pageViews == 4)
    #expect(recorder.refreshCount == 1)
  }

  @Test func concurrent401ResponsesShareOneRefresh() async throws {
    let recorder = RequestRecorder()
    let store = MemoryTokenStore(access: "old", refresh: "refresh")
    let session = mockSession { request in
      if request.url?.path == "/token" {
        recorder.recordRefresh()
        return (200, Data(#"{"access_token":"new","refresh_token":"refresh"}"#.utf8))
      }
      if request.value(forHTTPHeaderField: "Authorization") == "Bearer new" {
        return (200, Data(#"{"success":true,"result":[{"id":"account","name":"Example"}]}"#.utf8))
      }
      return (401, Data(#"{"success":false,"errors":[{"code":1000,"message":"expired"}]}"#.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session, tokenURL: URL(string: "https://auth.example.test/token")!)

    async let first = client.listAccounts()
    async let second = client.listAccounts()
    let values = try await (first, second)
    #expect(values.0.first?.name == "Example")
    #expect(values.1.first?.name == "Example")
    #expect(recorder.refreshCount == 1)
  }

  @Test func lateRefreshResponseDoesNotOverwriteReplacedCredential() async throws {
    let gate = RefreshResponseGate()
    let recorder = RequestRecorder()
    let store = MemoryTokenStore(access: "old", refresh: "old-refresh")
    let session = mockSession { request in
      if request.url?.path == "/token" {
        gate.markStartedAndWait()
        return (
          200,
          Data(#"{"access_token":"stale-refreshed","refresh_token":"stale-refresh"}"#.utf8)
        )
      }

      let authorization = request.value(forHTTPHeaderField: "Authorization") ?? "missing"
      recorder.record(authorization)
      if authorization == "Bearer replacement" {
        return (
          200,
          Data(#"{"success":true,"result":[{"id":"account","name":"Replacement"}]}"#.utf8)
        )
      }
      return (401, Data(#"{"success":false,"errors":[{"code":1000,"message":"expired"}]}"#.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session, tokenURL: URL(string: "https://auth.example.test/token")!)

    let request = Task { try await client.listAccounts() }
    await gate.waitUntilStarted()
    await store.setTokens(
      TokenSet(accessToken: "replacement", refreshToken: "replacement-refresh"))
    gate.release()

    let accounts = try await request.value
    #expect(accounts.map(\.name) == ["Replacement"])
    #expect(await store.getAccessToken() == "replacement")
    #expect(await store.getRefreshToken() == "replacement-refresh")
    #expect(recorder.paths == ["Bearer old", "Bearer replacement"])
  }

  @Test func revokedRefreshTokenSurfacesUnauthorizedAndClearsCredentials() async throws {
    let store = MemoryTokenStore(access: "old", refresh: "revoked")
    let session = mockSession { request in
      if request.url?.path == "/token" {
        return (400, Data(#"{"error":"invalid_grant"}"#.utf8))
      }
      return (401, Data(#"{"success":false,"errors":[{"code":1000,"message":"expired"}]}"#.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session, tokenURL: URL(string: "https://auth.example.test/token")!)

    do {
      _ = try await client.listAccounts()
      Issue.record("a revoked refresh token should surface as unauthorized")
    } catch let error as CloudflareAPIError {
      // invalid_grant must convert into a real 401 so AppModel's isUnauthorized
      // sign-out path fires — not an opaque .oauth error that strands the app.
      #expect(error.isUnauthorized)
    }

    let remainingRefresh = await store.getRefreshToken()
    #expect(remainingRefresh == nil)
  }

  @Test func lateInvalidGrantDoesNotClearReplacedCredential() async throws {
    let gate = RefreshResponseGate()
    let recorder = RequestRecorder()
    let store = MemoryTokenStore(access: "old", refresh: "revoked")
    let session = mockSession { request in
      if request.url?.path == "/token" {
        gate.markStartedAndWait()
        return (400, Data(#"{"error":"invalid_grant"}"#.utf8))
      }

      let authorization = request.value(forHTTPHeaderField: "Authorization") ?? "missing"
      recorder.record(authorization)
      if authorization == "Bearer replacement" {
        return (
          200,
          Data(#"{"success":true,"result":[{"id":"account","name":"Replacement"}]}"#.utf8)
        )
      }
      return (401, Data(#"{"success":false,"errors":[{"code":1000,"message":"expired"}]}"#.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session, tokenURL: URL(string: "https://auth.example.test/token")!)

    let request = Task { try await client.listAccounts() }
    await gate.waitUntilStarted()
    await store.setTokens(
      TokenSet(accessToken: "replacement", refreshToken: "replacement-refresh"))
    gate.release()

    let accounts = try await request.value
    #expect(accounts.map(\.name) == ["Replacement"])
    #expect(await store.getAccessToken() == "replacement")
    #expect(await store.getRefreshToken() == "replacement-refresh")
    #expect(recorder.paths == ["Bearer old", "Bearer replacement"])
  }

  @Test func rateLimitedRequestRetriesAfterShortWait() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let recorder = RequestRecorder()
    let session = mockSession { request in
      recorder.record(request.url?.path ?? "")
      if recorder.paths.count == 1 {
        return (
          429, Data(#"{"success":false,"errors":[{"code":971,"message":"rate limited"}]}"#.utf8)
        )
      }
      return (200, Data(#"{"success":true,"result":[{"id":"account","name":"Example"}]}"#.utf8))
    }
    MockURLProtocol.responseHeaders = ["Retry-After": "0"]
    defer { MockURLProtocol.responseHeaders = nil }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let accounts = try await client.listAccounts()
    #expect(accounts.first?.name == "Example")
    #expect(recorder.paths.count == 2)
  }

  @Test func rateLimitRetryDoesNotConsumeUnauthorizedRefresh() async throws {
    let store = MemoryTokenStore(access: "old", refresh: "refresh")
    let recorder = RequestRecorder()
    let session = mockSession { request in
      let path = request.url?.path ?? ""
      recorder.record(path)
      if path == "/token" {
        recorder.recordRefresh()
        return (200, Data(#"{"access_token":"new","refresh_token":"refresh"}"#.utf8))
      }
      let apiRequestCount = recorder.paths.filter { $0 == "/accounts" }.count
      if apiRequestCount == 1 {
        return (
          429, Data(#"{"success":false,"errors":[{"code":971,"message":"rate limited"}]}"#.utf8)
        )
      }
      if request.value(forHTTPHeaderField: "Authorization") == "Bearer old" {
        return (
          401, Data(#"{"success":false,"errors":[{"code":1000,"message":"expired"}]}"#.utf8)
        )
      }
      return (200, Data(#"{"success":true,"result":[{"id":"account","name":"Example"}]}"#.utf8))
    }
    MockURLProtocol.responseHeaders = ["Retry-After": "0"]
    defer { MockURLProtocol.responseHeaders = nil }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session, tokenURL: URL(string: "https://auth.example.test/token")!)

    let accounts = try await client.listAccounts()

    #expect(accounts.map(\.name) == ["Example"])
    #expect(recorder.refreshCount == 1)
    #expect(recorder.paths == ["/accounts", "/accounts", "/token", "/accounts"])
  }

  @Test func rateLimitedRequestSurfacesLongWaitImmediately() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let recorder = RequestRecorder()
    let session = mockSession { request in
      recorder.record(request.url?.path ?? "")
      return (
        429, Data(#"{"success":false,"errors":[{"code":971,"message":"rate limited"}]}"#.utf8)
      )
    }
    MockURLProtocol.responseHeaders = ["Retry-After": "120"]
    defer { MockURLProtocol.responseHeaders = nil }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    await #expect(throws: CloudflareAPIError.self) { try await client.listAccounts() }
    #expect(recorder.paths.count == 1)
  }

  @Test func rateLimitedRetriesAreCapped() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let recorder = RequestRecorder()
    let session = mockSession { request in
      recorder.record(request.url?.path ?? "")
      return (
        429, Data(#"{"success":false,"errors":[{"code":971,"message":"rate limited"}]}"#.utf8)
      )
    }
    MockURLProtocol.responseHeaders = ["Retry-After": "0"]
    defer { MockURLProtocol.responseHeaders = nil }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    do {
      _ = try await client.listAccounts()
      Issue.record("expected a rate-limit error")
    } catch let error as CloudflareAPIError {
      #expect(error.isRateLimited)
    }
    #expect(recorder.paths.count == CloudflareClient.maxAttempts + 1)
  }
}

private final class RefreshResponseGate: @unchecked Sendable {
  private let condition = NSCondition()
  private var started = false
  private var released = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []

  func markStartedAndWait() {
    condition.lock()
    started = true
    let waiters = startWaiters
    startWaiters.removeAll()
    condition.unlock()
    for waiter in waiters {
      waiter.resume()
    }

    condition.lock()
    while !released {
      condition.wait()
    }
    condition.unlock()
  }

  func waitUntilStarted() async {
    await withCheckedContinuation { continuation in
      condition.lock()
      if started {
        condition.unlock()
        continuation.resume()
      } else {
        startWaiters.append(continuation)
        condition.unlock()
      }
    }
  }

  func release() {
    condition.lock()
    released = true
    condition.broadcast()
    condition.unlock()
  }
}
