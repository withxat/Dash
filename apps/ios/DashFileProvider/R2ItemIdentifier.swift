import CloudflareAPI
import FileProvider
import Foundation

enum R2ItemIdentifier: Hashable, Sendable {
  case root
  case bucket(String)
  case object(R2ObjectPath)

  init?(_ identifier: NSFileProviderItemIdentifier) {
    if identifier == .rootContainer {
      self = .root
      return
    }

    let rawValue = identifier.rawValue
    if rawValue.hasPrefix("b:") {
      let bucket = String(rawValue.dropFirst(2))
      guard Self.isValidBucketComponent(bucket) else { return nil }
      self = .bucket(bucket)
      return
    }

    guard rawValue.hasPrefix("o:") else { return nil }
    let payload = rawValue.dropFirst(2)
    guard let separator = payload.firstIndex(of: ":") else { return nil }
    let bucket = String(payload[..<separator])
    let key = String(payload[payload.index(after: separator)...])
    guard Self.isValidBucketComponent(bucket), !key.isEmpty else { return nil }
    let path = R2ObjectPath(bucket: bucket, key: key)
    guard path.isFileProviderRepresentable else { return nil }
    self = .object(path)
  }

  var fileProviderIdentifier: NSFileProviderItemIdentifier {
    switch self {
    case .root:
      .rootContainer
    case .bucket(let bucket):
      NSFileProviderItemIdentifier("b:\(bucket)")
    case .object(let path):
      // The first colon terminates the DNS-safe bucket component. Everything
      // after it is the R2 key verbatim, including any further colons.
      NSFileProviderItemIdentifier("o:\(path.bucket):\(path.key)")
    }
  }

  var parentFileProviderIdentifier: NSFileProviderItemIdentifier {
    switch self {
    case .root:
      return .rootContainer
    case .bucket:
      return .rootContainer
    case .object(let path):
      let parentPrefix = path.parentPrefix
      if parentPrefix.isEmpty {
        return R2ItemIdentifier.bucket(path.bucket).fileProviderIdentifier
      }
      return R2ItemIdentifier.object(
        R2ObjectPath(bucket: path.bucket, key: parentPrefix)
      ).fileProviderIdentifier
    }
  }

  var bucketName: String? {
    switch self {
    case .root:
      nil
    case .bucket(let bucket):
      bucket
    case .object(let path):
      path.bucket
    }
  }

  var prefix: String? {
    switch self {
    case .root:
      nil
    case .bucket:
      ""
    case .object(let path):
      path.isDirectoryMarker ? path.key : nil
    }
  }

  private static func isValidBucketComponent(_ value: String) -> Bool {
    !value.isEmpty && !value.contains(":")
  }
}
