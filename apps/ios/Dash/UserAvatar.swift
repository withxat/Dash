import CryptoKit
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum Gravatar {
  static func normalize(_ email: String) -> String {
    email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  static func url(for email: String, size: Int) -> URL? {
    let normalized = normalize(email)
    guard !normalized.isEmpty else { return nil }
    let digest = Insecure.MD5.hash(data: Data(normalized.utf8))
    let hash = digest.map { String(format: "%02x", $0) }.joined()
    return URL(string: "https://www.gravatar.com/avatar/\(hash)?s=\(size)&d=404")
  }

}

enum CustomAvatarError: Error, Equatable, Sendable {
  case invalidImage
  case backupExclusionFailed
}

enum CustomAvatarLoadResult: Equatable, Sendable {
  case missing
  case unavailable
  case loaded(Data)
}

/// On-device persistence for the user's optional Dash profile photo. The
/// Cloudflare user id is hashed before it reaches the file system, and every
/// imported image is decoded, centre-cropped, scaled and re-encoded so the
/// stored copy contains no source metadata.
actor CustomAvatarFileStore {
  struct PreparedImage: Sendable {
    fileprivate let data: Data
  }

  static let maximumPixelSize = 512
  private static let thumbnailPixelSize = maximumPixelSize * 2

  private let directoryURL: URL
  private let dataReader: @Sendable (URL) throws -> Data
  private let backupExcluder: @Sendable (URL) throws -> Void

  init(
    directoryURL: URL? = nil,
    dataReader: @escaping @Sendable (URL) throws -> Data = {
      try Data(contentsOf: $0, options: .mappedIfSafe)
    },
    backupExcluder: @escaping @Sendable (URL) throws -> Void = {
      try CustomAvatarFileStore.excludeFromBackup($0)
    }
  ) {
    self.directoryURL = directoryURL ?? Self.defaultDirectoryURL
    self.dataReader = dataReader
    self.backupExcluder = backupExcluder
  }

  func loadImage(for userID: String) -> CustomAvatarLoadResult {
    guard !userID.isEmpty else { return .missing }
    let url = fileURL(for: userID)
    guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
    let data: Data
    do {
      data = try dataReader(url)
    } catch {
      // Complete file protection can make the image temporarily unavailable
      // while the phone is locked. Keep the file and retry in the foreground.
      return .unavailable
    }
    guard Self.isValidStoredImageData(data) else {
      try? FileManager.default.removeItem(at: url)
      return .missing
    }
    return .loaded(data)
  }

  @discardableResult
  func saveImage(from sourceURL: URL, for userID: String) throws -> Data {
    let image = try Self.prepareImage(from: sourceURL)
    return try savePreparedImage(image, for: userID)
  }

  @discardableResult
  func savePreparedImage(_ image: PreparedImage, for userID: String) throws -> Data {
    let data = image.data
    guard !userID.isEmpty, Self.isValidStoredImageData(data) else {
      throw CustomAvatarError.invalidImage
    }
    try Task.checkCancellation()
    try prepareDirectory()
    let destination = fileURL(for: userID)
    let candidate = directoryURL.appendingPathComponent(
      ".pending-\(UUID().uuidString)",
      isDirectory: false)
    defer { try? FileManager.default.removeItem(at: candidate) }
    try data.write(to: candidate, options: [.atomic, .completeFileProtection])
    do {
      try backupExcluder(candidate)
    } catch {
      throw CustomAvatarError.backupExclusionFailed
    }
    try Task.checkCancellation()
    if FileManager.default.fileExists(atPath: destination.path) {
      _ = try FileManager.default.replaceItemAt(destination, withItemAt: candidate)
    } else {
      try FileManager.default.moveItem(at: candidate, to: destination)
    }
    return data
  }

  func removeImage(for userID: String) throws {
    guard !userID.isEmpty else { return }
    try Task.checkCancellation()
    let url = fileURL(for: userID)
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.removeItem(at: url)
  }

  private static var defaultDirectoryURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Dash", isDirectory: true)
      .appendingPathComponent("ProfileAvatars", isDirectory: true)
      .appendingPathComponent("v1", isDirectory: true)
  }

  private func fileURL(for userID: String) -> URL {
    let digest = SHA256.hash(data: Data(userID.utf8))
    let filename = digest.map { String(format: "%02x", $0) }.joined()
    return directoryURL.appendingPathComponent(filename).appendingPathExtension("png")
  }

  private func prepareDirectory() throws {
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true,
      attributes: [.protectionKey: FileProtectionType.complete])
    try FileManager.default.setAttributes(
      [.protectionKey: FileProtectionType.complete],
      ofItemAtPath: directoryURL.path)
    do {
      try backupExcluder(directoryURL)
    } catch {
      throw CustomAvatarError.backupExclusionFailed
    }
  }

  private static func excludeFromBackup(_ url: URL) throws {
    var resourceValues = URLResourceValues()
    resourceValues.isExcludedFromBackup = true
    var mutableURL = url
    try mutableURL.setResourceValues(resourceValues)
    guard
      try mutableURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        == true
    else {
      throw CustomAvatarError.backupExclusionFailed
    }
  }

  static func prepareImage(from sourceURL: URL) throws -> PreparedImage {
    try Task.checkCancellation()
    guard
      let source = CGImageSourceCreateWithURL(
        sourceURL as CFURL,
        [kCGImageSourceShouldCache: false] as CFDictionary),
      let thumbnail = CGImageSourceCreateThumbnailAtIndex(
        source,
        0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceShouldCacheImmediately: true,
          kCGImageSourceThumbnailMaxPixelSize: Self.thumbnailPixelSize,
        ] as CFDictionary)
    else {
      throw CustomAvatarError.invalidImage
    }
    try Task.checkCancellation()

    let cropSide = min(thumbnail.width, thumbnail.height)
    let cropRect = CGRect(
      x: CGFloat(thumbnail.width - cropSide) / 2,
      y: CGFloat(thumbnail.height - cropSide) / 2,
      width: CGFloat(cropSide),
      height: CGFloat(cropSide))
    guard cropSide > 0, let cropped = thumbnail.cropping(to: cropRect) else {
      throw CustomAvatarError.invalidImage
    }

    let outputSide = min(cropSide, Self.maximumPixelSize)
    guard
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil,
        width: outputSide,
        height: outputSide,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else {
      throw CustomAvatarError.invalidImage
    }
    context.interpolationQuality = .high
    context.draw(
      cropped,
      in: CGRect(x: 0, y: 0, width: CGFloat(outputSide), height: CGFloat(outputSide)))
    guard let rendered = context.makeImage() else {
      throw CustomAvatarError.invalidImage
    }

    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        output, UTType.png.identifier as CFString, 1, nil)
    else {
      throw CustomAvatarError.invalidImage
    }
    CGImageDestinationAddImage(destination, rendered, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw CustomAvatarError.invalidImage
    }
    try Task.checkCancellation()
    return PreparedImage(data: output as Data)
  }

  private static func isValidStoredImageData(_ data: Data) -> Bool {
    guard
      let source = CGImageSourceCreateWithData(
        data as CFData,
        [
          kCGImageSourceShouldCache: false
        ] as CFDictionary),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return false }
    return image.width == image.height && image.width <= maximumPixelSize
      && image.height <= maximumPixelSize
  }
}

