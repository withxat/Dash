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

@Test func generatedCatalogsCoverOfficialScopesAndOpenAPI() {
  #expect(OAuthScopeCatalog.all.count == 368)
  #expect(Set(OAuthScopeCatalog.allIDs).count == OAuthScopeCatalog.all.count)
  #expect(OAuthScopeCatalog.byID["query-cache.read"]?.name == "Hyperdrive Read")
  #expect(CloudflareEndpointCatalog.all.count == 3_243)
  #expect(CloudflareEndpointCatalog.all.contains { $0.path == "/oauth/scopes" })
  #expect(OAuthScopeCoverage.all.count == OAuthScopeCatalog.all.count)
  #expect(Set(OAuthScopeCoverage.all.map(\.scopeID)) == Set(OAuthScopeCatalog.allIDs))
  #expect(
    OAuthScopeCoverage.all
      .filter { $0.disposition == .noPublicEndpoint }
      .allSatisfy { $0.reason?.isEmpty == false }
  )
  #expect(OAuthScopeCoverage.protocolManaged.map(\.scopeID) == ["offline_access"])
  #expect(CloudflareScopes.invalid(in: CloudflareScopes.published).isEmpty)
  #expect(Set(CloudflareScopes.required).isSubset(of: Set(CloudflareScopes.published)))
  #expect(!CloudflareScopes.published.contains("ai-search.metadata_read"))
  #expect(CloudflareScopes.published.count == 359)
  #expect(CloudflareScopes.unsupportedByOAuthClient.count == 10)
  #expect(
    CloudflareScopes.unsupported(in: CloudflareScopes.all)
      == CloudflareScopes.unsupportedByOAuthClient
  )
}

