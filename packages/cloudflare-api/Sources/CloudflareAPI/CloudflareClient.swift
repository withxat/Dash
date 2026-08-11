import Foundation

public enum CloudflareTransferError: Error, LocalizedError, Sendable {
  case exceedsLimit(limit: Int64, actual: Int64?)

  public var errorDescription: String? {
    switch self {
    case .exceedsLimit(let limit, let actual):
      let limitText = ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)
      if let actual {
        let actualText = ByteCountFormatter.string(fromByteCount: actual, countStyle: .file)
        return "The transfer is \(actualText), over the \(limitText) limit."
      }
      return "The transfer is over the \(limitText) limit."
    }
  }
}

private struct FileDownloadResult: @unchecked Sendable {
  let fileURL: URL?
  let response: HTTPURLResponse
}

/// One file-backed URLSession download. Foundation writes response chunks to
/// its own temporary file; the coordinator moves the finished file beside the
/// caller's destination and observes task byte counts so unknown-length bodies
/// can be cancelled as soon as a delivered chunk crosses the ceiling.
///
/// The caller uses its injected URLSession (and therefore its delegate, queue,
/// connection pool, and test protocol stack). Completion and task cancellation can race with waiter
/// registration. All completion state is lock-protected, and `completed` is
/// flipped before the single continuation is removed and resumed.
private final class FileDownloadCoordinator: @unchecked Sendable {
  private typealias DownloadContinuation = CheckedContinuation<FileDownloadResult, any Error>
  private typealias DownloadOutcome = Result<FileDownloadResult, any Error>

  private let partialURL: URL
  private let maximumBytes: Int64?
  private let lock = NSLock()
  private var storedFailure: (any Error)?
  private var truncatedErrorResponse: HTTPURLResponse?
  private var continuation: DownloadContinuation?
  private var pendingOutcome: DownloadOutcome?
  private var completionStarted = false
  private var completed = false

  init(partialURL: URL, maximumBytes: Int64?) {
    self.partialURL = partialURL
    self.maximumBytes = maximumBytes
  }

  func waitForCompletion() async throws -> FileDownloadResult {
    try await withCheckedThrowingContinuation { continuation in
      let pending = lock.withLock { () -> DownloadOutcome? in
        if let pendingOutcome {
          self.pendingOutcome = nil
          return pendingOutcome
        }
        self.continuation = continuation
        return nil
      }
      if let pending {
        continuation.resume(with: pending)
      }
    }
  }

  func observeProgress(of task: URLSessionDownloadTask) -> NSKeyValueObservation {
    task.observe(\.countOfBytesReceived, options: [.new]) { [weak self] task, _ in
      self?.didReceiveBytes(task)
    }
  }

  private func didReceiveBytes(_ task: URLSessionDownloadTask) {
    guard let response = task.response as? HTTPURLResponse else { return }
    let totalBytesWritten = task.countOfBytesReceived
    let totalBytesExpectedToWrite = task.countOfBytesExpectedToReceive
    guard (200..<300).contains(response.statusCode) else {
      let errorBodyLimit: Int64 = 1_048_576
      if totalBytesExpectedToWrite > errorBodyLimit || totalBytesWritten > errorBodyLimit {
        let shouldCancel = lock.withLock {
          guard !completionStarted, storedFailure == nil, truncatedErrorResponse == nil else {
            return false
          }
          truncatedErrorResponse = response
          return true
        }
        if shouldCancel {
          task.cancel()
        }
      }
      return
    }
    guard let maximumBytes else { return }

    let actual: Int64?
    if totalBytesExpectedToWrite > maximumBytes {
      actual = totalBytesExpectedToWrite
    } else if totalBytesWritten > maximumBytes {
      actual = totalBytesWritten
    } else {
      return
    }

    let error = CloudflareTransferError.exceedsLimit(limit: maximumBytes, actual: actual)
    if record(error) {
      task.cancel()
    }
  }