/// Session-scoped in-memory avatar cache shared by every `UserAvatar`.
/// A locally selected profile photo wins over Gravatar, while the existing
/// initials remain the final fallback. Disk storage is user-scoped and
/// persists across sign-out; clearing a session only drops decoded bitmaps.
@MainActor
@Observable
final class AvatarStore {
  /// Pixels requested from Gravatar — covers the largest rendering
  /// (80 pt at 3×) so every smaller avatar shares one bitmap.
  private static let canonicalPixelSize = 240

  private enum GravatarEntry {
    /// Gravatar answered 404: the user has no avatar. Definitive — the
    /// initials fallback is the right rendering, not a failure to heal.
    case missing
    case loaded(UIImage)
  }

  private enum CustomEntry {
    case missing
    case loaded(UIImage)
  }

  private var gravatarEntries: [String: GravatarEntry] = [:]
  private var customEntries: [String: CustomEntry] = [:]
  private var gravatarInFlight = Set<String>()
  private var customInFlight = Set<String>()
  private var customRevisions: [String: UInt64] = [:]
  private var requestedCustomEmails: [String: String] = [:]
  /// Every email ever asked for, so foregrounding can retry transient misses
  /// on behalf of long-lived views whose `.task` already ran.
  private var requestedGravatars = Set<String>()
  private var generation: UInt64 = 0
  private let session: URLSession
  private let customFiles: CustomAvatarFileStore

