import CloudflareAPI
import SwiftUI
import Testing
import UIKit

@testable import Dash

@Test func configurationRejectsUnexpandedBuildSettings() {
  #expect(
    !AppConfiguration(clientID: "$(DASH_CLIENT_ID)", redirectURI: "$(DASH_REDIRECT_URI)")
      .isConfigured)
}

@Test func appLanguageResolvesStoredPreference() {
  #expect(DashAppLanguage.resolved(stored: "system") == .system)
  #expect(DashAppLanguage.resolved(stored: "en") == .english)
  #expect(DashAppLanguage.resolved(stored: "zh-Hans") == .simplifiedChinese)
  #expect(DashAppLanguage.resolved(stored: "nope") == .system)
  #expect(DashAppLanguage.english.localeIdentifier == "en")
  #expect(DashAppLanguage.simplifiedChinese.localeIdentifier == "zh-Hans")
  #expect(DashAppLanguage.system.localeIdentifier == nil)
}

@Test func workspaceWashPresetResolvesStoredPreference() {
  #expect(DashWorkspaceWashPreset.defaultPreset == .cloudflare)
  #expect(DashWorkspaceWashPreset.resolved(stored: "cloudflare") == .cloudflare)
  #expect(DashWorkspaceWashPreset.resolved(stored: "blue") == .blue)
  #expect(DashWorkspaceWashPreset.resolved(stored: "purple") == .purple)
  #expect(DashWorkspaceWashPreset.resolved(stored: "teal") == .teal)
  #expect(DashWorkspaceWashPreset.resolved(stored: "unknown") == .cloudflare)

  let rawValues = DashWorkspaceWashPreset.allCases.map(\.rawValue)
  #expect(Set(rawValues).count == rawValues.count)
}

@Test @MainActor func customAvatarFilesAreNormalizedPersistentAndUserScoped() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("dash-avatar-tests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }

  let sourceA = root.appendingPathComponent("source-a.png")
  let sourceB = root.appendingPathComponent("source-b.png")
  try avatarTestImageData(size: CGSize(width: 1_200, height: 800), color: .systemBlue)
    .write(to: sourceA)
  try avatarTestImageData(size: CGSize(width: 700, height: 900), color: .systemOrange)
    .write(to: sourceB)

  let avatarDirectory = root.appendingPathComponent("avatars", isDirectory: true)
  let store = CustomAvatarFileStore(directoryURL: avatarDirectory)
  let savedA = try await store.saveImage(from: sourceA, for: "user-a")
  let imageA = try #require(UIImage(data: savedA)?.cgImage)
  #expect(imageA.width == CustomAvatarFileStore.maximumPixelSize)
  #expect(imageA.height == CustomAvatarFileStore.maximumPixelSize)

  let missingB = await store.loadImage(for: "user-b")
  #expect(missingB == .missing)
  let savedB = try await store.saveImage(from: sourceB, for: "user-b")
  #expect(savedA != savedB)

  let reloadedStore = CustomAvatarFileStore(directoryURL: avatarDirectory)
  let reloadedA = await reloadedStore.loadImage(for: "user-a")
  let reloadedB = await reloadedStore.loadImage(for: "user-b")
  #expect(reloadedA == .loaded(savedA))
  #expect(reloadedB == .loaded(savedB))

  let unavailableStore = CustomAvatarFileStore(
    directoryURL: avatarDirectory,
    dataReader: { _ in throw CocoaError(.fileReadNoPermission) })
  let temporarilyUnavailable = await unavailableStore.loadImage(for: "user-a")
  let stillStoredA = await reloadedStore.loadImage(for: "user-a")
  #expect(temporarilyUnavailable == .unavailable)
  #expect(stillStoredA == .loaded(savedA))

  try await reloadedStore.removeImage(for: "user-a")
  let removedA = await reloadedStore.loadImage(for: "user-a")
  let retainedB = await reloadedStore.loadImage(for: "user-b")
  #expect(removedA == .missing)
  #expect(retainedB == .loaded(savedB))
}

@Test @MainActor func invalidCustomAvatarDoesNotReplaceTheStoredPhoto() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("dash-avatar-tests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }

  let validSource = root.appendingPathComponent("valid.png")
  let invalidSource = root.appendingPathComponent("invalid.data")
  try avatarTestImageData(size: CGSize(width: 640, height: 480), color: .systemPurple)
    .write(to: validSource)
  try Data("not an image".utf8).write(to: invalidSource)

  let store = CustomAvatarFileStore(
    directoryURL: root.appendingPathComponent("avatars", isDirectory: true))
  let original = try await store.saveImage(from: validSource, for: "user-a")
  do {
    try await store.saveImage(from: invalidSource, for: "user-a")
    Issue.record("An invalid image should be rejected.")
  } catch {
    #expect(error as? CustomAvatarError == .invalidImage)
  }
  let retained = await store.loadImage(for: "user-a")
  #expect(retained == .loaded(original))
}

@Test @MainActor func customAvatarIsNotStoredWhenBackupExclusionFails() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("dash-avatar-tests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }

  let store = CustomAvatarFileStore(
    directoryURL: root.appendingPathComponent("avatars", isDirectory: true),
    backupExcluder: { _ in throw CocoaError(.fileWriteNoPermission) })
  let source = root.appendingPathComponent("source.png")
  try avatarTestImageData(size: CGSize(width: 256, height: 256), color: .systemTeal)
    .write(to: source)

  do {
    try await store.saveImage(from: source, for: "user-a")
    Issue.record("A photo must not be stored when backup exclusion cannot be guaranteed.")
  } catch {
    #expect(error as? CustomAvatarError == .backupExclusionFailed)
  }
  #expect(await store.loadImage(for: "user-a") == .missing)
}

@Test @MainActor func backupExclusionFailureDoesNotReplaceAnExistingCustomAvatar()
  async throws
{
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("dash-avatar-tests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }

  let avatarDirectory = root.appendingPathComponent("avatars", isDirectory: true)
  let oldSource = root.appendingPathComponent("old.png")
  let newSource = root.appendingPathComponent("new.png")
  try avatarTestImageData(size: CGSize(width: 300, height: 300), color: .systemIndigo)
    .write(to: oldSource)
  try avatarTestImageData(size: CGSize(width: 300, height: 300), color: .systemPink)
    .write(to: newSource)

  let originalStore = CustomAvatarFileStore(directoryURL: avatarDirectory)
  let original = try await originalStore.saveImage(from: oldSource, for: "user-a")
  let failingStore = CustomAvatarFileStore(
    directoryURL: avatarDirectory,
    backupExcluder: { url in
      if url != avatarDirectory {
        throw CocoaError(.fileWriteNoPermission)
      }
    })

  do {
    try await failingStore.saveImage(from: newSource, for: "user-a")
    Issue.record("A replacement must fail when its backup exclusion cannot be guaranteed.")
  } catch {
    #expect(error as? CustomAvatarError == .backupExclusionFailed)
  }
  #expect(await originalStore.loadImage(for: "user-a") == .loaded(original))
}

@MainActor
private func avatarTestImageData(size: CGSize, color: UIColor) -> Data {
  let format = UIGraphicsImageRendererFormat()
  format.opaque = true
  format.scale = 1
  return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
    context.cgContext.setFillColor(color.cgColor)
    context.cgContext.fill(CGRect(origin: .zero, size: size))
  }
}

/// Everything that pins `DashL10n.localeOverrideForTesting`. The pin is
/// process-global and Swift Testing runs cases in parallel by default, so these
/// have to be serialized or they read each other's locale.
@Suite(.serialized)
struct LocalizationTests {
  /// `DashL10n` must honor an explicit locale immediately (no relaunch), so
  /// Settings → Language can remount copy via `LocalizedStringResource.locale`.
  @Test func dashL10nFollowsActiveLocale() {
    let previous = DashL10n.localeOverrideForTesting
    defer { DashL10n.localeOverrideForTesting = previous }

    DashL10n.localeOverrideForTesting = Locale(identifier: "zh-Hans")
    #expect(DashL10n.string("Settings") == "设置")
    #expect(DashL10n.ui("Domains") == "域名")
    #expect(DashL10n.string("System") == "跟随系统")

    DashL10n.localeOverrideForTesting = Locale(identifier: "en")
    #expect(DashL10n.string("Settings") == "Settings")
    #expect(DashL10n.ui("Domains") == "Domains")
  }

  @MainActor
  @Test func workerDeploymentAgeFollowsInAppLanguageChanges() {
    let previous = DashL10n.localeOverrideForTesting
    defer { DashL10n.localeOverrideForTesting = previous }
    let deployedAt = "2026-07-25T12:00:00.123Z"
    let now = Date(timeIntervalSince1970: 1_785_240_000)

    DashL10n.localeOverrideForTesting = Locale(identifier: "en")
    let english = workerDeploymentAgeText(deployedAt, now: now)
    DashL10n.localeOverrideForTesting = Locale(identifier: "zh-Hans")
    let chinese = workerDeploymentAgeText(deployedAt, now: now)
    DashL10n.localeOverrideForTesting = Locale(identifier: "en")
    let englishAgain = workerDeploymentAgeText(deployedAt, now: now)

    #expect(english.hasPrefix("Deployed "))
    #expect(english.contains("ago"))
    #expect(chinese.hasPrefix("部署于"))
    #expect(chinese.contains("前"))
    #expect(!chinese.contains("ago"))
    #expect(englishAgain == english)
  }

  /// `ui(_:)` returns an unknown key unchanged. That is right for data — it is
  /// called on zone names and object keys too — and it is also why a translation
  /// that was never spliced reached the screen in English without a sound.
  /// `lookup` is the same call with the miss made visible.
  @Test func dashL10nLookupReportsCatalogMisses() {
    let previous = DashL10n.localeOverrideForTesting
    defer { DashL10n.localeOverrideForTesting = previous }
    DashL10n.localeOverrideForTesting = Locale(identifier: "zh-Hans")

    let hit = DashL10n.lookup("Domains")
    #expect(hit.value == "域名")
    #expect(hit.matchedCatalog)

    let miss = DashL10n.lookup("my-zone.example")
    #expect(miss.value == "my-zone.example")
    #expect(!miss.matchedCatalog)
  }

  #if DEBUG
    /// The strict flag is what a zh-Hans preview or an exploratory debug session
    /// turns on to make a silent miss trip instead of reaching the screen in
    /// English. Real catalog keys must not set it off — the failing direction
    /// traps by design, so it is the passing direction that needs a test.
    @Test func strictLookupAcceptsKnownCatalogKeys() {
      let previousLocale = DashL10n.localeOverrideForTesting
      let previousStrict = DashL10n.strictLookup
      defer {
        DashL10n.localeOverrideForTesting = previousLocale
        DashL10n.strictLookup = previousStrict
      }
      DashL10n.localeOverrideForTesting = Locale(identifier: "zh-Hans")
      DashL10n.strictLookup = true

      #expect(DashL10n.ui("Domains") == "域名")
      #expect(DashL10n.ui("Bucket settings") == "存储桶设置")
      // Empty input is a runtime guard, not copy — it must stay exempt.
      #expect(DashL10n.ui("") == "")
    }
  #endif

  /// Every badge a screen can render has to be translated in every language
  /// Dash ships. The string-typed badge failed this silently: it localized
  /// `text.capitalized`, and `"Read-only".capitalized` is `"Read-Only"`, which
  /// is not a catalog key — so the badge stayed English on a Chinese row while
  /// its `Locked` sibling two lines away translated fine.
  @Test func everyStatusTokenIsTranslatedInSimplifiedChinese() {
    let previous = DashL10n.localeOverrideForTesting
    defer { DashL10n.localeOverrideForTesting = previous }

    DashL10n.localeOverrideForTesting = Locale(identifier: "en")
    let english = StatusToken.allCases.map(\.label)
    DashL10n.localeOverrideForTesting = Locale(identifier: "zh-Hans")
    let chinese = StatusToken.allCases.map(\.label)

    for (index, token) in StatusToken.allCases.enumerated() {
      #expect(
        chinese[index] != english[index],
        "StatusToken.\(token.rawValue) has no zh-Hans entry for \(english[index].debugDescription)")
    }
  }

  // `View` is a @MainActor protocol, so StatusBadge/DashNotice statics are
  // isolated too — the test has to hop on as well.
  @MainActor
  @Test func statusBadgeAndNoticeExposeAccessibleCopy() {
    let previousLocale = DashL10n.localeOverrideForTesting
    DashL10n.localeOverrideForTesting = Locale(identifier: "en")
    defer { DashL10n.localeOverrideForTesting = previousLocale }

    #expect(StatusBadge.accessibilityText(for: .readOnly) == "Status, Read-only")
    #expect(StatusToken.current.presentation == .quiet)
    #expect(StatusToken.failed.presentation == .capsule)
    #expect(StatusToken.locked.presentation == .capsule)
    #expect(
      DashNotice.accessibilityText(kind: .warning, message: "Coverage limited")
        == "Warning: Coverage limited")
    #expect(DashTheme.Spacing.scrollBottomInset == 80)
    #expect(DashTheme.Layout.minimumHitTarget == 44)
  }
}

/// Cloudflare spells a failed Pages build `failure` and a running one `active`.
/// The word-list badge matched neither: `failure` missed `["error", "failed",
/// "critical", "inactive"]` and drew the informational capsule beside a red row
/// icon, while `active` matched the zone-health list and drew a green check on a
/// build still in flight. The mapping is now explicit and exhaustively toned.
@Test func pagesStatusTokensMatchCloudflareVocabulary() {
  #expect(StatusToken(pagesStatus: "success") == .success)
  #expect(StatusToken(pagesStatus: "failure") == .failed)
  #expect(StatusToken(pagesStatus: "failure").tone == .danger)
  #expect(StatusToken(pagesStatus: "active") == .inProgress)
  #expect(StatusToken(pagesStatus: "active").presentation == .capsule)
  #expect(StatusToken(pagesStatus: "canceled") == .canceled)
  #expect(StatusToken(pagesStatus: nil, isSkipped: true) == .skipped)
  #expect(StatusToken(pagesStatus: "teleporting") == .unknown)
}

@Test func pushBaseURLStripsPathFromRedirectURI() {
  let configured = AppConfiguration(
    clientID: "client",
    redirectURI: "https://dash.xat.sh/oauth/callback")
  #expect(configured.pushBaseURL?.absoluteString == "https://dash.xat.sh")

  let withPort = AppConfiguration(
    clientID: "client",
    redirectURI: "https://example.test:8443/oauth/callback")
  #expect(withPort.pushBaseURL?.absoluteString == "https://example.test:8443")
}

@Test func pushBaseURLRejectsNonHTTPSAndUnexpanded() {
  #expect(
    AppConfiguration(clientID: "c", redirectURI: "http://dash.xat.sh/oauth/callback")
      .pushBaseURL == nil)
  #expect(
    AppConfiguration(clientID: "c", redirectURI: "$(DASH_REDIRECT_URI)").pushBaseURL == nil)
  #expect(AppConfiguration(clientID: "c", redirectURI: "").pushBaseURL == nil)
  // isConfigured stays independent — missing push must not block sign-in.
  let loginOnly = AppConfiguration(clientID: "client", redirectURI: "http://insecure.test/cb")
  #expect(loginOnly.isConfigured)
  #expect(loginOnly.pushBaseURL == nil)
}

@Test func featureCatalogContainsEveryFeatureOnce() {
  let values = FeatureCatalog.grouped.flatMap(\.1)
  #expect(FeatureID.allCases.count == 5)
  #expect(values.count == FeatureID.allCases.count)
  #expect(Set(values).count == FeatureID.allCases.count)
  #expect(FeatureCatalog.descriptors.map(\.id) == FeatureCatalog.all)
  #expect(Set(FeatureCatalog.all) == Set(FeatureID.allCases))
}

@Test func everyFeatureCapabilityUsesOfficialScopes() {
  let official = Set(OAuthScopeCatalog.allIDs)
  for feature in FeatureID.allCases {
    #expect(feature.capability.all.isSubset(of: official))
    #expect(feature.capability.all.isDisjoint(with: CloudflareScopes.unsupportedByOAuthClient))
  }
}

/// The Demo's read-only profile must keep every catalog feature browsable
/// without allowing mutations. A new FeatureID belongs in `coreFeatures` at
/// the same time it gets a descriptor, or it does not ship.
@Test func everyFeatureIsBrowsableWithTheReadOnlyProfile() {
  #expect(DashAuthorizationScopes.coreFeatures == Set(FeatureID.allCases))
  for feature in FeatureID.allCases {
    #expect(
      feature.capability.accessLevel(grantedScopes: DashAuthorizationScopes.initialReadOnly)
        == .readOnly)
  }
}

@Test @MainActor func appModelDefaultsToFullAccountPermissions() {
  let model = AppModel(configuration: AppConfiguration(clientID: "", redirectURI: ""))
  #expect(model.selectedScopes == DashAuthorizationScopes.core)
  #expect(DashAuthorizationScopes.initialReadOnly.count == 15)
  #expect(DashAuthorizationScopes.core.count == 26)
  #expect(DashAuthorizationScopes.initialReadOnly.isStrictSubset(of: DashAuthorizationScopes.core))
  #expect(
    DashAuthorizationScopes.initialReadOnly.allSatisfy {
      !$0.hasSuffix(".write") && $0 != "cache.purge"
    })
  #expect(DashAuthorizationScopes.core.isStrictSubset(of: Set(CloudflareScopes.published)))
  #expect(
    DashAuthorizationScopes.watchtower.isSubset(of: DashAuthorizationScopes.initialReadOnly))
  #expect(
    DashAuthorizationScopes.shortcutsAndShareWrites.isSubset(
      of: DashAuthorizationScopes.core))
  #expect(
    DashAuthorizationScopes.shortcutsAndShareWrites.isDisjoint(
      with: DashAuthorizationScopes.initialReadOnly))
  #expect(DashAuthorizationScopes.core.contains("account-settings.write"))
  #expect(!DashAuthorizationScopes.initialReadOnly.contains("account-settings.write"))
  #expect(!model.hasScopes(["dns.write"]))
  model.grantedScopes = DashAuthorizationScopes.initialReadOnly
  #expect(model.hasScopes(["dns.read"]))
  #expect(!model.hasScopes(["dns.write"]))
  #expect(CloudflareScopes.required.allSatisfy(model.selectedScopes.contains))
}

@Test @MainActor func demoUsesTheSameReadOnlyGrantAndRoutesWritesToConnection() {
  #expect(AppModel.demoGrantedScopes == DashAuthorizationScopes.initialReadOnly)
  #expect(!AppModel.demoAccessRequiresConnection(["dns.read"]))
  #expect(AppModel.demoAccessRequiresConnection(["dns.write"]))
  for feature in FeatureID.allCases {
    #expect(
      feature.capability.accessLevel(grantedScopes: AppModel.demoGrantedScopes)
        == .readOnly)
  }
}

@Test func processExternalMutationsFailClosedWithoutTheirIncrementalGrant() {
  let required = DashAuthorizationScopes.shortcutsAndShareWrites
  #expect(
    !DashIntentAuthorization.hasRequiredScopes(
      required,
      granted: nil))
  #expect(
    !DashIntentAuthorization.hasRequiredScopes(
      required,
      granted: DashAuthorizationScopes.initialReadOnly))
  #expect(
    DashIntentAuthorization.hasRequiredScopes(
      required,
      granted: DashAuthorizationScopes.initialReadOnly.union(required)))
  #expect(
    R2ShareDestination.requiredWriteScopes.isSubset(
      of: DashAuthorizationScopes.shortcutsAndShareWrites))
  #expect(
    !R2ShareDestination.hasWriteAccess(
      grantedScopes: DashAuthorizationScopes.initialReadOnly))
  #expect(
    R2ShareDestination.hasWriteAccess(
      grantedScopes: DashAuthorizationScopes.initialReadOnly.union(required)))
}

/// Scopes that no surviving FeatureID declares, but that kept screens and App
/// Intents still call. `core` is derived from `coreFeatures`, so retiring a
/// feature drops its scopes from the grant with no build error and no runtime
/// error here — just a 403 on a screen that stayed. Each of these outlived the
/// feature that used to carry it.
@Test func scopesOutliveTheRetiredFeaturesThatDeclaredThem() {
  let operational: Set<String> = [
    "dns.read", "dns.write",  // DNSRecordsView, including create and delete
    "cache.purge",  // CachePurgeView and PurgeCacheIntent
    "workers-routes.read",  // WorkerDetail routes rows (zone-scoped, no carrier FeatureID)
    "notifications.read",  // Watchtower inbox (Cloudflare delivery history)
    "notifications.write",  // Push alerts webhook + policies
    "account-analytics.read",  // Worker metrics card (account-scoped GraphQL)
    "analytics.read",  // Zone HTTP Traffic Analytics, including Watchtower charts
    "zone-settings.read", "zone-settings.write",  // SetUnderAttack, ToggleDevelopmentMode
  ]
  let readOnlyOperational = operational.filter { !$0.hasSuffix(".write") && $0 != "cache.purge" }
  #expect(readOnlyOperational.isSubset(of: DashAuthorizationScopes.initialReadOnly))
  #expect(operational.isSubset(of: DashAuthorizationScopes.core))
}

