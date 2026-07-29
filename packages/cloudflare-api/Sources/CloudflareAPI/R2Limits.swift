import Foundation

/// Cloudflare REST API boundaries shared by the app and its File Provider.
///
/// These are deliberately package-owned: every process must reject the same
/// oversized transfer before it spends memory, disk, or the account-wide REST
/// request budget.
public enum R2Limits {
  /// Hard ceiling documented for `PUT /r2/buckets/{bucket}/objects/{key}`.
  public static let restUploadMaximumBytes: Int64 = 300 * 1024 * 1024
  /// Maximum accepted by both the bucket and object list endpoints.
  public static let listMaximumPerPage = 1000
  /// Shared across all R2 operations made through Cloudflare's REST API.
  public static let restRateLimitRequestsPerFiveMinutes = 1200
}

/// R2 treats folders as key prefixes. This helper preserves the original key
/// byte-for-byte while exposing the two path components File Provider needs.
public struct R2ObjectPath: Hashable, Sendable {
  public let bucket: String
  public let key: String

  public init(bucket: String, key: String) {
    self.bucket = bucket
    self.key = key
  }

  public var parentPrefix: String {
    let leaflessKey = isDirectoryMarker ? String(key.dropLast()) : key
    guard let separator = leaflessKey.lastIndex(of: "/") else { return "" }
    return String(leaflessKey[...separator])
  }

  public var name: String {
    let leaflessKey = isDirectoryMarker ? String(key.dropLast()) : key
    guard let separator = leaflessKey.lastIndex(of: "/") else { return leaflessKey }
    return String(leaflessKey[leaflessKey.index(after: separator)...])
  }

  public var isDirectoryMarker: Bool {
    key.hasSuffix("/")
  }

  /// Whether the object key has a one-to-one representation in Files.
  ///
  /// R2 permits leading and repeated slashes, but Files represents `/` as a
  /// hierarchy separator and cannot surface the resulting empty path
  /// components without changing the object's identity. Those objects remain
  /// available in Dash's native R2 browser instead of being aliased here.
  public var isFileProviderRepresentable: Bool {
    guard !key.isEmpty, !key.hasPrefix("/") else { return false }
    let path = isDirectoryMarker ? String(key.dropLast()) : key
    guard !path.isEmpty, !path.hasSuffix("/") else { return false }
    return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
      !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0")
    }
  }
}