  init(
    session: URLSession? = nil,
    customFiles: CustomAvatarFileStore = CustomAvatarFileStore()
  ) {
    self.session =
      session
      ?? {
        // Waiting for connectivity lets the one request complete late on a
        // flaky connection instead of failing fast and stranding the avatar.
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
      }()
    self.customFiles = customFiles
    NotificationCenter.default.addObserver(
      forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.retryMissing() }
    }
  }

  func image(userID: String?, email: String) -> UIImage? {
    if let userID, case .loaded(let image)? = customEntries[userID] {
      return image
    }
    guard
      case .loaded(let image)? = gravatarEntries[Gravatar.normalize(email)]
    else { return nil }
    return image
  }

  func hasCustomImage(for userID: String?) -> Bool {
    guard let userID, case .loaded? = customEntries[userID] else { return false }
    return true
  }

  /// Resolves the local user-scoped image before considering Gravatar. Safe to
  /// call from every avatar's `.task`; all three profile surfaces observe the
  /// same store and update together.
  func ensureLoaded(userID: String?, email: String) {
    guard let userID, !userID.isEmpty else {
      ensureGravatarLoaded(email)
      return
    }
    requestedCustomEmails[userID] = email
    switch customEntries[userID] {
    case .loaded?:
      return
    case .missing?:
      ensureGravatarLoaded(email)
    case nil:
      loadCustomImage(userID: userID, email: email)
    }
  }

  func setCustomImage(_ image: CustomAvatarFileStore.PreparedImage, for userID: String)
    async throws
  {
    let requestGeneration = generation
    let revision = beginCustomOperation(for: userID)
    let data: Data
    do {
      data = try await customFiles.savePreparedImage(image, for: userID)
    } catch {
      recoverCustomLoadIfNeeded(
        userID: userID, generation: requestGeneration, revision: revision)
      throw error
    }
    guard let image = UIImage(data: data) else { throw CustomAvatarError.invalidImage }
    guard requestGeneration == generation, customRevisions[userID] == revision
    else { throw CancellationError() }
    customEntries[userID] = .loaded(image)
  }

  func removeCustomImage(for userID: String, email: String) async throws {
    let requestGeneration = generation
    let revision = beginCustomOperation(for: userID)
    do {
      try await customFiles.removeImage(for: userID)
    } catch {
      recoverCustomLoadIfNeeded(
        userID: userID, generation: requestGeneration, revision: revision)
      throw error
    }
    guard requestGeneration == generation, customRevisions[userID] == revision
    else { throw CancellationError() }
    customEntries[userID] = .missing
    ensureGravatarLoaded(email)
  }

  func clearMemory() {
    generation &+= 1
    gravatarEntries = [:]
    customEntries = [:]
    gravatarInFlight = []
    customInFlight = []
    customRevisions = [:]
    requestedCustomEmails = [:]
    requestedGravatars = []
  }

  private func loadCustomImage(userID: String, email: String) {
    guard !customInFlight.contains(userID) else { return }
    let requestGeneration = generation
    let revision = nextCustomRevision(for: userID)
    customInFlight.insert(userID)
    Task {
      let result = await customFiles.loadImage(for: userID)
      guard requestGeneration == generation, customRevisions[userID] == revision
      else { return }
      customInFlight.remove(userID)
      switch result {
      case .loaded(let data):
        if let image = UIImage(data: data) {
          customEntries[userID] = .loaded(image)
        } else {
          customEntries[userID] = .missing
          ensureGravatarLoaded(email)
        }
      case .missing:
        customEntries[userID] = .missing
        ensureGravatarLoaded(email)
      case .unavailable:
        // Keep the local state unresolved so foregrounding can retry after
        // protected data becomes accessible. Gravatar remains a safe fallback.
        ensureGravatarLoaded(email)
      }
    }
  }

  private func beginCustomOperation(for userID: String) -> UInt64 {
    customInFlight.remove(userID)
    return nextCustomRevision(for: userID)
  }

  private func nextCustomRevision(for userID: String) -> UInt64 {
    let revision = (customRevisions[userID] ?? 0) &+ 1
    customRevisions[userID] = revision
    return revision
  }

  private func recoverCustomLoadIfNeeded(
    userID: String,
    generation requestGeneration: UInt64,
    revision: UInt64
  ) {
    guard requestGeneration == generation, customRevisions[userID] == revision,
      let email = requestedCustomEmails[userID]
    else { return }
    customEntries[userID] = nil
    loadCustomImage(userID: userID, email: email)
  }

  /// Kicks off a Gravatar fetch unless one already resolved or is running.
  /// A transient failure leaves the entry absent so returning to the
  /// foreground can retry it.
  private func ensureGravatarLoaded(_ email: String) {
    let key = Gravatar.normalize(email)
    guard !key.isEmpty, gravatarEntries[key] == nil, !gravatarInFlight.contains(key),
      let url = Gravatar.url(for: key, size: Self.canonicalPixelSize)
    else { return }
    let requestGeneration = generation
    requestedGravatars.insert(key)
    gravatarInFlight.insert(key)
    Task {
      let result = try? await session.data(from: url)
      guard requestGeneration == generation else { return }
      gravatarInFlight.remove(key)
      guard let (data, response) = result,
        let status = (response as? HTTPURLResponse)?.statusCode
      else { return }
      if status == 404 {
        gravatarEntries[key] = .missing
      } else if status == 200, let image = UIImage(data: data) {
        gravatarEntries[key] = .loaded(image)
      }
    }
  }

  private func retryMissing() {
    for (userID, email) in requestedCustomEmails where customEntries[userID] == nil {
      loadCustomImage(userID: userID, email: email)
    }
    for email in requestedGravatars where gravatarEntries[email] == nil {
      ensureGravatarLoaded(email)
    }
  }
}