@Test @MainActor func identityFailuresOnlySignOutOnDefinitive401() {
  let unauthorized = AppModel.authOutcome(
    afterIdentityError: CloudflareAPIError.request(status: 401, errors: []))
  #expect(unauthorized.state == .unauthenticated)
  #expect(!unauthorized.stale)

  let offline = AppModel.authOutcome(
    afterIdentityError: CloudflareAPIError.transport("offline"))
  #expect(offline.state == .authenticated)
  #expect(offline.stale)

  let serverError = AppModel.authOutcome(
    afterIdentityError: CloudflareAPIError.request(status: 500, errors: []))
  #expect(serverError.state == .authenticated)
  #expect(serverError.stale)

  let oauthOutage = AppModel.authOutcome(
    afterIdentityError: CloudflareAPIError.oauth("token endpoint unavailable"))
  #expect(oauthOutage.state == .authenticated)
  #expect(oauthOutage.stale)

  let unknown = AppModel.authOutcome(afterIdentityError: URLError(.timedOut))
  #expect(unknown.state == .authenticated)
  #expect(unknown.stale)
}

@Test func listPhaseKeepsContentVisibleThroughRefreshFailures() {
  #expect(
    DashListPhase.resolve(isLoading: true, error: nil, hasContent: false) == .loading)
  #expect(
    DashListPhase.resolve(isLoading: true, error: "boom", hasContent: true)
      == .content(banner: "boom", refreshing: true))
  #expect(
    DashListPhase.resolve(isLoading: false, error: "boom", hasContent: false)
      == .fullScreenError("boom"))
  #expect(
    DashListPhase.resolve(isLoading: false, error: "boom", hasContent: true)
      == .content(banner: "boom", refreshing: false))
  #expect(
    DashListPhase.resolve(isLoading: false, error: nil, hasContent: true)
      == .content(banner: nil, refreshing: false))
  #expect(
    DashListPhase.resolve(isLoading: false, error: nil, hasContent: false)
      == .content(banner: nil, refreshing: false))
  #expect(
    DashListPhase.resolve(isLoading: true, error: nil, hasContent: true)
      == .content(banner: nil, refreshing: true))
}

@Test func coldFailureWashRampFillsAtTheCopyAndClearsAbove() {
  let stops = DashColdFailureWashRamp.stops
  // Fill at the copy's edge, clear at the top of the band: the failure copy
  // always has an opaque floor and the placeholder above it always survives.
  #expect(stops.first?.location == 0)
  #expect(stops.first?.opacity == 1)
  #expect(stops.last?.location == 1)
  #expect(stops.last?.opacity == 0)
  // Monotonic in both axes: locations climb away from the copy and opacity only
  // falls, so the wash can never re-thicken further up the skeleton.
  for (previous, next) in zip(stops, stops.dropFirst()) {
    #expect(next.location > previous.location)
    #expect(next.opacity < previous.opacity)
  }
  #expect(DashColdFailureWashRamp.fadeDepth > 0)
}

@Test func failurePresentationMapsRecoveryActions() {
  #expect(
    DashFailurePresentation.from(
      message: "Your Cloudflare session is no longer valid. Sign in again."
    )
    .action == .signInAgain)
  #expect(
    DashFailurePresentation.from(message: "Permission denied\n\nGrant access for this product.")
      .action == .grantAccess)
  #expect(DashFailurePresentation.from(message: "offline").action == .tryAgain)
  #expect(DashFailureAction.signInAgain.title == "Sign in again")
  #expect(DashFailureAction.grantAccess.title == "Grant access")
  #expect(
    DashFailurePresentation.from(
      error: CloudflareAPIError.request(status: 404, errors: [])
    ).message
      == "Cloudflare couldn’t find this resource. It may have been removed or belong to another account."
  )
  #expect(
    DashFailurePresentation.from(error: CloudflareAPIError.transport("timed out")).message
      == "Dash couldn’t reach Cloudflare. Check your connection and try again."
  )
  #expect(
    DashFailurePresentation.from(
      error: CloudflareAPIError.request(
        status: 400,
        errors: [APIErrorItem(code: 81053, message: "Record already exists.")]
      )
    ).message == "Record already exists."
  )
  #expect(
    DashFailurePresentation.from(
      error: CloudflareAPIError.request(status: 422, errors: [])
    ).message
      == "Cloudflare couldn’t process this request. Check the resource and try again."
  )
  #expect(
    CloudflareAPIError.request(
      status: 400,
      errors: [APIErrorItem(code: 81053, message: "Record already exists.")]
    ).dashActionableMessage == "Record already exists."
  )
}

@Test func zoneSettingTitlesPreserveTechnicalAcronyms() {
  #expect(zoneSettingDisplayTitle("ssl") == "SSL")
  #expect(zoneSettingDisplayTitle("always_use_https") == "Always Use HTTPS")
  #expect(zoneSettingDisplayTitle("min_tls_version") == "Minimum TLS version")
  #expect(zoneSettingDisplayTitle("development_mode") == "Development Mode")
}

/// The settings menu commits with a plain `updateZoneSetting`, which stashes
/// nothing — offering `under_attack` there would raise the shield behind
/// `ZoneSecurityLevelOperation`'s back and lose the level it replaced when the
/// WAF switch went off.
@Test func zoneSettingsMenuNeverOffersUnderAttack() throws {
  let securityLevels = try #require(zoneSettingOptions["security_level"])
  #expect(!securityLevels.contains("under_attack"))
  // The rest of Cloudflare's enum must survive the removal.
  #expect(securityLevels == ["off", "essentially_off", "low", "medium", "high"])
}

@Test func pageStateAdvancesAndStopsOnTotals() {
  var state = DashPageState()
  #expect(state.nextPage == 1)
  #expect(!state.canLoadMore)

  // Total-driven: 50 of 120 loaded → more remain, request page 2 next.
  state.absorb(
    info: ResultInfo(page: 1, perPage: 50, totalCount: 120, cursor: nil),
    received: 50, loaded: 50, pageSize: 50)
  #expect(state.nextPage == 2)
  #expect(state.totalCount == 120)
  #expect(state.canLoadMore)

  // Final page: loaded reaches total.
  state.absorb(
    info: ResultInfo(page: 3, perPage: 50, totalCount: 120, cursor: nil),
    received: 20, loaded: 120, pageSize: 50)
  #expect(state.nextPage == 4)
  #expect(!state.canLoadMore)

  // Heuristic without result_info: a full page may have a successor.
  state.reset()
  state.absorb(info: nil, received: 50, loaded: 50, pageSize: 50)
  #expect(state.nextPage == 2)
  #expect(state.canLoadMore)
  state.absorb(info: nil, received: 12, loaded: 62, pageSize: 50)
  #expect(!state.canLoadMore)
}

@Test func pageStateRehydratesFromCachedArrays() {
  var state = DashPageState()
  state.rehydrate(loaded: 100, pageSize: 50)
  #expect(state.nextPage == 3)
  #expect(state.canLoadMore)

  state.rehydrate(loaded: 62, pageSize: 50)
  #expect(state.nextPage == 2)
  #expect(!state.canLoadMore)

  state.rehydrate(loaded: 0, pageSize: 50)
  #expect(state.nextPage == 1)
  #expect(!state.canLoadMore)
}

@Test func watchtowerSnapshotTracksStaleness() {
  let now = Date(timeIntervalSince1970: 1_000_000)
  let snapshot = WatchtowerSnapshot(alerts: [], alertsStatus: .ok, fetchedAt: now)
  #expect(!snapshot.isStale(now: now.addingTimeInterval(299), ttl: 300))
  #expect(!snapshot.isStale(now: now.addingTimeInterval(300), ttl: 300))
  #expect(snapshot.isStale(now: now.addingTimeInterval(301), ttl: 300))
}

/// The Resources tab treats read-only features as available to browse, while
/// an unknown grant fails closed. AppRoot does not mount the catalog until
/// bootstrap has restored the scope mirror or its conservative fallback.
@MainActor
@Test func featureCatalogDefaultFilterListsEveryReadableFeature() {
  #expect(FeatureCatalogView.defaultFilter == .available)
  let unknown = FeatureCatalogFiltering.features(
    filter: FeatureCatalogView.defaultFilter,
    grantedScopes: nil)
  #expect(unknown.isEmpty)
  let initialGrant = FeatureCatalogFiltering.features(
    filter: FeatureCatalogView.defaultFilter,
    grantedScopes: DashAuthorizationScopes.initialReadOnly)
  #expect(initialGrant.count == FeatureCatalog.all.count)
}

@Test func featureCatalogFilteringRespectsAccess() {
  let scopes: Set<String> = ["zone.read"]
  let locked = FeatureCatalogFiltering.features(
    filter: .locked, grantedScopes: scopes)
  #expect(locked.contains(.workers))
  #expect(!locked.contains(.zones))

  let readOnly = FeatureCatalogFiltering.features(
    filter: .readOnly, grantedScopes: scopes)
  #expect(readOnly.contains(.zones))
  #expect(!readOnly.contains(.workers))

  let fullScopes = Set(FeatureID.zones.capability.all)
  let available = FeatureCatalogFiltering.features(
    filter: .available, grantedScopes: fullScopes)
  #expect(available.contains(.zones))
  let readOnlyAvailable = FeatureCatalogFiltering.features(
    filter: .available, grantedScopes: scopes)
  #expect(readOnlyAvailable.contains(.zones))
}

@Test func homeDomainsRecoveryRequestsReadAccessOnly() {
  #expect(HomeDomainsAccess.recoveryScopes == ["zone.read"])
  #expect(
    HomeDomainsAccess.recoveryScopes.isDisjoint(
      with: FeatureID.zones.capability.write))
}

@Test func destinationFeatureMappingCoversDirectRoutes() {
  #expect(featureID(for: .zone("z1")) == .zones)
  #expect(featureID(for: .dns("z1")) == .zones)
  #expect(featureID(for: .worker("api")) == .workers)
  #expect(featureID(for: .r2Bucket("media", prefix: "")) == .r2)
  #expect(featureID(for: .kvNamespace("ns")) == .kv)
  #expect(featureID(for: .kvKey(namespaceID: "ns", key: "flag")) == .kv)
  #expect(featureID(for: .profile) == nil)
}

/// Operational destinations keep reads and mutations explicit so Demo and
/// per-control UI gating stay read-only even though real sign-in requests both.
@Test func destinationScopesSeparateReadsFromWrites() {
  #expect(requiredScopes(for: .dns("z1")).contains("dns.write"))
  #expect(requiredScopes(for: .cache("z1")).contains("cache.purge"))
  #expect(requiredScopes(for: .zoneSettings("z1")).contains("zone-settings.write"))
  #expect(requiredScopes(for: .zoneAnalytics("z1")).contains("analytics.read"))
  #expect(requiredScopes(for: .zoneWAF("z1")).contains("analytics.read"))
  #expect(requiredScopes(for: .auditLogs).contains("account-settings.read"))
  #expect(requiredScopes(for: .pushAlerts).contains("notifications.write"))
  #expect(readScopes(for: .dns("z1")) == ["zone.read", "dns.read"])
  #expect(writeScopes(for: .dns("z1")) == ["dns.write"])
  #expect(readScopes(for: .cache("z1")) == ["zone.read"])
  #expect(
    readScopes(for: .zoneWAF("z1"))
      == ["zone.read", "analytics.read", "zone-settings.read"])
  #expect(writeScopes(for: .cache("z1")) == ["cache.purge"])
  #expect(writeScopes(for: .zoneAnalytics("z1")).isEmpty)
  #expect(writeScopes(for: .zoneWAF("z1")) == ["zone-settings.write"])
  #expect(writeScopes(for: .pushAlerts) == ["notifications.write"])
  #expect(writeScopes(for: .profile) == ["account-settings.write"])
  // Each is absent from the feature the destination maps to.
  #expect(!FeatureID.zones.capability.all.contains("dns.write"))
  #expect(!FeatureID.zones.capability.all.contains("cache.purge"))
}

/// The widget counts Cloudflare's deliveries. It never characterises the
/// account: Dash no longer decides that anything is wrong.
@Test func widgetHeadlineCountsUnreadDeliveries() {
  func localized(
    _ resource: LocalizedStringResource,
    locale identifier: String
  ) -> String {
    var resource = resource
    resource.locale = Locale(identifier: identifier)
    return String(localized: resource)
  }

  let empty = WatchtowerWidgetSnapshot.headline(unreadCount: 0)
  let singular = WatchtowerWidgetSnapshot.headline(unreadCount: 1)
  let plural = WatchtowerWidgetSnapshot.headline(unreadCount: 4)
  let unavailable = WatchtowerWidgetSnapshot.headline(
    unreadCount: 0,
    alertsUnavailable: true)

  #expect(localized(empty, locale: "en") == "No unread alerts")
  #expect(localized(singular, locale: "en") == "1 unread alert")
  #expect(localized(plural, locale: "en") == "4 unread alerts")
  #expect(
    localized(unavailable, locale: "en")
      == "Alerts unavailable")
  #expect(localized(empty, locale: "zh-Hans") == "没有未读提醒")
  #expect(localized(singular, locale: "zh-Hans") == "1 条未读提醒")
  #expect(localized(plural, locale: "zh-Hans") == "4 条未读提醒")
  #expect(localized(unavailable, locale: "zh-Hans") == "提醒暂不可用")
}

@Test func analyticsChartAccessibilitySummaryIncludesTotals() {
  let summary = ZoneAnalyticsChartModel.chartAccessibilitySummary(
    rangeLabel: "Last 24 hours", requests: 1200, threats: 3)
  #expect(summary.contains("Last 24 hours"))
  #expect(summary.contains("1,200") || summary.contains("1200"))
  #expect(summary.contains("3"))
  #expect(summary.contains("threats"))
}

@Test func watchtowerAnalyticsAccessibilityNamesMetricAndTotal() {
  let summary = WatchtowerAnalyticsChartModel.accessibilitySummary(
    metric: .webTraffic,
    rangeLabel: "Last 24 hours",
    value: "12,345")
  #expect(summary.contains("Web Traffic"))
  #expect(summary.contains("Last 24 hours"))
  #expect(summary.contains("12,345"))
}

@Test func watchtowerEditorUsesLightweightChartPlaceholder() {
  let editing = WatchtowerMetricChartRenderingMode.resolved(isEditing: true)
  let normal = WatchtowerMetricChartRenderingMode.resolved(isEditing: false)

  #expect(editing == .placeholder)
  #expect(!editing.usesDitherChart)
  #expect(normal == .live)
  #expect(normal.usesDitherChart)
}

@Test func watchtowerChartSwapFinishesOutgoingBeforeIncoming() {
  var sequence = WatchtowerChartVisualSwapSequence(mode: .live)

  let exit = sequence.request(.placeholder)
  #expect(exit == .exit(.live))
  #expect(sequence.visibleMode == .live)

  sequence.begin(exit)
  #expect(sequence.visibleMode == nil)

  let enter = sequence.finishExit(.live)
  #expect(enter == .enter(.placeholder))
  #expect(sequence.visibleMode == nil)

  sequence.begin(enter)
  #expect(sequence.visibleMode == .placeholder)
  #expect(sequence.finishEnter(.placeholder) == .none)
}

@Test func watchtowerChartSwapRetargetsWithoutShowingTheObsoleteReplacement() {
  var sequence = WatchtowerChartVisualSwapSequence(mode: .live)

  let exit = sequence.request(.placeholder)
  sequence.begin(exit)
  #expect(sequence.visibleMode == nil)

  let reverse = sequence.request(.live)
  #expect(reverse == .enter(.live))
  sequence.begin(reverse)

  #expect(sequence.visibleMode == .live)
  #expect(sequence.finishEnter(.live) == .none)
}

@Test func watchtowerChartSwapCanReverseAnIncomingLayerImmediately() {
  var sequence = WatchtowerChartVisualSwapSequence(mode: .live)

  let exit = sequence.request(.placeholder)
  sequence.begin(exit)
  let enter = sequence.finishExit(.live)
  sequence.begin(enter)
  #expect(sequence.visibleMode == .placeholder)

  let reverse = sequence.request(.live)
  #expect(reverse == .exit(.placeholder))
  sequence.begin(reverse)
  #expect(sequence.visibleMode == nil)
}

@Test func watchtowerMetricRemovalExitsBeforeTheRemainingCardsReflow() {
  var sequence = WatchtowerMetricRemovalSequence()

  let beganCPUExit = sequence.begin(.cpuTime)
  #expect(beganCPUExit)
  #expect(sequence.phase == .exiting(.cpuTime))
  #expect(sequence.departingMetric == .cpuTime)
  let beganWorkerExit = sequence.begin(.workerInvocations)
  #expect(!beganWorkerExit)

  let finishedWorkerExit = sequence.finishExit(.workerInvocations)
  #expect(!finishedWorkerExit)
  let finishedCPUExit = sequence.finishExit(.cpuTime)
  #expect(finishedCPUExit)
  #expect(sequence.phase == .reflowing(.cpuTime))
  #expect(sequence.departingMetric == .cpuTime)

  sequence.finishReflow(.cpuTime)
  #expect(sequence.isIdle)
  #expect(sequence.departingMetric == nil)
}

@Test func watchtowerMetricRemovalCanCancelWithoutCommittingTheReflow() {
  var sequence = WatchtowerMetricRemovalSequence()

  let beganWebTrafficExit = sequence.begin(.webTraffic)
  #expect(beganWebTrafficExit)
  sequence.cancel()

  #expect(sequence.isIdle)
  #expect(sequence.departingMetric == nil)
  let finishedWebTrafficExit = sequence.finishExit(.webTraffic)
  #expect(!finishedWebTrafficExit)
}

@Test @MainActor func watchtowerDragOverlayLiftsToTheFingerAndEndsCleanly() {
  let visualState = WatchtowerMetricDragVisualState()
  let reference = UIView()
  let pressIdentifier = UUID()

  visualState.beginPress(
    .webTraffic,
    identifier: pressIdentifier,
    size: CGSize(width: 160, height: 220),
    fingerLocation: CGPoint(x: 220, y: 360),
    sourceCenter: CGPoint(x: 190, y: 380),
    isExpanded: true,
    reference: reference,
    reduceMotion: false)
  #expect(visualState.pressedMetric == .webTraffic)
  #expect(visualState.phase == .pressing)
  #expect(visualState.presentation?.center == CGPoint(x: 190, y: 380))
  #expect(visualState.presentation?.scale == 0.97)

  visualState.beginLift(
    metric: .webTraffic,
    size: CGSize(width: 160, height: 220),
    fingerLocation: CGPoint(x: 220, y: 360),
    sourceCenter: CGPoint(x: 190, y: 380),
    isExpanded: true,
    reference: reference,
    retaining: NSObject(),
    reduceMotion: false)

  #expect(visualState.activeReference === reference)
  #expect(visualState.pressedMetric == nil)
  #expect(visualState.phase == .lifting)
  #expect(visualState.presentation?.center == CGPoint(x: 190, y: 380))
  #expect(visualState.presentation?.scale == 0.97)

  // UIKit may cancel the source view's touch as UIDragInteraction takes over.
  visualState.endPress(identifier: pressIdentifier)
  #expect(visualState.phase == .lifting)
  #expect(visualState.presentation != nil)

  visualState.trackFinger(to: CGPoint(x: 230, y: 370))
  #expect(visualState.presentation?.center == CGPoint(x: 200, y: 390))

  visualState.liftToFinger()
  #expect(visualState.presentation?.center == CGPoint(x: 230, y: 370))
  #expect(visualState.presentation?.scale == 1)
  visualState.finishLift()
  #expect(visualState.phase == .tracking)

  visualState.trackFinger(to: CGPoint(x: 260, y: 410))
  #expect(visualState.presentation?.center == CGPoint(x: 260, y: 410))

  visualState.moveCenter(to: CGPoint(x: 120, y: 240))
  #expect(visualState.presentation?.center == CGPoint(x: 120, y: 240))

  visualState.beginSettling()
  #expect(visualState.isSettling)

  visualState.finish()
  #expect(visualState.presentation == nil)
  #expect(visualState.phase == nil)
  #expect(!visualState.isSettling)
  #expect(visualState.activeReference == nil)
}

@Test @MainActor func watchtowerDragOverlayRemovesMotionFromTheLift() {
  let visualState = WatchtowerMetricDragVisualState()
  let reference = UIView()

  visualState.beginLift(
    metric: .cpuTime,
    size: CGSize(width: 160, height: 120),
    fingerLocation: CGPoint(x: 220, y: 360),
    sourceCenter: CGPoint(x: 190, y: 380),
    isExpanded: false,
    reference: reference,
    retaining: NSObject(),
    reduceMotion: true)

  #expect(visualState.phase == .tracking)
  #expect(visualState.presentation?.center == CGPoint(x: 220, y: 360))
  #expect(visualState.presentation?.scale == 1)
}

