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
  /// Documented object key ceiling, in UTF-8 bytes.
  public static let objectKeyMaximumBytes = 1024
}

/// Why a requested folder name cannot become an R2 key prefix.
///
/// The package refuses the name; the message belongs to the caller, because
/// this type is shared by the app and the File Provider and neither of them
/// localizes in the same place.
public enum R2FolderNameProblem: Error, Equatable, Sendable {
  /// Nothing but whitespace and separators.
  case empty
  /// A `//` with no name between the separators.
  case emptyPathComponent
  /// `.` or `..` — no file system can represent either as a name.
  case relativePathComponent
  case controlCharacters
  /// The resulting key exceeds `R2Limits.objectKeyMaximumBytes`.
  case keyTooLong
}

/// Folders in R2 are key prefixes, so an empty folder has no object to list and
/// nothing to list it from. Cloudflare's own dashboard materializes one as a
/// zero-byte object whose key ends in `/`, and every S3 client (rclone,
/// Cyberduck, the AWS console) reads that marker back as a folder rather than a
/// file. Dash writes exactly that object instead of a Dash-only placeholder
/// file: a folder created in the app is then the same folder the dashboard
/// would have created, and one created on the web needs no special case here.
public enum R2FolderMarker {
  /// Whether a listed key is a folder rather than one of its children.
  ///
  /// A marker is metadata for its own prefix, so a browser must not paint it as
  /// a row — listed inside the folder it names, it has no name left to show.
  public static func isMarker(key: String) -> Bool {
    key.hasSuffix("/")
  }

  /// The leaf marker key for `name` created under `parentPrefix`, or nil when
  /// the name cannot be represented (see `nameProblem`).
  public static func markerKey(parentPrefix: String, name: String) -> String? {
    try? resolve(parentPrefix: parentPrefix, name: name).get().last
  }

  /// Every marker that must exist so each path component stays visible while
  /// empty. `photos/2026` under the root yields `photos/` then `photos/2026/` —
  /// writing only the leaf would leave `photos` as a prefix that vanishes the
  /// moment its only child is deleted.
  public static func markerKeys(parentPrefix: String, name: String) -> [String]? {
    try? resolve(parentPrefix: parentPrefix, name: name).get()
  }

  /// Markers from the bucket root down through `key` itself. Used when the
  /// caller already holds a resolved marker and still needs the intermediates.
  public static func markerKeys(for key: String) -> [String] {
    let markerKey = isMarker(key: key) ? key : "\(key)/"
    guard markerKey != "/" else { return [markerKey] }
    let body = markerKey.dropLast()
    var keys: [String] = []
    var current = ""
    for component in body.split(separator: "/", omittingEmptySubsequences: false) {
      current += component + "/"
      keys.append(current)
    }
    return keys
  }

  /// Why `name` cannot become a folder under `parentPrefix`, or nil when it can.
  public static func nameProblem(parentPrefix: String, name: String) -> R2FolderNameProblem? {
    guard case .failure(let problem) = resolve(parentPrefix: parentPrefix, name: name) else {
      return nil
    }
    return problem
  }

  /// `name` may nest with `/`: Dash teaches key prefixes rather than folders, so
  /// `photos/2026` is one legitimate request for two of them. Leading and
  /// trailing separators are ignored, and every component is trimmed — R2 would
  /// accept a key with a trailing space, but no one could tell it apart from the
  /// same folder without one.
  private static func resolve(
    parentPrefix: String,
    name: String
  ) -> Result<[String], R2FolderNameProblem> {
    var components = name.split(separator: "/", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    while components.first?.isEmpty == true { components.removeFirst() }
    while components.last?.isEmpty == true { components.removeLast() }
    guard !components.isEmpty else { return .failure(.empty) }
    for component in components {
      guard !component.isEmpty else { return .failure(.emptyPathComponent) }
      guard component != ".", component != ".." else {
        return .failure(.relativePathComponent)
      }
      guard
        !component.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
      else { return .failure(.controlCharacters) }
    }
    var keys: [String] = []
    var current = parentPrefix
    for component in components {
      current += component + "/"
      keys.append(current)
    }
    guard let leaf = keys.last, leaf.utf8.count <= R2Limits.objectKeyMaximumBytes else {
      return .failure(.keyTooLong)
    }
    return .success(keys)
  }
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
    R2FolderMarker.isMarker(key: key)
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
