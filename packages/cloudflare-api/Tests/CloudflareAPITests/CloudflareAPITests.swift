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

@Test func decodesPaginatedZoneEnvelope() throws {
  let data = Data(
    #"{"success":true,"result":[{"id":"zone","name":"example.com","status":"active"}],"result_info":{"page":1,"per_page":50,"total_count":1}}"#
      .utf8)
  let envelope = try JSONDecoder().decode(APIEnvelope<[CloudflareZone]>.self, from: data)
  #expect(envelope.result.first?.name == "example.com")
  #expect(envelope.resultInfo?.totalCount == 1)
}

@Test func decodesZonePlan() throws {
  let data = Data(
    #"{"id":"zone","name":"example.com","status":"active","plan":{"id":"p","name":"Free Website","legacy_id":"free"}}"#
      .utf8)
  let zone = try JSONDecoder().decode(CloudflareZone.self, from: data)
  #expect(zone.plan?.legacyId == "free")
  #expect(zone.plan?.name == "Free Website")
}

@Suite(.serialized)
struct NetworkTests {
  @Test func decodesZoneAnalyticsGraphQL() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { _ in
      let body = #"""
        {"data":{"viewer":{"zones":[{"httpRequests1dGroups":[
        {"dimensions":{"date":"2026-07-06"},"sum":{"requests":120,"pageViews":40,"threats":2,"bytes":98304}}
        ]}]}},"errors":null}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let days = try await client.zoneAnalytics(zoneID: "zone")
    #expect(days.count == 1)
    #expect(days.first?.requests == 120)
    #expect(days.first?.bytes == 98304)
  }
  @Test func genericResourceExtractsQueueAndRouteIdentity() throws {
    let decoder = JSONDecoder()
    let queue = try decoder.decode(
      GenericResource.self,
      from: Data(#"{"queue_id":"q1","queue_name":"jobs","producers":[]}"#.utf8))
    #expect(queue.id == "q1")
    #expect(queue.name == "jobs")

    let route = try decoder.decode(
      GenericResource.self,
      from: Data(#"{"id":"r1","pattern":"example.com/*","script":"worker"}"#.utf8))
    #expect(route.id == "r1")
    #expect(route.name == "example.com/*")
  }

  @Test func decodesImagesListEnvelope() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { _ in
      let body =
        #"{"success":true,"result":{"images":[{"id":"img","filename":"hero.png","requireSignedURLs":false}]}}"#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let images = try await client.listImages(accountID: "account")
    #expect(images.first?.filename == "hero.png")
  }

  @Test func decodesR2ResponseWrappers() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { _ in
      let body =
        #"{"success":true,"result":{"buckets":[{"name":"assets","creation_date":"2026-07-06"}]}}"#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let buckets = try await client.listR2Buckets(accountID: "account")
    #expect(buckets.map(\.name) == ["assets"])
  }

  @Test func returnsRawR2ObjectBody() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let payload = Data([0x50, 0x4B, 0x03, 0x04, 0x00])
    let session = mockSession { request in
      #expect(request.url?.path.hasSuffix("/r2/buckets/assets/objects/archive.zip") == true)
      return (200, payload)
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let data = try await client.getR2Object(
      accountID: "account", bucket: "assets", key: "archive.zip")
    #expect(data == payload)
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
}

private actor MemoryTokenStore: TokenStore {
  var access: String?
  var refresh: String?
  init(access: String?, refresh: String?) {
    self.access = access
    self.refresh = refresh
  }
  func clear() {
    access = nil
    refresh = nil
  }
  func getAccessToken() -> String? { access }
  func getRefreshToken() -> String? { refresh }
  func setTokens(_ tokens: TokenSet) {
    access = tokens.accessToken
    refresh = tokens.refreshToken
  }
}

private final class RequestRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var refreshCount: Int { lock.withLock { count } }
  func recordRefresh() { lock.withLock { count += 1 } }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?
  override class func canInit(with _: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      let (status, data) = try Self.handler?(request) ?? (500, Data())
      let response = HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() {}
}

private func mockSession(
  handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)
) -> URLSession {
  MockURLProtocol.handler = handler
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [MockURLProtocol.self]
  return URLSession(configuration: configuration)
}
