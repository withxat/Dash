import Foundation

public struct R2Bucket: CloudflareResource, Hashable {
  public var id: String { name }
  public let name: String
  public let creationDate: String?

  enum CodingKeys: String, CodingKey {
    case name
    case creationDate = "creation_date"
  }
}

public struct R2Object: Codable, Hashable, Identifiable, Sendable {
  public var id: String { key }
  public let key: String
  public let size: Int?
  public let etag: String?
  public let uploaded: String?
  public let httpMetadata: HTTPMetadata?

  public var contentType: String? { httpMetadata?.contentType }

  public struct HTTPMetadata: Codable, Hashable, Sendable {
    public let contentType: String?
  }

  enum CodingKeys: String, CodingKey {
    case key, size, etag
    case uploaded = "last_modified"
    case httpMetadata = "http_metadata"
  }
}

public struct R2ObjectPage: Sendable {
  public let objects: [R2Object]
  public let commonPrefixes: [String]
  public let cursor: String?
  public let isTruncated: Bool

  public init(
    objects: [R2Object], commonPrefixes: [String], cursor: String?, isTruncated: Bool
  ) {
    self.objects = objects
    self.commonPrefixes = commonPrefixes
    self.cursor = cursor
    self.isTruncated = isTruncated
  }
}

/// The bucket's r2.dev managed domain. Unlike the objects list, the domain
/// endpoints speak camelCase, so these models need no key mapping.
public struct R2ManagedDomain: Codable, Hashable, Sendable {
  public let bucketId: String
  public let domain: String
  public let enabled: Bool

  // Memberwise inits are internal; test fixtures need this one.
  public init(bucketId: String, domain: String, enabled: Bool) {
    self.bucketId = bucketId
    self.domain = domain
    self.enabled = enabled
  }
}

/// One custom domain attached to an R2 bucket. `status` is present on list and
/// get responses but absent from the create response, so it stays optional.
public struct R2CustomDomain: Codable, Hashable, Identifiable, Sendable {
  public var id: String { domain }
  public let domain: String
  public let enabled: Bool
  public let status: Status?
  public let minTLS: String?
  public let zoneId: String?
  public let zoneName: String?

  public struct Status: Codable, Hashable, Sendable {
    public let ownership: String?
    public let ssl: String?
  }
}

public struct KVNamespace: CloudflareResource, Hashable {
  public let id: String
  public let title: String
  public var name: String { title }
}

public struct KVKey: Codable, Hashable, Identifiable, Sendable {
  public var id: String { name }
  public let name: String
  public let expiration: Int?
  public let metadata: JSONValue?
}

public struct D1QueryResult: Codable, Hashable, Sendable {
  public let results: [[String: JSONValue]]?
  public let success: Bool?
  public let meta: [String: JSONValue]?
}

public struct StreamVideo: Codable, Hashable, Identifiable, Sendable {
  public let uid: String
  public let created: String?
  public let meta: StreamVideoMeta?

  public var id: String { uid }
  public var name: String { meta?.name ?? uid }
}

public struct StreamVideoMeta: Codable, Hashable, Sendable {
  public let name: String?
}

private struct R2BucketResult: Decodable, Sendable {
  let buckets: [LossyElement<R2Bucket>]?
}
private struct R2CustomDomainList: Decodable, Sendable { let domains: [R2CustomDomain] }

extension CloudflareClient {
  public func listR2Buckets(accountID: String) async throws -> [R2Bucket] {
    let path = "/accounts/\(accountID)/r2/buckets"
    var buckets: [R2Bucket] = []
    var seenBucketNames: Set<String> = []
    var seenCursors: Set<String> = []
    var cursor: String?

    while true {
      let data = try await raw(
        path, query: ["cursor": cursor, "per_page": "1000"])
      let envelope = try JSONDecoder().decode(APIEnvelope<R2BucketResult>.self, from: data)
      guard envelope.success else {
        throw CloudflareAPIError.request(status: 200, errors: envelope.errors ?? [])
      }
      buckets.append(
        contentsOf: (envelope.result.buckets ?? []).compactMap(\.value).filter {
          seenBucketNames.insert($0.name).inserted
        })

      guard let nextCursor = envelope.resultInfo?.cursor, !nextCursor.isEmpty else { break }
      guard nextCursor != cursor, seenCursors.insert(nextCursor).inserted else {
        throw CloudflareAPIError.invalidResponse
      }
      cursor = nextCursor
    }

    return buckets
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
    delimiter: String? = nil, startAfter: String? = nil, perPage: Int = 100
  ) async throws -> R2ObjectPage {
    let pageSize = min(max(perPage, 1), R2Limits.listMaximumPerPage)
    let data = try await raw(
      "/accounts/\(accountID)/r2/buckets/\(bucket)/objects",
      query: [
        "cursor": cursor, "prefix": prefix, "delimiter": delimiter, "start_after": startAfter,
        "per_page": String(pageSize),
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
  /// `URLRequest.httpBody`. The response body is bounded Cloudflare API
  /// metadata and is decoded when Cloudflare returns it.
  @discardableResult
  public func putR2Object(
    accountID: String, bucket: String, key: String, fileURL: URL, contentType: String?
  ) async throws -> R2Object? {
    let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
    if let fileSize = values.fileSize,
      Int64(fileSize) > R2Limits.restUploadMaximumBytes
    {
      throw CloudflareTransferError.exceedsLimit(
        limit: R2Limits.restUploadMaximumBytes, actual: Int64(fileSize))
    }
    let url = requestURL(
      path: "/accounts/\(accountID)/r2/buckets/\(bucket)/objects/\(key)")
    let response = try await uploadResponse(
      url: url, method: "PUT", fileURL: fileURL, contentType: contentType)
    return try decodeR2ObjectUploadResponse(
      response.0, requestedKey: key, contentType: contentType)
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
  public func listKVNamespaces(accountID: String, page: Int = 1, perPage: Int = 100)
    async throws -> Page<KVNamespace>
  {
    try await list(
      "/accounts/\(accountID)/storage/kv/namespaces",
      query: ["page": String(page), "per_page": String(perPage)])
  }
  public func getKVNamespace(accountID: String, namespaceID: String) async throws -> KVNamespace {
    try await request("/accounts/\(accountID)/storage/kv/namespaces/\(namespaceID)")
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
  public func queryD1(accountID: String, databaseID: String, sql: String) async throws
    -> [D1QueryResult]
  {
    try await request(
      "/accounts/\(accountID)/d1/database/\(databaseID)/query", method: "POST", body: ["sql": sql])
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
}
