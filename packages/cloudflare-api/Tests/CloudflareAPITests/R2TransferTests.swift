import Foundation
import Testing

@testable import CloudflareAPI

extension NetworkTests {
  @Test func uploadsR2ObjectFromFile() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let payload = Data("file-backed upload".utf8)
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "cloudflare-api-upload-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appending(path: "object.txt")
    try payload.write(to: source)

    let session = mockSession { request in
      #expect(request.httpMethod == "PUT")
      #expect(request.url?.path.hasSuffix("/r2/buckets/assets/objects/folder/object.txt") == true)
      #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
      #expect(request.value(forHTTPHeaderField: "Content-Type") == "text/plain")
      #expect(requestBodyData(request) == payload)
      return (200, Data())
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    try await client.putR2Object(
      accountID: "account", bucket: "assets", key: "folder/object.txt", fileURL: source,
      contentType: "text/plain")
  }

  @Test func downloadsR2ObjectDirectlyToFile() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let payload = Data([0x50, 0x4B, 0x03, 0x04, 0x00])
    let session = mockSession { request in
      #expect(request.httpMethod == "GET")
      #expect(request.url?.path.hasSuffix("/r2/buckets/assets/objects/archive.zip") == true)
      return (200, payload)
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "cloudflare-api-download-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appending(path: "archive.zip")

    let downloaded = try await client.downloadR2Object(
      accountID: "account", bucket: "assets", key: "archive.zip", to: destination,
      maximumBytes: 1024)

    #expect(downloaded == destination)
    #expect(try Data(contentsOf: destination) == payload)
  }

