import AppIntents
import CloudflareAPI
import Foundation
import UIKit

/// AppEntity titles are Cloudflare/user data, not catalog keys. Building the
/// resource at runtime keeps Swift's localization extractor from inventing a
/// universal `%@` entry while preserving DisplayRepresentation's native API.
private func dashIntentVerbatim(_ value: String) -> LocalizedStringResource {
  LocalizedStringResource(stringLiteral: value)
}

/// Surfaced to Siri, Spotlight, and the Shortcuts app. In-app intents run in
/// the app process, so they reuse the app's single `CloudflareClient` (via
/// `@Dependency`) to preserve its single-flight token refresh.
struct DashIntentError: Error, CustomLocalizedStringResourceConvertible {
  let localizedStringResource: LocalizedStringResource

  static let signedOut = DashIntentError(
    localizedStringResource: "Open Dash and sign in to your Cloudflare account first.")

  static let writeAccessRequired = DashIntentError(
    localizedStringResource:
      "Open Dash → Settings → Shortcuts & Share, grant write access, then run this shortcut again."
  )
}

enum DashIntentAuthorization {
  static func hasRequiredScopes(_ required: Set<String>, granted: Set<String>?) -> Bool {
    guard let granted else { return false }
    return required.isSubset(of: granted)
  }

  /// App Intents may start before `AppModel` has restored its observable auth
  /// state. Fall back to the shared Keychain record rather than interpreting a
  /// transient nil as full access and sending a mutation that will 403.
  @MainActor
  static func require(
    _ required: Set<String>,
    model: AppModel
  ) async throws {
    var granted = model.grantedScopes
    if granted == nil {
      granted = try? await KeychainTokenStore().getGrantedScopes()
      if let granted {
        model.grantedScopes = granted
      }
    }
    guard hasRequiredScopes(required, granted: granted) else {
      throw DashIntentError.writeAccessRequired
    }
  }
}

/// A Cloudflare zone, chosen in Shortcuts by name.
struct ZoneEntity: AppEntity, Identifiable {
  let id: String
  let name: String

  static let typeDisplayRepresentation: TypeDisplayRepresentation = "Domain"
  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: dashIntentVerbatim(name))
  }
  static let defaultQuery = ZoneEntityQuery()

  init(id: String, name: String) {
    self.id = id
    self.name = name
  }
  init(zone: CloudflareZone) {
    self.init(id: zone.id, name: zone.name)
  }
}

struct ZoneEntityQuery: EntityStringQuery {
  @Dependency private var model: AppModel

  @MainActor
  private func accountID() throws -> String {
    guard let accountID = model.activeAccountID else { throw DashIntentError.signedOut }
    return accountID
  }

  @MainActor
  func entities(for identifiers: [String]) async throws -> [ZoneEntity] {
    var zones: [ZoneEntity] = []
    for id in identifiers {
      if let zone = try? await model.client.getZone(id) {
        zones.append(ZoneEntity(zone: zone))
      }
    }
    return zones
  }

  @MainActor
  func entities(matching string: String) async throws -> [ZoneEntity] {
    let page = try await model.client.listZones(accountID: try accountID(), name: string)
    return page.items.map(ZoneEntity.init(zone:))
  }

  @MainActor
  func suggestedEntities() async throws -> [ZoneEntity] {
    let accountID = try accountID()
    if let cached: [CloudflareZone] = model.featureCache.get(FeatureCacheKey.zones(accountID)) {
      return cached.map(ZoneEntity.init(zone:))
    }
    let page = try await model.client.listZones(accountID: accountID)
    return page.items.map(ZoneEntity.init(zone:))
  }
}

struct PurgeCacheIntent: AppIntent {
  static let title: LocalizedStringResource = "Purge Cache"
  static let description = IntentDescription("Purge everything from a Cloudflare domain's cache.")

  @Parameter(title: "Domain") var zone: ZoneEntity
  @Dependency private var model: AppModel

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    try await DashIntentAuthorization.require(["cache.purge"], model: model)
    // The non-deprecated requestConfirmation(conditions:actionName:dialog:) is
    // iOS 18+, and the old overload is deprecated unconditionally (no version),
    // so this warns until IPHONEOS_DEPLOYMENT_TARGET reaches 18.0.
    try await requestConfirmation(
      result: .result(dialog: "Purge everything from \(zone.name)'s cache?"))
    try await model.client.purgeCache(zoneID: zone.id, files: nil)
    return .result(dialog: "Purged everything from \(zone.name).")
  }
}

