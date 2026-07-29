import Foundation
import Testing

@testable import CloudflareAPI

// Shared test doubles for the whole suite.
//
// These used to be `private` inside `CloudflareAPITests.swift`, which meant a
// second test file had to mock the network again — and two `URLProtocol`
// subclasses racing the same static handler is exactly the flakiness
// `NetworkTests`' `.serialized` trait exists to prevent. Every network test in
// this target goes through this one `MockURLProtocol`, so keep new suites in
// `extension NetworkTests` rather than standing up a parallel mock.

actor MemoryTokenStore: TokenStore {
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
  func replaceTokens(
    _ tokens: TokenSet,
    ifCurrentAccessToken expectedAccessToken: String?,
    refreshToken expectedRefreshToken: String?
  ) -> Bool {
    guard access == expectedAccessToken, refresh == expectedRefreshToken else {
      return false
    }
    access = tokens.accessToken
    refresh = tokens.refreshToken
    return true
  }
  func clearTokens(
    ifCurrentAccessToken expectedAccessToken: String?,
    refreshToken expectedRefreshToken: String?
  ) -> Bool {
    guard access == expectedAccessToken, refresh == expectedRefreshToken else {
      return false
    }
    access = nil
    refresh = nil
    return true
  }
}

/// `URLProtocol` moves a request body onto `httpBodyStream`, so an assertion
/// that reads `httpBody` alone silently sees nothing and passes against an
/// empty payload. Always read a mocked request's body through this.
func requestBodyData(_ request: URLRequest) -> Data? {
  if let body = request.httpBody { return body }
  guard let stream = request.httpBodyStream else { return nil }
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

/// Convenience for the common "assert on a JSON object body" shape.
func requestBodyObject(_ request: URLRequest) -> [String: Any]? {
  guard let data = requestBodyData(request), !data.isEmpty else { return nil }
  return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

final class RequestRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  private var recorded: [String] = []
  var refreshCount: Int { lock.withLock { count } }
  var paths: [String] { lock.withLock { recorded } }
  func recordRefresh() { lock.withLock { count += 1 } }
  func record(_ path: String) { lock.withLock { recorded.append(path) } }
}

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?
  /// Optional response headers for the next requests (e.g. Content-Type for
  /// module-worker multipart downloads). Reset it in tests that set it.
  nonisolated(unsafe) static var responseHeaders: [String: String]?
  /// Optional slow chunking for cancellation tests. NetworkTests is serialized,
  /// and every test that sets these restores the defaults in a defer.
  nonisolated(unsafe) static var chunkSize: Int?
  nonisolated(unsafe) static var chunkDelay: TimeInterval = 0
  nonisolated(unsafe) static var onChunk: (@Sendable (Int) -> Void)?

  private let stateLock = NSLock()
  private var stopped = false

  override class func canInit(with _: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let chunkSize = Self.chunkSize
    let chunkDelay = Self.chunkDelay
    if chunkSize != nil {
      DispatchQueue.global(qos: .userInitiated).async {
        self.performLoading(chunkSize: chunkSize, chunkDelay: chunkDelay)
      }
    } else {
      performLoading(chunkSize: nil, chunkDelay: 0)
    }
  }

  override func stopLoading() {
    stateLock.withLock { stopped = true }
  }

  private func performLoading(chunkSize: Int?, chunkDelay: TimeInterval) {
    do {
      let (status, data) = try Self.handler?(request) ?? (500, Data())
      guard !isStopped else { return }
      let response = HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: nil,
        headerFields: Self.responseHeaders)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      if let chunkSize, chunkSize > 0 {
        var offset = 0
        while offset < data.count {
          guard !isStopped else { return }
          let end = min(offset + chunkSize, data.count)
          let chunk = data.subdata(in: offset..<end)
          client?.urlProtocol(self, didLoad: chunk)
          Self.onChunk?(chunk.count)
          offset = end
          if chunkDelay > 0 {
            Thread.sleep(forTimeInterval: chunkDelay)
          }
        }
      } else {
        client?.urlProtocol(self, didLoad: data)
      }
      guard !isStopped else { return }
      client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }

  private var isStopped: Bool {
    stateLock.withLock { stopped }
  }
}

func mockSession(
  handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)
) -> URLSession {
  MockURLProtocol.handler = handler
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [MockURLProtocol.self]
  return URLSession(configuration: configuration)
}

func mockSession(
  delegate: any URLSessionDelegate,
  handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)
) -> URLSession {
  MockURLProtocol.handler = handler
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [MockURLProtocol.self]
  return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
}
