import Foundation

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
  public func listDNSRecords(zoneID: String, page: Int = 1, perPage: Int = 100) async throws
    -> Page<DNSRecord>
  {
    try await list(
      "/zones/\(zoneID)/dns_records", query: ["page": String(page), "per_page": String(perPage)])
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
    accountID: String, bucket: String, cursor: String? = nil, prefix: String? = nil
  ) async throws -> CursorPage<R2Object> {
    let result: R2ObjectResult = try await request(
      "/accounts/\(accountID)/r2/buckets/\(bucket)/objects",
      query: ["cursor": cursor, "prefix": prefix])
    return CursorPage(items: result.objects, cursor: result.cursor)
  }
  public func putR2Object(
    accountID: String, bucket: String, key: String, data: Data, contentType: String?
  ) async throws {
    let _: Data = try await raw(
      "/accounts/\(accountID)/r2/buckets/\(bucket)/objects/\(key)", method: "PUT", data: data,
      contentType: contentType)
  }
  public func deleteR2Object(accountID: String, bucket: String, key: String) async throws {
    let _: Data = try await raw(
      "/accounts/\(accountID)/r2/buckets/\(bucket)/objects/\(key)", method: "DELETE")
  }

  /// Raw object body — binary endpoint, no JSON envelope.
  public func getR2Object(accountID: String, bucket: String, key: String) async throws -> Data {
    try await raw("/accounts/\(accountID)/r2/buckets/\(bucket)/objects/\(key)")
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
  public func listNotificationHistory(accountID: String, perPage: Int = 10) async throws
    -> [NotificationHistoryEntry]
  {
    try await list(
      "/accounts/\(accountID)/alerting/v3/history", query: ["per_page": String(perPage)]
    ).items
  }
  public func listAuditLogs(accountID: String, perPage: Int = 10) async throws -> [AuditLogEntry] {
    try await list(
      "/accounts/\(accountID)/audit_logs",
      query: ["direction": "desc", "per_page": String(perPage)]
    ).items
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
    try await list("/accounts/\(accountID)/registrar/domains").items
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
      dimensions { date } sum { requests pageViews threats bytes } } } } }
      """
    let payload = try JSONEncoder().encode(["query": query])
    let response = try await raw(
      url: CloudflareEndpoints.graphql, method: "POST", data: payload,
      contentType: "application/json")
    let envelope = try JSONDecoder().decode(
      GraphQLEnvelope<ZoneAnalyticsData>.self, from: response)
    if let message = envelope.errors?.first?.message {
      throw CloudflareAPIError.request(
        status: 200, errors: [APIErrorItem(code: 0, message: message)])
    }
    return (envelope.data?.viewer.zones.first?.httpRequests1dGroups ?? []).map {
      ZoneAnalyticsDay(
        date: $0.dimensions.date, requests: $0.sum.requests, pageViews: $0.sum.pageViews,
        threats: $0.sum.threats, bytes: $0.sum.bytes)
    }
  }

  public func graphQL(query: String, variables: [String: JSONValue]) async throws -> JSONValue {
    let data = try JSONEncoder().encode([
      "query": JSONValue.string(query), "variables": .object(variables),
    ])
    let response = try await raw(
      url: CloudflareEndpoints.graphql, method: "POST", data: data, contentType: "application/json")
    return try JSONDecoder().decode(JSONValue.self, from: response)
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
    let envelope = try JSONDecoder().decode(APIEnvelope<[Value]>.self, from: data)
    guard envelope.success else {
      throw CloudflareAPIError.request(status: 200, errors: envelope.errors ?? [])
    }
    return Page(items: envelope.result, resultInfo: envelope.resultInfo)
  }

  private func raw(
    _ path: String, method: String = "GET", query: [String: String?] = [:], data: Data? = nil,
    contentType: String? = nil, attempt: Int = 0
  ) async throws -> Data {
    var components = URLComponents(
      url: apiBase.appending(path: path), resolvingAgainstBaseURL: false)!
    components.queryItems = query.compactMap { key, value in
      value.map { URLQueryItem(name: key, value: $0) }
    }
    return try await raw(
      url: components.url!, method: method, data: data, contentType: contentType, attempt: attempt)
  }

  private func raw(url: URL, method: String, data: Data?, contentType: String?, attempt: Int = 0)
    async throws -> Data
  {
    try await rawResponse(
      url: url, method: method, data: data, contentType: contentType, attempt: attempt
    ).0
  }

  private func rawResponse(
    url: URL, method: String, data: Data?, contentType: String?, attempt: Int = 0
  ) async throws -> (Data, HTTPURLResponse) {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.httpBody = data
    let requestToken = try await tokenStore.getAccessToken()
    if let requestToken {
      request.setValue("Bearer \(requestToken)", forHTTPHeaderField: "Authorization")
    }
    if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
    do {
      let (body, response) = try await session.data(for: request)
      guard let response = response as? HTTPURLResponse else {
        throw CloudflareAPIError.invalidResponse
      }
      if response.statusCode == 401, attempt == 0 {
        let currentToken = try await tokenStore.getAccessToken()
        let canRetry: Bool
        if currentToken != nil, currentToken != requestToken {
          canRetry = true
        } else {
          canRetry = try await refresh() != nil
        }
        if canRetry {
          return try await rawResponse(
            url: url, method: method, data: data, contentType: contentType, attempt: 1)
        }
      }
      guard (200..<300).contains(response.statusCode) else {
        let errors = (try? JSONDecoder().decode(ErrorEnvelope.self, from: body).errors) ?? []
        throw CloudflareAPIError.request(status: response.statusCode, errors: errors)
      }
      return (body, response)
    } catch let error as CloudflareAPIError { throw error } catch {
      throw CloudflareAPIError.transport(error.localizedDescription)
    }
  }

  private func refresh() async throws -> TokenSet? {
    if let refreshTask { return try await refreshTask.value }
    guard let refreshToken = try await tokenStore.getRefreshToken() else { return nil }
    let clientID = clientID
    let session = session
    let store = tokenStore
    let task = Task<TokenSet?, Error> {
      let tokens = try await OAuth.refresh(
        clientID: clientID, refreshToken: refreshToken, session: session, tokenURL: tokenURL)
      try await store.setTokens(tokens)
      return tokens
    }
    refreshTask = task
    defer { refreshTask = nil }
    return try await task.value
  }
}

private struct ErrorEnvelope: Decodable { let errors: [APIErrorItem] }
private struct GraphQLEnvelope<Value: Decodable & Sendable>: Decodable, Sendable {
  let data: Value?
  let errors: [GraphQLErrorItem]?
}
private struct GraphQLErrorItem: Decodable, Sendable { let message: String }
private struct ZoneAnalyticsData: Decodable, Sendable {
  let viewer: Viewer

  struct Viewer: Decodable, Sendable { let zones: [Zone] }
  struct Zone: Decodable, Sendable { let httpRequests1dGroups: [Group] }
  struct Group: Decodable, Sendable {
    let dimensions: Dimensions
    let sum: Sum

    struct Dimensions: Decodable, Sendable { let date: String }
    struct Sum: Decodable, Sendable {
      let requests: Int
      let pageViews: Int
      let threats: Int
      let bytes: Int64
    }
  }
}
private struct ImagesListResult: Decodable, Sendable { let images: [CloudflareImage]? }
private struct R2BucketResult: Decodable, Sendable { let buckets: [R2Bucket] }
private struct R2ObjectResult: Decodable, Sendable {
  let objects: [R2Object]
  let cursor: String?
}
