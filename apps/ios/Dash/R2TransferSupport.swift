import CloudflareAPI
import Foundation
import UniformTypeIdentifiers

// MARK: - Media detection

/// What Dash is willing to fetch and decode from a bucket, and how large an
/// on-device object transfer may be.
enum R2Media {
  /// On-device ceiling shared by uploads and previews. Object transfers are
  /// file-backed, but Dash still bounds disk, network, and the time a
  /// foreground operation can occupy.
  static let transferSizeLimit = 100 * 1024 * 1024
  static let transferSizeLimitBytes = Int64(transferSizeLimit)

  /// Row thumbnails skip anything above this — a grid of multi-megabyte
  /// downloads per scroll would swamp cell data for a 40pt square.
  static let thumbnailByteLimit = 8 * 1024 * 1024

  /// UIImage-decodable formats only — SVG stays a generic file row.
  private static let imageExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "avif", "bmp", "tif", "tiff",
  ]

  static func isImage(_ object: R2Object) -> Bool {
    if let type = object.contentType?.lowercased() {
      return type.hasPrefix("image/") && !type.contains("svg")
    }
    return isImageKey(object.key)
  }

  static func isImageKey(_ key: String) -> Bool {
    guard let name = key.split(separator: "/").last,
      let ext = name.split(separator: ".").last, ext.count < name.count
    else { return false }
    return imageExtensions.contains(ext.lowercased())
  }

  static func mimeType(forKey key: String) -> String? {
    let ext = key.split(separator: "/").last?.split(separator: ".").last.map(String.init)
    return ext.flatMap { UTType(filenameExtension: $0)?.preferredMIMEType }
  }

  static func isWithinTransferLimit(_ size: Int?) -> Bool {
    size.map { Int64($0) <= transferSizeLimitBytes } ?? true
  }

  /// Stable thumbnail identity. R2 normally returns an ETag, while metadata is
  /// the fallback for providers or fixtures that omit it.
  static func versionToken(for object: R2Object) -> String {
    if let etag = object.etag?.trimmingCharacters(in: .whitespacesAndNewlines),
      !etag.isEmpty
    {
      return "etag:\(etag)"
    }
    return [
      "metadata",
      object.uploaded ?? "unknown-date",
      object.size.map(String.init) ?? "unknown-size",
      object.contentType ?? "unknown-type",
    ].joined(separator: "|")
  }
}

/// Caller-owned scratch location for one R2 operation. Every purpose lives
/// under Dash's single temporary root so launch cleanup covers previews,
/// thumbnails, intents, and exports after a crash or force quit.
struct R2TemporaryFile: Hashable, Sendable {
  let directoryURL: URL
  let fileURL: URL

  private static let rootDirectoryName = "dash-r2"

  private static var rootURL: URL {
    rootURL(in: FileManager.default.temporaryDirectory)
  }

  private static func rootURL(in temporaryDirectory: URL) -> URL {
    temporaryDirectory
      .appending(path: rootDirectoryName, directoryHint: .isDirectory)
  }

  static func make(purpose: String, filename: String) -> R2TemporaryFile {
    let leaf = URL(fileURLWithPath: filename).lastPathComponent
    let safeName = leaf.isEmpty || leaf == "." || leaf == ".." ? "object" : leaf
    let purposeLeaf = URL(fileURLWithPath: purpose).lastPathComponent
    let safePurpose =
      purposeLeaf.isEmpty || purposeLeaf == "." || purposeLeaf == ".."
      ? "operation" : purposeLeaf
    let directory =
      rootURL
      .appending(path: safePurpose, directoryHint: .isDirectory)
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    return R2TemporaryFile(
      directoryURL: directory,
      fileURL: directory.appending(path: safeName, directoryHint: .notDirectory))
  }

  func write(_ data: Data) async throws {
    let directoryURL = directoryURL
    let fileURL = fileURL
    let writeTask = Task.detached(priority: .userInitiated) {
      do {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(
          at: directoryURL, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        try Task.checkCancellation()
      } catch {
        try? FileManager.default.removeItem(at: directoryURL)
        throw error
      }
    }
    try await withTaskCancellationHandler {
      try await writeTask.value
    } onCancel: {
      writeTask.cancel()
    }
  }

  func remove() {
    try? FileManager.default.removeItem(at: directoryURL)
  }

  /// File exports must survive long enough for the receiving app to copy them,
  /// but should not accumulate forever if the process stays alive.
  func scheduleRemoval(after delay: Duration = .seconds(600)) {
    let directoryURL = directoryURL
    Task.detached(priority: .utility) {
      try? await Task.sleep(for: delay)
      try? FileManager.default.removeItem(at: directoryURL)
    }
  }

  /// Best-effort launch cleanup for every R2 operation left behind if the app
  /// was terminated before its normal `defer` cleanup could run.
  static func removeStaleFiles(olderThan age: TimeInterval) {
    let root = rootURL
    Task.detached(priority: .utility) {
      guard
        let purposeDirectories = try? FileManager.default.contentsOfDirectory(
          at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
      else { return }
      let cutoff = Date().addingTimeInterval(-age)
      for purposeDirectory in purposeDirectories {
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
        if (try? FileManager.default.contentsOfDirectory(atPath: purposeDirectory.path).isEmpty)
          == true
        {
          try? FileManager.default.removeItem(at: purposeDirectory)
        }
      }
    }
  }

  /// Removes only Dash's dedicated R2 temporary root. Sign-out awaits this
  /// helper after account-scoped views have been dismissed so previews,
  /// exports, and interrupted operations do not outlive the session.
  static func removeAllFiles(
    in temporaryDirectory: URL = FileManager.default.temporaryDirectory
  ) async {
    let root = rootURL(in: temporaryDirectory)
    await Task.detached(priority: .utility) {
      try? FileManager.default.removeItem(at: root)
    }.value
  }
}
