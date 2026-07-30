import Foundation
import Testing

@testable import CloudflareAPI

@Test func r2FileObjectPathPreservesPrefixesAndDirectoryMarkers() {
  let file = R2ObjectPath(bucket: "assets", key: "photos/2026/cover.jpg")
  #expect(file.parentPrefix == "photos/2026/")
  #expect(file.name == "cover.jpg")
  #expect(!file.isDirectoryMarker)

  let folder = R2ObjectPath(bucket: "assets", key: "photos/2026/")
  #expect(folder.parentPrefix == "photos/")
  #expect(folder.name == "2026")
  #expect(folder.isDirectoryMarker)

  let rootFile = R2ObjectPath(bucket: "assets", key: "notes.txt")
  #expect(rootFile.parentPrefix.isEmpty)
  #expect(rootFile.name == "notes.txt")

  #expect(file.isFileProviderRepresentable)
  #expect(folder.isFileProviderRepresentable)
  #expect(!R2ObjectPath(bucket: "assets", key: "/photos/cover.jpg").isFileProviderRepresentable)
  #expect(!R2ObjectPath(bucket: "assets", key: "photos//cover.jpg").isFileProviderRepresentable)
  #expect(!R2ObjectPath(bucket: "assets", key: "photos//").isFileProviderRepresentable)
  #expect(!R2ObjectPath(bucket: "assets", key: "photos/../cover.jpg").isFileProviderRepresentable)
}

@Test func r2FolderMarkerResolvesNamesIntoKeyPrefixes() {
  #expect(R2FolderMarker.isMarker(key: "photos/"))
  #expect(!R2FolderMarker.isMarker(key: "photos/cover.jpg"))

  #expect(R2FolderMarker.markerKey(parentPrefix: "", name: "photos") == "photos/")
  #expect(R2FolderMarker.markerKey(parentPrefix: "photos/", name: "2026") == "photos/2026/")
  // Nesting, stray separators, and pasted whitespace all resolve to one leaf.
  #expect(R2FolderMarker.markerKey(parentPrefix: "", name: "photos/2026") == "photos/2026/")
  #expect(R2FolderMarker.markerKey(parentPrefix: "", name: "/photos/") == "photos/")
  #expect(R2FolderMarker.markerKey(parentPrefix: "", name: "  photos  ") == "photos/")
  #expect(R2FolderMarker.markerKey(parentPrefix: "a/", name: " b / c ") == "a/b/c/")
  // Nested names materialize every intermediate marker, not only the leaf —
  // otherwise a parent that exists only as a common prefix disappears when its
  // last child is deleted.
  #expect(
    R2FolderMarker.markerKeys(parentPrefix: "", name: "photos/2026") == [
      "photos/", "photos/2026/",
    ])
  #expect(
    R2FolderMarker.markerKeys(parentPrefix: "a/", name: " b / c ") == ["a/b/", "a/b/c/"])
  #expect(R2FolderMarker.markerKeys(for: "photos/2026") == ["photos/", "photos/2026/"])
  #expect(R2FolderMarker.markerKeys(for: "photos/") == ["photos/"])

  #expect(R2FolderMarker.nameProblem(parentPrefix: "", name: "photos") == nil)
  #expect(R2FolderMarker.nameProblem(parentPrefix: "", name: "") == .empty)
  #expect(R2FolderMarker.nameProblem(parentPrefix: "", name: "   ") == .empty)
  #expect(R2FolderMarker.nameProblem(parentPrefix: "", name: "///") == .empty)
  #expect(R2FolderMarker.nameProblem(parentPrefix: "", name: "a//b") == .emptyPathComponent)
  #expect(R2FolderMarker.nameProblem(parentPrefix: "", name: "a/ /b") == .emptyPathComponent)
  #expect(R2FolderMarker.nameProblem(parentPrefix: "", name: "..") == .relativePathComponent)
  #expect(R2FolderMarker.nameProblem(parentPrefix: "", name: "a/./b") == .relativePathComponent)
  // Only the edges are trimmed, so an interior control character stays visible
  // to the check instead of being silently written into a key.
  #expect(R2FolderMarker.nameProblem(parentPrefix: "", name: "a\u{0}b") == .controlCharacters)
  #expect(R2FolderMarker.nameProblem(parentPrefix: "", name: "a\nb") == .controlCharacters)
  #expect(R2FolderMarker.markerKey(parentPrefix: "", name: "a\u{0}b") == nil)

  let longName = String(repeating: "x", count: R2Limits.objectKeyMaximumBytes)
  #expect(R2FolderMarker.nameProblem(parentPrefix: "", name: longName) == .keyTooLong)
  let fittingName = String(repeating: "x", count: R2Limits.objectKeyMaximumBytes - 1)
  #expect(R2FolderMarker.markerKey(parentPrefix: "", name: fittingName)?.utf8.count == 1024)
  // Byte-counted, not character-counted: R2's ceiling is UTF-8 bytes, and the
  // marker slash spends one of them.
  let wideName = String(repeating: "书", count: R2Limits.objectKeyMaximumBytes / 3)
  #expect(R2FolderMarker.markerKey(parentPrefix: "", name: wideName)?.utf8.count == 1024)
  #expect(R2FolderMarker.nameProblem(parentPrefix: "", name: wideName + "书") == .keyTooLong)

  // Every name Dash accepts must survive the Files mount's own key rules.
  for name in ["photos", "photos/2026", "  spaced name  ", "emoji 🎈"] {
    let key = R2FolderMarker.markerKey(parentPrefix: "media/", name: name)
    #expect(key != nil)
    #expect(R2ObjectPath(bucket: "assets", key: key ?? "").isFileProviderRepresentable)
  }
}

