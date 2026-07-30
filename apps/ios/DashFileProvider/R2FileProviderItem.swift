import CloudflareAPI
import FileProvider
import Foundation
import UniformTypeIdentifiers

final class R2FileProviderItem: NSObject, NSFileProviderItem, @unchecked Sendable {
  let itemIdentifier: NSFileProviderItemIdentifier
  let parentItemIdentifier: NSFileProviderItemIdentifier
  let filename: String
  let contentType: UTType
  let capabilities: NSFileProviderItemCapabilities
  let documentSize: NSNumber?
  let creationDate: Date?
  let contentModificationDate: Date?
  let itemVersion: NSFileProviderItemVersion
  let isUploaded = true

  private init(
    identifier: R2ItemIdentifier,
    filename: String,
    contentType: UTType,
    capabilities: NSFileProviderItemCapabilities,
    documentSize: NSNumber? = nil,
    creationDate: Date? = nil,
    contentModificationDate: Date? = nil,
    contentVersion: Data,
    metadataVersion: Data
  ) {
    itemIdentifier = identifier.fileProviderIdentifier
    parentItemIdentifier = identifier.parentFileProviderIdentifier
    self.filename = filename
    self.contentType = contentType
    self.capabilities = capabilities
    self.documentSize = documentSize
    self.creationDate = creationDate
    self.contentModificationDate = contentModificationDate
    itemVersion = NSFileProviderItemVersion(
      contentVersion: contentVersion,
      metadataVersion: metadataVersion)
    super.init()
  }

  static func root(displayName: String) -> R2FileProviderItem {
    let name = displayName.isEmpty ? "R2" : displayName
    let version = Data("root:v1".utf8)
    return R2FileProviderItem(
      identifier: .root,
      filename: name,
      contentType: .folder,
      capabilities: [.allowsReading, .allowsContentEnumerating],
      contentVersion: version,
      metadataVersion: version)
  }

  static func bucket(
    name: String,
    creationDate: String? = nil,
    allowsWriting: Bool
  ) -> R2FileProviderItem {
    var capabilities: NSFileProviderItemCapabilities = [
      .allowsReading,
      .allowsContentEnumerating,
    ]
    if allowsWriting {
      capabilities.insert(.allowsAddingSubItems)
    }

    let parsedCreationDate = parseTimestamp(creationDate)
    let metadataToken = [
      "bucket",
      name,
      creationDate ?? "unknown-date",
    ].joined(separator: "|")
    return R2FileProviderItem(
      identifier: .bucket(name),
      filename: name,
      contentType: .folder,
      capabilities: capabilities,
      creationDate: parsedCreationDate,
      contentModificationDate: parsedCreationDate,
      contentVersion: Data("bucket:\(name)".utf8),
      metadataVersion: Data(metadataToken.utf8))
  }

  static func directory(
    path: R2ObjectPath,
    allowsWriting: Bool
  ) -> R2FileProviderItem {
    var capabilities: NSFileProviderItemCapabilities = [
      .allowsReading,
      .allowsContentEnumerating,
    ]
    if allowsWriting {
      capabilities.insert(.allowsAddingSubItems)
    }

    let version = Data("prefix:\(path.bucket):\(path.key)".utf8)
    return R2FileProviderItem(
      identifier: .object(path),
      filename: path.name,
      contentType: .folder,
      capabilities: capabilities,
      contentVersion: version,
      metadataVersion: version)
  }

  static func object(
    path: R2ObjectPath,
    metadata: R2Object?,
    fallbackSize: Int? = nil,
    fallbackContentType: String? = nil,
    fallbackModificationDate: Date? = nil,
    allowsWriting: Bool
  ) -> R2FileProviderItem {
    var capabilities: NSFileProviderItemCapabilities = [.allowsReading]
    if allowsWriting {
      capabilities.insert(.allowsWriting)
    }

    let size = metadata?.size ?? fallbackSize
    let declaredContentType = metadata?.contentType ?? fallbackContentType
    let modificationDate = parseTimestamp(metadata?.uploaded) ?? fallbackModificationDate
    let contentVersion =
      normalizedETag(metadata?.etag).map { Data($0.utf8) }
      ?? Data(
        [
          "metadata",
          metadata?.uploaded ?? modificationDate.map(String.init(describing:)) ?? "unknown-date",
          size.map(String.init) ?? "unknown-size",
          declaredContentType ?? "unknown-type",
        ].joined(separator: "|").utf8)
    let metadataVersion = Data(
      [
        path.key,
        metadata?.uploaded ?? modificationDate.map(String.init(describing:)) ?? "unknown-date",
        size.map(String.init) ?? "unknown-size",
        declaredContentType ?? "unknown-type",
      ].joined(separator: "|").utf8)

    return R2FileProviderItem(
      identifier: .object(path),
      filename: path.name,
      contentType: resolvedContentType(for: path.key, declared: declaredContentType),
      capabilities: capabilities,
      documentSize: size.map { NSNumber(value: Int64(max(0, $0))) },
      contentModificationDate: modificationDate,
      contentVersion: contentVersion,
      metadataVersion: metadataVersion)
  }

  private static func resolvedContentType(for key: String, declared: String?) -> UTType {
    if let declared, let type = UTType(mimeType: declared) {
      return type
    }
    if let inferred = R2Media.mimeType(forKey: key), let type = UTType(mimeType: inferred) {
      return type
    }
    let fileExtension = URL(fileURLWithPath: key).pathExtension
    if !fileExtension.isEmpty, let type = UTType(filenameExtension: fileExtension) {
      return type
    }
    return .data
  }

  private static func normalizedETag(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
    else { return nil }
    return value
  }

  private static func parseTimestamp(_ value: String?) -> Date? {
    guard let value else { return nil }
    let fractionalFormatter = ISO8601DateFormatter()
    fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractionalFormatter.date(from: value) {
      return date
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
  }
}