/// Serializes every Under Attack transition for a zone and owns the local
/// restore level. The gate deliberately stays held across Cloudflare reads and
/// writes so two entry points cannot interleave their read-modify-write cycles.
@MainActor
enum ZoneSecurityLevelOperation {
  struct Outcome: Equatable, Sendable {
    let currentLevel: String
    let changed: Bool

    var isUnderAttack: Bool {
      currentLevel == ZoneSecurityLevelOperation.underAttackLevel
    }
  }

  /// Injectable Cloudflare seam used by the production client and focused
  /// concurrency/error tests.
  struct Backend {
    let securityLevelValue: @MainActor (_ zoneID: String) async throws -> JSONValue?
    let updateLevel: @MainActor (_ zoneID: String, _ level: String) async throws -> Void
  }

  private static let keyPrefix = "dash.previous_security_level."
  nonisolated fileprivate static let underAttackLevel = "under_attack"
  private static let fallbackLevel = "medium"
  private static let gate = ZoneSecurityLevelGate()

  static func key(for zoneID: String) -> String {
    "\(keyPrefix)\(zoneID)"
  }

  static func setUnderAttack(
    zoneID: String,
    enabled: Bool,
    client: CloudflareClient,
    defaults: UserDefaults = .standard,
    isCurrent: @escaping @MainActor () -> Bool = { true }
  ) async throws -> Outcome {
    let backend = Backend(
      securityLevelValue: { zoneID in
        let settings = try await client.listZoneSettings(zoneID: zoneID)
        return settings.first(where: { $0.id == "security_level" })?.value
      },
      updateLevel: { zoneID, level in
        _ = try await client.updateZoneSetting(
          zoneID: zoneID,
          settingID: "security_level",
          value: .string(level))
      })

    return try await setUnderAttack(
      zoneID: zoneID,
      enabled: enabled,
      defaults: defaults,
      backend: backend,
      isCurrent: isCurrent)
  }

  static func setUnderAttack(
    zoneID: String,
    enabled: Bool,
    defaults: UserDefaults,
    backend: Backend,
    isCurrent: @escaping @MainActor () -> Bool = { true }
  ) async throws -> Outcome {
    try await gate.withLock(for: zoneID) {
      try checkContinuation(isCurrent)

      let current: String
      guard case .string(let level)? = try await backend.securityLevelValue(zoneID) else {
        throw CloudflareAPIError.invalidResponse
      }
      current = level
      try checkContinuation(isCurrent)

      if enabled {
        guard current != underAttackLevel else {
          return Outcome(currentLevel: current, changed: false)
        }

        defaults.set(current, forKey: key(for: zoneID))
        do {
          try await backend.updateLevel(zoneID, underAttackLevel)
        } catch {
          clearStashAfterDefinitiveFailure(error, zoneID: zoneID, defaults: defaults)
          throw error
        }
        try checkContinuation(isCurrent)
        return Outcome(currentLevel: underAttackLevel, changed: true)
      }

      guard current == underAttackLevel else {
        defaults.removeObject(forKey: key(for: zoneID))
        return Outcome(currentLevel: current, changed: false)
      }

      let restoreLevel = restoreLevel(for: zoneID, defaults: defaults)
      try await backend.updateLevel(zoneID, restoreLevel)
      try checkContinuation(isCurrent)
      defaults.removeObject(forKey: key(for: zoneID))
      return Outcome(currentLevel: restoreLevel, changed: true)
    }
  }

  private static func restoreLevel(for zoneID: String, defaults: UserDefaults) -> String {
    guard let stashed = defaults.string(forKey: key(for: zoneID)),
      stashed != underAttackLevel
    else {
      return fallbackLevel
    }
    return stashed
  }

  private static func checkContinuation(_ isCurrent: @MainActor () -> Bool) throws {
    try Task.checkCancellation()
    guard isCurrent() else { throw CancellationError() }
  }

  private static func clearStashAfterDefinitiveFailure(
    _ error: Error,
    zoneID: String,
    defaults: UserDefaults
  ) {
    guard
      case .request(let status, _) = error as? CloudflareAPIError,
      (400..<500).contains(status)
    else {
      return
    }
    defaults.removeObject(forKey: key(for: zoneID))
  }
}

@MainActor
private final class ZoneSecurityLevelGate {
  @MainActor
  private final class Waiter {
    let id = UUID()
    var continuation: CheckedContinuation<Bool, Never>?
  }

  private var lockedZones: Set<String> = []
  private var waiters: [String: [Waiter]] = [:]

  func withLock<Value>(
    for zoneID: String,
    operation: @MainActor () async throws -> Value
  ) async throws -> Value {
    guard await acquire(for: zoneID) else { throw CancellationError() }
    defer { release(for: zoneID) }
    try Task.checkCancellation()
    return try await operation()
  }

