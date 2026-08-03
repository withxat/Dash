import CloudflareAPI
import FileProvider
import Foundation
import UniformTypeIdentifiers

final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, @unchecked Sendable
{
  private static let maximumDownloadBytes: Int64 = 1024 * 1024 * 1024

  private let domain: NSFileProviderDomain
  private let accountID: String
  private let manager: NSFileProviderManager?
  private let tokenStore: KeychainTokenStore
  private let session: URLSession
  private let client: CloudflareClient
  private let operations = FileProviderOperationRegistry()

  required init(domain: NSFileProviderDomain) {
    let tokenStore = KeychainTokenStore()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 25
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    configuration.httpMaximumConnectionsPerHost = 2
    let session = URLSession(configuration: configuration)

    self.domain = domain
    accountID = domain.identifier.rawValue
    manager = NSFileProviderManager(for: domain)
    self.tokenStore = tokenStore
    self.session = session
    client = CloudflareClient(
      clientID: AppConfiguration.current.clientID,
      tokenStore: tokenStore,
      session: session)
    super.init()

    if let manager, let temporaryDirectory = try? manager.temporaryDirectoryURL() {
      FileProviderTemporaryFile.removeStaleFiles(in: temporaryDirectory)
    }
  }

  func invalidate() {
    operations.cancelAll()
    session.invalidateAndCancel()
  }

  func item(
    for identifier: NSFileProviderItemIdentifier,
    request: NSFileProviderRequest,
    completionHandler: @escaping (NSFileProviderItem?, (any Error)?) -> Void
  ) -> Progress {
    let completion = FileProviderSendableBox(completionHandler)
    return perform {
      do {
        let credentials = try await FileProviderCredentialState.load(from: self.tokenStore)
        let item = try await self.resolveItem(
          identifier,
          allowsWriting: credentials.allowsWriting)
        completion.value(item, nil)
      } catch {
        completion.value(
          nil,
          FileProviderErrorMapping.map(error, operation: .metadata))
      }
    }
  }

  func fetchContents(
    for itemIdentifier: NSFileProviderItemIdentifier,
    version requestedVersion: NSFileProviderItemVersion?,
    request: NSFileProviderRequest,
    completionHandler: @escaping (URL?, NSFileProviderItem?, (any Error)?) -> Void
  ) -> Progress {
    let completion = FileProviderSendableBox(completionHandler)
    return perform {
      var temporaryFile: FileProviderTemporaryFile?
      do {
        _ = try await FileProviderCredentialState.load(from: self.tokenStore)
        guard case .object(let path) = R2ItemIdentifier(itemIdentifier),
          !path.isDirectoryMarker
        else {
          throw FileProviderErrorMapping.featureUnsupported
        }

        guard
          let metadata = try await self.client.getR2ObjectMetadata(
            accountID: self.accountID,
            bucket: path.bucket,
            key: path.key)
        else {
          throw FileProviderErrorMapping.noSuchItem
        }
        if let size = metadata.size, Int64(size) > Self.maximumDownloadBytes {
          throw CloudflareTransferError.exceedsLimit(
            limit: Self.maximumDownloadBytes,
            actual: Int64(size))
        }

        let scratch = try self.makeTemporaryFile(
          purpose: "file-provider-download",
          filename: path.name)
        temporaryFile = scratch
        let downloadedURL = try await self.client.downloadR2Object(
          accountID: self.accountID,
          bucket: path.bucket,
          key: path.key,
          to: scratch.fileURL,
          maximumBytes: Self.maximumDownloadBytes)
        try Task.checkCancellation()

        let credentials = try await FileProviderCredentialState.load(from: self.tokenStore)
        let item = R2FileProviderItem.object(
          path: path,
          metadata: metadata,
          allowsWriting: credentials.allowsWriting)
        completion.value(downloadedURL, item, nil)
        // File Provider takes ownership, clones, and unlinks this URL after
        // the callback. It must remain untouched once handed over.
        temporaryFile = nil
      } catch {
        temporaryFile?.remove()
        completion.value(
          nil,
          nil,
          FileProviderErrorMapping.map(error, operation: .download))
      }
    }
  }

  func createItem(
    basedOn itemTemplate: NSFileProviderItem,
    fields: NSFileProviderItemFields,
    contents url: URL?,
    options: NSFileProviderCreateItemOptions = [],
    request: NSFileProviderRequest,
    completionHandler:
      @escaping (
        NSFileProviderItem?, NSFileProviderItemFields, Bool, (any Error)?
      ) -> Void
  ) -> Progress {
    let itemTemplate = FileProviderSendableBox(itemTemplate)
    let contents = FileProviderSendableBox(url)
    let completion = FileProviderSendableBox(completionHandler)
    return perform {
      do {
        let credentials = try await FileProviderCredentialState.load(from: self.tokenStore)
        guard credentials.allowsWriting else {
          throw FileProviderErrorMapping.writePermissionDenied
        }

        let template = itemTemplate.value
        let isDirectory = template.contentType?.conforms(to: .folder) == true
        let path = try self.destinationPath(
          parentIdentifier: template.parentItemIdentifier,
          filename: template.filename,
          isDirectory: isDirectory)

        if isDirectory {
          // Same zero-byte `…/` markers Dash and the Cloudflare dashboard write.
          // Delete stays unsupported here: empty-only folder delete is Dash's
          // surface until Files can mirror that guard safely.
          try await self.createFolder(at: path)
          try Task.checkCancellation()
          completion.value(
            R2FileProviderItem.directory(path: path, allowsWriting: true),
            [],
            false,
            nil)
          return
        }

        // Cloudflare's REST object PUT has no If-None-Match. This preflight
        // gives Files its normal "report 2.pdf" collision behavior, but there
        // remains an unavoidable TOCTOU window before the subsequent PUT.
        if try await self.client.getR2ObjectMetadata(
          accountID: self.accountID,
          bucket: path.bucket,
          key: path.key) != nil
        {
          throw FileProviderErrorMapping.filenameCollision
        }
        let childPrefix = try await self.client.listR2Objects(
          accountID: self.accountID,
          bucket: path.bucket,
          prefix: "\(path.key)/",
          delimiter: "/",
          perPage: 1)
        if !childPrefix.objects.isEmpty || !childPrefix.commonPrefixes.isEmpty {
          // Object stores permit both `reports` and `reports/...`; a file
          // system cannot represent those siblings with the same name.
          throw FileProviderErrorMapping.filenameCollision
        }

        guard let uploadURL = contents.value else {
          throw FileProviderErrorMapping.featureUnsupported
        }

        let fileSize = try self.validateUploadSize(uploadURL)
        let mimeType =
          template.contentType?.preferredMIMEType ?? R2Media.mimeType(forKey: path.key)
        let uploaded = try await self.client.putR2Object(
          accountID: self.accountID,
          bucket: path.bucket,
          key: path.key,
          fileURL: uploadURL,
          contentType: mimeType)
        try Task.checkCancellation()

        let item = R2FileProviderItem.object(
          path: path,
          metadata: uploaded,
          fallbackSize: fileSize,
          fallbackContentType: mimeType,
          fallbackModificationDate: Date(),
          allowsWriting: true)
        completion.value(item, [], false, nil)
      } catch {
        completion.value(
          nil,
          fields,
          false,
          FileProviderErrorMapping.map(error, operation: .upload))
      }
    }
  }

  func modifyItem(
    _ item: NSFileProviderItem,
    baseVersion version: NSFileProviderItemVersion,
    changedFields: NSFileProviderItemFields,
    contents newContents: URL?,
    options: NSFileProviderModifyItemOptions = [],
    request: NSFileProviderRequest,
    completionHandler:
      @escaping (
        NSFileProviderItem?, NSFileProviderItemFields, Bool, (any Error)?
      ) -> Void
  ) -> Progress {
    let item = FileProviderSendableBox(item)
    let newContents = FileProviderSendableBox(newContents)
    let completion = FileProviderSendableBox(completionHandler)
    return perform {
      do {
        let supportedFields: NSFileProviderItemFields = [
          .contents,
          .contentModificationDate,
        ]
        guard changedFields.contains(.contents),
          changedFields.subtracting(supportedFields).isEmpty,
          let contentsURL = newContents.value
        else {
          throw FileProviderErrorMapping.featureUnsupported
        }

        let credentials = try await FileProviderCredentialState.load(from: self.tokenStore)
        guard credentials.allowsWriting else {
          throw FileProviderErrorMapping.writePermissionDenied
        }
        guard case .object(let path) = R2ItemIdentifier(item.value.itemIdentifier),
          !path.isDirectoryMarker
        else {
          throw FileProviderErrorMapping.featureUnsupported
        }

        // R2's REST PUT has no conditional request header, so baseVersion
        // cannot be used as an atomic compare-and-swap.
        let fileSize = try self.validateUploadSize(contentsURL)
        let mimeType =
          item.value.contentType?.preferredMIMEType ?? R2Media.mimeType(forKey: path.key)
        let uploaded = try await self.client.putR2Object(
          accountID: self.accountID,
          bucket: path.bucket,
          key: path.key,
          fileURL: contentsURL,
          contentType: mimeType)
        try Task.checkCancellation()

        let updatedItem = R2FileProviderItem.object(
          path: path,
          metadata: uploaded,
          fallbackSize: fileSize,
          fallbackContentType: mimeType,
          fallbackModificationDate: Date(),
          allowsWriting: true)
        completion.value(updatedItem, [], false, nil)
      } catch {
        completion.value(
          nil,
          changedFields,
          false,
          FileProviderErrorMapping.map(error, operation: .upload))
      }
    }
  }

  func deleteItem(
    identifier: NSFileProviderItemIdentifier,
    baseVersion version: NSFileProviderItemVersion,
    options: NSFileProviderDeleteItemOptions = [],
    request: NSFileProviderRequest,
    completionHandler: @escaping ((any Error)?) -> Void
  ) -> Progress {
    let progress = Progress(totalUnitCount: 1)
    completionHandler(FileProviderErrorMapping.featureUnsupported)
    progress.completedUnitCount = 1
    return progress
  }

  func enumerator(
    for containerItemIdentifier: NSFileProviderItemIdentifier,
    request: NSFileProviderRequest
  ) throws -> any NSFileProviderEnumerator {
    let container: R2EnumeratorContainer
    if containerItemIdentifier == .workingSet {
      container = .workingSet
    } else if containerItemIdentifier == .trashContainer {
      throw FileProviderErrorMapping.featureUnsupported
    } else {
      guard let identifier = R2ItemIdentifier(containerItemIdentifier) else {
        throw FileProviderErrorMapping.noSuchItem
      }
      switch identifier {
      case .root:
        container = .root
      case .bucket(let bucket):
        container = .prefix(bucket: bucket, prefix: "")
      case .object(let path) where path.isDirectoryMarker:
        container = .prefix(bucket: path.bucket, prefix: path.key)
      case .object:
        throw FileProviderErrorMapping.noSuchItem
      }
    }

    return R2Enumerator(
      container: container,
      accountID: accountID,
      client: client,
      tokenStore: tokenStore)
  }

  private func perform(
    _ operation: @escaping @Sendable () async -> Void
  ) -> Progress {
    let progress = Progress(totalUnitCount: 1)
    let progressBox = FileProviderSendableBox(progress)
    let task = operations.start {
      await operation()
      progressBox.value.completedUnitCount = 1
    }
    progress.cancellationHandler = {
      task.cancel()
    }
    return progress
  }

  private func resolveItem(
    _ identifier: NSFileProviderItemIdentifier,
    allowsWriting: Bool
  ) async throws -> R2FileProviderItem {
    guard let identifier = R2ItemIdentifier(identifier) else {
      throw FileProviderErrorMapping.noSuchItem
    }
    switch identifier {
    case .root:
      return R2FileProviderItem.root(displayName: domain.displayName)
    case .bucket(let bucket):
      return R2FileProviderItem.bucket(name: bucket, allowsWriting: allowsWriting)
    case .object(let path) where path.isDirectoryMarker:
      guard !path.name.isEmpty else {
        throw FileProviderErrorMapping.noSuchItem
      }
      return R2FileProviderItem.directory(path: path, allowsWriting: allowsWriting)
    case .object(let path):
      guard
        let object = try await client.getR2ObjectMetadata(
          accountID: accountID,
          bucket: path.bucket,
          key: path.key)
      else {
        throw FileProviderErrorMapping.noSuchItem
      }
      return R2FileProviderItem.object(
        path: path,
        metadata: object,
        allowsWriting: allowsWriting)
    }
  }

  private func destinationPath(
    parentIdentifier: NSFileProviderItemIdentifier,
    filename: String,
    isDirectory: Bool
  ) throws -> R2ObjectPath {
    guard !filename.isEmpty, !filename.contains("/"), !filename.contains("\0"),
      let parent = R2ItemIdentifier(parentIdentifier)
    else {
      throw FileProviderErrorMapping.featureUnsupported
    }

    let bucket: String
    let parentPrefix: String
    switch parent {
    case .bucket(let name):
      bucket = name
      parentPrefix = ""
    case .object(let path) where path.isDirectoryMarker:
      bucket = path.bucket
      parentPrefix = path.key
    case .root, .object:
      throw FileProviderErrorMapping.featureUnsupported
    }

    if isDirectory {
      // Single path component only — Files' New Folder UI does not nest with `/`.
      guard
        R2FolderMarker.nameProblem(parentPrefix: parentPrefix, name: filename) == nil,
        let key = R2FolderMarker.markerKey(parentPrefix: parentPrefix, name: filename)
      else {
        throw FileProviderErrorMapping.featureUnsupported
      }
      return R2ObjectPath(bucket: bucket, key: key)
    }

    return R2ObjectPath(bucket: bucket, key: "\(parentPrefix)\(filename)")
  }

  /// Writes Cloudflare/Dash folder markers after the same collision checks the
  /// file upload path uses, so a name cannot hide a sibling object or folder.
  private func createFolder(at path: R2ObjectPath) async throws {
    let fileKey = String(path.key.dropLast())
    guard !fileKey.isEmpty else {
      throw FileProviderErrorMapping.featureUnsupported
    }
    if try await client.getR2ObjectMetadata(
      accountID: accountID, bucket: path.bucket, key: fileKey) != nil
    {
      throw FileProviderErrorMapping.filenameCollision
    }
    if try await client.getR2ObjectMetadata(
      accountID: accountID, bucket: path.bucket, key: path.key) != nil
    {
      throw FileProviderErrorMapping.filenameCollision
    }
    let listing = try await client.listR2Objects(
      accountID: accountID,
      bucket: path.bucket,
      prefix: path.key,
      delimiter: "/",
      perPage: 1)
    let hasChildren =
      listing.objects.contains { !R2FolderMarker.isMarker(key: $0.key) }
      || !listing.commonPrefixes.isEmpty
    if hasChildren {
      throw FileProviderErrorMapping.filenameCollision
    }

    try await client.createR2Folder(
      accountID: accountID, bucket: path.bucket, key: path.key)
  }

  private func validateUploadSize(_ fileURL: URL) throws -> Int? {
    let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
    if let size = values.fileSize, Int64(size) > R2Limits.restUploadMaximumBytes {
      throw CloudflareTransferError.exceedsLimit(
        limit: R2Limits.restUploadMaximumBytes,
        actual: Int64(size))
    }
    return values.fileSize
  }

  private func makeTemporaryFile(
    purpose: String,
    filename: String
  ) throws -> FileProviderTemporaryFile {
    guard let manager else {
      throw CloudflareAPIError.invalidResponse
    }
    return FileProviderTemporaryFile.make(
      in: try manager.temporaryDirectoryURL(),
      purpose: purpose,
      filename: filename)
  }
}

