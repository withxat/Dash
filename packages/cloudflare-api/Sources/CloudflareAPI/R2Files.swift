import Foundation

private struct R2FilesBucketResult: Decodable, Sendable {
  let buckets: [LossyElement<R2Bucket>]?
}

private struct R2ObjectUploadEnvelope: Decodable, Sendable {
  let success: Bool
  let result: R2ObjectUploadResult?
  let errors: [APIErrorItem]?
}

private struct R2ObjectUploadResult: Decodable, Sendable {
  let etag: String?
  let key: String?
  let size: Int?
  let uploaded: String?

  private enum CodingKeys: String, CodingKey {
    case etag, key, size, uploaded
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    etag = try container.decodeIfPresent(String.self, forKey: .etag)
    key = try container.decodeIfPresent(String.self, forKey: .key)
    uploaded = try container.decodeIfPresent(String.self, forKey: .uploaded)
    if let integer = try? container.decodeIfPresent(Int.self, forKey: .size) {
      size = integer
    } else if let string = try? container.decodeIfPresent(String.self, forKey: .size) {
      size = Int(string)
    } else {
      size = nil
    }
  }
}

extension CloudflareClient {
  /// Fetches one bounded bucket page. File Provider must never collect the
  /// account's unbounded bucket list in its memory-constrained process.
  public func listR2BucketsPage(
    accountID: String,
    cursor: String? = nil,
    perPage: Int = R2Limits.listMaximumPerPage
  ) async throws -> CursorPage<R2Bucket> {
    let pageSize = min(max(perPage, 1), R2Limits.listMaximumPerPage)
    let data = try await raw(
      "/accounts/\(accountID)/r2/buckets",
      query: ["cursor": cursor, "per_page": String(pageSize)])
    let envelope = try JSONDecoder().decode(
      APIEnvelope<R2FilesBucketResult>.self, from: data)
    guard envelope.success else {
      throw CloudflareAPIError.request(status: 200, errors: envelope.errors ?? [])
    }
    let nextCursor = envelope.resultInfo?.cursor.flatMap { $0.isEmpty ? nil : $0 }
    if let cursor, nextCursor == cursor {
      throw CloudflareAPIError.invalidResponse
    }
    var seenNames: Set<String> = []
    return CursorPage(
      items: (envelope.result.buckets ?? []).compactMap(\.value).filter {
        seenNames.insert($0.name).inserted
      },
      cursor: nextCursor)
  }

  /// Resolves an exact object key without mistaking a child or a similarly
  /// prefixed key for the requested object.
  public func getR2ObjectMetadata(
    accountID: String,
    bucket: String,
    key: String
  ) async throws -> R2Object? {
    // This lookup deliberately decodes strictly instead of going through the
    // browser list's LossyElement wrapper. A malformed matching row is not
    // proof that an object vanished: returning nil would make File Provider
    // delete its local replica.
    let data = try await raw(
      "/accounts/\(accountID)/r2/buckets/\(bucket)/objects",
      query: [
        "prefix": key,
        "per_page": String(R2Limits.listMaximumPerPage),
      ])
    let envelope = try JSONDecoder().decode(APIEnvelope<[R2Object]>.self, from: data)
    guard envelope.success else {
      throw CloudflareAPIError.request(status: 200, errors: envelope.errors ?? [])
    }
    return envelope.result.first { $0.key == key }
  }
}

func decodeR2ObjectUploadResponse(
  _ data: Data,
  requestedKey: String,
  contentType: String?
) throws -> R2Object? {
  guard !data.isEmpty else { return nil }
  let envelope = try JSONDecoder().decode(R2ObjectUploadEnvelope.self, from: data)
  guard envelope.success else {
    throw CloudflareAPIError.request(status: 200, errors: envelope.errors ?? [])
  }
  guard let result = envelope.result else { return nil }
  return R2Object(
    key: result.key ?? requestedKey,
    size: result.size,
    etag: result.etag,
    uploaded: result.uploaded,
    httpMetadata: contentType.map(R2Object.HTTPMetadata.init(contentType:)))
}