  private func acquire(for zoneID: String) async -> Bool {
    guard lockedZones.contains(zoneID) else {
      guard !Task.isCancelled else { return false }
      lockedZones.insert(zoneID)
      return true
    }

    let waiter = Waiter()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !Task.isCancelled else {
          continuation.resume(returning: false)
          return
        }
        waiter.continuation = continuation
        waiters[zoneID, default: []].append(waiter)
      }
    } onCancel: {
      Task { @MainActor in
        self.cancel(waiter, for: zoneID)
      }
    }
  }

  private func cancel(_ waiter: Waiter, for zoneID: String) {
    guard var queued = waiters[zoneID],
      let index = queued.firstIndex(where: { $0.id == waiter.id })
    else {
      return
    }

    queued.remove(at: index)
    if queued.isEmpty {
      waiters.removeValue(forKey: zoneID)
    } else {
      waiters[zoneID] = queued
    }
    let continuation = waiter.continuation
    waiter.continuation = nil
    continuation?.resume(returning: false)
  }

  private func release(for zoneID: String) {
    while var queued = waiters[zoneID], !queued.isEmpty {
      let waiter = queued.removeFirst()
      if queued.isEmpty {
        waiters.removeValue(forKey: zoneID)
      } else {
        waiters[zoneID] = queued
      }
      guard let continuation = waiter.continuation else { continue }
      waiter.continuation = nil
      continuation.resume(returning: true)
      return
    }
    lockedZones.remove(zoneID)
  }
}

struct SetUnderAttackIntent: AppIntent {
  static let title: LocalizedStringResource = "Set Under Attack Mode"
  static let description = IntentDescription(
    "Turn Under Attack mode on, or restore the previous security level.")

  @Parameter(title: "Domain") var zone: ZoneEntity
  @Parameter(title: "Enabled") var enabled: Bool
  @Dependency private var model: AppModel

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    try await DashIntentAuthorization.require(["zone-settings.write"], model: model)
    let outcome = try await ZoneSecurityLevelOperation.setUnderAttack(
      zoneID: zone.id,
      enabled: enabled,
      client: model.client)
    if outcome.isUnderAttack {
      return .result(dialog: "Under Attack mode is on for \(zone.name).")
    }
    return .result(
      dialog:
        "Security level for \(zone.name) restored to \(displayLevel(outcome.currentLevel)).")
  }

  private func displayLevel(_ level: String) -> String {
    level.replacingOccurrences(of: "_", with: " ").capitalized
  }
}

struct ToggleDevelopmentModeIntent: AppIntent {
  static let title: LocalizedStringResource = "Set Development Mode"
  static let description = IntentDescription(
    "Turn a domain's development mode on or off. Cloudflare auto-disables it after three hours.")

  @Parameter(title: "Domain") var zone: ZoneEntity
  @Parameter(title: "Enabled") var enabled: Bool
  @Dependency private var model: AppModel

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    try await DashIntentAuthorization.require(["zone-settings.write"], model: model)
    _ = try await model.client.updateZoneSetting(
      zoneID: zone.id, settingID: "development_mode", value: .string(enabled ? "on" : "off"))
    return .result(
      dialog: enabled
        ? "Development mode is on for \(zone.name). Cloudflare turns it off automatically after three hours."
        : "Development mode is off for \(zone.name).")
  }
}

/// An R2 bucket selected in Shortcuts. The opaque entity id includes the
/// Cloudflare account so two accounts with the same bucket name can never
/// resolve to whichever account happens to be active when the shortcut runs.
struct R2BucketEntity: AppEntity, Identifiable {
  let accountID: String
  let accountName: String
  let name: String

  var id: String {
    Self.identifier(accountID: accountID, bucketName: name)
  }

  static let typeDisplayRepresentation: TypeDisplayRepresentation = "R2 Bucket"
  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(
      title: dashIntentVerbatim(name),
      subtitle: dashIntentVerbatim(accountName)
    )
  }
  static let defaultQuery = R2BucketEntityQuery()

  init(accountID: String, accountName: String, name: String) {
    self.accountID = accountID
    self.accountName = accountName
    self.name = name
  }

  static func identifier(accountID: String, bucketName: String) -> String {
    "dash-r2-v1.\(encodeIdentifierPart(accountID)).\(encodeIdentifierPart(bucketName))"
  }

  static func decodeIdentifier(_ identifier: String) -> (accountID: String, bucketName: String)? {
    let parts = identifier.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0] == "dash-r2-v1",
      let accountID = decodeIdentifierPart(String(parts[1])),
      let bucketName = decodeIdentifierPart(String(parts[2])),
      !accountID.isEmpty, !bucketName.isEmpty
    else {
      return nil
    }
    return (accountID, bucketName)
  }

  private static func encodeIdentifierPart(_ value: String) -> String {
    Data(value.utf8).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func decodeIdentifierPart(_ value: String) -> String? {
    var base64 =
      value
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let remainder = base64.count % 4
    if remainder != 0 {
      base64 += String(repeating: "=", count: 4 - remainder)
    }
    guard let data = Data(base64Encoded: base64) else { return nil }
    return String(data: data, encoding: .utf8)
  }
}