@Test @MainActor func watchtowerDragPressIgnoresAnOldViewCancellation() {
  let visualState = WatchtowerMetricDragVisualState()
  let reference = UIView()
  let oldIdentifier = UUID()
  let currentIdentifier = UUID()

  visualState.beginPress(
    .webTraffic,
    identifier: oldIdentifier,
    size: CGSize(width: 160, height: 220),
    fingerLocation: CGPoint(x: 80, y: 110),
    sourceCenter: CGPoint(x: 80, y: 110),
    isExpanded: true,
    reference: reference,
    reduceMotion: false)
  visualState.beginPress(
    .cpuTime,
    identifier: currentIdentifier,
    size: CGSize(width: 160, height: 120),
    fingerLocation: CGPoint(x: 80, y: 60),
    sourceCenter: CGPoint(x: 80, y: 60),
    isExpanded: false,
    reference: reference,
    reduceMotion: false)

  visualState.endPress(identifier: oldIdentifier)
  #expect(visualState.pressedMetric == .cpuTime)
  visualState.endPress(identifier: currentIdentifier)
  #expect(visualState.pressedMetric == nil)
  #expect(visualState.presentation == nil)
  #expect(visualState.phase == nil)
}

/// Two collapsed cards over a full-width one, as the default layout paints it.
private let watchtowerDropFrames: [CGRect] = [
  CGRect(x: 0, y: 0, width: 180, height: 120),
  CGRect(x: 192, y: 0, width: 180, height: 120),
  CGRect(x: 0, y: 132, width: 372, height: 260),
]

@Test func watchtowerDropTargetingCountsCardsPassedInReadingOrder() {
  func index(_ x: CGFloat, _ y: CGFloat) -> Int {
    WatchtowerMetricDropTargeting.destinationIndex(
      point: CGPoint(x: x, y: y), otherFrames: watchtowerDropFrames)
  }

  // Before everything.
  #expect(index(40, 10) == 0)
  // Past the first collapsed card's horizontal centre, level with it.
  #expect(index(120, 60) == 1)
  // Past both collapsed cards but above the full-width card's vertical centre.
  #expect(index(300, 60) == 2)
  // Past the full-width card's centre — the append slot, which is the run-off
  // below the last card that entry-based targeting could never reach.
  #expect(index(180, 400) == 3)
}

@Test func watchtowerDropTargetingHoldsASlotUntilTheNextCentreIsCrossed() {
  let frame = watchtowerDropFrames[0]
  // Entering the card is not enough; its centre is.
  #expect(
    !WatchtowerMetricDropTargeting.precedes(
      frame, point: CGPoint(x: frame.minX + 4, y: frame.midY), isFullWidth: false))
  #expect(
    WatchtowerMetricDropTargeting.precedes(
      frame, point: CGPoint(x: frame.midX + 4, y: frame.midY), isFullWidth: false))
  // A full-width card has no left/right neighbour, so x must not decide it.
  #expect(
    !WatchtowerMetricDropTargeting.precedes(
      watchtowerDropFrames[2],
      point: CGPoint(x: 370, y: watchtowerDropFrames[2].midY - 4),
      isFullWidth: true))
}

@Test @MainActor func watchtowerVisibleMoveKeepsHiddenMetricsInPlace() {
  let defaults = UserDefaults(suiteName: "watchtower-visible-move")!
  defaults.removePersistentDomain(forName: "watchtower-visible-move")
  let state = WatchtowerChartCustomizationState(defaults: defaults)
  state.beginEditing()

  let visible = state.visibleMetrics
  guard let first = visible.first, visible.count >= 3 else {
    Issue.record("default layout should ship at least three visible charts")
    return
  }
  let hiddenBefore = state.order.filter(state.hidden.contains)

  state.move(first, toVisibleIndex: state.visibleMetrics.count)
  #expect(state.visibleMetrics.last == first)
  #expect(state.visibleMetrics.count == visible.count)
  #expect(state.order.filter(state.hidden.contains) == hiddenBefore)
}

@Test @MainActor func watchtowerChartCustomizationAllowsOnlyOneActiveDrag() {
  let suite = "watchtower-single-active-drag-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  let state = WatchtowerChartCustomizationState(defaults: defaults)
  state.beginEditing()

  #expect(state.beginDragging(.webTraffic))
  #expect(!state.beginDragging(.cpuTime))
  #expect(state.draggedMetric == .webTraffic)

  state.finishDragging()
  #expect(state.beginDragging(.cpuTime))
}

/// A lift must never be cancelled because the charts stack's coordinate view is
/// missing — `itemsForBeginning` returning an empty array is silent, so the
/// window has to stand in.
@Test @MainActor func watchtowerDragReferenceFallsBackToTheSourceWindow() {
  let visualState = WatchtowerMetricDragVisualState()
  let window = UIWindow()
  let source = UIView()
  window.addSubview(source)

  #expect(visualState.reference(for: source) === window)

  let coordinateView = UIView()
  visualState.coordinateView = coordinateView
  #expect(visualState.reference(for: source) === coordinateView)
}

@Test func watchtowerAnalyticsCardLayoutDefaultsExpandedAndPersistsCollapse() {
  #expect(WatchtowerAnalyticsCardLayout.isExpanded("webTraffic", raw: ""))
  #expect(WatchtowerAnalyticsCardLayout.collapsedIDs(in: "").isEmpty)

  let collapsed = WatchtowerAnalyticsCardLayout.toggled("webTraffic", in: "")
  #expect(collapsed == "webTraffic")
  #expect(!WatchtowerAnalyticsCardLayout.isExpanded("webTraffic", raw: collapsed))
  #expect(WatchtowerAnalyticsCardLayout.isExpanded("cacheRate", raw: collapsed))

  let both = WatchtowerAnalyticsCardLayout.toggled("cacheRate", in: collapsed)
  #expect(WatchtowerAnalyticsCardLayout.collapsedIDs(in: both) == ["cacheRate", "webTraffic"])

  let restored = WatchtowerAnalyticsCardLayout.toggled("webTraffic", in: both)
  #expect(restored == "cacheRate")
}

@Test func watchtowerAnalyticsCollapsedSeriesLiftsZerosOffTheFloor() {
  let lifted = WatchtowerAnalyticsChartModel.collapsedSeriesValues([0, 50, 0, 100])
  #expect(lifted.valueCeiling == nil)
  #expect(lifted.values == [10, 50, 10, 100])

  let quiet = WatchtowerAnalyticsChartModel.collapsedSeriesValues([0, 0, 0])
  #expect(quiet.valueCeiling == 1)
  #expect(quiet.values == [0.1, 0.1, 0.1])
}

@Test func watchtowerAnalyticsCardLayoutRowsKeepExpandedSolo() {
  let metrics: [WatchtowerAnalyticsMetric] = [
    .workerInvocations, .workerErrors, .webTraffic, .cacheRate,
  ]
  // All expanded → one metric per row.
  let open = WatchtowerAnalyticsCardLayout.rows(metrics, collapsedRaw: "", forceExpanded: false)
  #expect(
    open.map { $0.map(\.rawValue) } == [
      ["workerInvocations"], ["workerErrors"], ["webTraffic"], ["cacheRate"],
    ])

  // Collapse the middle two → they share a row; neighbors stay full-width.
  let packed = WatchtowerAnalyticsCardLayout.rows(
    metrics,
    collapsedRaw: "workerErrors,webTraffic",
    forceExpanded: false)
  #expect(
    packed.map { $0.map(\.rawValue) } == [
      ["workerInvocations"], ["workerErrors", "webTraffic"], ["cacheRate"],
    ])
}

@Test func watchtowerAnalyticsCardLayoutRestoresOrderAndAppendsNewMetrics() {
  let available: [WatchtowerAnalyticsMetric] = [
    .workerInvocations, .workerErrors, .webTraffic, .cacheRate,
  ]
  let restored = WatchtowerAnalyticsCardLayout.orderedMetrics(
    in: "cacheRate,unknown,workerErrors,cacheRate",
    available: available)

  #expect(restored == [.cacheRate, .workerErrors, .workerInvocations, .webTraffic])
  #expect(
    WatchtowerAnalyticsCardLayout.encodeOrder(restored)
      == "cacheRate,workerErrors,workerInvocations,webTraffic")
}

@Test func watchtowerAnalyticsCardLayoutNativeReorderCrossesItsTarget() {
  let metrics: [WatchtowerAnalyticsMetric] = [
    .workerInvocations, .workerErrors, .webTraffic, .cacheRate,
  ]

  let downward = WatchtowerAnalyticsCardLayout.moving(
    metrics, item: .workerInvocations, across: .webTraffic)
  #expect(downward == [.workerErrors, .webTraffic, .workerInvocations, .cacheRate])

  let upward = WatchtowerAnalyticsCardLayout.moving(
    metrics, item: .cacheRate, across: .workerErrors)
  #expect(upward == [.workerInvocations, .cacheRate, .workerErrors, .webTraffic])
}

@Test func watchtowerAnalyticsFreshInstallLayoutLeadsWithExpandedWebTraffic() {
  let fresh = WatchtowerAnalyticsCardLayout.layout(
    orderRaw: nil, collapsedRaw: nil, hiddenRaw: nil)

  #expect(
    fresh.order.filter { !fresh.hidden.contains($0) } == [
      .webTraffic, .cpuTime, .workerInvocations, .cacheRate, .clientRequestErrors,
    ])
  #expect(fresh.collapsed == [.cpuTime, .workerInvocations, .cacheRate, .clientRequestErrors])
  #expect(
    fresh.hidden == [.workerErrors, .totalBandwidth, .encryptedRequestsRate, .encryptedBandwidth])

  // One expanded headline card, then the four collapsed companions two-up.
  let rows = WatchtowerAnalyticsCardLayout.rows(
    fresh.order.filter { !fresh.hidden.contains($0) },
    collapsedRaw: WatchtowerAnalyticsCardLayout.encode(Set(fresh.collapsed.map(\.rawValue))),
    forceExpanded: false)
  #expect(
    rows.map { $0.map(\.rawValue) } == [
      ["webTraffic"],
      ["cpuTime", "workerInvocations"],
      ["cacheRate", "clientRequestErrors"],
    ])
}

/// A saved layout wins over the fresh-install defaults — including one that
/// deliberately hides nothing, which stores an empty string, not a missing key.
@Test func watchtowerAnalyticsSavedLayoutSurvivesTheFreshInstallDefaults() {
  let saved = WatchtowerAnalyticsCardLayout.layout(
    orderRaw: "cacheRate,webTraffic",
    collapsedRaw: "",
    hiddenRaw: "")

  #expect(Array(saved.order.prefix(2)) == [.cacheRate, .webTraffic])
  #expect(saved.collapsed.isEmpty)
  #expect(saved.hidden.isEmpty)
  #expect(saved.order.count == WatchtowerAnalyticsMetric.allCases.count)

  // Pre-editor installs only ever stored collapsed metrics; that is still a
  // used layout, so it must not be replaced by the fresh-install defaults.
  let legacy = WatchtowerAnalyticsCardLayout.layout(
    orderRaw: nil, collapsedRaw: "cacheRate", hiddenRaw: nil)
  #expect(legacy.order == Array(WatchtowerAnalyticsMetric.allCases))
  #expect(legacy.collapsed == [.cacheRate])
  #expect(legacy.hidden.isEmpty)
}

@Test @MainActor func watchtowerChartCustomizationCommitsAndCancelsDrafts() throws {
  let suite = "dash-tests-watchtower-layout-\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  // Seed a saved layout so the draft assertions below describe editing, not the
  // fresh-install defaults.
  defaults.set(
    WatchtowerAnalyticsCardLayout.encodeOrder(Array(WatchtowerAnalyticsMetric.allCases)),
    forKey: WatchtowerAnalyticsCardLayout.orderKey)
  defaults.set("", forKey: WatchtowerAnalyticsCardLayout.key)
  defaults.set("", forKey: WatchtowerAnalyticsCardLayout.hiddenKey)
  let customization = WatchtowerChartCustomizationState(defaults: defaults)

  customization.beginEditing()
  customization.move(.cacheRate, across: .workerInvocations)
  customization.remove(.workerErrors)
  customization.toggleExpanded(.webTraffic)
  customization.cancelEditing()

  #expect(customization.order.first == .workerInvocations)
  #expect(customization.visibleMetrics.contains(.workerErrors))
  #expect(customization.isExpanded(.webTraffic))

  customization.beginEditing()
  customization.move(.cacheRate, across: .workerInvocations)
  customization.remove(.workerErrors)
  customization.toggleExpanded(.webTraffic)
  customization.commitEditing()

  #expect(
    defaults.string(forKey: WatchtowerAnalyticsCardLayout.orderKey)?.hasPrefix("cacheRate") == true)
  #expect(defaults.string(forKey: WatchtowerAnalyticsCardLayout.hiddenKey) == "workerErrors")
  #expect(defaults.string(forKey: WatchtowerAnalyticsCardLayout.key) == "webTraffic")
}

@Test func watchtowerAnalyticsUpdatedTitleUsesRelativeTime() {
  let previousLocale = DashL10n.localeOverrideForTesting
  DashL10n.localeOverrideForTesting = Locale(identifier: "en")
  defer { DashL10n.localeOverrideForTesting = previousLocale }

  #expect(WatchtowerAnalyticsChartModel.updatedTitle(fetchedAt: nil, loading: true) == "Updating…")
  #expect(WatchtowerAnalyticsChartModel.updatedTitle(fetchedAt: nil, loading: false) == "Overview")

  let now = Date()
  let title = WatchtowerAnalyticsChartModel.updatedTitle(
    fetchedAt: now.addingTimeInterval(-180),
    loading: false,
    now: now)
  #expect(title.hasPrefix("Updated "))
  #expect(title.contains("minute") || title.contains("seconds"))
}

@Test func watchtowerAnalyticsChartPointsParseHourAndDayStamps() {
  let points = WatchtowerAnalyticsChartModel.chartPoints(from: [
    AccountAnalyticsPoint(datetime: "2026-07-22T10:00:00Z", requests: 10, bytes: 100),
    AccountAnalyticsPoint(datetime: "2026-07-21", requests: 20, bytes: 200),
    AccountAnalyticsPoint(datetime: "2026-07-22T11:00:00Z", requests: 30, bytes: 300),
  ])
  #expect(points.map(\.point.requests) == [20, 10, 30])
}

@Test func searchCancellationIsRecognized() {
  #expect(CancellationError().dashIsCancellation)
  #expect(URLError(.cancelled).dashIsCancellation)
  #expect(!URLError(.timedOut).dashIsCancellation)
}

@Test func legalDocumentsExposeStableTitles() {
  let previousLocale = DashL10n.localeOverrideForTesting
  DashL10n.localeOverrideForTesting = Locale(identifier: "en")
  defer { DashL10n.localeOverrideForTesting = previousLocale }

  #expect(LegalDocument.termsOfUse.title == "Terms of Use")
  #expect(LegalDocument.privacyPolicy.title == "Privacy Policy")
  #expect(LegalDocument.termsOfUse.resourceName == "TermsOfUse")
  #expect(LegalDocument.privacyPolicy.resourceName == "PrivacyPolicy")
}

@Test func featureVisualIdentityMapsStableTonesPerFeature() {
  #expect(FeatureVisualIdentity.tone(for: .zones) == .success)
  #expect(FeatureVisualIdentity.tone(for: .workers) == .brand)
  #expect(FeatureVisualIdentity.tone(for: .pages) == .info)
  #expect(FeatureVisualIdentity.tone(for: .r2) == .accent)
  #expect(FeatureVisualIdentity.tone(for: .kv) == .warning)

  // Each catalog feature keeps a distinct tone — Resources rows should not
  // share a color within Compute / Storage just because they share a section.
  let tones = FeatureCatalog.all.map { FeatureVisualIdentity.tone(for: $0) }
  #expect(Set(tones).count == tones.count)
  #expect(!tones.contains(.soft))
}

@Test func featureCatalogIconsAreUnique() {
  let fill = FeatureCatalog.descriptors.map(\.solarFillAssetName)
  let outline = FeatureCatalog.descriptors.map(\.solarOutlineAssetName)
  #expect(Set(fill).count == fill.count)
  #expect(Set(outline).count == outline.count)
}

@Test func contentSolarAssetsUseFillVariants() {
  #expect(!SolarAsset.Content.all.isEmpty)
  #expect(SolarAsset.Content.all.allSatisfy { $0.hasSuffix("Fill") })
}

@Test func contentTrayDragDecisionUsesProjectionAndVelocity() {
  #expect(
    TrayDragDecision.content(translation: 40, predictedEndTranslation: 40) == .settle)
  #expect(
    TrayDragDecision.content(translation: 130, predictedEndTranslation: 130) == .dismiss)
  #expect(
    TrayDragDecision.content(translation: 40, predictedEndTranslation: 200) == .dismiss)
  #expect(
    TrayDragDecision.content(translation: 40, predictedEndTranslation: 1000) == .dismiss)
}

@Test func expandableTraySlowSmallDragsDoNotDismiss() {
  #expect(
    TrayDragDecision.expandable(
      startDetent: .expanded, translation: 60, predictedEndTranslation: 140, velocity: 320,
      expandedTop: 80, floatingTop: 400
    ) == .settleExpanded(true))
  #expect(
    TrayDragDecision.expandable(
      startDetent: .floating, translation: 60, predictedEndTranslation: 140, velocity: 320,
      expandedTop: 80, floatingTop: 400
    ) == .settleExpanded(false))
}

@Test func expandableTrayFastFlickUsesStartingDetent() {
  #expect(
    TrayDragDecision.expandable(
      startDetent: .floating, translation: 40, predictedEndTranslation: 300, velocity: 1_040,
      expandedTop: 80, floatingTop: 400
    ) == .dismiss)
  #expect(
    TrayDragDecision.expandable(
      startDetent: .expanded, translation: 40, predictedEndTranslation: 300, velocity: 1_040,
      expandedTop: 80, floatingTop: 400
    ) == .settleExpanded(false))
}

@Test func expandableTrayDeliberatePullUsesDistancePastFloatingDetent() {
  #expect(
    TrayDragDecision.expandable(
      startDetent: .floating, translation: 130, predictedEndTranslation: 130, velocity: 0,
      expandedTop: 80, floatingTop: 400
    ) == .dismiss)
  #expect(
    TrayDragDecision.expandable(
      startDetent: .expanded, translation: 130, predictedEndTranslation: 430, velocity: 1_200,
      expandedTop: 80, floatingTop: 400
    ) == .settleExpanded(false))
  #expect(
    TrayDragDecision.expandable(
      startDetent: .expanded, translation: 450, predictedEndTranslation: 450, velocity: 0,
      expandedTop: 80, floatingTop: 400
    ) == .dismiss)
}

@Test func trayDragRubberBandsAboveExpandedDetent() {
  #expect(TrayDragDecision.rubberBand(cardTop: 50, expandedTop: 80) == 75.5)
}

@Test func profileTrayPhaseTitlesFollowFocus() {
  let previousLocale = DashL10n.localeOverrideForTesting
  DashL10n.localeOverrideForTesting = Locale(identifier: "en")
  defer { DashL10n.localeOverrideForTesting = previousLocale }

  #expect(ProfileTrayPhase.menu.title == "Profile")
  #expect(ProfileTrayPhase.accounts.title == "Switch account")
  #expect(ProfileTrayPhase.signOut.title == "Sign out")
}

@Test func accountRenameRequiresItsWriteScope() {
  #expect(ProfileAccountRenameAccess.requiredScopes == ["account-settings.write"])
  #expect(!ProfileAccountRenameAccess.isGranted(nil))
  #expect(!ProfileAccountRenameAccess.isGranted(["account-settings.read"]))
  #expect(
    ProfileAccountRenameAccess.isGranted([
      "account-settings.read",
      "account-settings.write",
    ]))
}

@Test func recentResourcesRecordDedupeAndTrim() {
  let zone = RecentResource(
    accountID: "acc1", kind: .zone, resourceID: "z1", title: "example.com")
  let worker = RecentResource(
    accountID: "acc1", kind: .worker, resourceID: "api-worker", title: "api-worker")

  var raw = RecentResources.recording(zone, in: "")
  raw = RecentResources.recording(worker, in: raw)
  #expect(RecentResources.decode(raw) == [worker, zone])

  // Re-opening an entry moves it to the front instead of duplicating it.
  raw = RecentResources.recording(zone, in: raw)
  #expect(RecentResources.decode(raw) == [zone, worker])

  // KV titles may contain the pins encoding's separators; JSON keeps them.
  let hostile = RecentResource(
    accountID: "acc1", kind: .kvNamespace, resourceID: "ns1", title: "prod|kv,cache")
  raw = RecentResources.recording(hostile, in: raw)
  #expect(RecentResources.decode(raw).first?.title == "prod|kv,cache")

  // The stored list trims to the limit; garbage decodes to empty.
  for index in 0..<40 {
    raw = RecentResources.recording(
      RecentResource(accountID: "acc1", kind: .worker, resourceID: "w\(index)", title: "w\(index)"),
      in: raw)
  }
  #expect(RecentResources.decode(raw).count == RecentResources.limit)
  #expect(RecentResources.decode("not json").isEmpty)
}