enum AvatarHeaderMetrics {
  /// Matches UIKit minimal back-button slot width on iOS.
  static let barSize: CGFloat = 44
  static let titleSize: CGFloat = 34
  /// Floated header chrome inset (avatar / inbox / editor). Toast tops use the
  /// same value so they share the avatar's top edge numerically.
  static let chromeInset: CGFloat = 10
}

/// The profile circle, in three layers: a locally chosen photo, then Gravatar,
/// then initials.
///
/// The first two are keyed to the **person** — the photo by Cloudflare user id,
/// Gravatar by the email's hash — because that is what they are. The initials
/// fallback is keyed to the **active account** instead, so switching accounts
/// visibly changes it: one user can own several accounts, every other profile
/// surface already names the active one (`AppModel.profileTitle`), and the
/// header button has always announced it to VoiceOver. A person with a photo
/// still sees the same photo everywhere — the letter is the only layer with a
/// free slot to say which account you are in.
struct UserAvatar: View {
  @Environment(AppModel.self) private var model
  let email: String
  var size: CGFloat = 32

  var body: some View {
    let userID = model.user?.id
    avatarContent
      .frame(width: size, height: size)
      .clipShape(Circle())
      // Flatten the circular clip so nav-bar transition snapshots don't briefly
      // reveal the underlying square Gravatar bitmap.
      .compositingGroup()
      .overlay { Circle().stroke(DashTheme.line, lineWidth: 0.5) }
      .contentShape(Circle())
      .task(id: "\(userID ?? ""):\(Gravatar.normalize(email))") {
        model.avatars.ensureLoaded(userID: userID, email: email)
      }
  }

  @ViewBuilder
  private var avatarContent: some View {
    if let image = model.avatars.image(userID: model.user?.id, email: email) {
      Image(uiImage: image).resizable().scaledToFill()
    } else {
      initialsFallback
    }
  }

  private var initialsFallback: some View {
    Circle()
      .fill(DashTheme.accent)
      .overlay {
        Text(Self.initial(for: initialSubject))
          .font(.system(size: size * 0.4, weight: .bold))
          .foregroundStyle(DashTheme.inverse)
      }
  }

  /// The active account's name, or the email while identity is still loading
  /// and there is no account to name yet.
  private var initialSubject: String {
    let name =
      model.activeAccount?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return name.isEmpty ? email : name
  }

  private static func initial(for subject: String) -> String {
    let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let first = trimmed.first else { return "?" }
    return String(first).uppercased()
  }
}

/// Tab-root profile control — same 44pt circle as the native back-button slot.
struct HeaderProfileAvatar: View {
  let email: String

  var body: some View {
    UserAvatar(email: email, size: AvatarHeaderMetrics.barSize)
  }
}