extension NetworkTests {
  @Test func r2CreateFolderPutsZeroByteMarkerWithLiteralTrailingSlash() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let recorder = RequestRecorder()
    let session = mockSession { request in
      let body = requestBodyData(request) ?? Data()
      recorder.record(
        [
          request.httpMethod ?? "?",
          request.url?.absoluteString ?? "?",
          "bytes=\(body.count)",
          "type=\(request.value(forHTTPHeaderField: "Content-Type") ?? "none")",
        ].joined(separator: " "))
      return (200, Data(#"{"success":true,"result":null}"#.utf8))
    }
    let client = CloudflareClient(
      clientID: "client",
      tokenStore: store,
      apiBase: URL(string: "https://api.example.test")!,
      session: session)

    try await client.createR2Folder(
      accountID: "account", bucket: "assets", key: "photos/2026/")
    // A caller that forgets the marker slash still creates a folder, never a
    // zero-byte file that looks like one.
    try await client.createR2Folder(
      accountID: "account", bucket: "assets", key: "photos/2026")

    // A percent-encoded separator would create an object literally named
    // "photos/2026/" instead of the prefix, and the trailing slash IS the
    // marker: both have to reach Cloudflare exactly as written, with a real
    // zero-byte body rather than no body at all. Nested keys also put every
    // intermediate marker so each empty parent survives on its own.
    func expected(_ key: String) -> String {
      "PUT https://api.example.test/accounts/account/r2/buckets/assets/objects/\(key)? "
        + "bytes=0 type=none"
    }
    #expect(
      recorder.paths == [
        expected("photos/"), expected("photos/2026/"),
        expected("photos/"), expected("photos/2026/"),
      ])
  }