@Test func homeShortcutsPreserveOrderAndSelection() {
  #expect(HomeShortcuts.decode(HomeShortcuts.defaultValue) == [.zones, .workers, .pages, .r2])
  #expect(HomeShortcuts.decode("r2,zones,r2,unknown") == [.r2, .zones])

  let removed = HomeShortcuts.toggled(.workers, in: HomeShortcuts.defaultValue)
  #expect(HomeShortcuts.decode(removed) == [.zones, .pages, .r2])

  let appended = HomeShortcuts.toggled(.kv, in: removed)
  #expect(HomeShortcuts.decode(appended) == [.zones, .pages, .r2, .kv])
}

@Test func homeActionsKeepAtMostThreeOrderedOperations() {
  #expect(
    HomeActions.decode(HomeActions.defaultValue)
      == [.purgeCache, .enableUnderAttackMode, .uploadR2])
  #expect(HomeActions.decode("purgeCache,uploadR2,purgeCache,unknown") == [.purgeCache, .uploadR2])

  // Changing the fresh-install default never rewrites a previously stored choice.
  let previousSelection = HomeActions.encode([.addDomain, .uploadR2, .addDNSRecord])
  #expect(
    HomeActions.decode(previousSelection) == [.addDomain, .uploadR2, .addDNSRecord])

  let full = HomeActions.defaultValue
  #expect(HomeActions.toggled(.createKVKey, in: full) == full)

  let removed = HomeActions.toggled(.purgeCache, in: full)
  #expect(HomeActions.decode(removed) == [.enableUnderAttackMode, .uploadR2])
  #expect(HomeActions.decode(HomeActions.toggled(.createKVKey, in: removed)).last == .createKVKey)
}

@Test func homeEducationRequiresAccountScopedR2EvidenceAndHonorsDismissal() {
  let firstAccount = "acc|one,primary"
  var recentsRaw = RecentResources.recording(
    RecentResource(
      accountID: firstAccount,
      kind: .r2Bucket,
      resourceID: "assets",
      title: "assets"
    ),
    in: ""
  )
  recentsRaw = RecentResources.recording(
    RecentResource(
      accountID: "acc-two",
      kind: .pagesProject,
      resourceID: "site",
      title: "site"
    ),
    in: recentsRaw
  )

  #expect(
    HomeEducation.recommendation(
      recentsRaw: recentsRaw,
      accountID: nil,
      dismissalsRaw: "",
      isDemoSession: false
    ) == nil)
  #expect(
    HomeEducation.recommendation(
      recentsRaw: recentsRaw,
      accountID: firstAccount,
      dismissalsRaw: "",
      isDemoSession: true
    ) == nil)
  #expect(
    HomeEducation.recommendation(
      recentsRaw: recentsRaw,
      accountID: "acc-two",
      dismissalsRaw: "",
      isDemoSession: false
    ) == nil)
  #expect(
    HomeEducation.recommendation(
      recentsRaw: recentsRaw,
      accountID: firstAccount,
      dismissalsRaw: "",
      isDemoSession: false
    ) == .r2ShareExtension)

  let dismissalsRaw = HomeEducation.recordingDismissal(
    .r2ShareExtension,
    accountID: firstAccount,
    in: ""
  )
  #expect(
    HomeEducation.recommendation(
      recentsRaw: recentsRaw,
      accountID: firstAccount,
      dismissalsRaw: dismissalsRaw,
      isDemoSession: false
    ) == nil)
  #expect(
    HomeEducation.recordingDismissal(
      .r2ShareExtension,
      accountID: firstAccount,
      in: dismissalsRaw
    ) == dismissalsRaw)

  recentsRaw = RecentResources.recording(
    RecentResource(
      accountID: "acc-two",
      kind: .r2Bucket,
      resourceID: "backups",
      title: "backups"
    ),
    in: recentsRaw
  )
  #expect(
    HomeEducation.recommendation(
      recentsRaw: recentsRaw,
      accountID: "acc-two",
      dismissalsRaw: dismissalsRaw,
      isDemoSession: false
    ) == .r2ShareExtension)
}

@Test func recentResourcesShowOnlyTheActiveAccount() {
  var raw = ""
  for index in 0..<8 {
    raw = RecentResources.recording(
      RecentResource(
        accountID: index.isMultiple(of: 2) ? "acc1" : "acc2",
        kind: .zone, resourceID: "z\(index)", title: "zone\(index)"),
      in: raw)
  }
  let visible = RecentResources.visible(in: raw, accountID: "acc1")
  #expect(visible.count == 4)
  #expect(visible.allSatisfy { $0.accountID == "acc1" })
  // Newest first.
  #expect(visible.first?.resourceID == "z6")
}

@Test func recentResourceRoutesEveryKindHome() {
  func resource(_ kind: RecentResource.Kind) -> RecentResource {
    RecentResource(accountID: "acc1", kind: kind, resourceID: "r1", title: "r1")
  }
  #expect(resource(.zone).destination == .zone("r1"))
  #expect(resource(.worker).destination == .worker("r1"))
  #expect(resource(.pagesProject).destination == .pagesProject("r1"))
  #expect(resource(.r2Bucket).destination == .r2Bucket("r1", prefix: ""))
  #expect(resource(.kvNamespace).destination == .kvNamespace("r1"))
  #expect(resource(.zone).featureID == .zones)
  #expect(resource(.worker).featureID == .workers)
  #expect(resource(.pagesProject).featureID == .pages)
  #expect(resource(.r2Bucket).featureID == .r2)
  #expect(resource(.kvNamespace).featureID == .kv)
}

/// Tab roots are transparent so all three share one `DashWorkspaceTopWash`,
/// which only works if the UIKit plates above them are punched through in both
/// appearances — light chrome is white, dark chrome is black.
@Test @MainActor func systemPlatesAreClearedInBothAppearances() {
  #expect(DashCanvasPlateRules.isSystemPlate(.white))
  #expect(DashCanvasPlateRules.isSystemPlate(.black))
  #expect(
    DashCanvasPlateRules.isSystemPlate(
      UIColor(red: 0xFB / 255, green: 0xFB / 255, blue: 0xFB / 255, alpha: 1)))
  #expect(
    DashCanvasPlateRules.isSystemPlate(
      UIColor(red: 0x03 / 255, green: 0x03 / 255, blue: 0x03 / 255, alpha: 1)))
}

/// A real surface — a card fill, a tinted plate, anything already translucent —
/// is somebody's content, not system chrome, and must survive untouched.
@Test @MainActor func contentPlatesSurviveTheClearPass() {
  #expect(!DashCanvasPlateRules.isSystemPlate(nil))
  #expect(!DashCanvasPlateRules.isSystemPlate(.systemOrange))
  #expect(!DashCanvasPlateRules.isSystemPlate(UIColor(white: 0.5, alpha: 1)))
  #expect(!DashCanvasPlateRules.isSystemPlate(UIColor(white: 1, alpha: 0.5)))
}

/// The header frost is off at rest and fully in after a short scroll — the band
/// has to be there by the time the first row slides under the status bar.
@Test func headerFrostRampsInOverTheFirstScrolledPoints() {
  #expect(DashHeaderScrimRules.progress(distance: -40) == 0)
  #expect(DashHeaderScrimRules.progress(distance: 0) == 0)
  #expect(DashHeaderScrimRules.progress(distance: DashHeaderScrimMetrics.ramp / 2) == 0.5)
  #expect(DashHeaderScrimRules.progress(distance: DashHeaderScrimMetrics.ramp) == 1)
  #expect(DashHeaderScrimRules.progress(distance: DashHeaderScrimMetrics.ramp * 4) == 1)
}

/// Every tab page stays mounted and a push leaves its root mounted underneath,
/// so several screens report at once: the frost follows the deepest push on the
/// selected tab, never a background tab's scroll position.
@Test func headerFrostFollowsTheDeepestScreenOnTheActiveTab() {
  let entries: [Int: DashHeaderScrollEntry] = [
    1: DashHeaderScrollEntry(isTabActive: true, depth: 0, progress: 1),
    2: DashHeaderScrollEntry(isTabActive: true, depth: 1, progress: 0),
    3: DashHeaderScrollEntry(isTabActive: false, depth: 4, progress: 1),
  ]
  #expect(DashHeaderScrimRules.frontmost(of: entries) == 2)
  #expect(DashHeaderScrimRules.frontmost(of: entries.filter { $0.key == 3 }) == nil)
  #expect(DashHeaderScrimRules.frontmost(of: [Int: DashHeaderScrollEntry]()) == nil)
}

/// Popping back must hand the frost to the screen underneath at *its* scroll
/// position, and an empty registry must clear the band instead of stranding it.
@Test @MainActor func headerFrostReturnsToTheScreenUnderneathOnPop() {
  let root = NSObject()
  let pushed = NSObject()
  let state = DashHeaderScrollState()

  state.report(
    DashHeaderScrollEntry(isTabActive: true, depth: 0, progress: 1),
    from: ObjectIdentifier(root))
  #expect(state.progress == 1)

  state.report(
    DashHeaderScrollEntry(isTabActive: true, depth: 1, progress: 0),
    from: ObjectIdentifier(pushed))
  #expect(state.progress == 0)

  state.withdraw(ObjectIdentifier(pushed))
  #expect(state.progress == 1)

  state.withdraw(ObjectIdentifier(root))
  #expect(state.progress == 0)
}

/// The band is solid across the bar and then eases to fully clear — a hard stop
/// at the bottom is exactly the edge this gradient exists to avoid.
@Test func headerFrostFadesOutInsteadOfEndingOnAnEdge() {
  let stops = DashHeaderScrimRules.maskStops(solidFraction: 0.5)
  #expect(stops.first?.opacity == 1)
  #expect(stops.first?.location == 0)
  #expect(stops.last?.opacity == 0)
  #expect(stops.last?.location == 1)
  // Solid all the way through the bar, then never brightening again.
  #expect(stops.contains { $0.opacity == 1 && $0.location == 0.5 })
  #expect(
    stops.indices.dropFirst().allSatisfy { index in
      stops[index].opacity <= stops[index - 1].opacity
        && stops[index].location >= stops[index - 1].location
    })
}

@Test func navigationDimmingScrubberPreservesContentBearingContainer() {
  #expect(
    NavigationTransitionChromeRules.shouldHideDimmingView(
      className: "_UIParallaxDimmingView",
      hasSubviews: false))
  #expect(
    !NavigationTransitionChromeRules.shouldHideDimmingView(
      className: "_UIParallaxDimmingView",
      hasSubviews: true))
  #expect(
    !NavigationTransitionChromeRules.shouldHideDimmingView(
      className: "NavigationDimmingScrubberView",
      hasSubviews: false))
}

@Test func addDomainAcceptsPlausibleZoneNamesOnly() {
  #expect(AddDomainValidation.isPlausibleZoneName("example.com"))
  #expect(AddDomainValidation.isPlausibleZoneName("  Sub.Example.CO.UK  "))
  #expect(AddDomainValidation.isPlausibleZoneName("xn--fiq228c.example"))
  #expect(!AddDomainValidation.isPlausibleZoneName(""))
  #expect(!AddDomainValidation.isPlausibleZoneName("example"))
  #expect(!AddDomainValidation.isPlausibleZoneName("example."))
  #expect(!AddDomainValidation.isPlausibleZoneName(".com"))
  #expect(!AddDomainValidation.isPlausibleZoneName("exa mple.com"))
  #expect(!AddDomainValidation.isPlausibleZoneName("example.c"))
  #expect(AddDomainValidation.normalized("  New.Example.COM ") == "new.example.com")
}

@Test func pinnedZonesRoundTripToggleAndAccountFiltering() {
  let a = PinnedZone(accountID: "acc1", zoneID: "z1", name: "example.com")
  let b = PinnedZone(accountID: "acc2", zoneID: "z2", name: "xat.sh")

  // Encode/decode round-trip preserves order and fields.
  let encoded = PinnedZones.encode([a, b])
  #expect(encoded == "acc1|z1|example.com,acc2|z2|xat.sh")
  #expect(PinnedZones.decode(encoded) == [a, b])

  // Toggle adds when absent, removes when present.
  let added = PinnedZones.toggled("", pin: a)
  #expect(PinnedZones.isPinned(added, zoneID: "z1"))
  let newest = PinnedZone(accountID: "acc1", zoneID: "z3", name: "new.example")
  #expect(PinnedZones.decode(PinnedZones.toggled(added, pin: newest)) == [newest, a])
  let removed = PinnedZones.toggled(encoded, pin: a)
  #expect(!PinnedZones.isPinned(removed, zoneID: "z1"))
  #expect(PinnedZones.decode(removed) == [b])

  // Malformed entries are dropped, not crashed on.
  #expect(PinnedZones.decode("garbage,acc|only-two") == [])

  // Account filtering keeps other accounts' pins invisible.
  let mine = PinnedZones.decode(encoded).filter { $0.accountID == "acc1" }
  #expect(mine == [a])
}

@Test func pinnedZonesBootstrapOnceAndPrioritizePins() {
  let defaults = (1...5).map {
    PinnedZone(accountID: "acc1", zoneID: "z\($0)", name: "zone-\($0).example")
  }
  let bootstrapped = PinnedZones.bootstrapped(
    "",
    initializedAccountsRaw: "",
    accountID: "acc1",
    defaults: defaults)

  #expect(PinnedZones.decode(bootstrapped.pins) == Array(defaults.prefix(4)))
  #expect(bootstrapped.initializedAccounts == "acc1")
  #expect(
    PinnedZones.pinnedZoneIDs(in: bootstrapped.pins, accountID: "acc1")
      == ["z1", "z2", "z3", "z4"])
  #expect(
    PinnedZones.prioritizedZoneIDs(
      ["z5", "z3", "z2", "z1", "z4"],
      pinsRaw: bootstrapped.pins,
      accountID: "acc1"
    ) == ["z1", "z2", "z3", "z4", "z5"])

  // Once initialized, a deliberate empty pin set stays empty.
  let afterManualClear = PinnedZones.bootstrapped(
    "",
    initializedAccountsRaw: bootstrapped.initializedAccounts,
    accountID: "acc1",
    defaults: defaults)
  #expect(afterManualClear.pins.isEmpty)

  // Another account still initializes independently.
  let other = PinnedZones.bootstrapped(
    bootstrapped.pins,
    initializedAccountsRaw: bootstrapped.initializedAccounts,
    accountID: "acc2",
    defaults: [PinnedZone(accountID: "acc2", zoneID: "other", name: "other.example")])
  #expect(other.initializedAccounts == "acc1,acc2")
  #expect(PinnedZones.decode(other.pins).first?.accountID == "acc2")
}

@Test func domainCardColorsPersistPerAccountAndDomain() {
  let violet = DomainCardColors.parseToken("violet")!
  let orange = DomainCardColors.parseToken("orange")!
  let ocean = DomainCardColors.parseToken("ocean")!

  var raw = DomainCardColors.setting(
    violet,
    in: "",
    accountID: "acc1",
    zoneID: "zone1")
  raw = DomainCardColors.setting(
    orange,
    in: raw,
    accountID: "acc2",
    zoneID: "zone1")

  #expect(
    DomainCardColors.hex(
      in: raw, accountID: "acc1", zoneID: "zone1", seed: "example.com") == violet)
  #expect(
    DomainCardColors.hex(
      in: raw, accountID: "acc2", zoneID: "zone1", seed: "example.com") == orange)

  raw = DomainCardColors.setting(
    ocean,
    in: raw,
    accountID: "acc1",
    zoneID: "zone1")
  #expect(DomainCardColors.decode(raw).count == 2)
  #expect(
    DomainCardColors.hex(
      in: raw, accountID: "acc1", zoneID: "zone1", seed: "example.com") == ocean)
  #expect(DomainCardColors.decode("bad,acc|zone|unknown").isEmpty)
  #expect(raw.contains("#0369A1"))
}

@Test func domainCardColorsMigrateLegacyTintNames() {
  let raw = "acc1|zone1|violet,acc2|zone2|#BE123C"
  let decoded = DomainCardColors.decode(raw)
  #expect(decoded.count == 2)
  #expect(decoded[0].hex == 0x7E22CE)
  #expect(decoded[1].hex == 0xBE123C)
  #expect(DomainCardColors.encode(decoded).contains("#7E22CE"))
}

@Test func domainCardDefaultColorIsStable() {
  let first = DomainCardColors.defaultHex(for: "example.com")
  #expect(first == DomainCardColors.defaultHex(for: "example.com"))
  #expect(DomainCardColors.defaultPalette.contains(first))
  #expect(DomainCardColors.prefersLightContent(0x047857))
  #expect(!DomainCardColors.prefersLightContent(0xFDFDFD))
}

@Test func analyticsChartPointsParseAndSortAscending() {
  let daily = [
    ZoneAnalyticsDay(
      date: "2026-07-14", requests: 3, pageViews: 1, threats: 0, bytes: 30, uniques: 3),
    ZoneAnalyticsDay(
      date: "2026-07-12", requests: 1, pageViews: 0, threats: 0, bytes: 10, uniques: 1),
    ZoneAnalyticsDay(date: "not-a-date", requests: 9, pageViews: 9, threats: 9, bytes: 9),
    ZoneAnalyticsDay(
      date: "2026-07-13", requests: 2, pageViews: 0, threats: 1, bytes: 20, uniques: 2),
  ]
  let dayPoints = ZoneAnalyticsChartModel.points(fromDaily: daily)
  #expect(dayPoints.map(\.requests) == [1, 2, 3])  // bad date dropped, sorted ascending
  #expect(dayPoints.map(\.uniques) == [1, 2, 3])

  let hourly = [
    ZoneAnalyticsPoint(
      datetime: "2026-07-14T09:00:00Z", requests: 20, pageViews: 8, threats: 0, bytes: 40,
      uniques: 6),
    ZoneAnalyticsPoint(
      datetime: "2026-07-14T08:00:00.000Z", requests: 10, pageViews: 4, threats: 1, bytes: 20,
      uniques: 4),
    ZoneAnalyticsPoint(datetime: "garbage", requests: 99, pageViews: 0, threats: 0, bytes: 0),
  ]
  let hourPoints = ZoneAnalyticsChartModel.points(fromHourly: hourly)
  #expect(hourPoints.map(\.requests) == [10, 20])  // fractional seconds parsed, garbage dropped
  #expect(hourPoints.map(\.uniques) == [4, 6])
}

@Test func webAnalyticsSiteResolvesByRulesetZoneTag() {
  let sites = [
    RUMSite(
      siteTag: "site-other", autoInstall: true,
      ruleset: RUMRuleset(zoneTag: "zone-other", zoneName: "other.example", enabled: true)),
    RUMSite(
      siteTag: "site-mine", autoInstall: true,
      ruleset: RUMRuleset(zoneTag: "zone-mine", zoneName: "mine.example", enabled: true)),
    // A site created by host instead of zone carries no ruleset at all.
    RUMSite(siteTag: "site-hostonly", autoInstall: false),
  ]

  #expect(WebAnalyticsChartModel.site(for: "zone-mine", in: sites)?.siteTag == "site-mine")
  #expect(WebAnalyticsChartModel.site(for: "zone-absent", in: sites) == nil)
}

@Test func dashRouteParsesEveryGrammarForm() {
  func parse(_ string: String) -> DashRoute? {
    guard let url = URL(string: string) else { return nil }
    return DashRoute.parse(url)
  }

  #expect(parse("dash://settings") == .settings)
  #expect(parse("dash://watchtower") == .watchtower)
  #expect(parse("dash://zone/abc") == .zone("abc"))
  #expect(parse("dash://zone/abc/dns") == .zoneDNS("abc"))
  #expect(parse("dash://zone/abc/cache") == .zoneCache("abc"))
  #expect(parse("dash://zone/abc/settings") == .zoneSettings("abc"))
  #expect(parse("dash://zone/abc/analytics") == .zoneAnalytics("abc"))
  #expect(parse("dash://zone/abc/waf") == .zoneWAF("abc"))
  #expect(parse("dash://zone/abc/unknown") == .zone("abc"))  // unknown subpath falls back
  #expect(parse("dash://feature/workers") == .feature(.workers))
  #expect(parse("dash://worker/my%20worker") == .worker("my worker"))  // percent-decoded
  #expect(parse("dash://pages/docs") == .pagesProject("docs"))
  #expect(
    parse("dash://pages/docs/deployments/dep-1")
      == .pagesDeployment(project: "docs", deploymentID: "dep-1"))
  #expect(parse("dash://pages/docs/domains") == .pagesDomains("docs"))
  #expect(parse("dash://r2/my-bucket") == .r2("my-bucket"))
  #expect(parse("dash://kv/ns1") == .kv("ns1"))

  // Optional account scope is parsed without changing the destination.
  let scoped = parse("dash://pages/docs?account=account-1")
  #expect(scoped?.accountID == "account-1")
  #expect(scoped?.unscoped == .pagesProject("docs"))
  #expect(scoped?.destination == .pagesProject("docs"))

  // Rejections.
  #expect(parse("dash://oauth/callback?code=x") == nil)  // owned by the auth session
  #expect(parse("dash://feature/bogus") == nil)  // unknown FeatureID
  #expect(parse("dash://feature/d1") == nil)  // retired FeatureID
  #expect(parse("dash://d1/db-uuid") == nil)  // retired host; stale Spotlight items land here
  #expect(parse("dash://zone") == nil)  // missing id
  #expect(parse("https://watchtower") == nil)  // wrong scheme
  #expect(parse("dash://unknownhost") == nil)
  #expect(parse("dash://watchtower?account=") == nil)
  #expect(parse("dash://watchtower?account=a&account=b") == nil)
  #expect(parse("dash://settings/extra") == nil)

  // destination mapping.
  #expect(DashRoute.settings.destination == .settings)
  #expect(DashRoute.watchtower.destination == nil)
  #expect(DashRoute.zoneDNS("z").destination == .dns("z"))
  #expect(DashRoute.feature(.r2).destination == .feature(.r2))
  #expect(DashRoute.worker("w").destination == .worker("w"))
  #expect(DashRoute.r2("b").destination == .r2Bucket("b", prefix: ""))
  #expect(DashRoute.kv("n").destination == .kvNamespace("n"))
}

