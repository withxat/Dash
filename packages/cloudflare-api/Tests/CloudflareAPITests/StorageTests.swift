import Foundation
import Testing

@testable import CloudflareAPI

extension NetworkTests {
  @Test func getKVNamespaceTargetsTheSingleNamespace() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.url?.path == "/accounts/account/storage/kv/namespaces/ns-1")
      return (
        200,
        Data(#"{"success":true,"result":{"id":"ns-1","title":"production-config"}}"#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let namespace = try await client.getKVNamespace(accountID: "account", namespaceID: "ns-1")

    #expect(namespace.id == "ns-1")
    #expect(namespace.title == "production-config")
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

  @Test func listR2BucketsAcceptsMissingCollectionsAndSkipsNamelessRows() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let recorder = RequestRecorder()
    let session = mockSession { _ in
      recorder.record("request")
      if recorder.paths.count == 1 {
        return (
          200,
          Data(
            #"""
            {"success":true,"result":{"buckets":[
              {"creation_date":"2026-07-05"},
              {"name":"assets","creation_date":"2026-07-06"}
            ]},"result_info":{"cursor":"next"}}
            """#.utf8)
        )
      }
      return (200, Data(#"{"success":true,"result":{}}"#.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let buckets = try await client.listR2Buckets(accountID: "account")

    #expect(buckets.map(\.name) == ["assets"])
    #expect(recorder.paths.count == 2)
  }

  @Test func listR2BucketsCollectsCursorPages() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let recorder = RequestRecorder()
    let session = mockSession { request in
      let query = Dictionary(
        uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
          .queryItems ?? []).map {
            ($0.name, $0.value ?? "")
          })
      #expect(query["per_page"] == "1000")
      if let cursor = query["cursor"] {
        recorder.record(cursor)
        #expect(cursor == "opaque+cursor")
        return (
          200,
          Data(
            #"""
            {"success":true,"result":{"buckets":[
              {"name":"second","creation_date":"2026-07-07"}
            ]},"result_info":{"per_page":1000}}
            """#.utf8)
        )
      }
      recorder.record("first")
      return (
        200,
        Data(
          #"""
          {"success":true,"result":{"buckets":[
            {"name":"first","creation_date":"2026-07-06"}
          ]},"result_info":{"cursor":"opaque+cursor","per_page":1000}}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let buckets = try await client.listR2Buckets(accountID: "account")

    #expect(buckets.map(\.name) == ["first", "second"])
    #expect(recorder.paths == ["first", "opaque+cursor"])
  }

  @Test func listR2BucketsRejectsANonAdvancingCursor() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let recorder = RequestRecorder()
    let session = mockSession { request in
      let cursor =
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
        .queryItems?.first { $0.name == "cursor" }?.value
      recorder.record(cursor ?? "first")
      return (
        200,
        Data(
          #"""
          {"success":true,"result":{"buckets":[
            {"name":"assets","creation_date":"2026-07-06"}
          ]},"result_info":{"cursor":"stuck","per_page":1000}}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    do {
      _ = try await client.listR2Buckets(accountID: "account")
      Issue.record("a repeated cursor should be rejected")
    } catch let error as CloudflareAPIError {
      guard case .invalidResponse = error else {
        Issue.record("expected invalidResponse, got \(error)")
        return
      }
    }

    #expect(recorder.paths == ["first", "stuck"])
  }

  @Test func listsR2ObjectsAndVirtualFolders() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      let query = Dictionary(
        uniqueKeysWithValues:
          URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map {
            ($0.name, $0.value ?? "")
          })
      #expect(query["prefix"] == "photos/")
      #expect(query["delimiter"] == "/")
      #expect(query["per_page"] == "100")
      let body = #"""
        {"success":true,"result":[
          {"key":"photos/cover.jpg","size":1048576,"etag":"abc123",
           "last_modified":"2026-07-15T08:00:00Z","storage_class":"Standard"}
        ],"result_info":{
          "cursor":"next-page","delimited":["photos/2025/","photos/raw/"],
          "is_truncated":true,"per_page":100
        }}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let page = try await client.listR2Objects(
      accountID: "account", bucket: "assets", prefix: "photos/", delimiter: "/")

    #expect(page.objects.map(\.key) == ["photos/cover.jpg"])
    #expect(page.objects.first?.size == 1_048_576)
    #expect(page.objects.first?.etag == "abc123")
    #expect(page.objects.first?.uploaded == "2026-07-15T08:00:00Z")
    #expect(page.commonPrefixes == ["photos/2025/", "photos/raw/"])
    #expect(page.cursor == "next-page")
    #expect(page.isTruncated)
  }

  @Test func paginatesR2ObjectsWithCursor() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      let query = Dictionary(
        uniqueKeysWithValues:
          URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map {
            ($0.name, $0.value ?? "")
          })
      #expect(query["prefix"] == "logs/")
      #expect(query["delimiter"] == "/")
      if let cursor = query["cursor"] {
        #expect(cursor == "opaque-cursor")
        let body = #"""
          {"success":true,"result":[
            {"key":"logs/latest.txt","size":12,"etag":"second",
             "last_modified":"2026-07-15T09:00:00Z"}
          ],"result_info":{"is_truncated":false,"per_page":100}}
          """#
        return (200, Data(body.utf8))
      }
      let body = #"""
        {"success":true,"result":[],
         "result_info":{"cursor":"opaque-cursor","delimited":["logs/2025/"],
                        "is_truncated":true,"per_page":100}}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let first = try await client.listR2Objects(
      accountID: "account", bucket: "archive", prefix: "logs/", delimiter: "/")
    let second = try await client.listR2Objects(
      accountID: "account", bucket: "archive", cursor: first.cursor, prefix: "logs/",
      delimiter: "/")

    #expect(first.commonPrefixes == ["logs/2025/"])
    #expect(first.cursor == "opaque-cursor")
    #expect(second.objects.map(\.key) == ["logs/latest.txt"])
    #expect(second.cursor == nil)
    #expect(!second.isTruncated)
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

  @Test func decodesR2ObjectHTTPMetadataContentType() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { _ in
      let body = #"""
        {"success":true,"result":[
          {"key":"cover.jpg","size":9,"etag":"e","last_modified":"2026-07-15T08:00:00Z",
           "http_metadata":{"contentType":"image/jpeg","cacheControl":"max-age=3600"}},
          {"key":"notes.txt","size":3,"etag":"f","last_modified":"2026-07-15T08:00:00Z"}
        ],"result_info":{"is_truncated":false,"per_page":100}}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let page = try await client.listR2Objects(accountID: "account", bucket: "assets")

    #expect(page.objects.first?.contentType == "image/jpeg")
    #expect(page.objects.last?.contentType == nil)
  }

  @Test func managedR2DomainRoundTripsEnabledFlag() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.url?.path.hasSuffix("/r2/buckets/assets/domains/managed") == true)
      if request.httpMethod == "PUT" {
        let body =
          #"{"success":true,"result":{"bucketId":"b1","domain":"pub-b1.r2.dev","enabled":true}}"#
        return (200, Data(body.utf8))
      }
      let body =
        #"{"success":true,"result":{"bucketId":"b1","domain":"pub-b1.r2.dev","enabled":false}}"#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let current = try await client.getR2ManagedDomain(accountID: "account", bucket: "assets")
    let updated = try await client.setR2ManagedDomain(
      accountID: "account", bucket: "assets", enabled: true)

    #expect(current.domain == "pub-b1.r2.dev")
    #expect(!current.enabled)
    #expect(updated.enabled)
  }

  @Test func listsR2CustomDomainsWithOptionalStatusFields() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.url?.path.hasSuffix("/r2/buckets/assets/domains/custom") == true)
      let body = #"""
        {"success":true,"result":{"domains":[
          {"domain":"img.example.com","enabled":true,
           "status":{"ownership":"active","ssl":"active"},
           "minTLS":"1.2","zoneId":"z1","zoneName":"example.com"},
          {"domain":"cdn.example.net","enabled":false,
           "status":{"ownership":"pending","ssl":"initializing"}}
        ]}}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let domains = try await client.listR2CustomDomains(accountID: "account", bucket: "assets")

    #expect(domains.map(\.domain) == ["img.example.com", "cdn.example.net"])
    #expect(domains.first?.status?.ssl == "active")
    #expect(domains.first?.zoneName == "example.com")
    #expect(domains.last?.zoneName == nil)
    #expect(domains.last?.minTLS == nil)
  }

  @Test func addR2CustomDomainPostsZoneAndDecodesStatuslessResponse() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.httpMethod == "POST")
      #expect(request.url?.path.hasSuffix("/r2/buckets/assets/domains/custom") == true)
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
        #expect(decoded["domain"] == .string("img.example.com"))
        #expect(decoded["zoneId"] == .string("z1"))
        #expect(decoded["enabled"] == .bool(true))
      }
      // The create response carries no `status` — provisioning starts async.
      let body =
        #"{"success":true,"result":{"domain":"img.example.com","enabled":true,"zoneId":"z1"}}"#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let added = try await client.addR2CustomDomain(
      accountID: "account", bucket: "assets", domain: "img.example.com", zoneID: "z1")

    #expect(added.domain == "img.example.com")
    #expect(added.status == nil)
  }

  @Test func deleteR2CustomDomainTargetsDomainPath() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.httpMethod == "DELETE")
      #expect(
        request.url?.path.hasSuffix("/r2/buckets/assets/domains/custom/img.example.com") == true)
      return (200, Data(#"{"success":true,"result":{"domain":"img.example.com"}}"#.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    try await client.deleteR2CustomDomain(
      accountID: "account", bucket: "assets", domain: "img.example.com")
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
}