private struct FileProviderTemporaryFile: Sendable {
  let directoryURL: URL
  let fileURL: URL

  private static let rootDirectoryName = "dash-r2"

  static func make(
    in temporaryDirectory: URL,
    purpose: String,
    filename: String
  ) -> FileProviderTemporaryFile {
    let safePurpose = safeComponent(purpose, fallback: "operation")
    let safeFilename = safeComponent(filename, fallback: "object")
    let directoryURL =
      temporaryDirectory
      .appending(path: rootDirectoryName, directoryHint: .isDirectory)
      .appending(path: safePurpose, directoryHint: .isDirectory)
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    return FileProviderTemporaryFile(
      directoryURL: directoryURL,
      fileURL: directoryURL.appending(path: safeFilename, directoryHint: .notDirectory))
  }

  func remove() {
    try? FileManager.default.removeItem(at: directoryURL)
  }

  static func removeStaleFiles(
    in temporaryDirectory: URL,
    olderThan age: TimeInterval = 24 * 60 * 60
  ) {
    let rootURL = temporaryDirectory.appending(
      path: rootDirectoryName,
      directoryHint: .isDirectory)
    Task.detached(priority: .utility) {
      guard
        let directories = try? FileManager.default.contentsOfDirectory(
          at: rootURL,
          includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey],
          options: [.skipsHiddenFiles])
      else { return }

      let cutoff = Date().addingTimeInterval(-age)
      for purposeDirectory in directories {
        guard
          let operationDirectories = try? FileManager.default.contentsOfDirectory(
            at: purposeDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey],
            options: [.skipsHiddenFiles])
        else { continue }
        for operationDirectory in operationDirectories {
          let values = try? operationDirectory.resourceValues(
            forKeys: [.contentModificationDateKey, .creationDateKey])
          let timestamp = values?.contentModificationDate ?? values?.creationDate
          if timestamp.map({ $0 < cutoff }) ?? true {
            try? FileManager.default.removeItem(at: operationDirectory)
          }
        }
      }
    }
  }

  private static func safeComponent(_ value: String, fallback: String) -> String {
    let component = URL(fileURLWithPath: value).lastPathComponent
    return component.isEmpty || component == "." || component == ".." ? fallback : component
  }
}