@Test func dashRouteRequiresConfirmationBeforeSwitchingAccounts() {
  let route = DashRoute.r2("assets").scoped(to: "account-a")

  #expect(
    route.accountResolution(
      activeAccountID: "account-a",
      availableAccountIDs: ["account-a", "account-b"])
      == .open(.r2("assets")))
  #expect(
    route.accountResolution(
      activeAccountID: "account-b",
      availableAccountIDs: ["account-a", "account-b"])
      == .confirmSwitch(accountID: "account-a", route: .r2("assets")))
  #expect(
    route.accountResolution(
      activeAccountID: "account-b",
      availableAccountIDs: ["account-b"])
      == .rejectUnavailable(accountID: "account-a"))

  // Legacy links remain current-account routes for backwards compatibility.
  #expect(
    DashRoute.r2("assets").accountResolution(
      activeAccountID: "account-b",
      availableAccountIDs: ["account-a", "account-b"])
      == .open(.r2("assets")))
}

@Test func watchtowerNotificationRouteCarriesAccountContext() {
  let route = WatchtowerNotifier.watchtowerRoute(accountID: "account with spaces")
  #expect(route == "dash://watchtower?account=account%20with%20spaces")
  #expect(
    route.flatMap(URL.init(string:)).flatMap(DashRoute.parse)?.accountID
      == "account with spaces")
  #expect(WatchtowerNotifier.watchtowerRoute(accountID: "  ") == nil)
}

@Test func legacyNotificationRoutesNeverGuessBetweenAccounts() {
  let legacy = DashRoute.zone("zone-1")
  #expect(
    NotificationRoutePolicy.resolve(legacy, availableAccountIDs: [])
      == .deferUntilAccountsLoad)
  #expect(
    NotificationRoutePolicy.resolve(legacy, availableAccountIDs: ["account-1"])
      == .open(legacy.scoped(to: "account-1")))
  #expect(
    NotificationRoutePolicy.resolve(
      legacy,
      availableAccountIDs: ["account-1", "account-2"])
      == .rejectAmbiguous)
  #expect(
    NotificationRoutePolicy.resolve(
      legacy,
      availableAccountIDs: ["demo-account"],
      allowsLegacyAccountInference: false)
      == .rejectAmbiguous)

  let scoped = legacy.scoped(to: "account-2")
  #expect(
    NotificationRoutePolicy.resolve(scoped, availableAccountIDs: [])
      == .open(scoped))
}

@Test func pushRegistrationTracksAccountsAndValidatesOpaqueRelayURLs() throws {
  let suite = "dash.tests.push.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }

  defaults.set("webhook-b", forKey: PushRegistrationService.webhookIDKey(accountID: "account-b"))
  defaults.set("webhook-a", forKey: PushRegistrationService.webhookIDKey(accountID: "account-a"))
  defaults.set("", forKey: PushRegistrationService.webhookIDKey(accountID: "empty"))
  defaults.set("unrelated", forKey: "dash.other")
  #expect(
    PushRegistrationService.enabledAccountIDs(in: defaults)
      == ["account-a", "account-b"])

  let opaque = String(repeating: "Abc_123-", count: 10)
  let scoped = "https://dash.xat.sh/push/notify/\(opaque)"
  let relay = try #require(URL(string: "https://dash.xat.sh"))
  #expect(
    PushRegistrationService.isValidRelayNotifyURL(
      scoped,
      relayBaseURL: relay))
  #expect(
    !PushRegistrationService.isValidRelayNotifyURL(
      scoped.replacingOccurrences(of: "dash.xat.sh", with: "example.com"),
      relayBaseURL: relay))
  #expect(
    !PushRegistrationService.isValidRelayNotifyURL(
      "https://dash.xat.sh/push/notify/short",
      relayBaseURL: relay))
  #expect(
    !PushRegistrationService.isValidRelayNotifyURL(
      "https://dash.xat.sh/push/notify/\(opaque).legacy",
      relayBaseURL: relay))
  #expect(
    !PushRegistrationService.isValidRelayNotifyURL(
      "https://dash.xat.sh/push/notify/\(opaque)?account=account-a",
      relayBaseURL: relay))
  #expect(
    !PushRegistrationService.isValidRelayNotifyURL(
      "https://dash.xat.sh/push/notify/\(opaque)/extra",
      relayBaseURL: relay))
}

@Test func pushPayloadSeparatesPossessionChallengeFromAccountRefresh() throws {
  let challenge = try #require(
    PushRemoteNotificationPayload.registrationChallenge(from: [
      "aps": ["content-available": 1],
      "dashKind": "registration-challenge",
      "requestID": "request-1",
      "ticket": "sealed-ticket",
      "nonce": "nonce-1",
    ]))
  #expect(
    challenge
      == PushRegistrationChallenge(
        requestID: "request-1",
        ticket: "sealed-ticket",
        nonce: "nonce-1"))
  #expect(
    PushRemoteNotificationPayload.accountID(from: [
      "aps": ["content-available": 1],
      "dashAccountID": "account-a",
    ]) == "account-a")
  #expect(
    PushRemoteNotificationPayload.registrationChallenge(from: [
      "dashKind": "registration-challenge",
      "requestID": "unsolicited",
    ]) == nil)
  #expect(PushRemoteNotificationPayload.accountID(from: ["dashAccountID": "  "]) == nil)
}

@Test func pushAuthorizationIncludesBadgeDelivery() {
  let provisional = WatchtowerNotifier.authorizationOptions(prominently: false)
  #expect(provisional.contains(.alert))
  #expect(provisional.contains(.sound))
  #expect(provisional.contains(.badge))
  #expect(provisional.contains(.provisional))

  let prominent = WatchtowerNotifier.authorizationOptions(prominently: true)
  #expect(prominent.contains(.alert))
  #expect(prominent.contains(.sound))
  #expect(prominent.contains(.badge))
  #expect(!prominent.contains(.provisional))

  // `.notSupported` is what a real legacy install reports — the badge option
  // was never requested, so iOS never had a setting to disable. Matching only
  // `.disabled` skipped every one of them.
  let authorizedMigration = WatchtowerNotifier.badgeAuthorizationMigrationOptions(
    authorizationStatus: .authorized,
    badgeSetting: .notSupported)
  #expect(authorizedMigration == [.badge])
  let provisionalMigration = WatchtowerNotifier.badgeAuthorizationMigrationOptions(
    authorizationStatus: .provisional,
    badgeSetting: .notSupported)
  #expect(provisionalMigration?.contains(.badge) == true)
  #expect(provisionalMigration?.contains(.provisional) == true)
  #expect(
    WatchtowerNotifier.badgeAuthorizationMigrationOptions(
      authorizationStatus: .authorized,
      badgeSetting: .disabled) == [.badge])
  #expect(
    WatchtowerNotifier.badgeAuthorizationMigrationOptions(
      authorizationStatus: .authorized,
      badgeSetting: .enabled) == nil)
  #expect(
    WatchtowerNotifier.badgeAuthorizationMigrationOptions(
      authorizationStatus: .denied,
      badgeSetting: .notSupported) == nil)
  #expect(
    WatchtowerNotifier.badgeAuthorizationMigrationOptions(
      authorizationStatus: .notDetermined,
      badgeSetting: .notSupported) == nil)
}

@Test func pushChallengeInboxRejectsUnsolicitedAndReplayedChallenges() async throws {
  let inbox = PushRegistrationChallengeInbox()
  let challenge = PushRegistrationChallenge(
    requestID: "request-1",
    ticket: "sealed-ticket",
    nonce: "nonce-1")
  let unsolicited = await inbox.receive(challenge)
  #expect(!unsolicited)

  await inbox.prepare(requestID: challenge.requestID)
  let accepted = await inbox.receive(challenge)
  #expect(accepted)
  let delivered = try await inbox.wait(for: challenge.requestID, timeout: .seconds(1))
  #expect(delivered == challenge)
  let replayed = await inbox.receive(challenge)
  #expect(!replayed)
}

@Test @MainActor func pushOperationGateLetsDisableSupersedeReconcile() throws {
  let accountID = "gate-\(UUID().uuidString)"
  let reconcile = try #require(
    PushRegistrationOperationGate.beginReconcile(
      accountID: accountID,
      isCurrentlyEnabled: true))
  #expect(PushRegistrationOperationGate.isCurrent(reconcile, enabled: true))

  let disable = PushRegistrationOperationGate.beginDesiredChange(
    accountID: accountID,
    enabled: false)
  #expect(!PushRegistrationOperationGate.isCurrent(reconcile, enabled: true))
  #expect(PushRegistrationOperationGate.isCurrent(disable, enabled: false))
  #expect(
    PushRegistrationOperationGate.beginReconcile(
      accountID: accountID,
      isCurrentlyEnabled: true) == nil)
}

@Test @MainActor func signOutPreparationInvalidatesUnstoredPushEnables() {
  let enablingAccount = "enable-\(UUID().uuidString)"
  let reconcilingAccount = "reconcile-\(UUID().uuidString)"
  let enable = PushRegistrationOperationGate.beginDesiredChange(
    accountID: enablingAccount,
    enabled: true)
  let reconcile = PushRegistrationOperationGate.beginReconcile(
    accountID: reconcilingAccount,
    isCurrentlyEnabled: true)

  PushRegistrationService.prepareForSignOut(
    accountIDs: [enablingAccount, reconcilingAccount])

  #expect(!PushRegistrationOperationGate.isCurrent(enable, enabled: true))
  #expect(reconcile != nil)
  if let reconcile {
    #expect(!PushRegistrationOperationGate.isCurrent(reconcile, enabled: true))
  }
  #expect(
    PushRegistrationOperationGate.beginReconcile(
      accountID: enablingAccount,
      isCurrentlyEnabled: true) == nil)
  #expect(
    PushRegistrationOperationGate.beginReconcile(
      accountID: reconcilingAccount,
      isCurrentlyEnabled: true) == nil)
}

@Test func pushWebhookNameIsStableWithoutExposingTheDeviceToken() {
  let token = String(repeating: "ab", count: 32)
  let otherToken = String(repeating: "cd", count: 32)
  let name = PushRegistrationService.webhookName(deviceToken: token)
  #expect(name == PushRegistrationService.webhookName(deviceToken: token.uppercased()))
  #expect(name != PushRegistrationService.webhookName(deviceToken: otherToken))
  #expect(!name.localizedCaseInsensitiveContains(token))
}

@Test func pushCleanupTombstonesPreserveTheRemoteDeletionHandle() throws {
  let suite = "dash.tests.push-cleanup.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let webhookKey = PushRegistrationService.webhookIDKey(accountID: "account-a")
  defaults.set("webhook-a", forKey: webhookKey)

  PushRegistrationService.recordCleanupAttempt(
    webhookID: "webhook-a",
    accountID: "account-a",
    defaults: defaults,
    now: Date(timeIntervalSince1970: 100))
  PushRegistrationService.recordCleanupAttempt(
    webhookID: "webhook-a",
    accountID: "account-a",
    defaults: defaults,
    now: Date(timeIntervalSince1970: 200))

  #expect(defaults.string(forKey: webhookKey) == "webhook-a")
  #expect(PushRegistrationService.pendingCleanupAccountIDs(in: defaults) == ["account-a"])
  #expect(PushRegistrationService.reconcilableAccountIDs(in: defaults).isEmpty)
  let tombstone = try #require(
    PushRegistrationService.cleanupTombstone(accountID: "account-a", in: defaults))
  #expect(tombstone.webhookID == "webhook-a")
  #expect(tombstone.attempts == 2)
  #expect(tombstone.lastAttemptAt == Date(timeIntervalSince1970: 200))

  PushRegistrationService.clearCleanup(accountID: "account-a", defaults: defaults)
  #expect(PushRegistrationService.pendingCleanupAccountIDs(in: defaults).isEmpty)
  #expect(PushRegistrationService.reconcilableAccountIDs(in: defaults) == ["account-a"])
}

@Test @MainActor
func remoteWatchtowerRefreshStaysAccountScopedAndSuppressesDuplicateAlerts() throws {
  let suite = "dash.tests.watchtower-remote-refresh.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }

  WatchtowerRemoteRefreshInvalidationStore.mark(
    accountID: "account-b",
    defaults: defaults)
  #expect(
    WatchtowerRemoteRefreshInvalidationStore.contains(
      accountID: "account-b", defaults: defaults))
  #expect(
    !WatchtowerRemoteRefreshInvalidationStore.contains(
      accountID: "account-a", defaults: defaults))
  #expect(
    !WatchtowerRemoteRefreshInvalidationStore.allowsLocalNotifications(
      source: .foreground,
      accountID: "account-b",
      defaults: defaults))
  #expect(
    WatchtowerRemoteRefreshInvalidationStore.allowsLocalNotifications(
      source: .foreground,
      accountID: "account-a",
      defaults: defaults))
  #expect(
    !WatchtowerRemoteRefreshInvalidationStore.allowsLocalNotifications(
      source: .remoteNotification,
      accountID: "account-a",
      defaults: defaults))
  WatchtowerRemoteRefreshInvalidationStore.mark(
    accountID: "account-b",
    defaults: defaults)
  WatchtowerRemoteRefreshInvalidationStore.clear(
    accountID: "account-b",
    matching: 1,
    defaults: defaults)
  #expect(
    WatchtowerRemoteRefreshInvalidationStore.pendingGeneration(
      accountID: "account-b", defaults: defaults) == 2)
  WatchtowerRemoteRefreshInvalidationStore.clear(
    accountID: "account-b",
    matching: 2,
    defaults: defaults)
  #expect(
    WatchtowerRemoteRefreshInvalidationStore.generation(
      accountID: "account-b", defaults: defaults) == 2)
  #expect(
    WatchtowerRemoteRefreshInvalidationStore.pendingGeneration(
      accountID: "account-b", defaults: defaults) == nil)
  #expect(
    WatchtowerRemoteRefreshInvalidationStore.allowsLocalNotifications(
      source: .foreground,
      accountID: "account-b",
      defaults: defaults))
}

@Test func notificationAccountAuthorizationDefaultsClosed() throws {
  let suite = "dash.tests.notification-accounts.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }

  #expect(!NotificationAccountAuthorizationStore.contains("account-a", in: defaults))
  NotificationAccountAuthorizationStore.replace(
    with: ["account-a", " account-b ", ""],
    in: defaults)
  #expect(NotificationAccountAuthorizationStore.contains("account-a", in: defaults))
  #expect(NotificationAccountAuthorizationStore.contains("account-b", in: defaults))
  #expect(!NotificationAccountAuthorizationStore.contains("account-c", in: defaults))
  #expect(!NotificationAccountAuthorizationStore.contains(nil, in: defaults))
  NotificationAccountAuthorizationStore.clear(in: defaults)
  #expect(!NotificationAccountAuthorizationStore.contains("account-a", in: defaults))
}

@Test func r2DelayedAttachmentGateRejectsStaleAndDismantledCallbacks() {
  var gate = R2DelayedAttachmentGate()
  let first = gate.schedule()
  #expect(gate.accepts(first))
  let second = gate.schedule()
  #expect(!gate.accepts(first))
  #expect(gate.accepts(second))
  gate.invalidate()
  #expect(!gate.accepts(second))
}

private actor ZoneSecurityLevelTestLatch {
  private var isOpen = false
  private var continuations: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { continuation in
      continuations.append(continuation)
    }
  }

  func open() {
    guard !isOpen else { return }
    isOpen = true
    let pending = continuations
    continuations.removeAll()
    for continuation in pending {
      continuation.resume()
    }
  }
}

@Test @MainActor func underAttackOperationsSerializeAcrossCloudflareAwaits() async throws {
  let suite = "dash.tests.under-attack-serialized.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let zoneID = "zone"
  let updateStarted = ZoneSecurityLevelTestLatch()
  let allowUpdate = ZoneSecurityLevelTestLatch()
  var remoteLevel = "high"
  var events: [String] = []

  let backend = ZoneSecurityLevelOperation.Backend(
    securityLevelValue: { _ in
      events.append("read:\(remoteLevel)")
      return .string(remoteLevel)
    },
    updateLevel: { _, level in
      events.append("write:\(level):start")
      if level == "under_attack" {
        await updateStarted.open()
        await allowUpdate.wait()
      }
      remoteLevel = level
      events.append("write:\(level):end")
    })

  let enable = Task { @MainActor in
    try await ZoneSecurityLevelOperation.setUnderAttack(
      zoneID: zoneID,
      enabled: true,
      defaults: defaults,
      backend: backend)
  }
  await updateStarted.wait()

  let disable = Task { @MainActor in
    try await ZoneSecurityLevelOperation.setUnderAttack(
      zoneID: zoneID,
      enabled: false,
      defaults: defaults,
      backend: backend)
  }
  await Task.yield()
  await Task.yield()
  #expect(events == ["read:high", "write:under_attack:start"])

  await allowUpdate.open()
  let enabled = try await enable.value
  let disabled = try await disable.value

  #expect(enabled == .init(currentLevel: "under_attack", changed: true))
  #expect(disabled == .init(currentLevel: "high", changed: true))
  #expect(remoteLevel == "high")
  #expect(defaults.string(forKey: ZoneSecurityLevelOperation.key(for: zoneID)) == nil)
  #expect(
    events == [
      "read:high",
      "write:under_attack:start",
      "write:under_attack:end",
      "read:under_attack",
      "write:high:start",
      "write:high:end",
    ])
}

@Test @MainActor func underAttackEnableDefinitiveFailureClearsStagedStashAndReleasesGate()
  async throws
{
  let suite = "dash.tests.under-attack-definitive-failure.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let zoneID = "zone"
  let key = ZoneSecurityLevelOperation.key(for: zoneID)
  defaults.set("stale", forKey: key)
  var shouldReject = true

  let backend = ZoneSecurityLevelOperation.Backend(
    securityLevelValue: { _ in .string("high") },
    updateLevel: { _, _ in
      if shouldReject {
        throw CloudflareAPIError.request(status: 403, errors: [])
      }
    })

  do {
    _ = try await ZoneSecurityLevelOperation.setUnderAttack(
      zoneID: zoneID,
      enabled: true,
      defaults: defaults,
      backend: backend)
    Issue.record("Expected the explicit Cloudflare rejection.")
  } catch {
    guard case .request(let status, _) = error as? CloudflareAPIError else {
      Issue.record("Expected a Cloudflare request error, got \(error).")
      return
    }
    #expect(status == 403)
  }
  #expect(defaults.string(forKey: key) == nil)

  shouldReject = false
  let retry = try await ZoneSecurityLevelOperation.setUnderAttack(
    zoneID: zoneID,
    enabled: true,
    defaults: defaults,
    backend: backend)
  #expect(retry == .init(currentLevel: "under_attack", changed: true))
  #expect(defaults.string(forKey: key) == "high")
}

@Test @MainActor func underAttackAmbiguousEnableFailuresPreserveTheStagedLevel() async throws {
  let suite = "dash.tests.under-attack-ambiguous-failure.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let failures: [(String, CloudflareAPIError)] = [
    ("transport", .transport("Connection lost")),
    ("server", .request(status: 503, errors: [])),
  ]

  for (zoneID, failure) in failures {
    let backend = ZoneSecurityLevelOperation.Backend(
      securityLevelValue: { _ in .string("high") },
      updateLevel: { _, _ in throw failure })

    do {
      _ = try await ZoneSecurityLevelOperation.setUnderAttack(
        zoneID: zoneID,
        enabled: true,
        defaults: defaults,
        backend: backend)
      Issue.record("Expected the ambiguous Cloudflare failure.")
    } catch {
      // The stash assertion is the contract under test; both failures propagate.
    }

    #expect(
      defaults.string(forKey: ZoneSecurityLevelOperation.key(for: zoneID)) == "high")
  }
}

