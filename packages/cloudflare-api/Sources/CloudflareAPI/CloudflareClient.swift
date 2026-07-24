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
    try await list("/accounts").items
  }
  public func listZones(accountID: String, page: Int = 1, perPage: Int = 50, name: String? = nil)
    async throws -> Page<CloudflareZone>
  {
    try await list(
      "/zones",
      query: [
        "account.id": accountID, "page": String(page), "per_page": String(perPage), "name": name,
      ])
  }
  public func getZone(_ id: String) async throws -> CloudflareZone {
    try await request("/zones/\(id)")
  }
  /// Adds a domain to the account. The created zone carries the assigned
  /// `nameServers`, which the caller must surface — the domain stays pending
  /// until the registrar points at them.
  public func createZone(name: String, accountID: String) async throws -> CloudflareZone {
    let body: [String: JSONValue] = [
      "name": .string(name),
      "account": .object(["id": .string(accountID)]),
    ]
    return try await request("/zones", method: "POST", body: body)
  }
  /// Asks Cloudflare to re-check the zone's name servers now instead of on the
  /// hourly sweep. Cloudflare rate-limits the trigger per zone; the 400 carries
  /// the wait message, so it surfaces unchanged.
  public func triggerZoneActivationCheck(zoneID: String) async throws {
    let _: JSONValue = try await request("/zones/\(zoneID)/activation_check", method: "PUT")
  }
  public func listDNSRecords(
    zoneID: String, page: Int = 1, perPage: Int = 100, search: String? = nil, type: String? = nil
  ) async throws -> Page<DNSRecord> {
    try await list(
      "/zones/\(zoneID)/dns_records",
      query: [
        "page": String(page),
        "per_page": String(perPage),
        "search": search.flatMap { $0.isEmpty ? nil : $0 },
        "type": type.flatMap { $0.isEmpty ? nil : $0 },
      ])
  }
  public func createDNSRecord(zoneID: String, input: DNSRecordInput) async throws -> DNSRecord {
    try await request("/zones/\(zoneID)/dns_records", method: "POST", body: input)
  }
  public func updateDNSRecord(zoneID: String, recordID: String, input: DNSRecordInput) async throws
    -> DNSRecord
  {
    try await request("/zones/\(zoneID)/dns_records/\(recordID)", method: "PUT", body: input)
  }
  public func deleteDNSRecord(zoneID: String, recordID: String) async throws {
    let _: JSONValue = try await request(
      "/zones/\(zoneID)/dns_records/\(recordID)", method: "DELETE")
  }
  public func purgeCache(zoneID: String, files: [String]? = nil) async throws {
    let body: [String: JSONValue] =
      files.map { ["files": .array($0.map(JSONValue.string))] } ?? ["purge_everything": .bool(true)]
    let _: JSONValue = try await request("/zones/\(zoneID)/purge_cache", method: "POST", body: body)
  }
  public func listZoneSettings(zoneID: String) async throws -> [ZoneSetting] {
    try await list("/zones/\(zoneID)/settings").items
  }
  public func updateZoneSetting(zoneID: String, settingID: String, value: JSONValue) async throws
    -> ZoneSetting
  {
    try await request(
      "/zones/\(zoneID)/settings/\(settingID)", method: "PATCH", body: ["value": value])
  }
  public func listWorkers(accountID: String) async throws -> [WorkerScript] {
    try await list("/accounts/\(accountID)/workers/scripts").items
  }
  public func listWorkerDeployments(accountID: String, scriptName: String) async throws
    -> [WorkerDeploymentSummary]
  {
    let result: WorkerDeploymentListResult = try await request(
      "/accounts/\(accountID)/workers/scripts/\(scriptName)/deployments")
    return result.deployments
  }

  /// Creates a whole-traffic deployment for one version (100%). Use this to
  /// roll back or promote — Dash does not expose gradual/canary splits.
  @discardableResult
  public func createWorkerDeployment(
    accountID: String, scriptName: String, versionID: String, message: String? = nil
  ) async throws -> WorkerDeploymentSummary {
    var body: [String: JSONValue] = [
      "strategy": .string("percentage"),
      "versions": .array([
        .object([
          "percentage": .number(100),
          "version_id": .string(versionID),
        ])
      ]),
    ]
    if let message {
      let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        body["annotations"] = .object(["workers/message": .string(trimmed)])
      }
    }
    return try await request(
      "/accounts/\(accountID)/workers/scripts/\(scriptName)/deployments",
      method: "POST",
      body: body)
  }

  public func listWorkerDomains(accountID: String, service: String? = nil) async throws
    -> [WorkerDomain]
  {
    try await list(
      "/accounts/\(accountID)/workers/domains",
      query: ["service": service.flatMap { $0.isEmpty ? nil : $0 }]
    ).items
  }

  /// Attaches a hostname from an existing zone so requests route to `service`.
  @discardableResult
  public func attachWorkerDomain(
    accountID: String, hostname: String, service: String, zoneID: String, zoneName: String
  ) async throws -> WorkerDomain {
    try await request(
      "/accounts/\(accountID)/workers/domains",
      method: "PUT",
      body: [
        "hostname": JSONValue.string(hostname),
        "service": .string(service),
        "zone_id": .string(zoneID),
        "zone_name": .string(zoneName),
      ])
  }

  public func detachWorkerDomain(accountID: String, domainID: String) async throws {
    let _: JSONValue = try await request(
      "/accounts/\(accountID)/workers/domains/\(domainID)", method: "DELETE")
  }

  /// Zone-scoped route patterns. Routes are the dashboard's other half of
  /// "Domains & Routes" — a worker bound only through routes has no
  /// `WorkerDomain` records at all.
  public func listWorkerRoutes(zoneID: String) async throws -> [WorkerRoute] {
    try await list("/zones/\(zoneID)/workers/routes").items
  }
  /// Downloads script content. Classic scripts come back as raw JS; module
  /// workers come back as multipart/form-data with one part per module, the
  /// boundary living in the response Content-Type header.
  public func getWorkerSource(accountID: String, name: String) async throws -> WorkerSource {
    var components = URLComponents(
      url: apiBase.appending(path: "/accounts/\(accountID)/workers/scripts/\(name)/content/v2"),
      resolvingAgainstBaseURL: false)!
    components.queryItems = nil
    let (data, response) = try await rawResponse(
      url: components.url!, method: "GET", data: nil, contentType: nil)
    let responseType = response.value(forHTTPHeaderField: "Content-Type") ?? ""
    guard responseType.lowercased().contains("multipart/") else {
      return WorkerSource(
        content: String(decoding: data, as: UTF8.self), mainModule: nil, moduleCount: 0)
    }
    let parts = MultipartDocument.parse(data: data, contentType: responseType)
    guard let main = parts.first else {
      return WorkerSource(
        content: String(decoding: data, as: UTF8.self), mainModule: nil, moduleCount: 0)
    }
    return WorkerSource(
      content: String(decoding: main.body, as: UTF8.self),
      mainModule: main.filename ?? main.name ?? "worker.js",
      moduleCount: parts.count)
  }

  /// Re-uploads script content, preserving settings and bindings. Module
  /// workers re-declare their main module; classic scripts use body_part.
  @discardableResult
  public func uploadWorkerScript(
    accountID: String, name: String, source: WorkerSource, content: String
  ) async throws -> JSONValue {
    var form = MultipartForm()
    if let mainModule = source.mainModule {
      form.addFile(
        name: "metadata", filename: "metadata.json", contentType: "application/json",
        data: try JSONEncoder().encode(["main_module": mainModule]))
      form.addFile(
        name: mainModule, filename: mainModule,
        contentType: "application/javascript+module", data: Data(content.utf8))
    } else {
      form.addFile(
        name: "metadata", filename: "metadata.json", contentType: "application/json",
        data: try JSONEncoder().encode(["body_part": "script"]))
      form.addFile(
        name: "script", filename: "script.js",
        contentType: "application/javascript", data: Data(content.utf8))
    }
    let data = try await raw(
      "/accounts/\(accountID)/workers/scripts/\(name)/content",
      method: "PUT", data: form.encode(), contentType: form.contentType)
    let envelope = try JSONDecoder().decode(APIEnvelope<JSONValue>.self, from: data)
    guard envelope.success else {
      throw CloudflareAPIError.request(status: 200, errors: envelope.errors ?? [])
    }
    return envelope.result
  }
  public func getWorkersAccountSubdomain(accountID: String) async throws
    -> WorkersAccountSubdomain
  {
    try await request("/accounts/\(accountID)/workers/subdomain")
  }

  public func getWorkerSubdomain(accountID: String, name: String) async throws
    -> WorkerSubdomainStatus
  {
    try await request("/accounts/\(accountID)/workers/scripts/\(name)/subdomain")
  }
  public func setWorkerSubdomain(accountID: String, name: String, enabled: Bool) async throws
    -> WorkerSubdomainStatus
  {
    try await request(
      "/accounts/\(accountID)/workers/scripts/\(name)/subdomain",
      method: "POST", body: ["enabled": enabled])
  }
  /// The immutable script tag (`external_script_id`) the Builds APIs key on,
  /// resolved from the documented scripts list.
  public func workerTag(accountID: String, name: String) async throws -> String? {
    try await listWorkers(accountID: accountID).first { $0.id == name }?.tag
  }
  public func listPagesProjects(accountID: String) async throws -> [PagesProject] {
    try await list("/accounts/\(accountID)/pages/projects").items
  }

  public func getPagesProject(accountID: String, projectName: String) async throws -> PagesProject {
    try await request("/accounts/\(accountID)/pages/projects/\(projectName)")
  }

  public func listPagesDeployments(
    accountID: String, projectName: String, page: Int = 1, perPage: Int = 25
  ) async throws -> Page<PagesDeployment> {
    try await list(
      "/accounts/\(accountID)/pages/projects/\(projectName)/deployments",
      query: ["page": String(page), "per_page": String(perPage)])
  }

  public func getPagesDeployment(
    accountID: String, projectName: String, deploymentID: String
  ) async throws -> PagesDeployment {
    try await request(
      "/accounts/\(accountID)/pages/projects/\(projectName)/deployments/\(deploymentID)")
  }

  public func getPagesDeploymentLogs(
    accountID: String, projectName: String, deploymentID: String
  ) async throws -> PagesDeploymentLogs {
    try await request(
      "/accounts/\(accountID)/pages/projects/\(projectName)/deployments/\(deploymentID)/history/logs"
    )
  }

  @discardableResult
  public func retryPagesDeployment(
    accountID: String, projectName: String, deploymentID: String
  ) async throws -> PagesDeployment {
    try await request(
      "/accounts/\(accountID)/pages/projects/\(projectName)/deployments/\(deploymentID)/retry",
      method: "POST")
  }

  @discardableResult
  public func rollbackPagesDeployment(
    accountID: String, projectName: String, deploymentID: String
  ) async throws -> PagesDeployment {
    try await request(
      "/accounts/\(accountID)/pages/projects/\(projectName)/deployments/\(deploymentID)/rollback",
      method: "POST")
  }

  public func listPagesDomains(accountID: String, projectName: String) async throws -> [PagesDomain]
  {
    try await list("/accounts/\(accountID)/pages/projects/\(projectName)/domains").items
  }

  @discardableResult
  public func addPagesDomain(accountID: String, projectName: String, name: String) async throws
    -> PagesDomain
  {
    try await request(
      "/accounts/\(accountID)/pages/projects/\(projectName)/domains",
      method: "POST",
      body: ["name": name])
  }

  public func deletePagesDomain(accountID: String, projectName: String, domainName: String)
    async throws
  {
    let _: JSONValue = try await request(
      "/accounts/\(accountID)/pages/projects/\(projectName)/domains/\(domainName)",
      method: "DELETE")
  }
  public func listR2Buckets(accountID: String) async throws -> [R2Bucket] {
    let result: R2BucketResult = try await request("/accounts/\(accountID)/r2/buckets")
    return result.buckets
  }
  public func createR2Bucket(accountID: String, name: String) async throws -> R2Bucket {
    try await request("/accounts/\(accountID)/r2/buckets", method: "POST", body: ["name": name])
  }
  public func deleteR2Bucket(accountID: String, name: String) async throws {
    let _: JSONValue = try await request(
      "/accounts/\(accountID)/r2/buckets/\(name)", method: "DELETE")
  }
  public func listR2Objects(
    accountID: String, bucket: String, cursor: String? = nil, prefix: String? = nil,
    delimiter: String? = nil
  ) async throws -> R2ObjectPage {
    let data = try await raw(
      "/accounts/\(accountID)/r2/buckets/\(bucket)/objects",
      query: [
        "cursor": cursor, "prefix": prefix, "delimiter": delimiter, "per_page": "100",
      ])
    let envelope = try JSONDecoder().decode(APIEnvelope<[LossyElement<R2Object>]>.self, from: data)
    guard envelope.success else {
      throw CloudflareAPIError.request(status: 200, errors: envelope.errors ?? [])
    }
    let isTruncated =
      envelope.resultInfo?.isTruncated ?? (envelope.resultInfo?.cursor?.isEmpty == false)
    return R2ObjectPage(
      objects: envelope.result.compactMap(\.value),
      commonPrefixes: envelope.resultInfo?.delimited ?? [],
      cursor: isTruncated ? envelope.resultInfo?.cursor : nil,
      isTruncated: isTruncated)
  }
  public func putR2Object(
    accountID: String, bucket: String, key: String, data: Data, contentType: String?
  ) async throws {
    let _: Data = try await raw(
      "/accounts/\(accountID)/r2/buckets/\(bucket)/objects/\(key)", method: "PUT", data: data,
      contentType: contentType)
  }

  /// File-backed upload for object bodies that should not be copied into
  /// `URLRequest.httpBody`. The response body remains bounded Cloudflare API
  /// metadata and is discarded.
  public func putR2Object(
    accountID: String, bucket: String, key: String, fileURL: URL, contentType: String?
  ) async throws {
    let url = requestURL(
      path: "/accounts/\(accountID)/r2/buckets/\(bucket)/objects/\(key)")
    _ = try await uploadResponse(
      url: url, method: "PUT", fileURL: fileURL, contentType: contentType)
  }

  public func deleteR2Object(accountID: String, bucket: String, key: String) async throws {
    let _: Data = try await raw(
      "/accounts/\(accountID)/r2/buckets/\(bucket)/objects/\(key)", method: "DELETE")
  }

  /// Raw object body — binary endpoint, no JSON envelope.
  public func getR2Object(accountID: String, bucket: String, key: String) async throws -> Data {
    try await raw("/accounts/\(accountID)/r2/buckets/\(bucket)/objects/\(key)")
  }

  /// Downloads an object directly to disk and atomically hands the temporary
  /// URL to the caller-owned destination. The destination must not already
  /// exist. A byte ceiling is enforced from response metadata when available
  /// and while streaming, before an oversized response can fill local storage.
  @discardableResult
  public func downloadR2Object(
    accountID: String, bucket: String, key: String, to destination: URL,
    maximumBytes: Int64? = nil
  ) async throws -> URL {
    let url = requestURL(
      path: "/accounts/\(accountID)/r2/buckets/\(bucket)/objects/\(key)")
    return try await downloadResponse(
      url: url, method: "GET", destination: destination, maximumBytes: maximumBytes)
  }
  public func getR2ManagedDomain(accountID: String, bucket: String) async throws -> R2ManagedDomain
  {
    try await request("/accounts/\(accountID)/r2/buckets/\(bucket)/domains/managed")
  }
  public func setR2ManagedDomain(accountID: String, bucket: String, enabled: Bool) async throws
    -> R2ManagedDomain
  {
    try await request(
      "/accounts/\(accountID)/r2/buckets/\(bucket)/domains/managed",
      method: "PUT", body: ["enabled": enabled])
  }
  public func listR2CustomDomains(accountID: String, bucket: String) async throws
    -> [R2CustomDomain]
  {
    let result: R2CustomDomainList = try await request(
      "/accounts/\(accountID)/r2/buckets/\(bucket)/domains/custom")
    return result.domains
  }
  /// Attaches a hostname from an existing zone in the same account. Cloudflare
  /// provisions DNS and the edge certificate; poll the list for `status`.
  @discardableResult
  public func addR2CustomDomain(accountID: String, bucket: String, domain: String, zoneID: String)
    async throws -> R2CustomDomain
  {
    try await request(
      "/accounts/\(accountID)/r2/buckets/\(bucket)/domains/custom",
      method: "POST",
      body: [
        "domain": JSONValue.string(domain),
        "zoneId": .string(zoneID),
        "enabled": .bool(true),
      ])
  }
  public func deleteR2CustomDomain(accountID: String, bucket: String, domain: String) async throws {
    let _: JSONValue = try await request(
      "/accounts/\(accountID)/r2/buckets/\(bucket)/domains/custom/\(domain)", method: "DELETE")
  }
  public func listKVNamespaces(accountID: String, page: Int = 1) async throws -> Page<KVNamespace> {
    try await list(
      "/accounts/\(accountID)/storage/kv/namespaces",
      query: ["page": String(page), "per_page": "100"])
  }
  public func listKVKeys(
    accountID: String, namespaceID: String, cursor: String? = nil, prefix: String? = nil
  ) async throws -> CursorPage<KVKey> {
    let page: Page<KVKey> = try await list(
      "/accounts/\(accountID)/storage/kv/namespaces/\(namespaceID)/keys",
      query: ["cursor": cursor, "prefix": prefix])
    return CursorPage(items: page.items, cursor: page.resultInfo?.cursor)
  }
  public func getKVValue(accountID: String, namespaceID: String, key: String) async throws -> Data {
    try await raw("/accounts/\(accountID)/storage/kv/namespaces/\(namespaceID)/values/\(key)")
  }
  public func putKVValue(accountID: String, namespaceID: String, key: String, data: Data)
    async throws
  {
    let _: Data = try await raw(
      "/accounts/\(accountID)/storage/kv/namespaces/\(namespaceID)/values/\(key)", method: "PUT",
      data: data, contentType: "application/octet-stream")
  }
  public func deleteKVValue(accountID: String, namespaceID: String, key: String) async throws {
    let _: Data = try await raw(
      "/accounts/\(accountID)/storage/kv/namespaces/\(namespaceID)/values/\(key)", method: "DELETE")
  }
  public func listD1Databases(accountID: String, page: Int = 1) async throws -> Page<D1Database> {
    try await list(
      "/accounts/\(accountID)/d1/database", query: ["page": String(page), "per_page": "50"])
  }
  public func queryD1(accountID: String, databaseID: String, sql: String) async throws
    -> [D1QueryResult]
  {
    try await request(
      "/accounts/\(accountID)/d1/database/\(databaseID)/query", method: "POST", body: ["sql": sql])
  }
  public func listImages(accountID: String, page: Int = 1, perPage: Int = 50) async throws
    -> [CloudflareImage]
  {
    let result: ImagesListResult = try await request(
      "/accounts/\(accountID)/images/v1",
      query: ["page": String(page), "per_page": String(perPage)])
    return result.images ?? []
  }
  /// Uploads one image through the Images v1 multipart endpoint.
  @discardableResult
  public func uploadImage(accountID: String, filename: String, data: Data) async throws
    -> CloudflareImage
  {
    var form = MultipartForm()
    form.addFile(
      name: "file", filename: filename, contentType: "application/octet-stream", data: data)
    let response = try await raw(
      "/accounts/\(accountID)/images/v1",
      method: "POST", data: form.encode(), contentType: form.contentType)
    let envelope = try JSONDecoder().decode(APIEnvelope<CloudflareImage>.self, from: response)
    guard envelope.success else {
      throw CloudflareAPIError.request(status: 200, errors: envelope.errors ?? [])
    }
    return envelope.result
  }

  /// Stream basic upload — multipart POST, documented for files under 200 MB.
  @discardableResult
  public func uploadStreamVideo(accountID: String, filename: String, data: Data) async throws
    -> StreamVideo
  {
    var form = MultipartForm()
    form.addFile(
      name: "file", filename: filename, contentType: "application/octet-stream", data: data)
    let response = try await raw(
      "/accounts/\(accountID)/stream",
      method: "POST", data: form.encode(), contentType: form.contentType)
    let envelope = try JSONDecoder().decode(APIEnvelope<StreamVideo>.self, from: response)
    guard envelope.success else {
      throw CloudflareAPIError.request(status: 200, errors: envelope.errors ?? [])
    }
    return envelope.result
  }

  /// Imports a video into Stream from a public URL.
  @discardableResult
  public func streamCopy(accountID: String, url: String, name: String?) async throws -> StreamVideo
  {
    var body: [String: JSONValue] = ["url": .string(url)]
    if let name, !name.isEmpty {
      body["meta"] = .object(["name": .string(name)])
    }
    return try await request("/accounts/\(accountID)/stream/copy", method: "POST", body: body)
  }

  public func listStreamVideos(accountID: String) async throws -> [StreamVideo] {
    try await list("/accounts/\(accountID)/stream").items
  }
  public func listAccountMembers(accountID: String, page: Int = 1, perPage: Int = 25) async throws
    -> Page<AccountMember>
  {
    try await list(
      "/accounts/\(accountID)/members",
      query: ["page": String(page), "per_page": String(perPage)])
  }
  public func listNotificationPolicies(accountID: String) async throws -> [NotificationPolicy] {
    try await list("/accounts/\(accountID)/alerting/v3/policies").items
  }
  public func createNotificationPolicy(accountID: String, input: NotificationPolicyInput)
    async throws -> NotificationPolicy
  {
    try await request(
      "/accounts/\(accountID)/alerting/v3/policies", method: "POST", body: input)
  }
  public func updateNotificationPolicy(
    accountID: String, policyID: String, input: NotificationPolicyInput
  ) async throws -> NotificationPolicy {
    try await request(
      "/accounts/\(accountID)/alerting/v3/policies/\(policyID)", method: "PUT", body: input)
  }
  public func deleteNotificationPolicy(accountID: String, policyID: String) async throws {
    let _: JSONValue = try await request(
      "/accounts/\(accountID)/alerting/v3/policies/\(policyID)", method: "DELETE")
  }
  public func listNotificationWebhooks(accountID: String) async throws -> [NotificationWebhook] {
    try await list("/accounts/\(accountID)/alerting/v3/destinations/webhooks").items
  }
  public func createNotificationWebhook(accountID: String, input: NotificationWebhookInput)
    async throws -> NotificationWebhook
  {
    try await request(
      "/accounts/\(accountID)/alerting/v3/destinations/webhooks", method: "POST", body: input)
  }
  public func updateNotificationWebhook(
    accountID: String, webhookID: String, input: NotificationWebhookInput
  ) async throws -> NotificationWebhook {
    try await request(
      "/accounts/\(accountID)/alerting/v3/destinations/webhooks/\(webhookID)", method: "PUT",
      body: input)
  }
  public func deleteNotificationWebhook(accountID: String, webhookID: String) async throws {
    let _: JSONValue = try await request(
      "/accounts/\(accountID)/alerting/v3/destinations/webhooks/\(webhookID)", method: "DELETE")
  }
  public func listAvailableAlerts(accountID: String) async throws -> [AvailableAlert] {
    let grouped: [String: [AvailableAlert]] = try await request(
      "/accounts/\(accountID)/alerting/v3/available_alerts")
    return grouped.values.flatMap { $0 }.sorted {
      ($0.displayName ?? $0.type ?? "") < ($1.displayName ?? $1.type ?? "")
    }
  }
  public func listNotificationHistory(accountID: String, perPage: Int = 10) async throws
    -> [NotificationHistoryEntry]
  {
    let data = try await raw(
      "/accounts/\(accountID)/alerting/v3/history", query: ["per_page": String(perPage)])
    let envelope = try JSONDecoder().decode(
      APIEnvelope<[NotificationHistoryEntry]?>.self, from: data)
    guard envelope.success else {
      throw CloudflareAPIError.request(status: 200, errors: envelope.errors ?? [])
    }
    return envelope.result ?? []
  }
  public func listAuditLogs(accountID: String, perPage: Int = 10) async throws -> [AuditLogEntry] {
    // Prefer Audit Logs v2; fall back to v1 when the account lacks access.
    do {
      return try await listAuditLogsV2(accountID: accountID, limit: perPage)
    } catch {
      return try await list(
        "/accounts/\(accountID)/audit_logs",
        query: ["direction": "desc", "per_page": String(perPage)]
      ).items
    }
  }

  public func listAuditLogsV2(accountID: String, limit: Int = 10) async throws -> [AuditLogEntry] {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    let since = formatter.string(from: Date().addingTimeInterval(-7 * 24 * 3600))
    let before = formatter.string(from: Date().addingTimeInterval(24 * 3600))
    let entries: [AuditLogV2Entry] = try await list(
      "/accounts/\(accountID)/logs/audit",
      query: [
        "direction": "desc",
        "limit": String(limit),
        "since": since,
        "before": before,
      ]
    ).items
    return entries.map(\.asLegacyEntry)
  }

  /// Asks Cloudflare to send a test notification for a policy.
  public func testNotificationPolicy(accountID: String, policyID: String) async throws {
    let _: JSONValue = try await request(
      "/accounts/\(accountID)/alerting/v3/policies/\(policyID)/test", method: "POST")
  }

  /// Worker invocation totals for the last `hours` via GraphQL Analytics.
  public func workerAnalytics(accountID: String, scriptName: String, hours: Int = 24)
    async throws -> WorkerAnalyticsPayload
  {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(identifier: "UTC")
    let until = Date()
    let since = until.addingTimeInterval(-TimeInterval(max(hours, 1)) * 3600)
    let escaped = scriptName.replacingOccurrences(of: "\"", with: "\\\"")
    let query = """
      { viewer { accounts(filter: {accountTag: "\(accountID)"}) { \
      workersInvocationsAdaptive(limit: 2500, orderBy: [datetimeFiveMinutes_ASC], filter: { \
      scriptName: "\(escaped)", \
      datetime_geq: "\(formatter.string(from: since))", \
      datetime_leq: "\(formatter.string(from: until))" \
      }) { sum { requests errors } quantiles { cpuTimeP50 } \
      dimensions { datetimeFiveMinutes status } } } } }
      """
    let payload = try JSONEncoder().encode(["query": query])
    let response = try await graphQLRaw(payload)
    let envelope = try JSONDecoder().decode(
      GraphQLEnvelope<WorkerAnalyticsData>.self, from: response)
    if let error = envelope.errors?.first {
      throw CloudflareAPIError.request(
        status: error.semanticStatusCode,
        errors: [APIErrorItem(code: 0, message: error.message)])
    }
    let rows = envelope.data?.viewer.accounts.first?.workersInvocationsAdaptive ?? []
    var requests = 0
    var errors = 0
    var cpuSamples: [Double] = []
    var byBucket:
      [String: (
        requests: Int, errors: Int, cpuWeighted: Double, cpuWeight: Double, cpuSum: Double,
        cpuCount: Int
      )] = [:]
    for row in rows {
      let req = row.sum.requests
      let err = row.sum.errors
      requests += req
      errors += err
      if let cpu = row.quantiles?.cpuTimeP50 { cpuSamples.append(cpu) }
      let key = row.dimensions.datetimeFiveMinutes ?? row.dimensions.datetime ?? "unknown"
      var bucket = byBucket[key] ?? (0, 0, 0, 0, 0, 0)
      bucket.requests += req
      bucket.errors += err
      if let cpu = row.quantiles?.cpuTimeP50 {
        bucket.cpuWeighted += cpu * Double(req)
        bucket.cpuWeight += Double(req)
        bucket.cpuSum += cpu
        bucket.cpuCount += 1
      }
      byBucket[key] = bucket
    }
    let points = byBucket.keys.sorted().map { key in
      let bucket = byBucket[key]!
      let cpu: Double
      if bucket.cpuWeight > 0 {
        cpu = bucket.cpuWeighted / bucket.cpuWeight
      } else if bucket.cpuCount > 0 {
        cpu = bucket.cpuSum / Double(bucket.cpuCount)
      } else {
        cpu = 0
      }
      return WorkerAnalyticsBucket(
        datetime: key, requests: bucket.requests, errors: bucket.errors, cpuTimeP50Us: cpu)
    }
    return WorkerAnalyticsPayload(
      requests: requests,
      errors: errors,
      cpuTimeP50Us: cpuSamples.isEmpty ? 0 : cpuSamples.reduce(0, +) / Double(cpuSamples.count),
      points: points
    )
  }
  public func listRumSites(accountID: String) async throws -> [RumSite] {
    try await list("/accounts/\(accountID)/rum/site_info/list").items
  }
  public func listTunnels(accountID: String, isDeleted: Bool = false) async throws
    -> [CloudflareTunnel]
  {
    try await list(
      "/accounts/\(accountID)/cfd_tunnel", query: ["is_deleted": String(isDeleted)]
    ).items
  }
  public func listLoadBalancerPools(accountID: String) async throws -> [LoadBalancerPool] {
    try await list("/accounts/\(accountID)/load_balancers/pools").items
  }
  public func listRegistrarDomains(accountID: String) async throws -> [RegistrarDomain] {
    try await list("/accounts/\(accountID)/registrar/domains").items.filter(\.hasIdentity)
  }
  public func getRegistrarRegistration(accountID: String, domainName: String) async throws
    -> RegistrarRegistration
  {
    try await request("/accounts/\(accountID)/registrar/registrations/\(domainName)")
  }
  public func listCertificatePacks(zoneID: String) async throws -> [CertificatePack] {
    try await list("/zones/\(zoneID)/ssl/certificate_packs", query: ["status": "all"]).items
  }
  public func listHealthchecks(zoneID: String) async throws -> [Healthcheck] {
    try await list("/zones/\(zoneID)/healthchecks").items
  }
  public func listResources(path: String, query: [String: String?] = [:]) async throws -> Page<
    GenericResource
  > {
    if path.contains("/workers/scripts/"), path.hasSuffix("/deployments") {
      let result: WorkerDeploymentsResult = try await request(path)
      return Page(items: result.deployments, resultInfo: nil)
    }
    return try await list(path, query: query)
  }
  public func mutate(path: String, method: String, body: [String: JSONValue]? = nil) async throws
    -> JSONValue
  {
    try await request(path, method: method, body: body)
  }

  // MARK: Rulesets — basePath is "/accounts/{id}" or "/zones/{id}" so one
  // code path serves both scopes.

  public func listRulesets(basePath: String) async throws -> [Ruleset] {
    try await request("\(basePath)/rulesets")
  }

  public func getRuleset(basePath: String, id: String) async throws -> RulesetDetail {
    try await request("\(basePath)/rulesets/\(id)")
  }

  @discardableResult
  public func addRulesetRule(
    basePath: String, rulesetID: String, body: [String: JSONValue]
  ) async throws -> RulesetDetail {
    try await request("\(basePath)/rulesets/\(rulesetID)/rules", method: "POST", body: body)
  }

  @discardableResult
  public func patchRulesetRule(
    basePath: String, rulesetID: String, ruleID: String, body: [String: JSONValue]
  ) async throws -> RulesetDetail {
    try await request(
      "\(basePath)/rulesets/\(rulesetID)/rules/\(ruleID)", method: "PATCH", body: body)
  }

  // MARK: Account members

  public func listAccountRoles(accountID: String) async throws -> [AccountRole] {
    try await list("/accounts/\(accountID)/roles", query: ["per_page": "50"]).items
  }

  @discardableResult
  public func inviteAccountMember(
    accountID: String, email: String, roleIDs: [String]
  ) async throws -> AccountMember {
    try await request(
      "/accounts/\(accountID)/members", method: "POST",
      body: [
        "email": JSONValue.string(email),
        "roles": .array(roleIDs.map(JSONValue.string)),
      ])
  }

  // MARK: Access policies

  public func listAccessApps(accountID: String) async throws -> [AccessApp] {
    try await request("/accounts/\(accountID)/access/apps")
  }

  public func listAccessPolicies(accountID: String) async throws -> [AccessPolicy] {
    try await request("/accounts/\(accountID)/access/policies")
  }

  public func listAppPolicies(accountID: String, appID: String) async throws -> [AccessPolicy] {
    try await request("/accounts/\(accountID)/access/apps/\(appID)/policies")
  }

  @discardableResult
  public func createAccessPolicy(
    accountID: String, appID: String? = nil, body: [String: JSONValue]
  ) async throws -> AccessPolicy {
    let path =
      appID.map { "/accounts/\(accountID)/access/apps/\($0)/policies" }
      ?? "/accounts/\(accountID)/access/policies"
    return try await request(path, method: "POST", body: body)
  }
  /// Daily HTTP request totals for a zone via the GraphQL Analytics API —
  /// the REST zone-analytics endpoints no longer exist.
  public func zoneAnalytics(zoneID: String, days: Int = 7) async throws -> [ZoneAnalyticsDay] {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    let until = Date()
    let since = until.addingTimeInterval(-TimeInterval(max(days - 1, 0)) * 86400)
    let query = """
      { viewer { zones(filter: {zoneTag: "\(zoneID)"}) { \
      httpRequests1dGroups(limit: \(days), \
      filter: {date_geq: "\(formatter.string(from: since))", \
      date_leq: "\(formatter.string(from: until))"}, orderBy: [date_DESC]) { \
      dimensions { date } sum { requests pageViews threats bytes cachedRequests cachedBytes } \
      uniq { uniques } } } } }
      """
    let payload = try JSONEncoder().encode(["query": query])
    let response = try await graphQLRaw(payload)
    let envelope = try JSONDecoder().decode(
      GraphQLEnvelope<ZoneAnalyticsData>.self, from: response)
    if let error = envelope.errors?.first {
      throw CloudflareAPIError.request(
        status: error.semanticStatusCode,
        errors: [APIErrorItem(code: 0, message: error.message)])
    }
    return (envelope.data?.viewer.zones.first?.httpRequests1dGroups ?? []).map {
      ZoneAnalyticsDay(
        date: $0.dimensions.date, requests: $0.sum.requests, pageViews: $0.sum.pageViews,
        threats: $0.sum.threats, bytes: $0.sum.bytes, uniques: $0.uniq?.uniques ?? 0,
        cachedRequests: $0.sum.cachedRequests ?? 0, cachedBytes: $0.sum.cachedBytes ?? 0)
    }
  }

  /// Every Web Analytics site on the account. The list is the only way to map
  /// a zone to its `siteTag`, so callers cache it per account.
  public func webAnalyticsSites(accountID: String) async throws -> [RUMSite] {
    try await request("/accounts/\(accountID)/rum/site_info/list")
  }

  /// Daily beacon-reported page loads for one RUM site, ascending. This is the
  /// Web Analytics number, not the edge's HTML-response count.
  public func webAnalyticsPageviews(siteTag: String, days: Int = 7) async throws
    -> [RUMPageviewsDay]
  {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(identifier: "UTC")
    let until = Date()
    let since = until.addingTimeInterval(-TimeInterval(max(days - 1, 0)) * 86400)
    let query = """
      { viewer { accounts { \
      rumPageloadEventsAdaptiveGroups(limit: \(max(days, 1)), \
      filter: {siteTag: "\(siteTag)", \
      datetime_geq: "\(formatter.string(from: since))", \
      datetime_leq: "\(formatter.string(from: until))"}, orderBy: [date_ASC]) { \
      count dimensions { date } } } } }
      """
    let response = try await graphQL(query: query)
    let envelope = try JSONDecoder().decode(
      GraphQLEnvelope<RUMPageviewsData>.self, from: response)
    if let error = envelope.errors?.first {
      throw CloudflareAPIError.request(
        status: error.semanticStatusCode,
        errors: [APIErrorItem(code: 0, message: error.message)])
    }
    return (envelope.data?.viewer.accounts.first?.rumPageloadEventsAdaptiveGroups ?? []).map {
      RUMPageviewsDay(date: $0.dimensions.date, pageviews: $0.count)
    }
  }

  /// Daily Web Analytics metrics for one RUM site — page views, visits, and the
  /// median page-load time (ms) — the three figures the Web Analytics dashboard
  /// shows. Page views and visits come from `rumPageloadEventsAdaptiveGroups`;
  /// page-load time lives on the separate `rumPerformanceEventsAdaptiveGroups`
  /// dataset (only it carries the timing quantiles), joined here by date.
  ///
  /// Both datasets are account-scoped, so the account is selected by `accountTag`
  /// and the site by `siteTag`. The window is `days * 2` so callers can split it
  /// into the current window and the immediately preceding one for a
  /// period-over-period comparison. Ascending by date.
  public func webAnalyticsMetrics(accountID: String, siteTag: String, days: Int = 7) async throws
    -> [RUMDailyMetrics]
  {
    let window = max(days, 1)
    let span = window * 2
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(identifier: "UTC")
    let until = Date()
    let since = until.addingTimeInterval(-TimeInterval(span - 1) * 86400)
    let filter =
      "{siteTag: \"\(siteTag)\", "
      + "datetime_geq: \"\(formatter.string(from: since))\", "
      + "datetime_leq: \"\(formatter.string(from: until))\"}"
    let query = """
      { viewer { accounts(filter: {accountTag: "\(accountID)"}) { \
      pageload: rumPageloadEventsAdaptiveGroups(limit: \(span), \
      filter: \(filter), orderBy: [date_ASC]) { \
      count sum { visits } dimensions { date } } \
      performance: rumPerformanceEventsAdaptiveGroups(limit: \(span), \
      filter: \(filter), orderBy: [date_ASC]) { \
      quantiles { pageLoadTimeP50 } dimensions { date } } } } }
      """
    let response = try await graphQL(query: query)
    let envelope = try JSONDecoder().decode(
      GraphQLEnvelope<RUMMetricsData>.self, from: response)
    if let error = envelope.errors?.first {
      throw CloudflareAPIError.request(
        status: error.semanticStatusCode,
        errors: [APIErrorItem(code: 0, message: error.message)])
    }
    guard let account = envelope.data?.viewer.accounts.first else { return [] }
    var p50ByDate: [String: Int] = [:]
    for group in account.performance {
      if let p50 = group.quantiles.pageLoadTimeP50 {
        p50ByDate[group.dimensions.date] = Int(p50.rounded())
      }
    }
    return account.pageload.map { group in
      RUMDailyMetrics(
        date: group.dimensions.date,
        pageviews: group.count,
        visits: group.sum.visits,
        pageLoadTimeP50Ms: p50ByDate[group.dimensions.date])
    }
  }

  /// Hourly HTTP request totals via the GraphQL `httpRequests1hGroups`
  /// dataset. Returned ascending so charts can plot it directly.
  public func zoneAnalyticsHourly(zoneID: String, hours: Int = 24) async throws
    -> [ZoneAnalyticsPoint]
  {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(identifier: "UTC")
    let until = Date()
    let since = until.addingTimeInterval(-TimeInterval(max(hours, 1)) * 3600)
    let query = """
      { viewer { zones(filter: {zoneTag: "\(zoneID)"}) { \
      httpRequests1hGroups(limit: \(hours + 1), \
      filter: {datetime_geq: "\(formatter.string(from: since))", \
      datetime_leq: "\(formatter.string(from: until))"}, orderBy: [datetime_ASC]) { \
      dimensions { datetime } sum { requests pageViews threats bytes cachedRequests cachedBytes } \
      uniq { uniques } } } } }
      """
    let payload = try JSONEncoder().encode(["query": query])
    let response = try await graphQLRaw(payload)
    let envelope = try JSONDecoder().decode(
      GraphQLEnvelope<ZoneAnalyticsHourlyData>.self, from: response)
    if let error = envelope.errors?.first {
      throw CloudflareAPIError.request(
        status: error.semanticStatusCode,
        errors: [APIErrorItem(code: 0, message: error.message)])
    }
    return (envelope.data?.viewer.zones.first?.httpRequests1hGroups ?? []).map {
      ZoneAnalyticsPoint(
        datetime: $0.dimensions.datetime, requests: $0.sum.requests, pageViews: $0.sum.pageViews,
        threats: $0.sum.threats, bytes: $0.sum.bytes, uniques: $0.uniq?.uniques ?? 0,
        cachedRequests: $0.sum.cachedRequests ?? 0, cachedBytes: $0.sum.cachedBytes ?? 0)
    }
  }

  /// Blocked firewall events for the last `hours`, grouped by country and rule.
  /// Uses `firewallEventsAdaptiveGroups` — requires `analytics.read`.
  public func firewallEventsSummary(zoneID: String, hours: Int = 24) async throws
    -> FirewallEventsSummary
  {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(identifier: "UTC")
    let until = Date()
    let since = until.addingTimeInterval(-TimeInterval(max(hours, 1)) * 3600)
    let sinceText = formatter.string(from: since)
    let untilText = formatter.string(from: until)
    let query = """
      { viewer { zones(filter: {zoneTag: "\(zoneID)"}) { \
      blocked: firewallEventsAdaptiveGroups(limit: 1, \
      filter: {datetime_geq: "\(sinceText)", datetime_leq: "\(untilText)", action: "block"}) { count } \
      byCountry: firewallEventsAdaptiveGroups(limit: 8, \
      filter: {datetime_geq: "\(sinceText)", datetime_leq: "\(untilText)", action: "block"}, \
      orderBy: [count_DESC]) { count dimensions { clientCountryName } } \
      byRule: firewallEventsAdaptiveGroups(limit: 8, \
      filter: {datetime_geq: "\(sinceText)", datetime_leq: "\(untilText)", action: "block"}, \
      orderBy: [count_DESC]) { count dimensions { ruleId } } } } }
      """
    let payload = try JSONEncoder().encode(["query": query])
    let response = try await graphQLRaw(payload)
    let envelope = try JSONDecoder().decode(
      GraphQLEnvelope<FirewallEventsData>.self, from: response)
    if let error = envelope.errors?.first {
      throw CloudflareAPIError.request(
        status: error.semanticStatusCode,
        errors: [APIErrorItem(code: 0, message: error.message)])
    }
    let zone = envelope.data?.viewer.zones.first
    let blocked = zone?.blocked.first?.count ?? 0
    let countries =
      (zone?.byCountry ?? []).compactMap { row -> FirewallEventsBucket? in
        guard let label = row.dimensions.clientCountryName, !label.isEmpty else { return nil }
        return FirewallEventsBucket(label: label, count: row.count)
      }
    let rules =
      (zone?.byRule ?? []).compactMap { row -> FirewallEventsBucket? in
        guard let label = row.dimensions.ruleId, !label.isEmpty else { return nil }
        return FirewallEventsBucket(label: label, count: row.count)
      }
    return FirewallEventsSummary(
      hours: hours, blocked: blocked, countries: countries, rules: rules)
  }

  /// Hourly request counts from the adaptive HTTP Traffic dataset available to
  /// every plan. Paid-only metrics such as page views are intentionally omitted.
  public func zoneRequestsHourly(zoneID: String, hours: Int = 24) async throws
    -> [ZoneAnalyticsPoint]
  {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(identifier: "UTC")
    let until = Date()
    let since = until.addingTimeInterval(-TimeInterval(max(hours, 1)) * 3600)
    let query = """
      { viewer { zones(filter: {zoneTag: "\(zoneID)"}) { \
      httpRequestsAdaptiveGroups(limit: \(hours + 1), \
      filter: {datetime_geq: "\(formatter.string(from: since))", \
      datetime_leq: "\(formatter.string(from: until))", requestSource: "eyeball"}, \
      orderBy: [datetimeHour_ASC]) { count dimensions { datetimeHour } } } } }
      """
    let payload = try JSONEncoder().encode(["query": query])
    let response = try await graphQLRaw(payload)
    let envelope = try JSONDecoder().decode(
      GraphQLEnvelope<ZoneRequestsHourlyData>.self, from: response)
    if let error = envelope.errors?.first {
      throw CloudflareAPIError.request(
        status: error.semanticStatusCode,
        errors: [APIErrorItem(code: 0, message: error.message)])
    }
    return (envelope.data?.viewer.zones.first?.httpRequestsAdaptiveGroups ?? []).map {
      ZoneAnalyticsPoint(
        datetime: $0.dimensions.datetimeHour,
        requests: $0.count,
        pageViews: 0,
        threats: 0,
        bytes: 0)
    }
  }

  public func graphQL(query: String, variables: [String: JSONValue]) async throws -> JSONValue {
    let data = try JSONEncoder().encode([
      "query": JSONValue.string(query), "variables": .object(variables),
    ])
    let response = try await graphQLRaw(data)
    return try JSONDecoder().decode(JSONValue.self, from: response)
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

  /// Runs a raw GraphQL document and returns the undecoded body. Every typed
  /// analytics call funnels through the same path, so probes and one-off
  /// queries inherit Bearer auth and the single 401 retry.
  public func graphQL(query: String) async throws -> Data {
    try await graphQLRaw(try JSONEncoder().encode(["query": query]))
  }

  public func execute(
    path: String,
    method: String,
    query: [String: String?] = [:],
    body: JSONValue? = nil
  ) async throws -> JSONValue {
    let data = try body.map { try JSONEncoder().encode($0) }
    let response = try await raw(
      path,
      method: method,
      query: query,
      data: data,
      contentType: data == nil ? nil : "application/json"
    )
    guard !response.isEmpty else { return .null }
    do {
      return try JSONDecoder().decode(JSONValue.self, from: response)
    } catch {
      return .string(String(data: response, encoding: .utf8) ?? response.base64EncodedString())
    }
  }

  public func executeRaw(
    path: String,
    method: String,
    query: [String: String?] = [:],
    data: Data? = nil,
    contentType: String? = nil
  ) async throws -> Data {
    try await raw(
      path,
      method: method,
      query: query,
      data: data,
      contentType: contentType
    )
  }

  private func request<Value: Decodable & Sendable, Body: Encodable & Sendable>(
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

  private func list<Value: Decodable & Sendable>(_ path: String, query: [String: String?] = [:])
    async throws -> Page<Value>
  {
    let data = try await raw(path, query: query)
    let envelope = try JSONDecoder().decode(APIEnvelope<[LossyElement<Value>]>.self, from: data)
    guard envelope.success else {
      throw CloudflareAPIError.request(status: 200, errors: envelope.errors ?? [])
    }
    return Page(items: envelope.result.compactMap(\.value), resultInfo: envelope.resultInfo)
  }

  private func raw(
    _ path: String, method: String = "GET", query: [String: String?] = [:], data: Data? = nil,
    contentType: String? = nil, attempt: Int = 0
  ) async throws -> Data {
    return try await raw(
      url: requestURL(path: path, query: query), method: method, data: data,
      contentType: contentType, attempt: attempt)
  }

  private func raw(url: URL, method: String, data: Data?, contentType: String?, attempt: Int = 0)
    async throws -> Data
  {
    try await rawResponse(
      url: url, method: method, data: data, contentType: contentType, attempt: attempt
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

  private func requestURL(path: String, query: [String: String?] = [:]) -> URL {
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

  private func canRetryUnauthorized(requestToken: String?, attempt: Int) async throws -> Bool {
    guard attempt == 0 else { return false }
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

  private func rawResponse(
    url: URL, method: String, data: Data?, contentType: String?, attempt: Int = 0
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
        if try await canRetryUnauthorized(requestToken: requestToken, attempt: attempt) {
          return try await rawResponse(
            url: url, method: method, data: data, contentType: contentType, attempt: 1)
        }
      }
      if response.statusCode == 429, attempt < Self.maxAttempts,
        let delay = Self.retryDelay(retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
      {
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        return try await rawResponse(
          url: url, method: method, data: data, contentType: contentType, attempt: attempt + 1)
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

  private func uploadResponse(
    url: URL, method: String, fileURL: URL, contentType: String?, attempt: Int = 0
  ) async throws -> (Data, HTTPURLResponse) {
    let (request, requestToken) = try await authorizedRequest(
      url: url, method: method, contentType: contentType)
    do {
      let (body, response) = try await session.upload(for: request, fromFile: fileURL)
      guard let response = response as? HTTPURLResponse else {
        throw CloudflareAPIError.invalidResponse
      }
      if response.statusCode == 401 {
        if try await canRetryUnauthorized(requestToken: requestToken, attempt: attempt) {
          return try await uploadResponse(
            url: url, method: method, fileURL: fileURL, contentType: contentType, attempt: 1)
        }
      }
      if response.statusCode == 429, attempt < Self.maxAttempts,
        let delay = Self.retryDelay(retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
      {
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        return try await uploadResponse(
          url: url, method: method, fileURL: fileURL, contentType: contentType,
          attempt: attempt + 1)
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

  private func downloadResponse(
    url: URL, method: String, destination: URL, maximumBytes: Int64?, attempt: Int = 0
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
        if try await canRetryUnauthorized(requestToken: requestToken, attempt: attempt) {
          return try await downloadResponse(
            url: url, method: method, destination: destination, maximumBytes: maximumBytes,
            attempt: 1)
        }
      }
      if response.statusCode == 429, attempt < Self.maxAttempts,
        let delay = Self.retryDelay(retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
      {
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        return try await downloadResponse(
          url: url, method: method, destination: destination, maximumBytes: maximumBytes,
          attempt: attempt + 1)
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
    let task = Task<TokenSet?, Error> {
      guard let refreshToken = try await store.getRefreshToken() else { return nil }
      do {
        let tokens = try await OAuth.refresh(
          clientID: clientID, refreshToken: refreshToken, session: session, tokenURL: tokenURL)
        try await store.setTokens(tokens)
        return tokens
      } catch let error as CloudflareAPIError where error.isInvalidGrant {
        // The refresh token is expired or revoked and can never be renewed.
        // Drop the dead credentials and report failure so the caller's 401
        // surfaces to the existing sign-out path instead of retrying forever.
        try? await store.clear()
        return nil
      }
    }
    refreshTask = task
    defer { refreshTask = nil }
    return try await task.value
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
private struct ZoneAnalyticsData: Decodable, Sendable {
  let viewer: Viewer

  struct Viewer: Decodable, Sendable { let zones: [Zone] }
  struct Zone: Decodable, Sendable { let httpRequests1dGroups: [Group] }
  struct Group: Decodable, Sendable {
    let dimensions: Dimensions
    let sum: Sum
    // Optional so a response without the uniq block still decodes.
    let uniq: Uniq?

    struct Dimensions: Decodable, Sendable { let date: String }
    struct Sum: Decodable, Sendable {
      let requests: Int
      let pageViews: Int
      let threats: Int
      let bytes: Int64
      let cachedRequests: Int?
      let cachedBytes: Int64?
    }
    struct Uniq: Decodable, Sendable { let uniques: Int }
  }
}
private struct RUMPageviewsData: Decodable, Sendable {
  let viewer: Viewer

  struct Viewer: Decodable, Sendable { let accounts: [Account] }
  struct Account: Decodable, Sendable { let rumPageloadEventsAdaptiveGroups: [Group] }
  struct Group: Decodable, Sendable {
    let count: Int
    let dimensions: Dimensions

    struct Dimensions: Decodable, Sendable { let date: String }
  }
}
private struct RUMMetricsData: Decodable, Sendable {
  let viewer: Viewer

  struct Viewer: Decodable, Sendable { let accounts: [Account] }
  struct Account: Decodable, Sendable {
    let pageload: [PageloadGroup]
    let performance: [PerformanceGroup]
  }
  struct DateDimension: Decodable, Sendable { let date: String }
  struct PageloadGroup: Decodable, Sendable {
    let count: Int
    let sum: Sum
    let dimensions: DateDimension

    struct Sum: Decodable, Sendable { let visits: Int }
  }
  struct PerformanceGroup: Decodable, Sendable {
    let quantiles: Quantiles
    let dimensions: DateDimension

    struct Quantiles: Decodable, Sendable { let pageLoadTimeP50: Double? }
  }
}
private struct ZoneAnalyticsHourlyData: Decodable, Sendable {
  let viewer: Viewer

  struct Viewer: Decodable, Sendable { let zones: [Zone] }
  struct Zone: Decodable, Sendable { let httpRequests1hGroups: [Group] }
  struct Group: Decodable, Sendable {
    let dimensions: Dimensions
    let sum: Sum
    let uniq: Uniq?

    struct Dimensions: Decodable, Sendable { let datetime: String }
    struct Sum: Decodable, Sendable {
      let requests: Int
      let pageViews: Int
      let threats: Int
      let bytes: Int64
      let cachedRequests: Int?
      let cachedBytes: Int64?
    }
    struct Uniq: Decodable, Sendable { let uniques: Int }
  }
}
private struct ZoneRequestsHourlyData: Decodable, Sendable {
  let viewer: Viewer

  struct Viewer: Decodable, Sendable { let zones: [Zone] }
  struct Zone: Decodable, Sendable { let httpRequestsAdaptiveGroups: [Group] }
  struct Group: Decodable, Sendable {
    let count: Int
    let dimensions: Dimensions

    struct Dimensions: Decodable, Sendable { let datetimeHour: String }
  }
}

private struct FirewallEventsData: Decodable, Sendable {
  let viewer: Viewer

  struct Viewer: Decodable, Sendable { let zones: [Zone] }
  struct Zone: Decodable, Sendable {
    let blocked: [CountRow]
    let byCountry: [DimensionRow]
    let byRule: [DimensionRow]
  }
  struct CountRow: Decodable, Sendable { let count: Int }
  struct DimensionRow: Decodable, Sendable {
    let count: Int
    let dimensions: Dimensions
    struct Dimensions: Decodable, Sendable {
      let clientCountryName: String?
      let ruleId: String?
    }
  }
}

private struct WorkerAnalyticsData: Decodable, Sendable {
  let viewer: Viewer

  struct Viewer: Decodable, Sendable { let accounts: [Account] }
  struct Account: Decodable, Sendable {
    let workersInvocationsAdaptive: [Row]
  }
  struct Row: Decodable, Sendable {
    let sum: Sum
    let quantiles: Quantiles?
    let dimensions: Dimensions

    struct Sum: Decodable, Sendable {
      let requests: Int
      let errors: Int
    }
    struct Quantiles: Decodable, Sendable {
      let cpuTimeP50: Double?
    }
    struct Dimensions: Decodable, Sendable {
      let datetimeFiveMinutes: String?
      let datetime: String?
      let status: String?
    }
  }
}

private struct ImagesListResult: Decodable, Sendable { let images: [CloudflareImage]? }
private struct R2BucketResult: Decodable, Sendable { let buckets: [R2Bucket] }
private struct R2CustomDomainList: Decodable, Sendable { let domains: [R2CustomDomain] }