  @Test func r2FileFetchesOneBucketPageAndPreservesOpaqueCursor() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let recorder = RequestRecorder()
    let session = mockSession { request in
      let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
      let query = Dictionary(
        uniqueKeysWithValues: (components?.queryItems ?? []).map {
          ($0.name, $0.value ?? "")
        })
      #expect(query["per_page"] == "1000")
      if query["cursor"] == "next+page" {
        recorder.record("second")
        #expect(request.url?.absoluteString.contains("cursor=next%2Bpage") == true)
        return (
          200,
          Data(
            #"""
            {"success":true,"result":{"buckets":[{"name":"second"}]},"result_info":{}}
            """#.utf8)
        )
      }
      recorder.record("first")
      return (
        200,
        Data(
          #"""
          {"success":true,"result":{"buckets":[{"name":"first"}]},
           "result_info":{"cursor":"next+page","per_page":1000}}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client",
      tokenStore: store,
      apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let first = try await client.listR2BucketsPage(accountID: "account")
    let second = try await client.listR2BucketsPage(
      accountID: "account", cursor: first.cursor)

    #expect(first.items.map(\.name) == ["first"])
    #expect(first.cursor == "next+page")
    #expect(second.items.map(\.name) == ["second"])
    #expect(second.cursor == nil)
    #expect(recorder.paths == ["first", "second"])
  }

  @Test func r2FileRejectsANonAdvancingBucketPageCursor() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { _ in
      (
        200,
        Data(
          #"""
          {"success":true,"result":{"buckets":[]},"result_info":{"cursor":"stuck"}}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client",
      tokenStore: store,
      apiBase: URL(string: "https://api.example.test")!,
      session: session)

    await #expect(throws: CloudflareAPIError.self) {
      try await client.listR2BucketsPage(accountID: "account", cursor: "stuck")
    }
  }

  @Test func r2FileObjectListingPreservesStartAfterAndClampsPageSize() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
      let query = Dictionary(
        uniqueKeysWithValues: (components?.queryItems ?? []).map {
          ($0.name, $0.value ?? "")
        })
      #expect(query["start_after"] == "folder+a.txt")
      #expect(query["per_page"] == "1000")
      #expect(request.url?.absoluteString.contains("start_after=folder%2Ba.txt") == true)
      return (
        200,
        Data(#"{"success":true,"result":[],"result_info":{"is_truncated":false}}"#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client",
      tokenStore: store,
      apiBase: URL(string: "https://api.example.test")!,
      session: session)

    _ = try await client.listR2Objects(
      accountID: "account",
      bucket: "assets",
      startAfter: "folder+a.txt",
      perPage: 5000)
  }

  @Test func r2FileResolvesOnlyExactObjectMetadataMatches() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      let prefix =
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
        .queryItems?.first { $0.name == "prefix" }?.value
      let result: String
      switch prefix {
      case "photos/a.png":
        result = """
          [
            {"key":"photos/a.png.bak","size":2},
            {"key":"photos/a.png","size":1,"etag":"exact"},
            {"key":"photos/a.png/thumb","size":3}
          ]
          """
      case "missing.png":
        result = #"[{"key":"missing.png/thumb","size":3}]"#
      case "notes/":
        result = #"[{"key":"notes","size":1},{"key":"notes/","size":0,"etag":"marker"}]"#
      default:
        result = "[]"
      }
      return (
        200,
        Data(
          """
          {"success":true,"result":\(result),"result_info":{"is_truncated":false}}
          """.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client",
      tokenStore: store,
      apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let exact = try await client.getR2ObjectMetadata(
      accountID: "account", bucket: "assets", key: "photos/a.png")
    let missing = try await client.getR2ObjectMetadata(
      accountID: "account", bucket: "assets", key: "missing.png")
    let marker = try await client.getR2ObjectMetadata(
      accountID: "account", bucket: "assets", key: "notes/")

    #expect(exact?.key == "photos/a.png")
    #expect(exact?.etag == "exact")
    #expect(missing == nil)
    #expect(marker?.key == "notes/")
    #expect(marker?.etag == "marker")
  }

  @Test func r2FileBackedUploadStreamsAndReturnsMetadata() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let payload = Data("stream me".utf8)
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "r2-files-upload-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appending(path: "report.txt")
    try payload.write(to: source)

    let session = mockSession { request in
      #expect(request.httpBody == nil)
      #expect(request.httpBodyStream != nil)
      #expect(requestBodyData(request) == payload)
      return (
        200,
        Data(
          #"""
          {"success":true,"result":{"key":"reports/report.txt","size":"9","etag":"uploaded",
           "uploaded":"2026-07-29T09:00:00Z"}}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client",
      tokenStore: store,
      apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let object = try await client.putR2Object(
      accountID: "account",
      bucket: "assets",
      key: "reports/report.txt",
      fileURL: source,
      contentType: "text/plain")

    #expect(object?.key == "reports/report.txt")
    #expect(object?.size == payload.count)
    #expect(object?.etag == "uploaded")
    #expect(object?.uploaded == "2026-07-29T09:00:00Z")
    #expect(object?.contentType == "text/plain")
  }

  @Test func r2FileBackedUploadAcceptsNullMetadata() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "r2-files-upload-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appending(path: "empty.txt")
    try Data().write(to: source)
    let session = mockSession { _ in
      (200, Data(#"{"success":true,"result":null}"#.utf8))
    }
    let client = CloudflareClient(
      clientID: "client",
      tokenStore: store,
      apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let object = try await client.putR2Object(
      accountID: "account",
      bucket: "assets",
      key: "empty.txt",
      fileURL: source,
      contentType: "text/plain")

    #expect(object == nil)
  }

  @Test func r2FileKnownOversizedDownloadLeavesNoDestinationFile() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let payload = Data(repeating: 0xA5, count: 16)
    MockURLProtocol.responseHeaders = ["Content-Length": String(payload.count)]
    defer { MockURLProtocol.responseHeaders = nil }
    let session = mockSession { _ in (200, payload) }
    let client = CloudflareClient(
      clientID: "client",
      tokenStore: store,
      apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "r2-files-download-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appending(path: "too-large.bin")

    await #expect(throws: CloudflareTransferError.self) {
      try await client.downloadR2Object(
        accountID: "account",
        bucket: "assets",
        key: "too-large.bin",
        to: destination,
        maximumBytes: 8)
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
  }
}