struct R2BucketEntityQuery: EntityStringQuery {
  @Dependency private var model: AppModel

  @MainActor
  private func activeAccount() throws -> CloudflareAccount {
    guard let account = model.activeAccount else { throw DashIntentError.signedOut }
    return account
  }

  @MainActor
  func entities(for identifiers: [String]) async throws -> [R2BucketEntity] {
    try identifiers.map { identifier in
      guard let decoded = R2BucketEntity.decodeIdentifier(identifier) else {
        throw DashIntentError(
          localizedStringResource:
            "This shortcut uses an older unscoped bucket. Edit it and choose the R2 bucket again.")
      }
      let accountName =
        model.accounts.first(where: { $0.id == decoded.accountID })?.name
        ?? "Account \(decoded.accountID)"
      return R2BucketEntity(
        accountID: decoded.accountID,
        accountName: accountName,
        name: decoded.bucketName)
    }
  }

  @MainActor
  func entities(matching string: String) async throws -> [R2BucketEntity] {
    try await all().filter { $0.name.localizedCaseInsensitiveContains(string) }
  }

  @MainActor
  func suggestedEntities() async throws -> [R2BucketEntity] {
    try await all()
  }

  @MainActor
  private func all() async throws -> [R2BucketEntity] {
    let account = try activeAccount()
    let accountID = account.id
    if let cached: [R2Bucket] = model.featureCache.get(FeatureCacheKey.r2Buckets(accountID)) {
      return cached.map {
        R2BucketEntity(accountID: accountID, accountName: account.name, name: $0.name)
      }
    }
    return try await model.client.listR2Buckets(accountID: accountID)
      .map { R2BucketEntity(accountID: accountID, accountName: account.name, name: $0.name) }
  }
}

struct UploadToR2Intent: AppIntent {
  static let title: LocalizedStringResource = "Upload to R2"
  static let description = IntentDescription(
    "Upload a file to an R2 bucket. Copies the public URL when the bucket has one.")

  @Parameter(title: "File") var file: IntentFile
  /// Optional on purpose: without it the intent reuses the last destination
  /// the user uploaded to (in-app or via the share sheet).
  @Parameter(title: "Bucket") var bucket: R2BucketEntity?
  @Parameter(title: "Folder") var folder: String?
  @Dependency private var model: AppModel

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    guard let context = model.accountRequestContext else { throw DashIntentError.signedOut }
    try await DashIntentAuthorization.require(
      R2ShareDestination.requiredWriteScopes,
      model: model)
    let accountID = context.accountID
    let remembered = R2ShareDestination.destination(accountID: accountID)
    if let bucket, bucket.accountID != accountID {
      throw DashIntentError(
        localizedStringResource:
          "This shortcut targets \(bucket.accountName). Switch to that account in Dash or choose a bucket from the active account."
      )
    }
    guard let bucketName = bucket?.name ?? remembered?.bucket else {
      throw DashIntentError(
        localizedStringResource:
          "Pick a bucket — Dash has no remembered R2 destination for this account yet.")
    }
    let accountName = bucket?.accountName ?? model.activeAccount?.name ?? "Account \(accountID)"
    let rawFolder =
      folder ?? remembered.flatMap { $0.bucket == bucketName ? $0.prefix : nil } ?? ""
    let prefix = Self.normalizedPrefix(rawFolder)
    let key = prefix + file.filename

    try await requestConfirmation(
      result: .result(
        dialog: "Upload \(file.filename) to \(bucketName) in \(accountName)?"))
    guard model.isCurrentAccount(context) else {
      throw DashIntentError(
        localizedStringResource:
          "The active account changed before the upload started. Run the shortcut again.")
    }

    let inputFileURL = file.fileURL
    let accessesSecurityScope = inputFileURL?.startAccessingSecurityScopedResource() ?? false
    defer {
      if accessesSecurityScope {
        inputFileURL?.stopAccessingSecurityScopedResource()
      }
    }

