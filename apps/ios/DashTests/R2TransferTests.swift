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

@Test func r2FolderPathNormalizesEveryWayAFolderCanBeWritten() {
  #expect(R2FolderPath.normalized("") == "")
  #expect(R2FolderPath.normalized("   ") == "")
  #expect(R2FolderPath.normalized("/images/covers") == "images/covers/")
  #expect(R2FolderPath.normalized("images/covers/") == "images/covers/")
  #expect(R2FolderPath.normalized("images") == "images/")
  // Same rule as the Shortcuts intent, which now shares this implementation.
  #expect(R2FolderPath.normalized("/a/b") == UploadToR2Intent.normalizedPrefix("/a/b"))
}

@Test func r2FolderPathLabelsAFolderByItsWholePathWithoutTheSeparator() {
  #expect(R2FolderPath.label(for: "images/covers/") == "images/covers")
  #expect(R2FolderPath.label(for: "images/") == "images")
  #expect(R2FolderPath.label(for: "") == "")
}

@Test func r2FolderPathTrailWalksBackUpAndKeepsEmptySegments() {
  #expect(R2FolderPath.trail(of: "") == [])
  #expect(R2FolderPath.trail(of: "images/") == ["images/"])
  #expect(
    R2FolderPath.trail(of: "images/covers/2026/") == [
      "images/", "images/covers/", "images/covers/2026/",
    ])
  // `a//b/` is a real, different key prefix — collapsing it would offer a
  // folder the bucket does not have.
  #expect(R2FolderPath.trail(of: "a//b/") == ["a/", "a//", "a//b/"])
}

@Test func r2FolderPathDestinationsOfferThePathDownPlusItsOwnFolders() {
  #expect(
    R2FolderPath.destinations(prefix: "", children: ["images/", "logs/"]) == ["images/", "logs/"])
  #expect(
    R2FolderPath.destinations(prefix: "images/", children: ["images/covers/"])
      == ["images/", "images/covers/"])
  // The chosen prefix changes a frame before its listing arrives: the previous
  // level's siblings must not pose as this level's folders.
  #expect(
    R2FolderPath.destinations(prefix: "images/", children: ["images/", "logs/"]) == ["images/"])
  // No duplicate rows when a listing repeats a folder already on the path.
  #expect(
    R2FolderPath.destinations(prefix: "images/covers/", children: ["images/covers/"])
      == ["images/", "images/covers/"])
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

@MainActor
@Test func r2BucketUploadWorkSurvivesDeeperRoutesAndCancelsOnPop() async throws {
  let navigator = DestinationNavigator(accountID: "account-a")
  let bucketEntryID = try #require(
    navigator.push(.r2Bucket("assets", prefix: "")))
  let work = R2BucketWork()
  let upload = longRunningR2TestTask()
  work.upload = upload
  work.retainUploadWhileRouteExists(in: navigator, entryID: bucketEntryID)

  navigator.push(.r2Bucket("assets", prefix: "images/"))
  await settleR2RouteObservation()
  #expect(!upload.isCancelled)
  #expect(work.upload != nil)

  navigator.pop()
  await settleR2RouteObservation()
  #expect(!upload.isCancelled)
  #expect(work.upload != nil)

  navigator.pop()
  let cancelled = await waitForR2RouteCancellation(upload: upload, work: work)
  #expect(cancelled)
  #expect(work.upload == nil)
}

@MainActor
@Test func r2BucketUploadWorkCancelsWhenHiddenResourceIsPruned() async throws {
  let navigator = DestinationNavigator(accountID: "account-a")
  navigator.push(.feature(.r2))
  let bucketEntryID = try #require(
    navigator.push(.r2Bucket("assets", prefix: "")))
  navigator.push(.r2Bucket("assets", prefix: "images/"))
  navigator.push(.about)
  let work = R2BucketWork()
  let upload = longRunningR2TestTask()
  work.upload = upload
  work.retainUploadWhileRouteExists(in: navigator, entryID: bucketEntryID)

  navigator.removeAll(ownedBy: .r2Bucket("assets"))
  let cancelled = await waitForR2RouteCancellation(upload: upload, work: work)

  #expect(cancelled)
  #expect(work.upload == nil)
  #expect(navigator.path == [.feature(.r2), .about])
}

@MainActor
@Test func r2BucketUploadWorkCancelsWhenAccountScopeResetsRoutes() async throws {
  let navigator = DestinationNavigator(accountID: "account-a")
  let bucketEntryID = try #require(
    navigator.push(.r2Bucket("assets", prefix: "")))
  let work = R2BucketWork()
  let upload = longRunningR2TestTask()
  work.upload = upload
  work.retainUploadWhileRouteExists(in: navigator, entryID: bucketEntryID)

  navigator.setAccountScope("account-b")
  let cancelled = await waitForR2RouteCancellation(upload: upload, work: work)

  #expect(cancelled)
  #expect(work.upload == nil)
  #expect(navigator.depth == 0)
}

@MainActor
private func longRunningR2TestTask() -> Task<Void, Never> {
  Task {
    do {
      try await Task.sleep(for: .seconds(30))
    } catch {
      // Cancellation is the result under test.
    }
  }
}

@MainActor
private func settleR2RouteObservation() async {
  for _ in 0..<8 { await Task.yield() }
}

@MainActor
private func waitForR2RouteCancellation(
  upload: Task<Void, Never>,
  work: R2BucketWork
) async -> Bool {
  for _ in 0..<32 {
    if upload.isCancelled, work.upload == nil { return true }
    await Task.yield()
  }
  return upload.isCancelled && work.upload == nil
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