@Test @MainActor func underAttackDisableFailurePreservesRestoreLevel() async throws {
  let suite = "dash.tests.under-attack-disable-failure.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let zoneID = "zone"
  let key = ZoneSecurityLevelOperation.key(for: zoneID)
  defaults.set("high", forKey: key)
  let backend = ZoneSecurityLevelOperation.Backend(
    securityLevelValue: { _ in .string("under_attack") },
    updateLevel: { _, _ in
      throw CloudflareAPIError.request(status: 403, errors: [])
    })

  do {
    _ = try await ZoneSecurityLevelOperation.setUnderAttack(
      zoneID: zoneID,
      enabled: false,
      defaults: defaults,
      backend: backend)
    Issue.record("Expected the restore request to fail.")
  } catch {
    // A retry still needs the exact restore level after every failed disable.
  }

  #expect(defaults.string(forKey: key) == "high")
}

@Test @MainActor func underAttackReadFailurePreservesStashAndNeverWrites() async throws {
  let suite = "dash.tests.under-attack-read-failure.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  var updateCount = 0

  for enabled in [true, false] {
    let zoneID = enabled ? "enable" : "disable"
    let key = ZoneSecurityLevelOperation.key(for: zoneID)
    defaults.set("high", forKey: key)
    let backend = ZoneSecurityLevelOperation.Backend(
      securityLevelValue: { _ in
        throw CloudflareAPIError.request(status: 403, errors: [])
      },
      updateLevel: { _, _ in updateCount += 1 })

    do {
      _ = try await ZoneSecurityLevelOperation.setUnderAttack(
        zoneID: zoneID,
        enabled: enabled,
        defaults: defaults,
        backend: backend)
      Issue.record("Expected the security-level read to fail.")
    } catch {
      // A failed GET proves nothing about the remote state, so the stash stays.
    }

    #expect(defaults.string(forKey: key) == "high")
  }
  #expect(updateCount == 0)
}

@Test @MainActor func underAttackInvalidSecurityValueFailsClosed() async throws {
  let suite = "dash.tests.under-attack-invalid-value.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let invalidValues: [JSONValue?] = [nil, .bool(true)]
  var updateCount = 0

  for (index, value) in invalidValues.enumerated() {
    let zoneID = "zone-\(index)"
    let key = ZoneSecurityLevelOperation.key(for: zoneID)
    defaults.set("stale", forKey: key)
    let backend = ZoneSecurityLevelOperation.Backend(
      securityLevelValue: { _ in value },
      updateLevel: { _, _ in updateCount += 1 })

    do {
      _ = try await ZoneSecurityLevelOperation.setUnderAttack(
        zoneID: zoneID,
        enabled: true,
        defaults: defaults,
        backend: backend)
      Issue.record("Expected a missing or non-string security level to fail.")
    } catch {
      guard case .invalidResponse = error as? CloudflareAPIError else {
        Issue.record("Expected invalidResponse, got \(error).")
        continue
      }
    }

    #expect(defaults.string(forKey: key) == "stale")
  }
  #expect(updateCount == 0)
}

@Test @MainActor func underAttackDisableWhenAlreadyOffClearsStaleStashWithoutWriting()
  async throws
{
  let suite = "dash.tests.under-attack-disable-no-op.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let zoneID = "zone"
  let key = ZoneSecurityLevelOperation.key(for: zoneID)
  defaults.set("high", forKey: key)
  var updateCount = 0
  let backend = ZoneSecurityLevelOperation.Backend(
    securityLevelValue: { _ in .string("low") },
    updateLevel: { _, _ in updateCount += 1 })

  let outcome = try await ZoneSecurityLevelOperation.setUnderAttack(
    zoneID: zoneID,
    enabled: false,
    defaults: defaults,
    backend: backend)

  #expect(outcome == .init(currentLevel: "low", changed: false))
  #expect(updateCount == 0)
  #expect(defaults.string(forKey: key) == nil)
}

@Test @MainActor func underAttackCancellationReleasesGateAndSkipsCancelledWaiter()
  async throws
{
  let suite = "dash.tests.under-attack-cancellation.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let zoneID = "zone"
  let updateStarted = ZoneSecurityLevelTestLatch()
  let allowUpdate = ZoneSecurityLevelTestLatch()
  var remoteLevel = "high"
  var readCount = 0

  let backend = ZoneSecurityLevelOperation.Backend(
    securityLevelValue: { _ in
      readCount += 1
      return .string(remoteLevel)
    },
    updateLevel: { _, level in
      await updateStarted.open()
      await allowUpdate.wait()
      remoteLevel = level
    })

  let active = Task { @MainActor in
    try await ZoneSecurityLevelOperation.setUnderAttack(
      zoneID: zoneID,
      enabled: true,
      defaults: defaults,
      backend: backend)
  }
  await updateStarted.wait()

  let cancelledWaiter = Task { @MainActor in
    try await ZoneSecurityLevelOperation.setUnderAttack(
      zoneID: zoneID,
      enabled: true,
      defaults: defaults,
      backend: backend)
  }
  await Task.yield()
  await Task.yield()
  cancelledWaiter.cancel()
  do {
    _ = try await cancelledWaiter.value
    Issue.record("Expected the queued operation to be cancelled.")
  } catch {
    #expect(error is CancellationError)
  }

  let follower = Task { @MainActor in
    try await ZoneSecurityLevelOperation.setUnderAttack(
      zoneID: zoneID,
      enabled: true,
      defaults: defaults,
      backend: backend)
  }
  active.cancel()
  await allowUpdate.open()

  do {
    _ = try await active.value
    Issue.record("Expected the active operation to observe cancellation.")
  } catch {
    #expect(error is CancellationError)
  }
  let outcome = try await follower.value

  #expect(outcome == .init(currentLevel: "under_attack", changed: false))
  #expect(remoteLevel == "under_attack")
  #expect(readCount == 2)
  #expect(
    defaults.string(forKey: ZoneSecurityLevelOperation.key(for: zoneID)) == "high")
}

@Test func r2BucketIntentEntityIdentifierIncludesAccount() throws {
  let first = R2BucketEntity(
    accountID: "account-a", accountName: "Personal", name: "assets")
  let second = R2BucketEntity(
    accountID: "account-b", accountName: "Work", name: "assets")

  #expect(first.id != second.id)
  #expect(first.displayRepresentation != second.displayRepresentation)

  let decoded = try #require(R2BucketEntity.decodeIdentifier(first.id))
  #expect(decoded.accountID == "account-a")
  #expect(decoded.bucketName == "assets")
  #expect(R2BucketEntity.decodeIdentifier("assets") == nil)
}

@Test func zoneEntityMapsFromCloudflareZone() throws {
  let zone = try JSONDecoder().decode(
    CloudflareZone.self,
    from: Data(#"{"id":"z1","name":"example.com","status":"active"}"#.utf8))
  let entity = ZoneEntity(zone: zone)
  #expect(entity.id == "z1")
  #expect(entity.name == "example.com")
}

@Test func watchtowerWidgetSnapshotMapsAndRoundTrips() throws {
  let suite = "dash.tests.widget-snapshot.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  let formatter = ISO8601DateFormatter()
  let old = NotificationHistoryEntry(
    historyID: "old", name: "Older delivery", alertType: "test",
    sent: formatter.string(from: Date(timeIntervalSince1970: 100)))

  // The first page is the local read baseline, so it lands in history.
  let baseline = WatchtowerSnapshot(
    alerts: [old], alertsStatus: .ok, fetchedAt: Date(timeIntervalSince1970: 1_000_000)
  ).widgetSnapshot(accountID: "account-1", accountName: "Acme", defaults: defaults)
  #expect(baseline.unreadCount == 0)
  #expect(baseline.alerts.isEmpty)

  let fresh = NotificationHistoryEntry(
    historyID: "fresh", name: "Tunnel health", alertType: "tunnel_health_event",
    alertBody: "homelab-01 disconnected",
    sent: formatter.string(from: Date(timeIntervalSinceNow: 60)))
  let widget = WatchtowerSnapshot(
    alerts: [fresh, old], alertsStatus: .ok, fetchedAt: Date(timeIntervalSince1970: 1_000_000)
  ).widgetSnapshot(accountID: "account-1", accountName: "Acme", defaults: defaults)

  #expect(widget.unreadCount == 1)
  #expect(widget.alerts.map(\.title) == ["Tunnel health"])
  #expect(!widget.alertsUnavailable)
  #expect(widget.accountID == "account-1")
  #expect(widget.accountName == "Acme")
  #expect(widget.deepLinkURL?.absoluteString == "dash://watchtower?account=account-1")

  // A failed history fetch says so instead of claiming an empty inbox.
  let unavailable = WatchtowerSnapshot(
    alerts: [], alertsStatus: .error, fetchedAt: Date(timeIntervalSince1970: 1_000_000)
  ).widgetSnapshot(accountID: "account-1", accountName: nil, defaults: defaults)
  #expect(unavailable.alertsUnavailable)

  // Codable round-trips through the App Group file format.
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("watchtower-\(UUID().uuidString).json")
  try widget.write(to: url)
  let loaded = try WatchtowerWidgetSnapshot.load(from: url)
  #expect(loaded == widget)
  WatchtowerWidgetSnapshot.clear(at: url)

  // A snapshot written before Watchtower dropped its health verdict decodes as
  // "nothing unread" rather than resurrecting deleted issue counts.
  let legacy = try JSONDecoder().decode(
    WatchtowerWidgetSnapshot.self,
    from: Data(
      """
      {
        "issueCount": 3,
        "criticalCount": 1,
        "warningCount": 2,
        "signals": [{"title": "Tunnels", "detail": "1 down", "status": "critical"}],
        "accountName": "Legacy",
        "fetchedAt": 0
      }
      """.utf8)
  )
  #expect(legacy.unreadCount == 0)
  #expect(legacy.alerts.isEmpty)
  #expect(legacy.accountID == nil)
  #expect(legacy.deepLinkURL == nil)
  var whitespaceAccount = legacy
  whitespaceAccount.accountID = "  "
  #expect(whitespaceAccount.deepLinkURL == nil)
}

@Test func watchtowerWidgetStalenessTiers() {
  let base = WatchtowerWidgetSnapshot(
    unreadCount: 0, alerts: [], accountName: nil,
    fetchedAt: Date(timeIntervalSince1970: 0))
  #expect(base.staleness(now: Date(timeIntervalSince1970: 3600)) == .fresh)
  #expect(base.staleness(now: Date(timeIntervalSince1970: 3 * 3600)) == .aging)
  #expect(base.staleness(now: Date(timeIntervalSince1970: 25 * 3600)) == .stale)
  // Widget copy still uses Bundle `String(localized:)` — compare against the
  // same resolver so the assertion holds on zh-Hans simulators too.
  let agingRelative = String(localized: "\(3) hr ago")
  #expect(
    WatchtowerFreshness.checkedText(
      fetchedAt: base.fetchedAt,
      now: Date(timeIntervalSince1970: 3 * 3_600))
      == String(localized: "Checked \(agingRelative) · Refresh recommended"))
  let staleRelative = String(localized: "1 day ago")
  #expect(
    WatchtowerFreshness.checkedText(
      fetchedAt: base.fetchedAt,
      now: Date(timeIntervalSince1970: 25 * 3_600))
      == String(localized: "Checked \(staleRelative) · Refresh now"))
}

@Test func watchtowerNotificationPlannerDiffsDeliveries() {
  func snapshot(_ ids: [String], detail: String? = "d") -> WatchtowerWidgetSnapshot {
    WatchtowerWidgetSnapshot(
      unreadCount: ids.count,
      alerts: ids.map { .init(id: $0, title: $0, detail: detail) },
      accountID: "account-1", accountName: nil,
      fetchedAt: Date(timeIntervalSince1970: 0))
  }
  typealias Planner = WatchtowerNotificationPlanner

  // First run: nothing to diff against.
  #expect(Planner.plans(previous: nil, current: snapshot(["a"])).isEmpty)

  // A delivery that was not in the baseline fires with a stable identifier.
  let arrived = Planner.plans(previous: snapshot(["a"]), current: snapshot(["tunnel", "a"]))
  #expect(arrived.map(\.identifier) == ["watchtower.alert.tunnel"])
  #expect(arrived.first?.title == "tunnel")
  #expect(arrived.first?.body == "d")

  // An unchanged page does not re-notify.
  #expect(Planner.plans(previous: snapshot(["a"]), current: snapshot(["a"])).isEmpty)

  // Several new deliveries collapse into one summary keeping the first body.
  let summary = Planner.plans(previous: snapshot([]), current: snapshot(["tunnel", "pages"]))
  #expect(summary.map(\.identifier) == ["watchtower.alerts"])
  #expect(summary.first?.title == "tunnel")
  #expect(summary.first?.body == "d · 1 more unread alert.")

  // A delivery with no body still says something useful.
  let bodyless = Planner.plans(
    previous: snapshot([]), current: snapshot(["tunnel"], detail: nil))
  #expect(bodyless.first?.body == "New alert from Cloudflare.")

  // Read/ignored away → nothing.
  #expect(Planner.plans(previous: snapshot(["a"]), current: snapshot([])).isEmpty)
}

@Test func watchtowerNotificationPlannerResetsBaselineAcrossAccounts() {
  func snapshot(accountID: String?, alerts: [WatchtowerWidgetSnapshot.Alert])
    -> WatchtowerWidgetSnapshot
  {
    WatchtowerWidgetSnapshot(
      unreadCount: alerts.count,
      alerts: alerts,
      accountID: accountID,
      accountName: nil,
      fetchedAt: Date(timeIntervalSince1970: 0))
  }

  let alert = WatchtowerWidgetSnapshot.Alert(
    id: "cf:1", title: "Pages deployment", detail: "Latest deployment failed")
  let current = snapshot(accountID: "account-b", alerts: [alert])

  #expect(
    WatchtowerNotificationPlanner.plans(
      previous: snapshot(accountID: "account-a", alerts: []),
      current: current
    ).isEmpty)
  #expect(
    WatchtowerNotificationPlanner.plans(
      previous: snapshot(accountID: nil, alerts: []),
      current: current
    ).isEmpty)
  #expect(
    WatchtowerNotificationPlanner.plans(
      previous: snapshot(accountID: "account-b", alerts: []),
      current: current
    ).map(\.identifier) == ["watchtower.alert.cf:1"])
}

@Test func watchtowerNotificationBaselinesStayAccountScoped() {
  let suite = "dash.tests.watchtower-baselines.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }

  func snapshot(accountID: String, title: String) -> WatchtowerWidgetSnapshot {
    WatchtowerWidgetSnapshot(
      unreadCount: 1,
      alerts: [.init(id: "cf:\(title)", title: title, detail: "Delivered")],
      accountID: accountID,
      accountName: accountID,
      fetchedAt: Date(timeIntervalSince1970: 0))
  }

  let accountA = snapshot(accountID: "account-a", title: "Pages")
  let accountB = snapshot(accountID: "account-b", title: "Workers")
  WatchtowerNotificationBaselineStore.store(
    accountA, accountID: "account-a", defaults: defaults)
  WatchtowerNotificationBaselineStore.store(
    accountB, accountID: "account-b", defaults: defaults)

  #expect(
    WatchtowerNotificationBaselineStore.snapshot(
      accountID: "account-a", defaults: defaults) == accountA)
  #expect(
    WatchtowerNotificationBaselineStore.snapshot(
      accountID: "account-b", defaults: defaults) == accountB)

  WatchtowerNotificationBaselineStore.clearAll(defaults: defaults)
  #expect(
    WatchtowerNotificationBaselineStore.snapshot(
      accountID: "account-a", defaults: defaults) == nil)
}

@Test @MainActor func watchtowerInboxStateRejectsStaleAccountLoads() {
  let accountA = AccountRequestContext(accountID: "account-a", generation: 1)
  let accountB = AccountRequestContext(accountID: "account-b", generation: 2)
  let state = WatchtowerInboxScreenState()
  let loadA = state.beginLoad(for: accountA)
  let entry = WatchtowerInboxEntry(
    id: "cf:hist-1",
    title: "Tunnel health",
    detail: "homelab-01 disconnected",
    sentAt: Date(timeIntervalSince1970: 100),
    category: .unread)
  state.contents = WatchtowerInboxContents(
    unreadNotifications: [entry],
    history: [],
    ignored: [])
  state.ignoredIDs = [entry.id]
  state.alertsStatus = .ok
  state.loading = false
  state.hasPresentedContent = true

  state.reset(for: accountB)

  #expect(state.loadedContext == accountB)
  #expect(state.contents.isEmpty)
  #expect(state.ignoredIDs.isEmpty)
  #expect(state.alertsStatus == .loading)
  #expect(state.loading)
  #expect(!state.hasPresentedContent)
  #expect(!state.ownsLoad(loadA, context: accountA))
  let loadB = state.beginLoad(for: accountB)
  #expect(state.ownsLoad(loadB, context: accountB))
}

@Test @MainActor func legacyAuthorizationUpgradeRequestsFullAccountAccess() {
  let legacyGrant = DashAuthorizationScopes.initialReadOnly
  #expect(Set(["analytics.read"]).isSubset(of: legacyGrant))

  let request = AppModel.accountAuthorizationRequest(
    granted: legacyGrant,
    requested: ["analytics.read"]
  )
  #expect(request != nil)
  let scopes = request ?? []
  #expect(legacyGrant.isSubset(of: scopes))
  #expect(DashAuthorizationScopes.core.isSubset(of: scopes))
  #expect(!scopes.isSubset(of: legacyGrant))
  #expect(Set(CloudflareScopes.required).isSubset(of: scopes))
  #expect(
    AppModel.accountAuthorizationRequest(
      granted: DashAuthorizationScopes.core,
      requested: ["analytics.read"]) == nil)
  #expect(
    DashAuthorizationScopes.core.isSubset(
      of:
        AppModel.accountAuthorizationRequest(
          granted: nil,
          requested: ["analytics.read"]) ?? []))
}

@Test func featureAccessDistinguishesLockedReadOnlyAndFull() {
  let capability = FeatureCapability(read: ["product.read"], write: ["product.write"])
  #expect(capability.accessLevel(grantedScopes: nil) == .locked)
  #expect(capability.accessLevel(grantedScopes: []) == .locked)
  #expect(capability.accessLevel(grantedScopes: ["product.read"]) == .readOnly)
  #expect(
    capability.accessLevel(grantedScopes: ["product.read", "product.write"]) == .full
  )
}

@Test @MainActor func featureDataCacheStoresAndClearsValues() {
  let cache = FeatureDataCache()
  cache.set("zones:test", ["zone-a"])
  #expect(cache.get("zones:test") as [String]? == ["zone-a"])
  cache.remove("zones:test")
  #expect(cache.get("zones:test") as [String]? == nil)
  cache.set("workers:test", 3)
  cache.clear()
  #expect(cache.get("workers:test") as Int? == nil)
}

@Test @MainActor func featureDataCacheHonorsTTLAndMemoryPurge() {
  let cache = FeatureDataCache()
  cache.set("zones:a", 1, ttl: 0.001)
  cache.set("watchtower:acc", 2, ttl: nil)
  // Force expiry for the short-TTL entry.
  Thread.sleep(forTimeInterval: 0.01)
  #expect(cache.get("zones:a") as Int? == nil)
  #expect(cache.get("watchtower:acc") as Int? == 2)
  cache.set("zones:b", 3)
  cache.purgeForMemoryPressure()
  #expect(cache.get("zones:b") as Int? == nil)
  #expect(cache.get("watchtower:acc") as Int? == 2)
}

/// Nothing Dash detects reaches the inbox — only Cloudflare's deliveries do,
/// and ignoring one is local to this iPhone.
@Test func watchtowerInboxCarriesCloudflareDeliveriesOnly() {
  let suite = "dash.tests.inbox.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  let account = "acct-1"

  let alerts = [
    NotificationHistoryEntry(
      historyID: "hist-1",
      policyID: "pol-1",
      name: "Tunnel health",
      alertType: "tunnel_health_event",
      mechanism: "email",
      alertBody: "homelab-01 disconnected from Cloudflare",
      description: nil,
      sent: ISO8601DateFormatter().string(from: Date.now.addingTimeInterval(60)))
  ]
  // The first Cloudflare page is history, not a synthetic unread row.
  _ = WatchtowerInboxStore.unreadCount(
    accountID: account, alerts: [], defaults: defaults)
  let contents = WatchtowerInboxStore.contents(
    accountID: account, alerts: alerts, defaults: defaults)
  #expect(contents.unreadNotifications.map(\.id) == ["cf:hist-1"])
  #expect(contents.history.isEmpty)

  let entryID = "cf:hist-1"
  WatchtowerInboxStore.ignore([entryID], accountID: account, defaults: defaults)
  #expect(WatchtowerInboxStore.isIgnored(entryID, accountID: account, defaults: defaults))
  #expect(
    WatchtowerInboxStore.unreadCount(
      accountID: account, alerts: alerts, defaults: defaults) == 0)
  #expect(
    WatchtowerInboxStore.contents(
      accountID: account, alerts: alerts, defaults: defaults
    ).ignored.map(\.id) == [entryID])

  WatchtowerInboxStore.unignore(entryID, accountID: account, defaults: defaults)
  #expect(
    WatchtowerInboxStore.unreadCount(
      accountID: account, alerts: alerts, defaults: defaults) == 1)
}