  func complete(
    location: URL?,
    response: URLResponse?,
    error: (any Error)?
  ) {
    let state = lock.withLock {
      () -> (truncated: HTTPURLResponse?, failure: (any Error)?)? in
      guard !completionStarted else { return nil }
      completionStarted = true
      return (truncatedErrorResponse, storedFailure)
    }
    guard let state else { return }

    if let response = state.truncated {
      finish(.success(FileDownloadResult(fileURL: nil, response: response)))
      return
    }
    if let storedFailure = state.failure {
      finish(.failure(storedFailure))
      return
    }
    if let error {
      finish(.failure(error))
      return
    }
    guard let response = response as? HTTPURLResponse else {
      finish(.failure(CloudflareAPIError.invalidResponse))
      return
    }
    guard let location else {
      finish(
        .failure(
          CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: partialURL.path])))
      return
    }
    do {
      try FileManager.default.moveItem(at: location, to: partialURL)
    } catch {
      finish(.failure(error))
      return
    }
    finish(.success(FileDownloadResult(fileURL: partialURL, response: response)))
  }

  @discardableResult
  private func record(_ error: any Error) -> Bool {
    lock.withLock {
      guard !completionStarted, !completed, storedFailure == nil else { return false }
      storedFailure = error
      return true
    }
  }

  private func finish(_ outcome: DownloadOutcome) {
    let continuation = lock.withLock { () -> DownloadContinuation? in
      guard !completed else { return nil }
      completed = true
      let continuation = self.continuation
      self.continuation = nil
      if continuation == nil {
        pendingOutcome = outcome
      }
      return continuation
    }
    continuation?.resume(with: outcome)
  }
}