  @Test func fileBackedR2DownloadUsesTheInjectedSessionDelegate() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let metrics = SessionMetricsRecorder()
    let session = mockSession(delegate: metrics) { _ in
      (200, Data("same session".utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "cloudflare-api-download-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }

    _ = try await client.downloadR2Object(
      accountID: "account", bucket: "assets", key: "delegate.txt",
      to: directory.appending(path: "delegate.txt"), maximumBytes: 1024)
    for _ in 0..<50 {
      if metrics.count > 0 { break }
      try await Task.sleep(for: .milliseconds(10))
    }

    #expect(metrics.count == 1)
  }

  @Test func rejectsUnknownLengthOversizedFileBackedR2DownloadAndCleansDestination() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let payload = Data(repeating: 0xAB, count: 16)
    let session = mockSession { _ in (200, payload) }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "cloudflare-api-download-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appending(path: "large.bin")

    do {
      _ = try await client.downloadR2Object(
        accountID: "account", bucket: "assets", key: "large.bin", to: destination,
        maximumBytes: 8)
      Issue.record("expected the transfer limit to reject the file")
    } catch let error as CloudflareTransferError {
      guard case .exceedsLimit(let limit, let actual) = error else {
        Issue.record("expected an exceeds-limit error")
        return
      }
      #expect(limit == 8)
      // MockURLProtocol delivers this response as one unknown-length chunk.
      #expect(actual == Int64(payload.count))
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    let leftovers =
      (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)) ?? []
    #expect(leftovers.isEmpty)
  }

  @Test func cancelsUnknownLengthR2DownloadBeforeTheWholeBodyArrives() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let payload = Data(repeating: 0xCD, count: 2 * 1024 * 1024)
    let delivered = ByteRecorder()
    MockURLProtocol.chunkSize = 64 * 1024
    MockURLProtocol.chunkDelay = 0.01
    MockURLProtocol.onChunk = { delivered.record($0) }
    defer {
      MockURLProtocol.chunkSize = nil
      MockURLProtocol.chunkDelay = 0
      MockURLProtocol.onChunk = nil
    }
    let session = mockSession { _ in (200, payload) }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "cloudflare-api-download-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appending(path: "large.bin")

    do {
      _ = try await client.downloadR2Object(
        accountID: "account", bucket: "assets", key: "large.bin", to: destination,
        maximumBytes: 100 * 1024)
      Issue.record("expected the transfer limit to cancel the download")
    } catch let error as CloudflareTransferError {
      guard case .exceedsLimit(let limit, let actual) = error else {
        Issue.record("expected an exceeds-limit error")
        return
      }
      #expect(limit == 100 * 1024)
      #expect((actual ?? 0) > limit)
    }

    #expect(delivered.bytes < payload.count)
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    let leftovers =
      (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)) ?? []
    #expect(leftovers.isEmpty)
  }

  @Test func cancellingFileBackedR2DownloadRemovesPartialFile() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let payload = Data(repeating: 0xAC, count: 2 * 1024 * 1024)
    let delivered = ByteRecorder()
    MockURLProtocol.chunkSize = 64 * 1024
    MockURLProtocol.chunkDelay = 0.01
    MockURLProtocol.onChunk = { delivered.record($0) }
    defer {
      MockURLProtocol.chunkSize = nil
      MockURLProtocol.chunkDelay = 0
      MockURLProtocol.onChunk = nil
    }
    let session = mockSession { _ in (200, payload) }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "cloudflare-api-download-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appending(path: "cancelled.bin")

    let download = Task {
      try await client.downloadR2Object(
        accountID: "account", bucket: "assets", key: "cancelled.bin", to: destination)
    }
    try await Task.sleep(for: .milliseconds(30))
    download.cancel()
    do {
      _ = try await download.value
      Issue.record("expected cancellation")
    } catch is CancellationError {
      // Expected.
    } catch {
      Issue.record("expected CancellationError, got \(error)")
    }

    #expect(delivered.bytes < payload.count)
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    let leftovers =
      (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)) ?? []
    #expect(leftovers.isEmpty)
  }

  @Test func fileBackedR2DownloadRetriesAfterRefreshingUnauthorizedToken() async throws {
    let store = MemoryTokenStore(access: "old", refresh: "refresh")
    let recorder = RequestRecorder()
    let payload = Data("refreshed download".utf8)
    let session = mockSession { request in
      recorder.record(request.url?.path ?? "")
      if request.url?.path == "/token" {
        return (200, Data(#"{"access_token":"new","refresh_token":"refresh"}"#.utf8))
      }
      if request.value(forHTTPHeaderField: "Authorization") == "Bearer new" {
        return (200, payload)
      }
      return (401, Data(#"{"success":false,"errors":[{"code":1000,"message":"expired"}]}"#.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session, tokenURL: URL(string: "https://auth.example.test/token")!)
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "cloudflare-api-download-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appending(path: "object.txt")

    try await client.downloadR2Object(
      accountID: "account", bucket: "assets", key: "object.txt", to: destination,
      maximumBytes: 1024)

    #expect(try Data(contentsOf: destination) == payload)
    #expect(
      recorder.paths == [
        "/accounts/account/r2/buckets/assets/objects/object.txt",
        "/token",
        "/accounts/account/r2/buckets/assets/objects/object.txt",
      ])
  }

  @Test func fileBackedR2DownloadRetriesAfterRateLimit() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let recorder = RequestRecorder()
    let payload = Data("retried download".utf8)
    MockURLProtocol.responseHeaders = ["Retry-After": "0"]
    defer { MockURLProtocol.responseHeaders = nil }
    let session = mockSession { request in
      recorder.record(request.url?.path ?? "")
      if recorder.paths.count == 1 {
        return (
          429, Data(#"{"success":false,"errors":[{"code":971,"message":"rate limited"}]}"#.utf8)
        )
      }
      return (200, payload)
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "cloudflare-api-download-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appending(path: "object.txt")

    try await client.downloadR2Object(
      accountID: "account", bucket: "assets", key: "object.txt", to: destination,
      maximumBytes: 1024)

    #expect(try Data(contentsOf: destination) == payload)
    #expect(recorder.paths.count == 2)
  }

  @Test func fileBackedR2DownloadBoundsErrorBodyAndPreservesHTTPStatus() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let payload = Data(repeating: 0xEE, count: 2 * 1024 * 1024)
    let delivered = ByteRecorder()
    MockURLProtocol.chunkSize = 64 * 1024
    MockURLProtocol.chunkDelay = 0.01
    MockURLProtocol.onChunk = { delivered.record($0) }
    defer {
      MockURLProtocol.chunkSize = nil
      MockURLProtocol.chunkDelay = 0
      MockURLProtocol.onChunk = nil
    }
    let session = mockSession { _ in (503, payload) }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "cloudflare-api-download-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }

    do {
      _ = try await client.downloadR2Object(
        accountID: "account", bucket: "assets", key: "failure.bin",
        to: directory.appending(path: "failure.bin"), maximumBytes: 8)
      Issue.record("expected the HTTP error to be preserved")
    } catch let error as CloudflareAPIError {
      guard case .request(let status, _) = error else {
        Issue.record("expected a request error")
        return
      }
      #expect(status == 503)
    }

    #expect(delivered.bytes < payload.count)
  }

  @Test func fileBackedR2DownloadPreservesExistingDestinationAndCocoaError() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let recorder = RequestRecorder()
    let session = mockSession { request in
      recorder.record(request.url?.path ?? "")
      return (200, Data("replacement".utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "cloudflare-api-download-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appending(path: "object.txt")
    let original = Data("keep me".utf8)
    try original.write(to: destination)

    do {
      _ = try await client.downloadR2Object(
        accountID: "account", bucket: "assets", key: "object.txt", to: destination,
        maximumBytes: 1024)
      Issue.record("expected an existing-destination Cocoa error")
    } catch is CocoaError {
      // Expected: local filesystem failures must not be presented as transport errors.
    } catch {
      Issue.record("expected CocoaError, got \(error)")
    }

    #expect(try Data(contentsOf: destination) == original)
    #expect(recorder.paths.isEmpty)
  }
}

private final class ByteRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var bytes: Int { lock.withLock { count } }
  func record(_ bytes: Int) { lock.withLock { count += bytes } }
}

private final class SessionMetricsRecorder: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private var recordedCount = 0
  var count: Int { lock.withLock { recordedCount } }

  func urlSession(
    _: URLSession,
    task _: URLSessionTask,
    didFinishCollecting _: URLSessionTaskMetrics
  ) {
    lock.withLock { recordedCount += 1 }
  }
}