@Test func watchtowerInboxSeparatesUnreadFromHistory() {
  let suite = "dash.tests.inbox-semantics.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  let account = "acct-semantics"
  let formatter = ISO8601DateFormatter()
  let history = NotificationHistoryEntry(
    historyID: "history",
    name: "Older delivery",
    alertType: "test",
    sent: formatter.string(from: Date(timeIntervalSince1970: 100)))

  // Existing Cloudflare rows establish a local read baseline on upgrade.
  #expect(
    WatchtowerInboxStore.unreadCount(
      accountID: account, alerts: [history], defaults: defaults) == 0)
  var contents = WatchtowerInboxStore.contents(
    accountID: account, alerts: [history], defaults: defaults)
  #expect(contents.history.map(\.id) == ["cf:history"])
  #expect(contents.unreadNotifications.isEmpty)

  let newer = NotificationHistoryEntry(
    historyID: "new",
    name: "New delivery",
    alertType: "test",
    sent: formatter.string(from: Date.now.addingTimeInterval(60)))
  contents = WatchtowerInboxStore.contents(
    accountID: account, alerts: [newer, history], defaults: defaults)
  #expect(contents.unreadNotifications.map(\.id) == ["cf:new"])
  #expect(contents.history.map(\.id) == ["cf:history"])
  #expect(
    WatchtowerInboxStore.unreadCount(
      accountID: account, alerts: [newer, history], defaults: defaults) == 1)

  WatchtowerInboxStore.markRead(["cf:new"], accountID: account, defaults: defaults)
  contents = WatchtowerInboxStore.contents(
    accountID: account, alerts: [newer, history], defaults: defaults)
  #expect(contents.unreadNotifications.isEmpty)
  #expect(Set(contents.history.map(\.id)) == ["cf:new", "cf:history"])
  #expect(
    WatchtowerInboxStore.unreadCount(
      accountID: account, alerts: [newer, history], defaults: defaults) == 0)
}

@Test func tabBarHideRulesRespectDepthAndOverlays() {
  // Any open tray displaces the dock so the card can slide up cleanly.
  #expect(
    shouldHideTabBar(
      overlays: DashTrayPresentation(content: true), navigationDepth: 0))
  #expect(
    shouldHideTabBar(
      overlays: DashTrayPresentation(large: true), navigationDepth: 0))
  #expect(shouldHideTabBar(overlays: DashTrayPresentation(), navigationDepth: 1))
  #expect(
    shouldHideTabBar(
      overlays: DashTrayPresentation(content: true), navigationDepth: 2))
  #expect(!shouldHideTabBar(overlays: DashTrayPresentation(), navigationDepth: 0))
}

@Test func headerAvatarHidesForAnyOverlayOrPush() {
  #expect(
    shouldHideHeaderAvatar(
      overlays: DashTrayPresentation(content: true), navigationDepth: 0))
  #expect(
    shouldHideHeaderAvatar(
      overlays: DashTrayPresentation(large: true), navigationDepth: 0))
  #expect(shouldHideHeaderAvatar(overlays: DashTrayPresentation(), navigationDepth: 1))
  #expect(!shouldHideHeaderAvatar(overlays: DashTrayPresentation(), navigationDepth: 0))
}

@Test func trayPresentationMergesStylesFromSizing() {
  let content = DashTrayPresentation(sizing: .content, isPresented: true)
  #expect(content.content && !content.large && content.presented)
  let large = DashTrayPresentation(sizing: .large, isPresented: true)
  #expect(large.large && !large.content && large.presented)
  let closed = DashTrayPresentation(sizing: .content, isPresented: false)
  #expect(!closed.presented)
}

@MainActor
@Test func destinationNavigatorPushPopAndReset() {
  let navigator = DestinationNavigator()
  #expect(navigator.depth == 0)
  #expect(navigator.top == nil)

  navigator.reset(to: .feature(.zones))
  #expect(navigator.depth == 1)
  #expect(navigator.top == .feature(.zones))

  navigator.push(.zone("z1"))
  #expect(navigator.depth == 2)
  #expect(navigator.top == .zone("z1"))

  navigator.popToRoot()
  #expect(navigator.depth == 0)
  #expect(navigator.top == nil)

  navigator.push(.feature(.workers))
  navigator.push(.worker("api"))
  navigator.reset()
  #expect(navigator.depth == 0)
}

