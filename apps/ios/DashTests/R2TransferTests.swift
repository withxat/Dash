import CloudflareAPI
import Foundation
import Testing

@testable import Dash

private func r2Object(
  key: String = "folder/object.bin", size: Int? = 42, etag: String? = "abc",
  uploaded: String? = "2026-07-24T08:00:00Z"
) throws -> R2Object {
  var object: [String: Any] = ["key": key]
  if let size { object["size"] = size }
  if let etag { object["etag"] = etag }
  if let uploaded { object["last_modified"] = uploaded }
  return try JSONDecoder().decode(
    R2Object.self, from: JSONSerialization.data(withJSONObject: object))
}

@Test func r2TransferLimitAcceptsUnknownAndBoundarySizes() {
  #expect(R2Media.isWithinTransferLimit(nil))
  #expect(R2Media.isWithinTransferLimit(R2Media.transferSizeLimit))
  #expect(!R2Media.isWithinTransferLimit(R2Media.transferSizeLimit + 1))
}

@Test func r2TemporaryFileUsesASanitizedLeafAndOwnDirectory() {
  let scratch = R2TemporaryFile.make(
    purpose: "dash-r2-tests",
    filename: "../../nested/object.json")
  defer { scratch.remove() }

  #expect(scratch.fileURL.lastPathComponent == "object.json")
  #expect(scratch.fileURL.deletingLastPathComponent() == scratch.directoryURL)
  #expect(scratch.directoryURL.lastPathComponent != "dash-r2-tests")
  #expect(scratch.directoryURL.deletingLastPathComponent().lastPathComponent == "dash-r2-tests")
  #expect(
    scratch.directoryURL.deletingLastPathComponent().deletingLastPathComponent()
      .lastPathComponent == "dash-r2")
}

@Test func r2TemporaryFileWritesAndRemovesItsOperationDirectory() async throws {
  let scratch = R2TemporaryFile.make(
    purpose: "dash-r2-tests",
    filename: "payload.bin")
  let payload = Data((0..<4_096).map { UInt8($0 % 251) })

  try await scratch.write(payload)
  #expect(FileManager.default.fileExists(atPath: scratch.fileURL.path))
  #expect(try Data(contentsOf: scratch.fileURL) == payload)

  scratch.remove()
  #expect(!FileManager.default.fileExists(atPath: scratch.directoryURL.path))
}

@Test func r2TemporaryFileExplicitCleanupRemovesOnlyItsDedicatedRoot() async throws {
  let sandbox = FileManager.default.temporaryDirectory
    .appending(path: "dash-r2-cleanup-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
  defer { try? FileManager.default.removeItem(at: sandbox) }
  let r2Root = sandbox.appending(path: "dash-r2", directoryHint: .isDirectory)
  let operation =
    r2Root
    .appending(path: "preview", directoryHint: .isDirectory)
    .appending(path: UUID().uuidString, directoryHint: .isDirectory)
  let sibling = sandbox.appending(path: "keep", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: operation, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
  try Data("payload".utf8).write(to: operation.appending(path: "object.bin"))

  await R2TemporaryFile.removeAllFiles(in: sandbox)

  #expect(!FileManager.default.fileExists(atPath: r2Root.path))
  #expect(FileManager.default.fileExists(atPath: sibling.path))
}

@Test func r2ThumbnailVersionFallsBackToObjectMetadataWhenETagIsMissing() throws {
  let original = try r2Object(size: 42, etag: nil, uploaded: "2026-07-24T08:00:00Z")
  let resized = try r2Object(size: 43, etag: nil, uploaded: "2026-07-24T08:00:00Z")
  let replaced = try r2Object(size: 42, etag: nil, uploaded: "2026-07-24T09:00:00Z")
  let tagged = try r2Object(size: 42, etag: "version-1", uploaded: nil)

  #expect(R2Media.versionToken(for: original) != R2Media.versionToken(for: resized))
  #expect(R2Media.versionToken(for: original) != R2Media.versionToken(for: replaced))
  #expect(R2Media.versionToken(for: tagged) == "etag:version-1")
}

@Test func r2BucketRequestIdentityChangesWithAccountGenerationAndLocation() {
  let original = R2BucketRequestIdentity(
    context: AccountRequestContext(accountID: "account-a", generation: 1),
    bucket: "assets",
    folderPrefix: "images/")

  #expect(
    original
      != R2BucketRequestIdentity(
        context: AccountRequestContext(accountID: "account-a", generation: 2),
        bucket: "assets",
        folderPrefix: "images/"))
  #expect(
    original
      != R2BucketRequestIdentity(
        context: AccountRequestContext(accountID: "account-b", generation: 1),
        bucket: "assets",
        folderPrefix: "images/"))
  #expect(
    original
      != R2BucketRequestIdentity(
        context: original.context,
        bucket: "archive",
        folderPrefix: "images/"))
  #expect(
    original
      != R2BucketRequestIdentity(
        context: original.context,
        bucket: "assets",
        folderPrefix: "videos/"))
}

@Test func r2ThumbnailRequestIdentityScopesVersionToAccountAndObject() {
  let original = R2ThumbnailRequestIdentity(
    context: AccountRequestContext(accountID: "account-a", generation: 1),
    bucket: "assets",
    objectKey: "images/hero.png",
    version: "etag:v1")

  #expect(
    original
      != R2ThumbnailRequestIdentity(
        context: AccountRequestContext(accountID: "account-a", generation: 2),
        bucket: "assets",
        objectKey: "images/hero.png",
        version: "etag:v1"))
  #expect(
    original
      != R2ThumbnailRequestIdentity(
        context: original.context,
        bucket: "assets",
        objectKey: "images/card.png",
        version: "etag:v1"))
  #expect(
    original
      != R2ThumbnailRequestIdentity(
        context: original.context,
        bucket: "assets",
        objectKey: "images/hero.png",
        version: "etag:v2"))
}