    let uploadURL: URL
    let ownedTemporaryFile: R2TemporaryFile?
    if let fileURL = inputFileURL {
      guard let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
        throw DashIntentError(localizedStringResource: "Dash can't read \(file.filename).")
      }
      guard size <= R2Media.transferSizeLimit else {
        throw DashIntentError(
          localizedStringResource: "\(file.filename) is over the 100 MB upload limit.")
      }
      uploadURL = fileURL
      ownedTemporaryFile = nil
    } else {
      // IntentFile can also be constructed from Data. Materialize that rare
      // representation off the main actor, while the common file-backed path
      // stays zero-copy.
      let data = file.data
      guard data.count <= R2Media.transferSizeLimit else {
        throw DashIntentError(
          localizedStringResource: "\(file.filename) is over the 100 MB upload limit.")
      }
      let temporaryFile = R2TemporaryFile.make(
        purpose: "r2-intent-upload", filename: file.filename)
      try await temporaryFile.write(data)
      uploadURL = temporaryFile.fileURL
      ownedTemporaryFile = temporaryFile
    }
    defer { ownedTemporaryFile?.remove() }

    guard model.isCurrentAccount(context) else {
      throw DashIntentError(
        localizedStringResource:
          "The active account changed before the upload started. Run the shortcut again.")
    }
    try await model.client.putR2Object(
      accountID: accountID, bucket: bucketName, key: key, fileURL: uploadURL,
      contentType: file.type?.preferredMIMEType ?? R2Media.mimeType(forKey: key))
    guard model.isCurrentAccount(context) else {
      throw DashIntentError(
        localizedStringResource:
          "The active account changed before the upload finished.")
    }
    model.featureCache.remove(
      prefix: FeatureCacheKey.r2ObjectsPrefix(accountID: accountID, bucket: bucketName))
    let host: String? = {
      let snapshot: R2DomainsSnapshot? = model.featureCache.get(
        FeatureCacheKey.r2Domains(accountID: accountID, bucket: bucketName))
      if let host = snapshot?.publicHost { return host }
      if let remembered, remembered.bucket == bucketName, !remembered.publicHost.isEmpty {
        return remembered.publicHost
      }
      return nil
    }()
    R2ShareDestination.record(
      R2ShareDestination(
        accountID: accountID, bucket: bucketName, prefix: prefix, publicHost: host ?? ""))
    if let host, let url = R2DomainsSnapshot.url(host: host, key: key) {
      UIPasteboard.general.url = url
      return .result(
        dialog:
          "Uploaded \(file.filename) to \(bucketName) in \(accountName) — public URL copied.")
    }
    return .result(dialog: "Uploaded \(file.filename) to \(bucketName) in \(accountName).")
  }

  /// Pure: "/a/b" and "a/b/" both become "a/b/"; empty stays empty.
  static func normalizedPrefix(_ raw: String) -> String {
    var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    while value.hasPrefix("/") { value.removeFirst() }
    if !value.isEmpty && !value.hasSuffix("/") { value += "/" }
    return value
  }
}

struct OpenWatchtowerIntent: AppIntent {
  static let title: LocalizedStringResource = "Open Watchtower"
  static let description = IntentDescription("Open the Watchtower tab in Dash.")
  static let openAppWhenRun = true

  @Dependency private var model: AppModel

  @MainActor
  func perform() async throws -> some IntentResult {
    guard let accountID = model.activeAccountID else { throw DashIntentError.signedOut }
    model.pendingRoute = DashRoute.watchtower.scoped(to: accountID)
    return .result()
  }
}

struct DashShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: PurgeCacheIntent(),
      phrases: ["Purge cache with \(.applicationName)"],
      shortTitle: "Purge Cache",
      systemImageName: "trash")
    AppShortcut(
      intent: SetUnderAttackIntent(),
      phrases: ["Set under attack mode in \(.applicationName)"],
      shortTitle: "Under Attack Mode",
      systemImageName: "shield.lefthalf.filled")
    AppShortcut(
      intent: ToggleDevelopmentModeIntent(),
      phrases: ["Set development mode in \(.applicationName)"],
      shortTitle: "Development Mode",
      systemImageName: "hammer")
    AppShortcut(
      intent: OpenWatchtowerIntent(),
      phrases: ["Open Watchtower in \(.applicationName)"],
      shortTitle: "Open Watchtower",
      systemImageName: "binoculars")
    AppShortcut(
      intent: UploadToR2Intent(),
      phrases: ["Upload to R2 with \(.applicationName)"],
      shortTitle: "Upload to R2",
      systemImageName: "arrow.up.circle")
  }
}