@Test func r2MediaDetectsImagesByExtensionAndContentType() throws {
  #expect(R2Media.isImageKey("photos/cover.JPG"))
  #expect(R2Media.isImageKey("a/b/c.webp"))
  #expect(!R2Media.isImageKey("archive.zip"))
  #expect(!R2Media.isImageKey("Makefile"))
  #expect(!R2Media.isImageKey("photos/"))
  #expect(!R2Media.isImageKey("diagram.svg"))

  let decoder = JSONDecoder()
  let typed = try decoder.decode(
    R2Object.self,
    from: Data(#"{"key":"blob","http_metadata":{"contentType":"image/png"}}"#.utf8))
  #expect(R2Media.isImage(typed))
  let svg = try decoder.decode(
    R2Object.self,
    from: Data(#"{"key":"pic.png","http_metadata":{"contentType":"image/svg+xml"}}"#.utf8))
  #expect(!R2Media.isImage(svg))
  #expect(R2Media.mimeType(forKey: "photos/cover.jpg") == "image/jpeg")
}

@Test func r2DomainsSnapshotPrefersServingCustomDomainOverR2Dev() {
  let managed = R2ManagedDomain(bucketId: "b", domain: "pub-b.r2.dev", enabled: true)
  let decoder = JSONDecoder()
  let serving = try? decoder.decode(
    R2CustomDomain.self,
    from: Data(
      #"{"domain":"img.example.com","enabled":true,"status":{"ownership":"active","ssl":"active"}}"#
        .utf8))
  let pending = try? decoder.decode(
    R2CustomDomain.self,
    from: Data(
      #"{"domain":"cdn.example.net","enabled":true,"status":{"ownership":"pending","ssl":"pending"}}"#
        .utf8))

  let full = R2DomainsSnapshot(managed: managed, custom: [pending, serving].compactMap { $0 })
  #expect(full.publicHost == "img.example.com")

  let pendingOnly = R2DomainsSnapshot(managed: managed, custom: [pending].compactMap { $0 })
  #expect(pendingOnly.publicHost == "pub-b.r2.dev")

  let disabled = R2ManagedDomain(bucketId: "b", domain: "pub-b.r2.dev", enabled: false)
  let dark = R2DomainsSnapshot(managed: disabled, custom: [])
  #expect(dark.publicHost == nil)
}

@Test func r2PublicURLEncodesKeyPathSegments() {
  let snapshot = R2DomainsSnapshot(
    managed: R2ManagedDomain(bucketId: "b", domain: "img.example.com", enabled: true), custom: [])
  let url = snapshot.publicURL(forKey: "photos/2026/日本 trip #1.png")
  #expect(url?.host() == "img.example.com")
  #expect(url?.path(percentEncoded: false) == "/photos/2026/日本 trip #1.png")
  #expect(url?.absoluteString.contains("#") == false)
}

@Test func r2ShareDestinationRecordsOneEntryPerAccount() throws {
  let suite = "dash.tests.r2share.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }

  // JSON, not pipes: bucket names and prefixes can contain any separator.
  let first = R2ShareDestination(
    accountID: "a1", bucket: "pics|weird,name", prefix: "2026/", publicHost: "img.example.com")
  let second = R2ShareDestination(accountID: "a1", bucket: "docs", prefix: "", publicHost: "")
  let other = R2ShareDestination(accountID: "a2", bucket: "cdn", prefix: "x/", publicHost: "")

  R2ShareDestination.record(first, in: defaults)
  R2ShareDestination.record(other, in: defaults)
  #expect(R2ShareDestination.destination(accountID: "a1", in: defaults) == first)

  // Same account replaces its entry instead of stacking a history.
  R2ShareDestination.record(second, in: defaults)
  #expect(R2ShareDestination.destination(accountID: "a1", in: defaults) == second)
  #expect(R2ShareDestination.destination(accountID: "a2", in: defaults) == other)

  R2ShareDestination.setActiveAccountID("a2", in: defaults)
  #expect(R2ShareDestination.activeAccountID(in: defaults) == "a2")
  #expect(R2ShareDestination.isActiveAccount("a2", in: defaults))
  #expect(!R2ShareDestination.isActiveAccount("a1", in: defaults))
  R2ShareDestination.clear(in: defaults)
  #expect(R2ShareDestination.activeAccountID(in: defaults) == nil)
  #expect(R2ShareDestination.destination(accountID: "a1", in: defaults) == nil)

  #expect(R2ShareDestination.decode("") == [])
  #expect(R2ShareDestination.decode("not json") == [])
}

@Test func uploadIntentNormalizesFolderPrefixes() {
  #expect(UploadToR2Intent.normalizedPrefix("") == "")
  #expect(UploadToR2Intent.normalizedPrefix("  ") == "")
  #expect(UploadToR2Intent.normalizedPrefix("/a/b") == "a/b/")
  #expect(UploadToR2Intent.normalizedPrefix("a/b/") == "a/b/")
  #expect(UploadToR2Intent.normalizedPrefix("a") == "a/")
}

@Test func kvJSONFormattingPrettyPrintsAndRejectsPlainText() {
  #expect(KVJSONFormatting.isValidJSON(#"{"a":1}"#))
  #expect(KVJSONFormatting.isValidJSON(#""hello""#))
  #expect(!KVJSONFormatting.isValidJSON("not-json"))
  #expect(KVJSONFormatting.prettyPrinted("not-json") == nil)

  let pretty = KVJSONFormatting.prettyPrinted(#"{"title":"Dash","n":2}"#)
  #expect(pretty?.contains("\n") == true)
  #expect(pretty?.contains("\"title\"") == true)

  #expect(KVJSONFormatting.preparedForDisplay("plain") == "plain")
  #expect(KVJSONFormatting.preparedForDisplay(#"{"x":1}"#).contains("\n"))
  let compactExpandingJSON =
    "[" + Array(repeating: "0", count: 70_000).joined(separator: ",") + "]"
  #expect(KVJSONFormatting.isWithinDisplayLimit(compactExpandingJSON))
  #expect(KVJSONFormatting.prettyPrinted(compactExpandingJSON) != nil)
  #expect(KVJSONFormatting.prettyPrintedForDisplay(compactExpandingJSON) == nil)
  #expect(KVJSONFormatting.preparedForDisplay(compactExpandingJSON) == compactExpandingJSON)

  let aboveDisplayLimit = KVJSONFormatting.displayByteLimit + 1
  #expect(!KVJSONFormatting.isWithinDisplayLimit(byteCount: aboveDisplayLimit))
  #expect(KVValueLimits.writeByteLimit == 25 * 1024 * 1024)
  #expect(KVValueLimits.isWithinWriteLimit(byteCount: aboveDisplayLimit))
  #expect(KVValueLimits.isWithinWriteLimit(byteCount: KVValueLimits.writeByteLimit))
  #expect(!KVValueLimits.isWithinWriteLimit(byteCount: KVValueLimits.writeByteLimit + 1))

  let oversized = Data(repeating: 0x61, count: KVJSONFormatting.displayByteLimit + 1)
  #expect(KVJSONFormatting.displayValue(for: oversized) == .tooLarge)
  #expect(KVJSONFormatting.displayValue(for: Data([0xFF, 0xFE])) == .nonText)
  #expect(
    KVJSONFormatting.displayValue(for: Data(#"{"x":1}"#.utf8))
      == .text("{\n  \"x\" : 1\n}"))
}

@Test func demoKVKeysDecodeAsValidJSON() async throws {
  let client = CloudflareClient(
    clientID: "demo", tokenStore: DemoTokenStore(), session: DemoBackend.session)
  let page = try await client.listKVKeys(accountID: DemoBackend.accountID, namespaceID: "kv-prod")
  #expect(page.items.count == 99)
  #expect(page.items.contains(where: { $0.name == "bulk:item-001" }))
  #expect(page.items.contains(where: { $0.name == "bulk:item-096" }))

  let cache = try await client.listKVKeys(accountID: DemoBackend.accountID, namespaceID: "kv-cache")
  #expect(cache.items.count == 50)
  #expect(cache.items.contains(where: { $0.name == "cache:page-001" }))

  // Value body must stay valid JSON too (raw-string `"#` can steal a closing quote).
  let session = try await client.getKVValue(
    accountID: DemoBackend.accountID, namespaceID: "kv-prod", key: "session:8f3a2c")
  #expect(throws: Never.self) {
    try JSONSerialization.jsonObject(with: session)
  }
}

@Test @MainActor func toastCenterReplacesAndDismissesCurrentToast() {
  let model = AppModel(configuration: AppConfiguration(clientID: "", redirectURI: ""))
  #expect(model.toasts.current == nil)

  model.toasts.success("Uploaded logo.png.", haptic: false)
  let first = model.toasts.current
  #expect(first?.kind == .success)
  #expect(first?.message == "Uploaded logo.png.")
  #expect(first?.duration == DashToast.Kind.success.duration)

  model.toasts.error("Permission denied.", title: "R2", haptic: false)
  let second = model.toasts.current
  #expect(second?.id != first?.id)
  #expect(second?.kind == .error)
  #expect(second?.resolvedTitle == "R2")
  #expect(second?.duration == DashToast.Kind.error.duration)

  model.toasts.dismiss(id: first!.id)
  #expect(model.toasts.current?.id == second?.id)

  model.toasts.dismiss()
  #expect(model.toasts.current == nil)
}

@Test func toastDurationsPreferShorterSuccessWindows() {
  #expect(DashToast.Kind.success.duration < DashToast.Kind.warning.duration)
  #expect(DashToast.Kind.warning.duration < DashToast.Kind.error.duration)
  #expect(DashToast(kind: .success, message: "ok", duration: 1).duration == 1)
}

private actor DeferredDeletionTestExecutor: DeferredDeletionExecuting {
  enum Result: Sendable {
    case success
    case failure
    case missing
    case uncertain
  }

  private(set) var executed: [DeferredDeleteCommand] = []
  var result: Result = .success
  var reconciliation: DeferredDeletionReconciliationResult = .resourceMissing

  func execute(_ command: DeferredDeleteCommand) async throws {
    executed.append(command)
    switch result {
    case .success:
      return
    case .failure:
      throw CloudflareAPIError.request(
        status: 403,
        errors: [APIErrorItem(code: 10000, message: "Forbidden")])
    case .missing:
      throw CloudflareAPIError.request(status: 404, errors: [])
    case .uncertain:
      throw CloudflareAPIError.transport("Connection lost")
    }
  }

  func reconcile(_ command: DeferredDeleteCommand) async throws
    -> DeferredDeletionReconciliationResult
  {
    reconciliation
  }

  func executionCount() -> Int {
    executed.count
  }

  func setResultForTesting(_ result: Result) {
    self.result = result
  }

  func setReconciliationForTesting(_ result: DeferredDeletionReconciliationResult) {
    reconciliation = result
  }
}

private actor DeferredDeletionTestSleeper {
  private var continuations: [CheckedContinuation<Void, Never>] = []

  func sleep() async {
    await withCheckedContinuation { continuation in
      continuations.append(continuation)
    }
  }

  func fire() {
    let pending = continuations
    continuations.removeAll()
    for continuation in pending {
      continuation.resume()
    }
  }
}

private func testDNSDeletion(
  recordID: String = "record-1",
  displayName: String = "api.example.com"
) -> DeferredDeleteCommand {
  .dnsRecord(
    accountID: "account-1",
    zoneID: "zone-1",
    recordID: recordID,
    recordType: "A",
    displayName: displayName)
}

@Test @MainActor func deferredDeletionWaitsForDeadlineBeforeExecuting() async {
  let executor = DeferredDeletionTestExecutor()
  let sleeper = DeferredDeletionTestSleeper()
  let toasts = DashToastCenter()
  let coordinator = DeferredDeletionCoordinator(
    executor: executor,
    toasts: toasts,
    sleeper: { _ in await sleeper.sleep() })
  let command = testDNSDeletion()

  coordinator.schedule(command)

  #expect(coordinator.isPendingDeletion(command.resourceKey))
  #expect(await executor.executionCount() == 0)
  #expect(toasts.current?.id == .deferredDeletionBatch)
  #expect(toasts.current?.action == .undoDeferredDeletionBatch)

  coordinator.commitPendingOperations()
  await coordinator.waitForActiveWork()

  #expect(await executor.executionCount() == 1)
  #expect(coordinator.isPendingDeletion(command.resourceKey))
}

@Test @MainActor func deferredDeletionUndoRemovesTombstoneAndNeverExecutes() async {
  let executor = DeferredDeletionTestExecutor()
  let sleeper = DeferredDeletionTestSleeper()
  let coordinator = DeferredDeletionCoordinator(
    executor: executor,
    toasts: DashToastCenter(),
    sleeper: { _ in await sleeper.sleep() })
  let command = testDNSDeletion()

  coordinator.schedule(command)
  coordinator.undoCurrentBatch()
  await sleeper.fire()
  await Task.yield()

  #expect(!coordinator.isPendingDeletion(command.resourceKey))
  #expect(await executor.executionCount() == 0)
}

@Test @MainActor func deferredDeletionBatchUsesOneToastAndUndoesEveryItem() async {
  let executor = DeferredDeletionTestExecutor()
  let sleeper = DeferredDeletionTestSleeper()
  let toasts = DashToastCenter()
  let coordinator = DeferredDeletionCoordinator(
    executor: executor,
    toasts: toasts,
    sleeper: { _ in await sleeper.sleep() })
  let first = testDNSDeletion()
  let second = testDNSDeletion(recordID: "record-2", displayName: "www.example.com")

  coordinator.schedule(first)
  coordinator.schedule(second)

  #expect(toasts.current?.id == .deferredDeletionBatch)
  #expect(toasts.current?.actionTitle == "Undo all")
  #expect(coordinator.isPendingDeletion(first.resourceKey))
  #expect(coordinator.isPendingDeletion(second.resourceKey))

  coordinator.undoCurrentBatch()

  #expect(!coordinator.isPendingDeletion(first.resourceKey))
  #expect(!coordinator.isPendingDeletion(second.resourceKey))
  #expect(await executor.executionCount() == 0)
}

@Test @MainActor func deferredDeletionFailureRestoresResource() async {
  let executor = DeferredDeletionTestExecutor()
  await executor.setResultForTesting(.failure)
  let coordinator = DeferredDeletionCoordinator(
    executor: executor,
    toasts: DashToastCenter())
  let command = testDNSDeletion()

  coordinator.schedule(command)
  coordinator.commitPendingOperations()
  await coordinator.waitForActiveWork()

  #expect(!coordinator.isPendingDeletion(command.resourceKey))
  #expect(await executor.executionCount() == 1)
}

@Test @MainActor func deferredDeletionTreatsMissingResourceAsSuccess() async {
  let executor = DeferredDeletionTestExecutor()
  await executor.setResultForTesting(.missing)
  let coordinator = DeferredDeletionCoordinator(
    executor: executor,
    toasts: DashToastCenter())
  let command = testDNSDeletion()

  coordinator.schedule(command)
  coordinator.commitPendingOperations()
  await Task.yield()
  await Task.yield()

  #expect(coordinator.isPendingDeletion(command.resourceKey))
  #expect(await executor.executionCount() == 1)
}

@Test @MainActor func uncertainDeletionReconcilesBeforeRestoringResource() async {
  let executor = DeferredDeletionTestExecutor()
  await executor.setResultForTesting(.uncertain)
  await executor.setReconciliationForTesting(.resourceExists)
  let coordinator = DeferredDeletionCoordinator(
    executor: executor,
    toasts: DashToastCenter())
  let command = testDNSDeletion()

  coordinator.schedule(command)
  coordinator.commitPendingOperations()
  await coordinator.waitForActiveWork()

  #expect(!coordinator.isPendingDeletion(command.resourceKey))
  #expect(await executor.executionCount() == 1)
}

@Test @MainActor func accountSwitchCancelsOnlyPendingOperations() async {
  let executor = DeferredDeletionTestExecutor()
  let coordinator = DeferredDeletionCoordinator(
    executor: executor,
    toasts: DashToastCenter())
  let command = testDNSDeletion()

  coordinator.schedule(command)
  coordinator.cancelPendingOperations(forAccountID: "account-1")

  #expect(!coordinator.isPendingDeletion(command.resourceKey))
  #expect(await executor.executionCount() == 0)
}

@Test @MainActor func toastQueuesFeedbackBehindProgrammaticDeletionToast() {
  let toasts = DashToastCenter()
  let owner = toasts.claimDeferredDeletionOwner()
  toasts.show(
    DashToast(
      id: .deferredDeletionBatch,
      kind: .warning,
      message: "Pending",
      dismissBehavior: .programmaticOnly),
    haptic: false,
    deferredDeletionOwner: owner)

  toasts.success("Saved.", haptic: false)

  #expect(toasts.current?.id == .deferredDeletionBatch)
  toasts.releaseDeferredDeletionToast(owner: owner)
  #expect(toasts.current?.message == "Saved.")
}

// MARK: - Pages deployment build-outcomes donut

private func decodePagesDeployments(_ json: String) throws -> [PagesDeployment] {
  try JSONDecoder().decode([PagesDeployment].self, from: Data(json.utf8))
}

@Test func pagesDeploymentChartNormalizesStatuses() {
  #expect(PagesDeploymentChartModel.outcome(forStatus: "Success") == .success)
  #expect(PagesDeploymentChartModel.outcome(forStatus: "failure") == .failure)
  #expect(PagesDeploymentChartModel.outcome(forStatus: "FAILED") == .failure)
  #expect(PagesDeploymentChartModel.outcome(forStatus: "canceled") == .canceled)
  #expect(PagesDeploymentChartModel.outcome(forStatus: "cancelled") == .canceled)
  #expect(PagesDeploymentChartModel.outcome(forStatus: "skipped") == .canceled)
  #expect(PagesDeploymentChartModel.outcome(forStatus: "active") == .inFlight)
  #expect(PagesDeploymentChartModel.outcome(forStatus: "idle") == .inFlight)
  #expect(PagesDeploymentChartModel.outcome(forStatus: "Building") == .inFlight)
  #expect(PagesDeploymentChartModel.outcome(forStatus: "deploying") == .inFlight)
  #expect(PagesDeploymentChartModel.outcome(forStatus: "queued") == .inFlight)
  #expect(PagesDeploymentChartModel.outcome(forStatus: "initializing") == .inFlight)
  #expect(PagesDeploymentChartModel.outcome(forStatus: nil) == .other)
  #expect(PagesDeploymentChartModel.outcome(forStatus: nil, isSkipped: true) == .canceled)
  #expect(PagesDeploymentChartModel.outcome(forStatus: "mystery") == .other)
}

@Test func pagesDeploymentChartBucketsDropZeroCountsAndKeepOrder() throws {
  // No canceled deployments — that bucket must be dropped, and the rest keep
  // the stable success → in-flight → failure → other order regardless of the
  // input order.
  let deployments = try decodePagesDeployments(
    """
    [
      {"id":"a","latest_stage":{"name":"build","status":"failure"}},
      {"id":"b","latest_stage":{"name":"deploy","status":"Success"}},
      {"id":"c","latest_stage":{"name":"build","status":"building"}},
      {"id":"d","latest_stage":{"name":"deploy","status":"success"}},
      {"id":"e","latest_stage":{"name":"queued","status":null}}
    ]
    """)
  let buckets = PagesDeploymentChartModel.buckets(deployments)
  #expect(buckets.map(\.outcome) == [.success, .inFlight, .failure, .other])
  #expect(buckets.map(\.count) == [2, 1, 1, 1])
  #expect(buckets.map(\.id) == ["success", "in-flight", "failure", "other"])

  #expect(PagesDeploymentChartModel.buckets([]).isEmpty)
}

@Test func pagesDeploymentChartBucketsMatchDemoFixtureShape() throws {
  // Mirrors DemoBackend's marketing-site deployments: two successful deploys
  // around one failed build.
  let deployments = try decodePagesDeployments(
    """
    [
      {"id":"pd-3","is_skipped":false,"latest_stage":{"name":"deploy","status":"success"}},
      {"id":"pd-2","is_skipped":false,"latest_stage":{"name":"build","status":"failure"}},
      {"id":"pd-1","is_skipped":false,"latest_stage":{"name":"deploy","status":"success"}}
    ]
    """)
  let buckets = PagesDeploymentChartModel.buckets(deployments)
  #expect(buckets.map(\.outcome) == [.success, .failure])
  #expect(buckets.map(\.count) == [2, 1])
}

@Test func pagesDeploymentChartFilterNarrowsToSelectedOutcome() throws {
  let deployments = try decodePagesDeployments(
    """
    [
      {"id":"success-1","latest_stage":{"name":"deploy","status":"success"}},
      {"id":"failure-1","latest_stage":{"name":"build","status":"failure"}},
      {"id":"success-2","latest_stage":{"name":"deploy","status":"Success"}},
      {"id":"skipped-1","is_skipped":true,"latest_stage":{"name":"queued","status":null}}
    ]
    """)

  let successes = PagesDeploymentChartModel.deployments(deployments, in: "success")
  let failures = PagesDeploymentChartModel.deployments(deployments, in: "failure")
  let canceled = PagesDeploymentChartModel.deployments(deployments, in: "canceled")

  #expect(successes.map(\.id) == ["success-1", "success-2"])
  #expect(failures.map(\.id) == ["failure-1"])
  #expect(canceled.map(\.id) == ["skipped-1"])

  let buckets = PagesDeploymentChartModel.buckets(deployments)
  #expect(
    buckets.allSatisfy {
      PagesDeploymentChartModel.deployments(deployments, in: $0.id).count == $0.count
    })
}

@Test func pagesDeploymentChartFilterFallsBackForMissingOrStaleSelection() throws {
  let deployments = try decodePagesDeployments(
    """
    [
      {"id":"success-1","latest_stage":{"name":"deploy","status":"success"}},
      {"id":"failure-1","latest_stage":{"name":"build","status":"failure"}}
    ]
    """)

  #expect(PagesDeploymentChartModel.deployments(deployments, in: nil).count == 2)
  #expect(PagesDeploymentChartModel.deployments(deployments, in: "canceled").count == 2)
  #expect(PagesDeploymentChartModel.bucket(deployments, withID: nil) == nil)
  #expect(PagesDeploymentChartModel.bucket(deployments, withID: "canceled") == nil)
  #expect(PagesDeploymentChartModel.bucket(deployments, withID: "failure")?.count == 1)
}

@Test func pagesDeploymentChartAccessibilitySummaryCountsOutcomes() {
  let previousLocale = DashL10n.localeOverrideForTesting
  DashL10n.localeOverrideForTesting = Locale(identifier: "en")
  defer { DashL10n.localeOverrideForTesting = previousLocale }

  let summary = PagesDeploymentChartModel.chartAccessibilitySummary(buckets: [
    PagesDeploymentChartModel.Bucket(outcome: .success, count: 2),
    PagesDeploymentChartModel.Bucket(outcome: .failure, count: 1),
  ])
  #expect(summary.contains("3"))
  #expect(summary.contains("2"))
  #expect(summary.contains("1"))
  #expect(summary.contains("Success"))
  #expect(summary.contains("Failed"))

  let empty = PagesDeploymentChartModel.chartAccessibilitySummary(buckets: [])
  #expect(empty.contains("No deployments"))
}

@Test func workerAnalyticsChartPointsSortDropUnparseableAndConvertToMilliseconds() {
  let buckets = [
    WorkerAnalyticsBucket(
      datetime: "2026-07-23T10:10:00Z", requests: 30, errors: 1, cpuTimeP50Us: 1500),
    WorkerAnalyticsBucket(
      datetime: "not-a-date", requests: 99, errors: 9, cpuTimeP50Us: 5000),
    WorkerAnalyticsBucket(
      datetime: "2026-07-23T10:05:00.000Z", requests: 20, errors: 0, cpuTimeP50Us: 500),
  ]

  let points = WorkerAnalyticsChartModel.points(from: buckets)

  #expect(points.count == 2)
  #expect(points.map(\.requests) == [20, 30])
  #expect(points.map(\.errors) == [0, 1])
  #expect(points[0].cpuTimeP50Ms == 0.5)
  #expect(points[1].cpuTimeP50Ms == 1.5)
}

@Test func workerAnalyticsRequestsSummaryMentionsErrorsOnlyWhenPresent() {
  let previousLocale = DashL10n.localeOverrideForTesting
  DashL10n.localeOverrideForTesting = Locale(identifier: "en")
  defer { DashL10n.localeOverrideForTesting = previousLocale }

  let withErrors = WorkerAnalyticsChartModel.requestsAccessibilitySummary(
    requests: 1200, errors: 4)
  #expect(withErrors.contains("1,200") || withErrors.contains("1200"))
  #expect(withErrors.contains("4"))
  #expect(withErrors.contains("errors"))

  let clean = WorkerAnalyticsChartModel.requestsAccessibilitySummary(requests: 50, errors: 0)
  #expect(clean.contains("50"))
  #expect(!clean.contains("errors"))
}

@Test func workerAnalyticsCPUSummaryNamesPeakMilliseconds() {
  let previousLocale = DashL10n.localeOverrideForTesting
  DashL10n.localeOverrideForTesting = Locale(identifier: "en")
  defer { DashL10n.localeOverrideForTesting = previousLocale }

  let points = WorkerAnalyticsChartModel.points(from: [
    WorkerAnalyticsBucket(
      datetime: "2026-07-23T10:00:00Z", requests: 10, errors: 0, cpuTimeP50Us: 900),
    WorkerAnalyticsBucket(
      datetime: "2026-07-23T10:05:00Z", requests: 10, errors: 0, cpuTimeP50Us: 1440),
  ])

  let summary = WorkerAnalyticsChartModel.cpuAccessibilitySummary(points: points)
  #expect(summary.contains("1.4"))
  #expect(summary.contains("milliseconds"))
}

@Test func wafChartModelCapsCountriesToTopSixByCount() {
  let buckets = (1...9).map { FirewallEventsBucket(label: "C\($0)", count: $0 * 10) }
  let top = WAFChartModel.topCountries(buckets)

  #expect(top.count == 6)
  #expect(top.map(\.count) == [90, 80, 70, 60, 50, 40])
  #expect(top.first?.label == "C9")
}

@Test func wafChartModelKeepsShortListsAndUsesStableTieOrder() {
  let buckets = [
    FirewallEventsBucket(label: "US", count: 64),
    FirewallEventsBucket(label: "CN", count: 38),
    FirewallEventsBucket(label: "RU", count: 21),
    FirewallEventsBucket(label: "DE", count: 21),
  ]
  let top = WAFChartModel.topCountries(buckets)
  #expect(top.map(\.label) == ["US", "CN", "DE", "RU"])
}

@Test func wafCountriesSummaryNamesLeaderAndTotal() {
  let previousLocale = DashL10n.localeOverrideForTesting
  DashL10n.localeOverrideForTesting = Locale(identifier: "en")
  defer { DashL10n.localeOverrideForTesting = previousLocale }

  let summary = WAFChartModel.countriesAccessibilitySummary(buckets: [
    FirewallEventsBucket(label: "US", count: 64),
    FirewallEventsBucket(label: "CN", count: 38),
    FirewallEventsBucket(label: "RU", count: 21),
  ])
  #expect(summary.contains("United States"))
  #expect(summary.contains("64"))
  #expect(summary.contains("123"))

  let fullSummary = WAFChartModel.countriesAccessibilitySummary(
    buckets: [FirewallEventsBucket(label: "US", count: 64)],
    totalBlocked: 400)
  #expect(fullSummary.contains("64"))
  #expect(fullSummary.contains("400"))

  let empty = WAFChartModel.countriesAccessibilitySummary(buckets: [])
  #expect(empty.contains("No blocked events"))
}

@Test func wafGlobeCentroidsCoverISOAlpha2AndCloudflareKosovoExtension() throws {
  let expectedCodes = Set(
    ("AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ BA BB BD BE BF BG BH BI BJ "
      + "BL BM BN BO BQ BR BS BT BV BW BY BZ CA CC CD CF CG CH CI CK CL CM CN CO CR "
      + "CU CV CW CX CY CZ DE DJ DK DM DO DZ EC EE EG EH ER ES ET FI FJ FK FM FO FR "
      + "GA GB GD GE GF GG GH GI GL GM GN GP GQ GR GS GT GU GW GY HK HM HN HR HT HU "
      + "ID IE IL IM IN IO IQ IR IS IT JE JM JO JP KE KG KH KI KM KN KP KR KW KY KZ "
      + "LA LB LC LI LK LR LS LT LU LV LY MA MC MD ME MF MG MH MK ML MM MN MO MP MQ "
      + "MR MS MT MU MV MW MX MY MZ NA NC NE NF NG NI NL NO NP NR NU NZ OM PA PE PF "
      + "PG PH PK PL PM PN PR PS PT PW PY QA RE RO RS RU RW SA SB SC SD SE SG SH SI "
      + "SJ SK SL SM SN SO SR SS ST SV SX SY SZ TC TD TF TG TH TJ TK TL TM TN TO TR "
      + "TT TV TW TZ UA UG UM US UY UZ VA VC VE VG VI VN VU WF WS XK YE YT ZA ZM ZW").split(
        separator: " "
      ).map(String.init))

  #expect(WAFISOCountryCentroids.supportedCodes == expectedCodes)
  #expect(WAFISOCountryCentroids.coordinate(for: " us ")?.latitude == 39.538479)
  let bqLongitude = try #require(WAFISOCountryCentroids.coordinate(for: "bq")?.longitude)
  #expect(abs(bqLongitude - (-63.1334)) < 1e-9)
  #expect(WAFISOCountryCentroids.coordinate(for: "UM") != nil)
  #expect(WAFISOCountryCentroids.coordinate(for: "XX") == nil)
  #expect(WAFISOCountryCentroids.coordinate(for: "T1") == nil)
  #expect(WAFISOCountryCentroids.coordinate(for: "United States") == nil)
}

@Test func wafGlobeModelMergesSortsAndSafelyDropsUnknownCountries() throws {
  let buckets = [
    FirewallEventsBucket(label: "ru", count: 1),
    FirewallEventsBucket(label: " CN ", count: 16),
    FirewallEventsBucket(label: "cn", count: 9),
    FirewallEventsBucket(label: "US", count: 64),
    FirewallEventsBucket(label: "US", count: 0),
    FirewallEventsBucket(label: "DE", count: -2),
    FirewallEventsBucket(label: "XX", count: 10_000),
    FirewallEventsBucket(label: "T1", count: 10_000),
    FirewallEventsBucket(label: "not-a-country", count: 10_000),
  ]
  let points = WAFGlobeModel.points(from: buckets)

  #expect(points.map(\.countryCode) == ["US", "CN", "RU"])
  #expect(points.map(\.count) == [64, 25, 1])
  #expect(points[0].markerSize == WAFGlobeModel.maximumMarkerSize)
  #expect(points[0].markerSize > points[1].markerSize)
  #expect(points[1].markerSize > points[2].markerSize)
  #expect(
    points.allSatisfy {
      (WAFGlobeModel.minimumMarkerSize...WAFGlobeModel.maximumMarkerSize).contains($0.markerSize)
    })

  let marker = try #require(points.first?.marker(accessibilityLabel: "United States, 64 blocks"))
  #expect(marker.id == "US")
  #expect(marker.coordinate == points[0].coordinate)
  #expect(marker.size == points[0].markerSize)
  #expect(marker.accessibilityLabel == "United States, 64 blocks")
}

@Test func wafGlobeModelUsesStableTieOrderAndSquareRootMarkerScale() {
  let tied = WAFGlobeModel.points(from: [
    FirewallEventsBucket(label: "FR", count: 10),
    FirewallEventsBucket(label: "DE", count: 10),
  ])
  #expect(tied.map(\.countryCode) == ["DE", "FR"])
  #expect(tied.allSatisfy { $0.markerSize == WAFGlobeModel.maximumMarkerSize })

  let quarterScale = WAFGlobeModel.markerSize(count: 25, maximumCount: 100)
  let expected =
    WAFGlobeModel.minimumMarkerSize
    + (WAFGlobeModel.maximumMarkerSize - WAFGlobeModel.minimumMarkerSize) * 0.5
  #expect(abs(quarterScale - expected) < 0.000_001)
  #expect(
    WAFGlobeModel.markerSize(count: 0, maximumCount: 100)
      == WAFGlobeModel.minimumMarkerSize)
  #expect(
    WAFGlobeModel.markerSize(count: 200, maximumCount: 100)
      == WAFGlobeModel.maximumMarkerSize)
}

// MARK: - DNS record-type donut chart model

/// `DNSRecord` has no public memberwise init — decode minimal JSON like the
/// API layer does.
private func makeDNSRecords(types: [String]) throws -> [DNSRecord] {
  let objects = types.enumerated().map { index, type in
    #"{"id":"dns-\#(index)","type":"\#(type)","name":"example.com","content":"203.0.113.1","ttl":300}"#
  }
  return try JSONDecoder().decode(
    [DNSRecord].self, from: Data("[\(objects.joined(separator: ","))]".utf8))
}

@Test func dnsChartModelKeepsTopFiveTypesAndFoldsOther() throws {
  // 7 types with distinct counts: A×6, CNAME×5, TXT×4, MX×3, AAAA×2, SRV×1, CAA×1.
  let types =
    Array(repeating: "A", count: 6) + Array(repeating: "CNAME", count: 5)
    + Array(repeating: "TXT", count: 4) + Array(repeating: "MX", count: 3)
    + Array(repeating: "AAAA", count: 2) + ["SRV", "CAA"]
  let buckets = DNSChartModel.buckets(try makeDNSRecords(types: types.shuffled()))

  #expect(buckets.map(\.id) == ["A", "CNAME", "TXT", "MX", "AAAA", DNSChartModel.otherBucketID])
  #expect(buckets.map(\.count) == [6, 5, 4, 3, 2, 2])
}

@Test func dnsChartModelBreaksCountTiesAlphabeticallyAndUppercases() throws {
  // Lowercase "a" merges into "A"; ties (2,2,2) order alphabetically, and the
  // sixth tied type folds into Other deterministically.
  let types = ["a", "A", "TXT", "TXT", "MX", "MX", "CNAME", "CNAME", "AAAA", "AAAA", "SRV", "SRV"]
  let buckets = DNSChartModel.buckets(try makeDNSRecords(types: types))

  #expect(buckets.map(\.id) == ["A", "AAAA", "CNAME", "MX", "SRV", DNSChartModel.otherBucketID])
  #expect(buckets.map(\.count) == [2, 2, 2, 2, 2, 2])
}

@Test func dnsChartModelSkipsOtherBucketWhenFiveOrFewerTypes() throws {
  let buckets = DNSChartModel.buckets(try makeDNSRecords(types: ["A", "A", "CNAME"]))
  #expect(buckets.map(\.id) == ["A", "CNAME"])
  #expect(buckets.map(\.count) == [2, 1])
  #expect(!buckets.contains { $0.id == DNSChartModel.otherBucketID })
}

@Test func dnsChartFilterNarrowsToTheSelectedNamedType() throws {
  let records = try makeDNSRecords(types: ["A", "a", "CNAME", "TXT"])
  let filtered = DNSChartModel.records(records, in: "A")

  // Bucketing uppercases, so the lowercase "a" record filters with its bucket.
  #expect(filtered.map(\.type) == ["A", "a"])
}

@Test func dnsChartFilterCollectsEveryFoldedTypeUnderOther() throws {
  // 6 distinct types: A×3, AAAA×2, CNAME×2, MX×2, TXT×2 stay named; SRV and
  // CAA lose the cut and fold into Other.
  let types =
    Array(repeating: "A", count: 3) + ["AAAA", "AAAA", "CNAME", "CNAME", "MX", "MX", "TXT", "TXT"]
    + ["SRV", "CAA"]
  let records = try makeDNSRecords(types: types)
  let filtered = DNSChartModel.records(records, in: DNSChartModel.otherBucketID)

  #expect(Set(filtered.map(\.type)) == ["SRV", "CAA"])

  // The buckets partition the loaded records: every slice filters to exactly
  // its own count, and together they account for the whole list.
  let buckets = DNSChartModel.buckets(records)
  let matchesSliceCounts = buckets.allSatisfy {
    DNSChartModel.records(records, in: $0.id, buckets: buckets).count == $0.count
  }
  #expect(matchesSliceCounts)
  #expect(buckets.reduce(0) { $0 + $1.count } == records.count)
}

@Test func dnsChartFilterFallsBackToTheFullListForAStaleSelection() throws {
  let records = try makeDNSRecords(types: ["A", "CNAME"])

  // No selection, an id no bucket claims, and the Other bucket in a list that
  // never folded one all widen back to every loaded record rather than empty.
  #expect(DNSChartModel.records(records, in: nil).count == 2)
  #expect(DNSChartModel.records(records, in: "MX").count == 2)
  #expect(DNSChartModel.records(records, in: DNSChartModel.otherBucketID).count == 2)
  #expect(DNSChartModel.bucket(records, withID: "MX") == nil)
  #expect(DNSChartModel.bucket(records, withID: nil) == nil)
  #expect(DNSChartModel.bucket(records, withID: "A")?.count == 1)
}

@Test func dnsChartSummaryDescribesLoadedRecordsOnly() throws {
  let previousLocale = DashL10n.localeOverrideForTesting
  DashL10n.localeOverrideForTesting = Locale(identifier: "en")
  defer { DashL10n.localeOverrideForTesting = previousLocale }

  let buckets = DNSChartModel.buckets(
    try makeDNSRecords(types: ["A", "A", "CNAME", "TXT", "MX", "AAAA", "SRV", "CAA"]))
  let summary = DNSChartModel.chartAccessibilitySummary(buckets: buckets)
  // Names the LOADED total (the list paginates) and every bucket label.
  #expect(summary.contains("loaded"))
  #expect(summary.contains("8"))
  #expect(summary.contains("A 2"))
  #expect(summary.contains("Other"))

  let empty = DNSChartModel.chartAccessibilitySummary(buckets: [])
  #expect(empty.contains("No DNS records loaded"))
}