@Test func authenticationAndAuthorizationErrorsAreDistinct() {
  let unauthorized = CloudflareAPIError.request(status: 401, errors: [])
  let forbidden = CloudflareAPIError.request(status: 403, errors: [])
  #expect(unauthorized.isUnauthorized)
  #expect(!unauthorized.isPermissionDenied)
  #expect(forbidden.isForbidden)
  #expect(forbidden.isPermissionDenied)
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

@Test func parsesTailRequestEventWithLogsAndExceptions() throws {
  let blob = #"""
    {"outcome":"exception","eventTimestamp":1752470000000,
     "event":{"request":{"method":"GET","url":"https://example.com/api"}},
     "logs":[{"level":"info","message":["hit",{"user":"x"},42]}],
     "exceptions":[{"name":"TypeError","message":"undefined is not a function"}]}
    """#
  let event = try #require(WorkerTailMessage.parse(Data(blob.utf8)))
  #expect(event.outcome == "exception")
  #expect(event.summary == "GET https://example.com/api — exception")
  #expect(event.timestamp == Date(timeIntervalSince1970: 1_752_470_000))
  #expect(event.lines.count == 2)
  #expect(event.lines[0] == #"[info] hit {"user":"x"} 42"#)
  #expect(event.lines[1] == "[exception] TypeError: undefined is not a function")
}

@Test func parsesTailCronAndMinimalEvents() throws {
  let cron = try #require(
    WorkerTailMessage.parse(
      Data(#"{"outcome":"ok","event":{"cron":"*/5 * * * *"}}"#.utf8)))
  #expect(cron.summary == "cron */5 * * * * — ok")
  #expect(cron.timestamp == nil)
  #expect(cron.lines.isEmpty)

  let minimal = try #require(WorkerTailMessage.parse(Data("{}".utf8)))
  #expect(minimal.summary == "event")
  #expect(minimal.outcome == nil)

  #expect(WorkerTailMessage.parse(Data("not json".utf8)) == nil)
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

  @Test func decodesRulesetListAndDetail() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      if request.url?.path == "/accounts/account/rulesets" {
        let body = #"""
          {"success":true,"result":[
          {"id":"rs1","name":"Custom rules","kind":"custom","phase":"http_request_firewall_custom"},
          {"id":"rs2","name":"Managed","kind":"managed","phase":"http_request_firewall_managed"}
          ]}
          """#
        return (200, Data(body.utf8))
      }
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
    let rulesets = try await client.listRulesets(basePath: "/accounts/account")
    #expect(rulesets.map(\.kind) == ["custom", "managed"])
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

  @Test func multipartFormEncodesGoldenBytes() {
    var form = MultipartForm(boundary: "b0")
    form.addField(name: "requireSignedURLs", value: "true")
    form.addFile(
      name: "file", filename: "photo.jpg", contentType: "image/jpeg",
      data: Data("JPEGDATA".utf8))
    let expected =
      "--b0\r\n"
      + "Content-Disposition: form-data; name=\"requireSignedURLs\"\r\n"
      + "\r\ntrue\r\n"
      + "--b0\r\n"
      + "Content-Disposition: form-data; name=\"file\"; filename=\"photo.jpg\"\r\n"
      + "Content-Type: image/jpeg\r\n"
      + "\r\nJPEGDATA\r\n"
      + "--b0--\r\n"
    #expect(form.contentType == "multipart/form-data; boundary=b0")
    #expect(form.encode() == Data(expected.utf8))
  }

  @Test func multipartDocumentParsesModuleDownload() {
    let body =
      "--sep\r\n"
      + "Content-Disposition: form-data; name=\"worker.js\"; filename=\"worker.js\"\r\n"
      + "Content-Type: application/javascript+module\r\n"
      + "\r\nexport default { fetch() {} }\r\n"
      + "--sep\r\n"
      + "Content-Disposition: form-data; name=\"lib.js\"; filename=\"lib.js\"\r\n"
      + "Content-Type: application/javascript+module\r\n"
      + "\r\nexport const x = 1\r\n"
      + "--sep--\r\n"
    let parts = MultipartDocument.parse(
      data: Data(body.utf8), contentType: "multipart/form-data; boundary=sep")
    #expect(parts.count == 2)
    #expect(parts.first?.filename == "worker.js")
    #expect(parts.first?.contentType == "application/javascript+module")
    #expect(
      String(decoding: parts.first?.body ?? Data(), as: UTF8.self)
        == "export default { fetch() {} }")
  }

  @Test func workerSourceBranchesOnResponseContentType() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.url?.path.hasSuffix("/workers/scripts/api/content/v2") == true)
      let body =
        "--sep\r\n"
        + "Content-Disposition: form-data; name=\"index.mjs\"; filename=\"index.mjs\"\r\n"
        + "Content-Type: application/javascript+module\r\n"
        + "\r\nexport default {}\r\n"
        + "--sep--\r\n"
      return (200, Data(body.utf8))
    }
    MockURLProtocol.responseHeaders = [
      "Content-Type": "multipart/form-data; boundary=sep"
    ]
    defer { MockURLProtocol.responseHeaders = nil }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let source = try await client.getWorkerSource(accountID: "account", name: "api")
    #expect(source.mainModule == "index.mjs")
    #expect(source.moduleCount == 1)
    #expect(source.content == "export default {}")
  }

  @Test func classicWorkerSourceDecodesAsPlainScript() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { _ in
      (200, Data("addEventListener('fetch', () => {})".utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let source = try await client.getWorkerSource(accountID: "account", name: "legacy")
    #expect(source.mainModule == nil)
    #expect(source.moduleCount == 0)
    #expect(source.content.hasPrefix("addEventListener"))
  }

  @Test func uploadWorkerScriptSendsMetadataAndModulePart() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.httpMethod == "PUT")
      #expect(request.url?.path.hasSuffix("/workers/scripts/api/content") == true)
      let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? ""
      #expect(contentType.hasPrefix("multipart/form-data; boundary="))
      return (200, Data(#"{"success":true,"result":{"id":"api"}}"#.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let source = WorkerSource(content: "old", mainModule: "index.mjs", moduleCount: 1)
    _ = try await client.uploadWorkerScript(
      accountID: "account", name: "api", source: source, content: "export default {}")
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

  @Test func mediaUploadsSendMultipartFilePart() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let recorder = RequestRecorder()
    let session = mockSession { request in
      recorder.record(request.url?.path ?? "")
      let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? ""
      #expect(contentType.hasPrefix("multipart/form-data; boundary="))
      if request.url?.path.hasSuffix("/images/v1") == true {
        return (200, Data(#"{"success":true,"result":{"id":"img1","filename":"a.jpg"}}"#.utf8))
      }
      return (200, Data(#"{"success":true,"result":{"uid":"vid1"}}"#.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let image = try await client.uploadImage(
      accountID: "account", filename: "a.jpg", data: Data("img".utf8))
    #expect(image.id == "img1")
    let video = try await client.uploadStreamVideo(
      accountID: "account", filename: "a.mp4", data: Data("vid".utf8))
    #expect(video.uid == "vid1")
    #expect(
      recorder.paths == ["/accounts/account/images/v1", "/accounts/account/stream"])
  }

  @Test func streamCopySendsURLAndOptionalName() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.url?.path.hasSuffix("/stream/copy") == true)
      return (200, Data(#"{"success":true,"result":{"uid":"vid2"}}"#.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let video = try await client.streamCopy(
      accountID: "account", url: "https://example.com/a.mp4", name: "A")
    #expect(video.uid == "vid2")
  }

  @Test func executeRawPassesBinaryBodiesThroughUntouched() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let payload = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])
    let session = mockSession { request in
      #expect(request.url?.path.hasSuffix("/browser-rendering/screenshot") == true)
      #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
      return (200, payload)
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let body = try JSONEncoder().encode(JSONValue.object(["url": .string("https://example.com")]))
    let data = try await client.executeRaw(
      path: "/accounts/account/browser-rendering/screenshot",
      method: "POST", data: body, contentType: "application/json")
    #expect(data == payload)
  }

  @Test func workerTagMatchesExactScriptName() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.url?.path == "/accounts/account/workers/scripts")
      let body = #"""
        {"success":true,"result":[
        {"id":"api-staging","tag":"e8f70fdbc8b1fb0b8ddb1af166186758"},
        {"id":"api","tag":"57eb1c68b8504f0baa4b5cc56cbc7d0f"}
        ]}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let tag = try await client.workerTag(accountID: "account", name: "api")
    #expect(tag == "57eb1c68b8504f0baa4b5cc56cbc7d0f")
  }

  @Test func genericResourceExtractsBuildIdentity() throws {
    let build = try JSONDecoder().decode(
      GenericResource.self,
      from: Data(
        #"{"build_uuid":"b-1","status":"stopped","branch":"main","created_at":"2026-07-09"}"#.utf8))
    #expect(build.id == "b-1")
    #expect(build.name == "main")
    #expect(build.detail == "stopped")
  }

  @Test func listResourcesUnwrapsWorkerDeployments() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { _ in
      let body = #"""
        {"success":true,"result":{"deployments":[
        {"id":"dep-1","created_on":"2026-07-09T00:00:00Z","source":"api"}
        ]}}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let page = try await client.listResources(
      path: "/accounts/account/workers/scripts/api/deployments")
    #expect(page.items.map(\.id) == ["dep-1"])
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

  @Test func workerTailLifecycleTargetsDocumentedPaths() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let recorder = RequestRecorder()
    let session = mockSession { request in
      recorder.record("\(request.httpMethod ?? "?") \(request.url?.path ?? "")")
      switch request.httpMethod {
      case "POST":
        return (
          200,
          Data(
            #"{"success":true,"result":{"id":"tail-1","url":"wss://tail.developers.workers.dev/tail-1","expires_at":"2026-07-14T13:00:00Z"}}"#
              .utf8)
        )
      case "GET":
        return (
          200,
          Data(
            #"{"success":true,"result":[{"id":"tail-1","url":"wss://tail.developers.workers.dev/tail-1"}]}"#
              .utf8)
        )
      default:
        return (200, Data(#"{"success":true,"result":{"id":"tail-1"}}"#.utf8))
      }
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let tail = try await client.startWorkerTail(accountID: "acc", scriptName: "api")
    #expect(tail.id == "tail-1")
    #expect(tail.url.hasPrefix("wss://"))
    #expect(tail.expiresAt == "2026-07-14T13:00:00Z")

    let tails = try await client.listWorkerTails(accountID: "acc", scriptName: "api")
    #expect(tails.map(\.id) == ["tail-1"])
    #expect(tails.first?.expiresAt == nil)

    try await client.deleteWorkerTail(accountID: "acc", scriptName: "api", tailID: "tail-1")
    #expect(
      recorder.paths == [
        "POST /accounts/acc/workers/scripts/api/tails",
        "GET /accounts/acc/workers/scripts/api/tails",
        "DELETE /accounts/acc/workers/scripts/api/tails/tail-1",
      ])
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
  private var recorded: [String] = []
  var refreshCount: Int { lock.withLock { count } }
  var paths: [String] { lock.withLock { recorded } }
  func recordRefresh() { lock.withLock { count += 1 } }
  func record(_ path: String) { lock.withLock { recorded.append(path) } }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?
  /// Optional response headers for the next requests (e.g. Content-Type for
  /// module-worker multipart downloads). Reset it in tests that set it.
  nonisolated(unsafe) static var responseHeaders: [String: String]?
  override class func canInit(with _: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      let (status, data) = try Self.handler?(request) ?? (500, Data())
      let response = HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: nil,
        headerFields: Self.responseHeaders)!
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