public actor CloudflareClient {
  private let apiBase: URL
  private let clientID: String
  private let session: URLSession
  private let tokenStore: any TokenStore
  private let tokenURL: URL
  private var refreshTask: Task<TokenSet?, Error>?

  public init(
    clientID: String, tokenStore: any TokenStore, apiBase: URL = CloudflareEndpoints.api,
    session: URLSession = .shared, tokenURL: URL = CloudflareEndpoints.token
  ) {
    self.clientID = clientID
    self.tokenStore = tokenStore
    self.apiBase = apiBase
    self.session = session
    self.tokenURL = tokenURL
  }

  public func getUser() async throws -> CloudflareUser { try await request("/user") }
  public func listAccounts() async throws -> [CloudflareAccount] {
    try await listAllPages("/accounts", perPage: 50)
  }
  public func getAccount(_ id: String) async throws -> CloudflareAccount {
    try await request("/accounts/\(id)")
  }

  /// GraphQL authentication failures can arrive inside a successful HTTP 200
  /// response. Refresh and replay that case once, matching REST request behavior.
  func graphQLRaw(_ data: Data, attempt: Int = 0) async throws -> Data {
    let requestToken = try await tokenStore.getAccessToken()
    let response = try await raw(
      url: CloudflareEndpoints.graphql,
      method: "POST",
      data: data,
      contentType: "application/json")

    guard
      attempt == 0,
      let error = try? JSONDecoder().decode(GraphQLErrorEnvelope.self, from: response).errors.first,
      error.semanticStatusCode == 401
    else {
      return response
    }

    let currentToken = try await tokenStore.getAccessToken()
    let canRetry: Bool
    if currentToken != nil, currentToken != requestToken {
      canRetry = true
    } else {
      canRetry = try await refresh() != nil
    }
    guard canRetry else { return response }
    return try await graphQLRaw(data, attempt: 1)
  }

  func request<Value: Decodable & Sendable, Body: Encodable & Sendable>(
    _ path: String, method: String = "GET", query: [String: String?] = [:],
    body: Body? = Optional<String>.none
  ) async throws -> Value {
    let data = try body.map { try JSONEncoder().encode($0) }
    let response = try await raw(
      path, method: method, query: query, data: data,
      contentType: data == nil ? nil : "application/json")
    let envelope = try JSONDecoder().decode(APIEnvelope<Value>.self, from: response)
    guard envelope.success else {
      throw CloudflareAPIError.request(status: 200, errors: envelope.errors ?? [])
    }
    return envelope.result
  }

  func list<Value: Decodable & Sendable>(_ path: String, query: [String: String?] = [:])
    async throws -> Page<Value>
  {
    let data = try await raw(path, query: query)
    let envelope = try JSONDecoder().decode(APIEnvelope<[LossyElement<Value>]>.self, from: data)
    guard envelope.success else {
      throw CloudflareAPIError.request(status: 200, errors: envelope.errors ?? [])
    }
    return Page(items: envelope.result.compactMap(\.value), resultInfo: envelope.resultInfo)
  }

  /// Collects a page-number endpoint into the complete resource list expected
  /// by callers. Cloudflare's list envelopes are occasionally missing
  /// `total_count`, so a short/empty page remains the fallback terminator.
  ///
  /// Only the string identity is required because some paged payloads do not
  /// expose the display name required by `CloudflareResource`.
  func listAllPages<Value: Decodable & Sendable & Identifiable>(
    _ path: String, query: [String: String?] = [:], perPage: Int
  ) async throws -> [Value] where Value.ID == String {
    var pageNumber = 1
    var items: [Value] = []
    var seenIDs: Set<String> = []

    while true {
      var pageQuery = query
      pageQuery["page"] = String(pageNumber)
      pageQuery["per_page"] = String(perPage)
      let page: Page<Value> = try await list(path, query: pageQuery)
      let newItems = page.items.filter { seenIDs.insert($0.id).inserted }
      items.append(contentsOf: newItems)

      if let totalCount = page.resultInfo?.totalCount, items.count >= totalCount {
        break
      }
      if let totalPages = page.resultInfo?.totalPages, pageNumber >= totalPages {
        break
      }
      guard !page.items.isEmpty else { break }
      if page.resultInfo?.totalCount == nil, page.resultInfo?.totalPages == nil {
        let reportedPageSize = page.resultInfo?.perPage ?? perPage
        guard page.items.count >= reportedPageSize else { break }
      }
      guard !newItems.isEmpty else {
        throw CloudflareAPIError.invalidResponse
      }
      pageNumber += 1
    }

    return items
  }

  func raw(
    _ path: String, method: String = "GET", query: [String: String?] = [:], data: Data? = nil,
    contentType: String? = nil, rateLimitAttempt: Int = 0, refreshed: Bool = false
  ) async throws -> Data {
    return try await raw(
      url: requestURL(path: path, query: query), method: method, data: data,
      contentType: contentType, rateLimitAttempt: rateLimitAttempt, refreshed: refreshed)
  }

  func raw(
    url: URL, method: String, data: Data?, contentType: String?, rateLimitAttempt: Int = 0,
    refreshed: Bool = false
  )
    async throws -> Data
  {
    try await rawResponse(
      url: url, method: method, data: data, contentType: contentType,
      rateLimitAttempt: rateLimitAttempt, refreshed: refreshed
    ).0
  }

  static let maxAttempts = 2
  static let maxAutoRetryDelay: TimeInterval = 5

  /// Auto-retry delay for a 429. A missing or unparseable header earns one
  /// cheap retry; a server-requested wait longer than `maxAutoRetryDelay`
  /// means the caller should surface the rate limit instead of stalling.
  static func retryDelay(retryAfter header: String?) -> TimeInterval? {
    guard let header, let seconds = TimeInterval(header) else { return 1 }
    guard seconds <= maxAutoRetryDelay else { return nil }
    return max(0, seconds)
  }

  func requestURL(path: String, query: [String: String?] = [:]) -> URL {
    var components = URLComponents(
      url: apiBase.appending(path: path), resolvingAgainstBaseURL: false)!
    components.queryItems = query.compactMap { key, value in
      value.map { URLQueryItem(name: key, value: $0) }
    }
    // URLQueryItem leaves literal '+' unescaped and Cloudflare form-decodes it
    // to a space — R2 cursors and object prefixes can carry '+'. Keys are
    // fixed ASCII strings, so a blanket re-escape of the encoded query is safe.
    components.percentEncodedQuery = components.percentEncodedQuery?
      .replacingOccurrences(of: "+", with: "%2B")
    return components.url!
  }

  private func authorizedRequest(
    url: URL, method: String, contentType: String?
  ) async throws -> (request: URLRequest, token: String?) {
    var request = URLRequest(url: url)
    request.httpMethod = method
    let requestToken = try await tokenStore.getAccessToken()
    if let requestToken {
      request.setValue("Bearer \(requestToken)", forHTTPHeaderField: "Authorization")
    }
    if let contentType {
      request.setValue(contentType, forHTTPHeaderField: "Content-Type")
    }
    return (request, requestToken)
  }

  private func canRetryUnauthorized(requestToken: String?, refreshed: Bool) async throws -> Bool {
    guard !refreshed else { return false }
    let currentToken = try await tokenStore.getAccessToken()
    if currentToken != nil, currentToken != requestToken {
      return true
    }
    return try await refresh() != nil
  }

  private func validateResponse(_ response: HTTPURLResponse, body: Data) throws {
    guard (200..<300).contains(response.statusCode) else {
      let errors = (try? JSONDecoder().decode(ErrorEnvelope.self, from: body).errors) ?? []
      throw CloudflareAPIError.request(status: response.statusCode, errors: errors)
    }
  }

  func rawResponse(
    url: URL, method: String, data: Data?, contentType: String?, rateLimitAttempt: Int = 0,
    refreshed: Bool = false
  ) async throws -> (Data, HTTPURLResponse) {
    var (request, requestToken) = try await authorizedRequest(
      url: url, method: method, contentType: contentType)
    request.httpBody = data
    do {
      let (body, response) = try await session.data(for: request)
      guard let response = response as? HTTPURLResponse else {
        throw CloudflareAPIError.invalidResponse
      }
      if response.statusCode == 401 {
        if try await canRetryUnauthorized(requestToken: requestToken, refreshed: refreshed) {
          return try await rawResponse(
            url: url, method: method, data: data, contentType: contentType,
            rateLimitAttempt: rateLimitAttempt, refreshed: true)
        }
      }
      if response.statusCode == 429, rateLimitAttempt < Self.maxAttempts,
        let delay = Self.retryDelay(retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
      {
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        return try await rawResponse(
          url: url, method: method, data: data, contentType: contentType,
          rateLimitAttempt: rateLimitAttempt + 1, refreshed: refreshed)
      }
      try validateResponse(response, body: body)
      return (body, response)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch let error as CloudflareAPIError { throw error } catch {
      throw CloudflareAPIError.transport(error.localizedDescription)
    }
  }

  func uploadResponse(
    url: URL, method: String, fileURL: URL, contentType: String?, rateLimitAttempt: Int = 0,
    refreshed: Bool = false
  ) async throws -> (Data, HTTPURLResponse) {
    let (request, requestToken) = try await authorizedRequest(
      url: url, method: method, contentType: contentType)
    do {
      let (body, response) = try await session.upload(for: request, fromFile: fileURL)
      guard let response = response as? HTTPURLResponse else {
        throw CloudflareAPIError.invalidResponse
      }
      if response.statusCode == 401 {
        if try await canRetryUnauthorized(requestToken: requestToken, refreshed: refreshed) {
          return try await uploadResponse(
            url: url, method: method, fileURL: fileURL, contentType: contentType,
            rateLimitAttempt: rateLimitAttempt, refreshed: true)
        }
      }
      if response.statusCode == 429, rateLimitAttempt < Self.maxAttempts,
        let delay = Self.retryDelay(retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
      {
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        return try await uploadResponse(
          url: url, method: method, fileURL: fileURL, contentType: contentType,
          rateLimitAttempt: rateLimitAttempt + 1, refreshed: refreshed)
      }
      try validateResponse(response, body: body)
      return (body, response)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch let error as CloudflareAPIError {
      throw error
    } catch {
      throw CloudflareAPIError.transport(error.localizedDescription)
    }
  }

  func downloadResponse(
    url: URL, method: String, destination: URL, maximumBytes: Int64?,
    rateLimitAttempt: Int = 0, refreshed: Bool = false
  ) async throws -> URL {
    let (request, requestToken) = try await authorizedRequest(
      url: url, method: method, contentType: nil)
    do {
      try Task.checkCancellation()
      guard !FileManager.default.fileExists(atPath: destination.path) else {
        throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
      }
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      let partialURL = destination.deletingLastPathComponent()
        .appending(path: ".\(UUID().uuidString).download", directoryHint: .notDirectory)
      defer { try? FileManager.default.removeItem(at: partialURL) }

      let download = try await fileDownload(
        request, to: partialURL, maximumBytes: maximumBytes)
      let response = download.response
      if response.statusCode == 401 {
        if try await canRetryUnauthorized(requestToken: requestToken, refreshed: refreshed) {
          return try await downloadResponse(
            url: url, method: method, destination: destination, maximumBytes: maximumBytes,
            rateLimitAttempt: rateLimitAttempt, refreshed: true)
        }
      }
      if response.statusCode == 429, rateLimitAttempt < Self.maxAttempts,
        let delay = Self.retryDelay(retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
      {
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        return try await downloadResponse(
          url: url, method: method, destination: destination, maximumBytes: maximumBytes,
          rateLimitAttempt: rateLimitAttempt + 1, refreshed: refreshed)
      }
      if !(200..<300).contains(response.statusCode) {
        let body = try download.fileURL.map(boundedBody(from:)) ?? Data()
        try validateResponse(response, body: body)
      }
      guard let downloadedURL = download.fileURL else {
        throw CloudflareAPIError.invalidResponse
      }

      let receivedBytes = try fileSize(at: downloadedURL)
      if let maximumBytes, receivedBytes > maximumBytes {
        throw CloudflareTransferError.exceedsLimit(
          limit: maximumBytes, actual: receivedBytes)
      }

      try Task.checkCancellation()
      guard !FileManager.default.fileExists(atPath: destination.path) else {
        throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
      }
      try FileManager.default.moveItem(at: downloadedURL, to: destination)
      return destination
    } catch let error as CloudflareTransferError {
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch let error as CloudflareAPIError {
      throw error
    } catch let error as CocoaError {
      throw error
    } catch {
      throw CloudflareAPIError.transport(error.localizedDescription)
    }
  }

  private func fileDownload(
    _ request: URLRequest, to partialURL: URL, maximumBytes: Int64?
  ) async throws -> FileDownloadResult {
    let coordinator = FileDownloadCoordinator(partialURL: partialURL, maximumBytes: maximumBytes)
    let task = session.downloadTask(with: request) { location, response, error in
      coordinator.complete(location: location, response: response, error: error)
    }
    let progressObservation = coordinator.observeProgress(of: task)
    task.resume()
    defer { progressObservation.invalidate() }
    return try await withTaskCancellationHandler {
      let result = try await coordinator.waitForCompletion()
      try Task.checkCancellation()
      return result
    } onCancel: {
      task.cancel()
    }
  }

  private func boundedBody(from fileURL: URL) throws -> Data {
    let handle = try FileHandle(forReadingFrom: fileURL)
    defer { try? handle.close() }
    return try handle.read(upToCount: 1_048_576) ?? Data()
  }

  private func fileSize(at fileURL: URL) throws -> Int64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    guard let size = attributes[.size] as? NSNumber else {
      throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: fileURL.path])
    }
    return size.int64Value
  }

  private func refresh() async throws -> TokenSet? {
    if let refreshTask { return try await refreshTask.value }
    let clientID = clientID
    let session = session
    let store = tokenStore
    let tokenURL = tokenURL
    // Assign `refreshTask` with no `await` between the nil-check above and the
    // assignment below, so concurrent 401s (e.g. Watchtower's fan-out) all join
    // one refresh instead of each POSTing the rotating refresh token in
    // parallel. The keychain read moves inside the task for the same reason.
    //
    // That single-flight is per client *instance* and cannot see another
    // process. `withExclusiveRefreshAccess` is what extends it across the
    // processes that share one keychain credential; both layers stay, they
    // solve different halves of the same race.
    let task = Task<TokenSet?, Error> {
      // Snapshot before the lock. Anything different on the other side of it
      // was written by whoever we were waiting for.
      let observedAccessToken = try await store.getAccessToken()
      return try await store.withExclusiveRefreshAccess { isExclusive in
        let accessToken = try await store.getAccessToken()
        if accessToken != nil, accessToken != observedAccessToken {
          // Another process rotated while we waited. Cloudflare has already
          // consumed the refresh token we were about to spend, so POSTing it
          // would fail and cost us the credential we can see right now.
          return try await Self.currentTokens(in: store)
        }
        guard isExclusive else {
          // Another process still owns the rotating token. Proceeding without
          // the lock can consume it first, then let the lock holder clear the
          // credential after its late invalid_grant. Surface transient
          // contention so the caller can retry after the winner writes back.
          throw CloudflareAPIError.transport(
            "Token refresh is already in progress. Please retry.")
        }
        guard let refreshToken = try await store.getRefreshToken() else { return nil }
        do {
          let tokens = try await OAuth.refresh(
            clientID: clientID, refreshToken: refreshToken, session: session, tokenURL: tokenURL)
          let installed = try await store.replaceTokens(
            tokens,
            ifCurrentAccessToken: accessToken,
            refreshToken: refreshToken)
          if installed { return tokens }
          return try await Self.currentTokens(in: store)
        } catch let error as CloudflareAPIError where error.isInvalidGrant {
          // The refresh token is expired or revoked and can never be renewed.
          // The credential must still be the one we spent; a completed OAuth
          // replacement must survive a late invalid_grant from the old token.
          // Reaching this branch also proves we hold the cross-process lock:
          // the non-exclusive path fails closed before it can POST.
          guard try await store.getAccessToken() == accessToken else {
            return try await Self.currentTokens(in: store)
          }
          let cleared =
            (try? await store.clearTokens(
              ifCurrentAccessToken: accessToken,
              refreshToken: refreshToken)) == true
          return cleared ? nil : try await Self.currentTokens(in: store)
        }
      }
    }
    refreshTask = task
    defer { refreshTask = nil }
    return try await task.value
  }

  private static func currentTokens(in store: any TokenStore) async throws -> TokenSet? {
    guard let accessToken = try await store.getAccessToken() else { return nil }
    return TokenSet(
      accessToken: accessToken,
      refreshToken: try await store.getRefreshToken())
  }
}

private struct ErrorEnvelope: Decodable { let errors: [APIErrorItem] }
struct GraphQLErrorEnvelope: Decodable, Sendable {
  let errors: [GraphQLErrorItem]
}
struct GraphQLEnvelope<Value: Decodable & Sendable>: Decodable, Sendable {
  let data: Value?
  let errors: [GraphQLErrorItem]?
}
struct GraphQLErrorItem: Decodable, Sendable {
  let message: String

  var semanticStatusCode: Int {
    let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if normalized == "unauthorized" {
      return 401
    }
    if normalized.contains("not authorized") || normalized.contains("does not have access") {
      return 403
    }
    if normalized.contains("rate limiter") || normalized.contains("too many queries") {
      return 429
    }
    if normalized.contains("unable to execute query") {
      return 503
    }
    if normalized.contains("cannot request data older")
      || normalized.contains("query time range is too large")
    {
      return 400
    }
    return 200
  }
}
