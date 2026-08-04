import CloudflareAPI
import CoreText
import SwiftUI
import Testing
import UIKit

@testable import Dash

@Test @MainActor func onboardingWordmarkKeepsLaunchOpticalSpacingAtRest() {
  let magnification = OnboardingBrandTypography.launchMagnification

  for baseSize in [CGFloat(28), 34, 56] {
    let restingFont = OnboardingBrandTypography.wordmarkFont(
      baseSize: baseSize,
      renderMagnification: 1
    )
    let launchFont = OnboardingBrandTypography.wordmarkFont(
      baseSize: baseSize,
      renderMagnification: magnification
    )
    let restingLine = CTLineCreateWithAttributedString(
      NSAttributedString(string: "Dash", attributes: [.font: restingFont])
    )
    let launchLine = CTLineCreateWithAttributedString(
      NSAttributedString(string: "Dash", attributes: [.font: launchFont])
    )

    for characterIndex in 0..<4 {
      let restingOrigin = CTLineGetOffsetForStringIndex(
        restingLine,
        characterIndex,
        nil
      )
      let normalizedLaunchOrigin =
        CTLineGetOffsetForStringIndex(launchLine, characterIndex, nil) / magnification
      #expect(abs(restingOrigin - normalizedLaunchOrigin) < 0.001)
    }

    let restingWidth = CTLineGetTypographicBounds(restingLine, nil, nil, nil)
    let normalizedLaunchWidth =
      CTLineGetTypographicBounds(launchLine, nil, nil, nil) / magnification
    #expect(abs(restingWidth - normalizedLaunchWidth) < 0.001)
  }
}

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

@Test func dateFormattingFollowsLanguageLocale() {
  // 2026-07-30 14:30:00 UTC → fixed local wall via explicit TimeZone.
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(secondsFromGMT: 0)!
  let date = calendar.date(
    from: DateComponents(year: 2026, month: 7, day: 30, hour: 14, minute: 30))!
  let zone = TimeZone(secondsFromGMT: 0)!
  let english = Locale(identifier: "en")
  let chinese = Locale(identifier: "zh_Hans")

  let englishDateTime = DashDateFormatting.dateAndTime(
    date, locale: english, timeZone: zone)
  #expect(englishDateTime.contains("2:30"))
  #expect(englishDateTime.uppercased().contains("PM"))

  let chineseDateTime = DashDateFormatting.dateAndTime(
    date, locale: chinese, timeZone: zone)
  #expect(chineseDateTime.contains("14:30"))
  #expect(!chineseDateTime.uppercased().contains("PM"))
  #expect(!chineseDateTime.uppercased().contains("AM"))

  let chineseDay = DashDateFormatting.dateOnly(
    date, locale: chinese, timeZone: zone)
  #expect(chineseDay.contains("2026"))
  #expect(chineseDay.contains("7"))

  #expect(
    DashDateFormatting.dateOnly(fromISO8601: "not-a-date")
      == "not-a-date")
  #expect(
    DashDateFormatting.dateOnly(
      fromISO8601: "2026-07-30T14:30:00Z",
      locale: english,
      timeZone: zone
    )
    .contains("2026"))
  #expect(DashDateFormatting.date(fromISO8601: "2026-06-01T00:00:00Z") != nil)
  #expect(DashDateFormatting.date(fromISO8601: "2026-06-01T00:00:00.000Z") != nil)
  #expect(DashDateFormatting.date(fromISO8601: "2026-06-01") != nil)
  #expect(DashDateFormatting.date(fromISO8601: "not a date") == nil)
}

@Test func workspaceWashPresetResolvesStoredPreference() {
  #expect(DashWorkspaceWashPreset.defaultPreset == .cloudflare)
  #expect(DashWorkspaceWashPreset.resolved(stored: "none") == .none)
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
  /// its `Needs authorization` sibling two lines away translated fine.
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

  /// A registry status arrives spelled three ways — RDAP spaces it, WHOIS sends
  /// EPP camelCase, Cloudflare's Registrar API lowercases it and runs it
  /// together. Only the first two have a boundary to split on, so the third used
  /// to reach the screen as `Clienttransferprohibited`: one word, and a key the
  /// catalog cannot hold, which is why it stayed English on a Chinese screen.
  @Test func registryStatusLabelsFoldEverySpellingOntoOneCatalogKey() {
    let previous = DashL10n.localeOverrideForTesting
    defer { DashL10n.localeOverrideForTesting = previous }

    DashL10n.localeOverrideForTesting = Locale(identifier: "en")
    for spelling in [
      "clienttransferprohibited", "clientTransferProhibited",
      "client transfer prohibited", "CLIENT_TRANSFER_PROHIBITED",
      "client-transfer-prohibited",
    ] {
      #expect(rdapStatusLabel(spelling) == "Client Transfer Prohibited")
    }
    #expect(rdapStatusLabel("ok") == "OK")
    #expect(rdapStatusLabel("OK") == "OK")
    #expect(rdapStatusLabel("autorenewperiod") == "Auto Renew Period")
    // Outside the closed vocabulary, keep Cloudflare's own wording — a
    // lowercase run holds no words to recover.
    #expect(rdapStatusLabel("someFutureState") == "Some Future State")

    // Every entry must be reachable by its own key, and translated: a typo'd
    // key can never match, and an untranslated label ships English anyway.
    for (code, english) in RegistryStatusVocabulary.labels {
      #expect(RegistryStatusVocabulary.key(code) == code)
      #expect(rdapStatusLabel(code) == english)
    }
    DashL10n.localeOverrideForTesting = Locale(identifier: "zh-Hans")
    for (code, english) in RegistryStatusVocabulary.labels {
      #expect(
        rdapStatusLabel(code) != english,
        "registry status \(english.debugDescription) has no zh-Hans entry")
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
    #expect(StatusBadge.accessibilityText(for: .verified) == "Status, Verified")
    #expect(StatusToken.current.presentation == .quiet)
    #expect(StatusToken.failed.presentation == .capsule)
    #expect(StatusToken.locked.presentation == .capsule)
    #expect(
      DashNotice.accessibilityText(kind: .warning, message: "Coverage limited")
        == "Warning: Coverage limited")
    #expect(
      DashNotice.accessibilityText(kind: .info, message: "Managed automatically")
        == "Note: Managed automatically")
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

@Test func registrarAndTunnelStatusTokensMatchCloudflareVocabulary() {
  #expect(StatusToken(registrarStatus: "active") == .registered)
  #expect(StatusToken(registrarStatus: "registration_pending") == .registrationPending)
  #expect(StatusToken(registrarStatus: "expired") == .expired)
  #expect(StatusToken(registrarStatus: "suspended") == .suspended)
  #expect(StatusToken(registrarStatus: "redemption_period") == .redemptionPeriod)
  #expect(StatusToken(registrarStatus: "pending_delete") == .pendingDelete)
  #expect(StatusToken(registrarStatus: "teleporting") == .unknown)

  #expect(StatusToken(tunnelStatus: "healthy") == .healthy)
  #expect(StatusToken(tunnelStatus: "degraded") == .degraded)
  #expect(StatusToken(tunnelStatus: "down") == .down)
  #expect(StatusToken(tunnelStatus: "inactive") == .inactive)
  #expect(StatusToken(tunnelStatus: "teleporting") == .unknown)
}

@Test @MainActor func emailRoutingListTokenReadsSettingsCacheBeforeSnapshot() {
  let cache = FeatureDataCache()
  let zoneID = "zone-list-status"
  let settings = EmailRoutingSettings(
    id: "email-1", name: "example.com", enabled: true, status: "ready")
  // Settings-only write must not require a full snapshot — that was how the
  // domains index waited on a detail visit before any row could badge.
  EmailRoutingStatusMapping.storeListSettings(settings, zoneID: zoneID, cache: cache)
  #expect(EmailRoutingStatusMapping.listToken(zoneID: zoneID, cache: cache) == .ready)
  #expect(cache.get(FeatureCacheKey.emailRouting(zoneID)) as EmailRoutingSnapshot? == nil)

  let misconfigured = EmailRoutingSettings(
    id: "email-2", name: "docs.example.com", enabled: true, status: "misconfigured")
  cache.set(
    FeatureCacheKey.emailRouting(zoneID),
    EmailRoutingSnapshot(settings: misconfigured, rules: [], catchAll: nil))
  // Settings cache still wins while present — list fan-out owns that key.
  #expect(EmailRoutingStatusMapping.listToken(zoneID: zoneID, cache: cache) == .ready)
  cache.remove(FeatureCacheKey.emailRoutingSettings(zoneID))
  #expect(EmailRoutingStatusMapping.listToken(zoneID: zoneID, cache: cache) == .misconfigured)
  #expect(EmailRoutingStatusMapping.token(for: misconfigured) == .misconfigured)
  #expect(
    EmailRoutingStatusMapping.token(
      for: EmailRoutingSettings(
        id: "email-3", name: "off.example.com", enabled: false, status: "unconfigured"))
      == .disabled)
}

@Test func emailRoutingHasEditableShapeAllowsWildcardLocalParts() {
  let zone = "example.com"
  func rule(
    address: String,
    actions: [EmailRoutingRuleAction] = [EmailRoutingRuleAction(type: "drop")],
    matchers: [EmailRoutingRuleMatcher]? = nil
  ) -> EmailRoutingRule {
    EmailRoutingRule(
      id: "r1",
      matchers: matchers
        ?? [EmailRoutingRuleMatcher(type: "literal", field: "to", value: address)],
      actions: actions)
  }

  #expect(EmailRoutingView.hasEditableShape(rule(address: "hi@example.com"), zoneName: zone))
  #expect(EmailRoutingView.hasEditableShape(rule(address: "*@example.com"), zoneName: zone))
  #expect(EmailRoutingView.hasEditableShape(rule(address: "sales*@example.com"), zoneName: zone))
  #expect(EmailRoutingView.hasEditableShape(rule(address: "*desk@example.com"), zoneName: zone))
  #expect(
    EmailRoutingView.hasEditableShape(
      rule(
        address: "*@example.com",
        actions: [EmailRoutingRuleAction(type: "forward", value: ["inbox@example.net"])]),
      zoneName: zone))

  #expect(!EmailRoutingView.hasEditableShape(rule(address: "@example.com"), zoneName: zone))
  #expect(!EmailRoutingView.hasEditableShape(rule(address: "hi@other.com"), zoneName: zone))
  #expect(
    !EmailRoutingView.hasEditableShape(
      rule(
        address: "hi@example.com",
        actions: [EmailRoutingRuleAction(type: "worker", value: ["mail-worker"])]),
      zoneName: zone))
  #expect(
    !EmailRoutingView.hasEditableShape(
      rule(
        address: "hi@example.com",
        actions: [
          EmailRoutingRuleAction(type: "forward", value: ["a@example.net", "b@example.net"])
        ]),
      zoneName: zone))
  #expect(
    !EmailRoutingView.hasEditableShape(
      rule(
        address: "hi@example.com",
        matchers: [
          EmailRoutingRuleMatcher(type: "literal", field: "to", value: "hi@example.com"),
          EmailRoutingRuleMatcher(type: "literal", field: "to", value: "bye@example.com"),
        ]),
      zoneName: zone))
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
  #expect(FeatureID.allCases.count == 8)
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

/// Core features stay browsable on the Demo / read-only profile. Experimental
/// features stay out of `coreFeatures` and out of sign-in; Demo still carries
/// their read scopes so an opted-in Resources row can open without a fake
/// connection wall.
@Test func everyCoreFeatureIsBrowsableWithTheReadOnlyProfile() {
  #expect(
    DashAuthorizationScopes.coreFeatures
      .union(DashAuthorizationScopes.experimentalFeatures)
      == Set(FeatureID.allCases))
  #expect(
    DashAuthorizationScopes.coreFeatures.isDisjoint(
      with: DashAuthorizationScopes.experimentalFeatures))
  #expect(!DashAuthorizationScopes.core.contains("argotunnel.read"))
  #expect(!DashAuthorizationScopes.core.contains("access.read"))
  #expect(
    DashAuthorizationScopes.authorizationScopes(for: .tunnels)
      == ["argotunnel.read", "access.read"])
  for feature in DashAuthorizationScopes.coreFeatures {
    let access = feature.capability.accessLevel(
      grantedScopes: DashAuthorizationScopes.initialReadOnly)
    // Demo / initial-read grants omit write scopes, so every unlocked core
    // feature with mutations is Read-only. (None of coreFeatures is
    // permanently write-free — that pattern is Tunnels.)
    #expect(!feature.capability.write.isEmpty)
    #expect(access == .readOnly)
  }
  #expect(
    FeatureID.tunnels.capability.accessLevel(
      grantedScopes: DashAuthorizationScopes.initialReadOnly) == .locked)
}

@Test @MainActor func appModelDefaultsToFullAccountPermissions() {
  let model = AppModel(configuration: AppConfiguration(clientID: "", redirectURI: ""))
  #expect(model.selectedScopes == DashAuthorizationScopes.core)
  #expect(DashAuthorizationScopes.initialReadOnly.count == 18)
  #expect(DashAuthorizationScopes.core.count == 32)
  #expect(DashAuthorizationScopes.initialReadOnly.isStrictSubset(of: DashAuthorizationScopes.core))
  #expect(
    DashAuthorizationScopes.initialReadOnly.allSatisfy {
      !$0.hasSuffix(".write") && $0 != "cache.purge"
    })
  #expect(DashAuthorizationScopes.core.isStrictSubset(of: Set(CloudflareScopes.published)))
  #expect(
    DashAuthorizationScopes.watchtower.isSubset(of: DashAuthorizationScopes.initialReadOnly))
  #expect(
    R2ShareDestination.requiredWriteScopes.isSubset(of: DashAuthorizationScopes.core))
  #expect(
    R2ShareDestination.requiredWriteScopes.isDisjoint(
      with: DashAuthorizationScopes.initialReadOnly))
  #expect(DashAuthorizationScopes.core.contains("cache.purge"))
  #expect(DashAuthorizationScopes.core.contains("zone-settings.write"))
  #expect(DashAuthorizationScopes.core.contains("account-settings.write"))
  #expect(!DashAuthorizationScopes.initialReadOnly.contains("account-settings.write"))
  #expect(!model.hasScopes(["dns.write"]))
  model.grantedScopes = DashAuthorizationScopes.initialReadOnly
  #expect(model.hasScopes(["dns.read"]))
  #expect(!model.hasScopes(["dns.write"]))
  #expect(CloudflareScopes.required.allSatisfy(model.selectedScopes.contains))
}

@Test @MainActor func demoUsesReadOnlyGrantPlusExperimentalReads() {
  #expect(DashAuthorizationScopes.initialReadOnly.isStrictSubset(of: AppModel.demoGrantedScopes))
  #expect(AppModel.demoGrantedScopes.contains("argotunnel.read"))
  #expect(AppModel.demoGrantedScopes.contains("access.read"))
  #expect(!AppModel.demoAccessRequiresConnection(["dns.read"]))
  #expect(AppModel.demoAccessRequiresConnection(["dns.write"]))
  for feature in FeatureID.allCases {
    let access = feature.capability.accessLevel(
      grantedScopes: AppModel.demoGrantedScopes)
    // Demo never grants write scopes; permanently write-free features
    // (Tunnels) are Read-only too once unlocked.
    #expect(access == .readOnly)
  }
}

@Test func experimentalTunnelsStayHiddenUntilOptedIn() {
  #expect(
    !DashExperimentalFeatures.isCatalogVisible(.tunnels, tunnelsEnabled: false))
  #expect(
    DashExperimentalFeatures.isCatalogVisible(.tunnels, tunnelsEnabled: true))
  #expect(
    DashExperimentalFeatures.isCatalogVisible(.zones, tunnelsEnabled: false))

  let coreOnly = FeatureCatalogFiltering.enabledFeatures(
    tunnelsExperimentalEnabled: false)
  #expect(coreOnly == DashAuthorizationScopes.coreFeatures)
  #expect(!coreOnly.contains(.tunnels))

  let withTunnels = FeatureCatalogFiltering.enabledFeatures(
    tunnelsExperimentalEnabled: true)
  #expect(withTunnels == Set(FeatureID.allCases))

  let lockedCatalog = FeatureCatalogFiltering.features(
    filter: .all,
    grantedScopes: DashAuthorizationScopes.initialReadOnly,
    enabled: withTunnels)
  #expect(lockedCatalog.contains(.tunnels))
  #expect(
    FeatureID.tunnels.capability.accessLevel(
      grantedScopes: DashAuthorizationScopes.initialReadOnly) == .locked)
}

@Test func processExternalMutationsFailClosedWithoutWriteScopes() {
  let intentWrites: Set<String> = ["cache.purge", "zone-settings.write"]
  let r2Writes = R2ShareDestination.requiredWriteScopes
  #expect(
    !DashIntentAuthorization.hasRequiredScopes(
      intentWrites,
      granted: nil))
  #expect(
    !DashIntentAuthorization.hasRequiredScopes(
      intentWrites,
      granted: DashAuthorizationScopes.initialReadOnly))
  #expect(
    DashIntentAuthorization.hasRequiredScopes(
      intentWrites,
      granted: DashAuthorizationScopes.core))
  #expect(intentWrites.isSubset(of: DashAuthorizationScopes.core))
  #expect(r2Writes.isSubset(of: DashAuthorizationScopes.core))
  #expect(
    !R2ShareDestination.hasWriteAccess(
      grantedScopes: DashAuthorizationScopes.initialReadOnly))
  #expect(
    R2ShareDestination.hasWriteAccess(
      grantedScopes: DashAuthorizationScopes.core))
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
    "notifications.write",  // Default alert webhook + policies
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
  // Settled-empty keeps the placeholder body mounted. Snapshot screens (chart
  // detail) and details whose chrome is not tied to primary rows (zone settings
  // alerts/nameservers, R2 bucket settings) must set hasContent after settle —
  // leaving the default false is a permanent skeleton, not a calm empty.
  #expect(
    DashListPhase.resolve(isLoading: false, error: nil, hasContent: false)
      == .empty)
  #expect(
    DashListPhase.resolve(isLoading: true, error: nil, hasContent: true)
      == .content(banner: nil, refreshing: true))
}

@Test func listPhaseBodyModeStaysLiveAcrossWarmRefresh() {
  #expect(DashListPhase.loading.bodyMode == .placeholder)
  #expect(DashListPhase.empty.bodyMode == .placeholder)
  #expect(DashListPhase.fullScreenError("boom").bodyMode == .placeholder)
  #expect(
    DashListPhase.content(banner: nil, refreshing: false).bodyMode == .live)
  // Warm refresh keeps `.live` so the handoff animation does not replay.
  #expect(
    DashListPhase.content(banner: nil, refreshing: true).bodyMode == .live)
  #expect(
    DashListPhase.content(banner: "boom", refreshing: true).bodyMode == .live)
}

@Test func coldFailureWashRampClearsAtTopAndFillsTowardTheCenteredCopy() {
  let stops = DashColdFailureWashRamp.stops
  // Clear at the top of the veil so the skeleton peeks through; densest from
  // mid to bottom so the centred tip sits on readable canvas.
  #expect(stops.first?.location == 0)
  #expect(stops.first?.opacity == 0)
  #expect(stops.last?.location == 1)
  #expect(stops.last?.opacity == 0.88)
  // Monotonic: locations climb top → bottom and opacity only rises, so the
  // wash never re-thins under the copy.
  for (previous, next) in zip(stops, stops.dropFirst()) {
    #expect(next.location > previous.location)
    #expect(next.opacity >= previous.opacity)
  }
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
  #expect(zoneSettingDisplayTitle("http3") == "HTTP/3")
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

/// The Resources tab lists every enabled feature, including locked
/// experimental ones, while an unknown grant fails closed. AppRoot does not
/// mount the catalog until bootstrap has restored the scope mirror or its
/// conservative fallback.
@MainActor
@Test func featureCatalogDefaultFilterListsEveryEnabledFeature() {
  #expect(FeatureCatalogView.defaultFilter == .all)
  let unknown = FeatureCatalogFiltering.features(
    filter: FeatureCatalogView.defaultFilter,
    grantedScopes: nil)
  #expect(unknown.isEmpty)
  let coreEnabled = FeatureCatalogFiltering.enabledFeatures(
    tunnelsExperimentalEnabled: false)
  let initialGrant = FeatureCatalogFiltering.features(
    filter: FeatureCatalogView.defaultFilter,
    grantedScopes: DashAuthorizationScopes.initialReadOnly,
    enabled: coreEnabled)
  #expect(initialGrant.count == DashAuthorizationScopes.coreFeatures.count)
  #expect(!initialGrant.contains(.tunnels))
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
  #expect(featureID(for: .zoneEmailRouting("z1")) == .emailRouting)
  #expect(featureID(for: .worker("api")) == .workers)
  #expect(featureID(for: .tunnel("t1")) == .tunnels)
  #expect(featureID(for: .r2Bucket("media", prefix: "")) == .r2)
  #expect(featureID(for: .kvNamespace("ns")) == .kv)
  #expect(featureID(for: .kvKey(namespaceID: "ns", key: "flag")) == .kv)
  #expect(featureID(for: .profile) == nil)
  #expect(featureID(for: .settingsAccounts) == nil)
  #expect(featureID(for: .emailAddresses) == .emailRouting)
  #expect(featureID(for: .registrarDomain("example.com")) == .registrar)
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
  #expect(requiredScopes(for: .settingsAccounts).isEmpty)
  #expect(
    readScopes(for: .zoneEmailRouting("z1"))
      == [
        "zone.read", "dns.read", "zone-settings.read",
        "email-routing-rule.read", "email-routing-address.read",
      ])
  #expect(
    writeScopes(for: .zoneEmailRouting("z1"))
      == ["zone-settings.write", "email-routing-rule.write"])
  #expect(readScopes(for: .emailAddresses) == ["email-routing-address.read"])
  #expect(writeScopes(for: .emailAddresses) == ["email-routing-address.write"])
  #expect(readScopes(for: .registrarDomain("example.com")) == ["registrar-domains.read"])
  #expect(FeatureID.registrar.capability.write == ["registrar-domains.admin"])
  #expect(!FeatureID.registrar.showsCatalogReadOnlyBanner)
  #expect(
    FeatureID.emailRouting.capability.write
      == ["email-routing-rule.write", "email-routing-address.write"])
  #expect(!FeatureID.emailRouting.showsCatalogReadOnlyBanner)
  #expect(
    writeScopes(for: .registrarDomain("example.com"))
      == ["registrar-domains.admin"])
  #expect(readScopes(for: .tunnel("t1")) == ["argotunnel.read", "access.read"])
  #expect(writeScopes(for: .tunnel("t1")).isEmpty)
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

@Test func watchtowerExpandedChartSwapUsesFastOpacityProfile() {
  let expanded = WatchtowerChartVisualSwapProfile.resolved(isExpanded: true)
  let collapsed = WatchtowerChartVisualSwapProfile.resolved(isExpanded: false)

  #expect(expanded.liveEffect == .opacityOnly)
  #expect(expanded.placeholderEffect == .opacityOnly)
  #expect(expanded.totalDuration <= 0.3)
  #expect(expanded.totalDuration < collapsed.totalDuration)
  #expect(collapsed.liveEffect == .rich)
  #expect(collapsed.placeholderEffect == .rich)
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

  visualState.settle(to: CGPoint(x: 120, y: 240))
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

@Test @MainActor func watchtowerDragKeepsTheLastSwiftUILayoutSlotAcrossRebuilds() {
  let visualState = WatchtowerMetricDragVisualState()
  let reference = UIView()
  let initialFrame = CGRect(x: 0, y: 20, width: 160, height: 220)
  let destinationFrame = CGRect(x: 0, y: 280, width: 160, height: 220)
  let neighborFrame = CGRect(x: 172, y: 20, width: 160, height: 120)

  visualState.updateLayoutFrames([
    .webTraffic: initialFrame,
    .cpuTime: neighborFrame,
  ])
  visualState.beginLift(
    metric: .webTraffic,
    size: initialFrame.size,
    fingerLocation: CGPoint(x: 60, y: 80),
    sourceCenter: CGPoint(x: initialFrame.midX, y: initialFrame.midY),
    isExpanded: true,
    reference: reference,
    retaining: NSObject(),
    reduceMotion: false)
  #expect(visualState.frames(for: [.webTraffic, .cpuTime])[.cpuTime] == neighborFrame)

  visualState.updateLayoutFrames([
    .webTraffic: destinationFrame,
    .cpuTime: neighborFrame,
  ])
  #expect(
    visualState.sourceCenter(for: .webTraffic)
      == CGPoint(x: destinationFrame.midX, y: destinationFrame.midY))

  // A representable can disappear for one update while the flow reorders.
  // The release target must remain the last real insertion slot, not nil.
  visualState.updateLayoutFrames([:])
  let cachedCenter = visualState.sourceCenter(for: .webTraffic)
  let expectedCenter = CGPoint(x: destinationFrame.midX, y: destinationFrame.midY)
  #expect(cachedCenter == expectedCenter)

  visualState.settle(to: expectedCenter)
  #expect(visualState.phase == .settling)
  #expect(visualState.presentation?.center == expectedCenter)
}

@Test @MainActor func watchtowerDragSourceRejectsAnOffscreenStaleRegistration() {
  let visualState = WatchtowerMetricDragVisualState()
  let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
  let liveSource = UIView(frame: CGRect(x: 24, y: 180, width: 160, height: 120))
  let staleSource = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
  window.addSubview(liveSource)

  visualState.registerSourceView(liveSource, for: .cpuTime)
  visualState.registerSourceView(staleSource, for: .cpuTime)
  visualState.beginLift(
    metric: .webTraffic,
    size: CGSize(width: 342, height: 220),
    fingerLocation: CGPoint(x: 195, y: 100),
    sourceCenter: CGPoint(x: 195, y: 100),
    isExpanded: true,
    reference: window,
    retaining: NSObject(),
    reduceMotion: false)

  #expect(visualState.frames(for: [.cpuTime])[.cpuTime] == liveSource.frame)
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
      point: CGPoint(x: x, y: y),
      otherFrames: watchtowerDropFrames,
      containerWidth: 372)
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

@Test func watchtowerDropTargetingKeepsHalfWidthReadingOrderWithoutAnExpandedPeer() {
  let collapsedOnly = Array(watchtowerDropFrames.prefix(2))

  #expect(
    WatchtowerMetricDropTargeting.destinationIndex(
      point: CGPoint(x: 120, y: 60),
      otherFrames: collapsedOnly,
      containerWidth: 372) == 1)
  #expect(
    WatchtowerMetricDropTargeting.destinationIndex(
      point: CGPoint(x: 300, y: 60),
      otherFrames: collapsedOnly,
      containerWidth: 372) == 2)
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

@Test func watchtowerAnalyticsUpdatedBadgeUsesRelativeTime() {
  let previousLocale = DashL10n.localeOverrideForTesting
  DashL10n.localeOverrideForTesting = Locale(identifier: "en")
  defer { DashL10n.localeOverrideForTesting = previousLocale }

  // No snapshot yet: the skeleton and the pull-to-refresh spinner are the only
  // loading signals, so the header shows no freshness text at all.
  #expect(WatchtowerAnalyticsChartModel.updatedBadge(fetchedAt: nil) == nil)

  let now = Date()
  let badge = WatchtowerAnalyticsChartModel.updatedBadge(
    fetchedAt: now.addingTimeInterval(-180),
    now: now)
  #expect(badge?.contains("minute") == true || badge?.contains("seconds") == true)
  // Visible string is the bare fragment; only VoiceOver gets the subject.
  #expect(badge?.hasPrefix("Updated") == false)
  #expect(
    WatchtowerAnalyticsChartModel.updatedAccessibilityLabel("3 minutes ago")
      == "Updated 3 minutes ago")

  // A TimelineView tick can lag the wall clock, so a just-fetched stamp looks
  // slightly in the future. The zero/sub-second formatter boundary must stay
  // a positive, localized "just now" result rather than "in 0 seconds".
  let futureClamped = WatchtowerAnalyticsChartModel.updatedBadge(
    fetchedAt: now.addingTimeInterval(45),
    now: now)
  #expect(futureClamped == "just now")
  #expect(
    WatchtowerAnalyticsChartModel.updatedBadge(
      fetchedAt: now.addingTimeInterval(-0.5),
      now: now) == "just now")
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
  #expect(FeatureVisualIdentity.tone(for: .registrar) == .teal)
  #expect(FeatureVisualIdentity.tone(for: .emailRouting) == .danger)
  #expect(FeatureVisualIdentity.tone(for: .workers) == .brand)
  #expect(FeatureVisualIdentity.tone(for: .pages) == .info)
  #expect(FeatureVisualIdentity.tone(for: .r2) == .accent)
  #expect(FeatureVisualIdentity.tone(for: .kv) == .warning)
  #expect(FeatureVisualIdentity.tone(for: .tunnels) == .violet)

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

@Test func compactTrayDragDecisionUsesOriginalProjectionThresholds() {
  #expect(
    TrayDragDecision.content(translation: 40, predictedEndTranslation: 40) == .settle)
  #expect(
    TrayDragDecision.content(translation: 120, predictedEndTranslation: 120) == .settle)
  #expect(
    TrayDragDecision.content(translation: 121, predictedEndTranslation: 121) == .dismiss)
  #expect(
    TrayDragDecision.content(translation: 32, predictedEndTranslation: 161) == .dismiss)
  #expect(
    TrayDragDecision.content(translation: 31, predictedEndTranslation: 1_000) == .settle)
}

@Test func compactTrayUpwardDragUsesOriginalFixedFrictionRubberBand() {
  #expect(TrayDragDecision.rubberBand(cardTop: -100, expandedTop: 0) == -15)
  #expect(TrayDragDecision.rubberBand(cardTop: 42, expandedTop: 0) == 42)
}

@Test func compactTrayRestoresOriginalShellTokens() {
  #expect(DashTheme.Sheet.floatingMargin == 12)
  #expect(DashTheme.Sheet.floatingBottomTuck == 6)
  #expect(DashTheme.Sheet.scrimOpacity == 0.35)
}

@Test func profileTrayPhaseTitlesStayLocalizedCatalogKeys() {
  #expect(ProfileTrayPhase.initial == .accounts)
  #expect(ProfileTrayPhase.accounts.title == "Switch account")
  #expect(ProfileTrayPhase.signOut.title == "Sign out")
}

@Test func profileTrayPhaseMapsRoutesToSemanticRoles() throws {
  let account = try JSONDecoder().decode(
    CloudflareAccount.self,
    from: Data(#"{"id":"account-1","name":"Example"}"#.utf8)
  )

  #expect(ProfileTrayPhase.accounts.trayRole == .root)
  #expect(ProfileTrayPhase.switchAccount(account).trayRole == .detail)
  #expect(ProfileTrayPhase.signOut.trayRole == .destructive)
}

@Test func signOutTrayCostsTwoTapsWhereverItIsOffered() {
  // Settings' sign out is the same pair as the profile tray's pushed step:
  // the row names the action at the root, and only the destructive step
  // commits. A single-step Settings tray was the odd one out.
  #expect(SignOutTrayStep.intro.trayRole == .root)
  #expect(SignOutTrayStep.confirm.trayRole == .destructive)
  #expect(ProfileTrayPhase.signOut.trayRole == SignOutTrayStep.confirm.trayRole)
}

@Test @MainActor func trayFlowStackDrivesRouteAndRoleFromThePathTail() throws {
  let account = try JSONDecoder().decode(
    CloudflareAccount.self,
    from: Data(#"{"id":"account-1","name":"Example"}"#.utf8)
  )
  var path: [ProfileTrayPhase] = []
  let binding = Binding(get: { path }, set: { path = $0 })

  let atRoot = DashTrayFlow(root: .accounts, path: binding, role: \.trayRole) { _ in
    EmptyView()
  }
  #expect(atRoot.route == .accounts)
  #expect(atRoot.role == .root)

  path = [.switchAccount(account), .signOut]
  let pushed = DashTrayFlow(root: .accounts, path: binding, role: \.trayRole) { _ in
    EmptyView()
  }
  #expect(pushed.route == .signOut)
  #expect(pushed.role == .destructive)
}

@Test func sheetHeaderActionsDefaultToTheDestructiveCircle() {
  // Every pre-tone header action was the fixed danger circle; the tone work
  // must not silently recolor them. Only an explicit non-destructive role
  // opts an action into `\.dashTrayTone`.
  let action = DashSheetHeaderAction(
    id: "delete", icon: "TrashBinTrashOutline", accessibilityLabel: "Delete"
  ) {}
  #expect(action.role == .destructive)
}

@Test func morphingLabelSegmentsShareCharacterAffixes() {
  // Family's Continue → Confirm: the shared "Con" stays planted.
  let verb = DashMorphingLabelSegments(from: "Continue", to: "Confirm")
  #expect(verb.prefix == "Con")
  #expect(verb.changed == "firm")
  #expect(verb.suffix.isEmpty)

  // A count appearing after a stable verb — only the count run morphs.
  let count = DashMorphingLabelSegments(from: "Delete", to: "Delete 3")
  #expect(count.prefix == "Delete")
  #expect(count.changed == " 3")
  #expect(count.suffix.isEmpty)

  // Character-level diffing keeps CJK affixes intact around the number.
  let cjk = DashMorphingLabelSegments(from: "删除 3 个对象", to: "删除 12 个对象")
  #expect(cjk.prefix == "删除 ")
  #expect(cjk.changed == "12")
  #expect(cjk.suffix == " 个对象")

  // The prefix and suffix scans must never claim the same characters.
  let overlap = DashMorphingLabelSegments(from: "aa", to: "aba")
  #expect(overlap.prefix == "a")
  #expect(overlap.changed == "b")
  #expect(overlap.suffix == "a")

  // Rebuilding the segments always yields the new string verbatim.
  for split in [verb, count, cjk, overlap] {
    #expect(split.joined == split.prefix + split.changed + split.suffix)
  }
  #expect(cjk.joined == "删除 12 个对象")

  // Resting state: everything is the changeable run, so the first morph can
  // keep whatever the next string happens to share.
  let resting = DashMorphingLabelSegments(text: "Delete")
  #expect(resting.prefix.isEmpty)
  #expect(resting.changed == "Delete")
  #expect(resting.suffix.isEmpty)
}

@Test func accentTrayPillsKeepDarkInkOnTheOrangeFill() {
  // Adaptive `inverse` is near-white in light mode — ~2.4:1 on brand orange
  // `#F6821F` — so `.accent` (the R2 / storage tray tone) pins its submit-pill
  // label near-black instead. Every other tone keeps the adaptive pair.
  #expect(FeatureVisualTone.accent.vividLabel == Color(hex: 0x171717))
  #expect(FeatureVisualTone.success.vividLabel == DashTheme.inverse)
  #expect(FeatureVisualTone.brand.vividLabel == DashTheme.inverse)
}

@Test func trayBackActionEqualityIsDepthOnly() {
  var performed = 0
  let first = DashTrayBackAction(depth: 1) { performed += 1 }
  let sameDepth = DashTrayBackAction(depth: 1) {}
  let deeper = DashTrayBackAction(depth: 2) {}

  #expect(first == sameDepth)
  #expect(first != deeper)
  first.perform()
  #expect(performed == 1)
}

@Test func trayAnchorTransformMapsTheCardOntoTheSourceRect() {
  let card = CGRect(x: 20, y: 400, width: 350, height: 300)
  let source = CGRect(x: 24, y: 620, width: 118, height: 88)

  // Progress 0: the whole card renders scaled and translated onto the source —
  // its center lands on the source center at the source's proportions.
  let start = DashTrayAnchorMath.transform(source: source, card: card, progress: 0)
  #expect(abs(start.scaleX - source.width / card.width) < 0.0001)
  #expect(abs(start.scaleY - source.height / card.height) < 0.0001)
  #expect(abs(start.offsetX - (source.midX - card.midX)) < 0.0001)
  #expect(abs(start.offsetY - (source.midY - card.midY)) < 0.0001)

  // Progress 1: exact identity, so handing off to the slide modifier (which
  // also renders identity at 1) can never jump.
  let end = DashTrayAnchorMath.transform(source: source, card: card, progress: 1)
  #expect(end == DashTrayAnchorMath.Transform(scaleX: 1, scaleY: 1, offsetX: 0, offsetY: 0))

  // An unmeasured card (first frame) must not divide by zero.
  let unmeasured = DashTrayAnchorMath.transform(source: source, card: .zero, progress: 0)
  #expect(unmeasured == DashTrayAnchorMath.Transform(scaleX: 1, scaleY: 1, offsetX: 0, offsetY: 0))

  // The card fades in over the first third and is opaque from there on.
  #expect(DashTrayAnchorMath.opacity(progress: 0) == 0)
  #expect(DashTrayAnchorMath.opacity(progress: 1.0 / 3.0) == 1)
  #expect(DashTrayAnchorMath.opacity(progress: 1) == 1)
}

@Test @MainActor func trayAnchorSourcesMustBeOnScreenAndControlSized() {
  let bounds = CGRect(x: 0, y: 0, width: 393, height: 852)

  // A quick-action tile: anchorable.
  #expect(
    DashTraySourceRegistry.isPresentableSource(
      CGRect(x: 16, y: 300, width: 120, height: 90), in: bounds))

  // Scrolled fully off screen, collapsed, or oversized (a scroll container or
  // near-full-screen surface would read as a zoom glitch): bottom reveal.
  #expect(
    !DashTraySourceRegistry.isPresentableSource(
      CGRect(x: 16, y: -400, width: 120, height: 90), in: bounds))
  #expect(
    !DashTraySourceRegistry.isPresentableSource(
      CGRect(x: 16, y: 300, width: 0, height: 0), in: bounds))
  #expect(
    !DashTraySourceRegistry.isPresentableSource(
      CGRect(x: 0, y: 0, width: 393, height: 852), in: bounds))
  #expect(
    !DashTraySourceRegistry.isPresentableSource(
      CGRect(x: 16, y: 300, width: 120, height: 90), in: .zero))
}

@Test @MainActor func trayAnchorSourceClaimIsExclusiveAndOwnerReleased() {
  let registry = DashTraySourceRegistry()

  #expect(registry.claim("first"))
  #expect(registry.occupiedID == AnyHashable("first"))
  #expect(!registry.claim("second"))
  #expect(registry.occupiedID == AnyHashable("first"))

  registry.release("second")
  #expect(registry.occupiedID == AnyHashable("first"))
  registry.release("first")
  #expect(registry.occupiedID == nil)
  #expect(registry.claim("second"))

  var lease: DashTrayAnchorLease? = DashTrayAnchorLease(registry: registry)
  lease?.adopt(DashTrayAnchorClaim(sourceID: "second", frame: .zero))
  lease = nil
  #expect(registry.occupiedID == nil)
}

@Test func successCheckFlightArcsBetweenItsEndpointsWithALateDissolve() {
  let from = CGPoint(x: 300, y: 700)
  let to = CGPoint(x: 60, y: 120)

  // The quadratic bezier is pinned to its endpoints…
  #expect(DashTrayFlightMath.point(from: from, to: to, progress: 0) == from)
  #expect(DashTrayFlightMath.point(from: from, to: to, progress: 1) == to)

  // …and its midpoint rises above the straight line: the control point sits
  // `apexLift` above the higher endpoint, so at t = 0.5 the arc is half a
  // lift above the chord's midpoint minus the endpoint spread's pull.
  let mid = DashTrayFlightMath.point(from: from, to: to, progress: 0.5)
  #expect(mid.x == (from.x + to.x) / 2)
  #expect(mid.y < (from.y + to.y) / 2)

  // Size interpolates start → landing; a degenerate start stays untouched.
  #expect(DashTrayFlightMath.scale(from: 20, to: 10, progress: 0) == 1)
  #expect(abs(DashTrayFlightMath.scale(from: 20, to: 10, progress: 1) - 0.5) < 0.0001)
  #expect(DashTrayFlightMath.scale(from: 0, to: 10, progress: 0.5) == 1)

  // Fully visible for three quarters of the travel, then dissolving into the
  // toast mark it lands on.
  #expect(DashTrayFlightMath.opacity(0) == 1)
  #expect(DashTrayFlightMath.opacity(0.75) == 1)
  #expect(abs(DashTrayFlightMath.opacity(0.875) - 0.5) < 0.0001)
  #expect(DashTrayFlightMath.opacity(1) == 0)

  // The ink → green crossfade is pinned to pill ink at liftoff and toast
  // green well before touchdown, ramping through the middle of the travel.
  #expect(DashTrayFlightMath.colorBlend(0) == 0)
  #expect(abs(DashTrayFlightMath.colorBlend(0.5) - 0.5) < 0.0001)
  #expect(DashTrayFlightMath.colorBlend(0.7) == 1)
  #expect(DashTrayFlightMath.colorBlend(1) == 1)
}

@Test @MainActor func toastCenterSuccessReturnsThePresentedIdentity() {
  // The flight's landing match depends on `success` returning the identity
  // of the toast it actually enqueued — with an empty queue, that toast is
  // presented immediately.
  let center = DashToastCenter()
  let id = center.success("Created successfully.", haptic: false)
  #expect(center.current?.id == id)

  // A second success while the first holds the slot queues instead — its ID
  // must still name the *new* toast, not the visible one.
  let queued = center.success("Another one.", haptic: false)
  #expect(queued != id)
  #expect(center.current?.id == id)
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

  let scopedURL = HomeActions.deepLink(action: .purgeCache, accountID: " account one ")
  #expect(scopedURL?.absoluteString == "dash://action/purgeCache?account=account%20one")
  #expect(scopedURL.flatMap(DashRoute.parse) == .action(.purgeCache).scoped(to: "account one"))

  let accountA = AccountRequestContext(accountID: "account-a", generation: 1)
  let accountB = AccountRequestContext(accountID: "account-b", generation: 2)
  let pending = PendingHomeAction(action: .purgeCache, context: accountA)
  #expect(pending.matches(accountA))
  #expect(!pending.matches(accountB))
  #expect(!pending.matches(nil))
}

@Test func widgetPreferenceMirrorsPreserveExplicitHomeSelectionAndChartStyle() {
  let suiteName = "DashTests.WidgetPreferences.\(UUID().uuidString)"
  guard let store = UserDefaults(suiteName: suiteName) else {
    Issue.record("Could not create isolated widget preference defaults")
    return
  }
  defer { store.removePersistentDomain(forName: suiteName) }

  #expect(HomeActions.mirroredActions(in: store) == HomeActions.defaults)
  store.set("", forKey: HomeActions.key)
  #expect(HomeActions.mirroredActions(in: store).isEmpty)
  store.set(HomeActions.encode([.addDomain, .uploadR2]), forKey: HomeActions.key)
  #expect(HomeActions.mirroredActions(in: store) == [.addDomain, .uploadR2])

  #expect(!DashWidgetBridges.mirroredChartStyleIsSystem(in: store))
  DashWidgetBridges.mirrorChartStyle("system", in: store)
  #expect(DashWidgetBridges.mirroredChartStyleIsSystem(in: store))
  DashWidgetBridges.mirrorChartStyle("unknown", in: store)
  #expect(!DashWidgetBridges.mirroredChartStyleIsSystem(in: store))

  let systemLocale = Locale(identifier: "ja_JP")
  #expect(
    DashWidgetBridges.mirroredLocale(in: store, systemLocale: systemLocale)
      .language.languageCode?.identifier == "ja")
  store.set("zh-Hans", forKey: DashWidgetBridges.languageKey)
  #expect(
    DashWidgetBridges.mirroredLocale(in: store, systemLocale: systemLocale)
      .language.languageCode?.identifier == "zh")
  store.set("en", forKey: DashWidgetBridges.languageKey)
  #expect(
    DashWidgetBridges.mirroredLocale(in: store, systemLocale: systemLocale)
      .language.languageCode?.identifier == "en")
  store.set("system", forKey: DashWidgetBridges.languageKey)
  #expect(
    DashWidgetBridges.mirroredLocale(in: store, systemLocale: systemLocale)
      .language.languageCode?.identifier == "ja")
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

/// The frost is a threshold, not a scrub: it arms once content has genuinely
/// gone under the bar, and disarms only back at the top. Between the two lines
/// it holds whatever it already was, so resting a finger there can't chatter it.
@Test func headerFrostArmsAndDisarmsOnSeparateThresholds() {
  let enter = DashHeaderScrimMetrics.enter
  let exit = DashHeaderScrimMetrics.exit
  #expect(enter > exit)

  #expect(!DashHeaderScrimRules.isScrolled(distance: -40, wasScrolled: false))
  #expect(!DashHeaderScrimRules.isScrolled(distance: enter, wasScrolled: false))
  #expect(DashHeaderScrimRules.isScrolled(distance: enter + 1, wasScrolled: false))

  // Armed, and still armed inside the dead band between the thresholds.
  #expect(DashHeaderScrimRules.isScrolled(distance: enter - 1, wasScrolled: true))
  #expect(DashHeaderScrimRules.isScrolled(distance: exit + 1, wasScrolled: true))
  #expect(!DashHeaderScrimRules.isScrolled(distance: exit, wasScrolled: true))
  #expect(!DashHeaderScrimRules.isScrolled(distance: -40, wasScrolled: true))
}

/// The frost and the glow answer to different things: the frost is chrome and
/// stays pinned to the window's top edge, the glow belongs to the top of the
/// content and leaves with it. Same probe, same distance, two behaviours.
@Test func workspaceGlowRidesTheScrollItIsMeasuredAgainst() {
  #expect(DashWorkspaceWashRules.lift(for: 0) == 0)
  #expect(DashWorkspaceWashRules.lift(for: 1) == 1)
  // Past the frost's own threshold the glow is still just tracking, not
  // flipping: it has no armed state to hold on to.
  #expect(DashWorkspaceWashRules.lift(for: DashHeaderScrimMetrics.enter) > 0)
  #expect(DashWorkspaceWashRules.lift(for: 120) == 120)
}

/// Clamped at both ends. A rubber-band pull past the top would otherwise push
/// the light down off its own edge and leave bare canvas above it, and once the
/// field has travelled its full depth there is nothing left on screen to move.
@Test func workspaceGlowNeverTravelsBelowItsEdgeOrPastItsDepth() {
  let depth = DashWorkspaceWashRules.depth
  #expect(depth > 0)
  #expect(DashWorkspaceWashRules.lift(for: -1) == 0)
  #expect(DashWorkspaceWashRules.lift(for: -400) == 0)
  #expect(DashWorkspaceWashRules.lift(for: depth) == depth)
  #expect(DashWorkspaceWashRules.lift(for: depth + 800) == depth)
}

/// Keep the reference implementation's deliberately restrained blur and tint
/// tuning in one shared contract, so the SwiftUI wrapper cannot quietly drift
/// back toward the taller, heavier material slab this replaced.
@Test func headerVariableBlurKeepsReferenceTuning() {
  #expect(DashHeaderScrimMetrics.maxBlurRadius == 5)
  #expect(DashHeaderScrimMetrics.startOffset == 0)
  #expect(DashHeaderScrimMetrics.tail == 40)
  #expect(DashHeaderScrimMetrics.tintOpacityTop == 0.7)
  #expect(DashHeaderScrimMetrics.tintOpacityMiddle == 0.5)
  #expect(DashHeaderScrimMetrics.tintMiddleY == 56)
}

/// The conditionally mounted backdrop enters far enough from its final
/// position to hide the filter's first frame. A full-width atmospheric layer
/// gets the same calm duration in either direction, with a smaller exit lift.
@Test func headerFrostUsesMatchedBidirectionalTiming() {
  #expect(DashHeaderScrimMotion.insertionOffsetY == -8)
  #expect(DashHeaderScrimMotion.removalOffsetY == -3)
  #expect(DashHeaderScrimMotion.insertionDuration == 0.36)
  #expect(DashHeaderScrimMotion.removalDuration == 0.36)
  #expect(DashHeaderScrimMotion.insertionDuration > 0)
  #expect(DashHeaderScrimMotion.removalDuration > 0)
  #expect(abs(DashHeaderScrimMotion.removalOffsetY) < abs(DashHeaderScrimMotion.insertionOffsetY))
  #expect(DashHeaderScrimMotion.insertionDuration == DashHeaderScrimMotion.removalDuration)
  #expect(DashHeaderScrimMotion.insertionDuration <= 0.4)
}

/// The store carries the hysteresis: it is asked with a raw scroll distance and
/// remembers what it answered, so a screen parked between the two thresholds
/// keeps whatever it already had. A screen with no scroll view clears outright.
@Test @MainActor func headerFrostStateRemembersWhatItAnswered() {
  let state = DashHeaderScrollState()
  #expect(!state.isFrosted)

  state.report(distance: DashHeaderScrimMetrics.enter)
  #expect(!state.isFrosted)

  state.report(distance: DashHeaderScrimMetrics.enter + 1)
  #expect(state.isFrosted)

  // Between the thresholds: holds.
  state.report(distance: DashHeaderScrimMetrics.exit + 1)
  #expect(state.isFrosted)

  state.report(distance: 0)
  #expect(!state.isFrosted)

  state.report(distance: DashHeaderScrimMetrics.enter + 1)
  #expect(state.isFrosted)
  state.clear()
  #expect(!state.isFrosted)
}

/// A bounded accessibility mask must reach fully clear at its own extent and
/// stay there, or its fallback canvas paints a hard step over the content.
@Test func headerAccessibilityMaskClearsAtItsConfiguredExtent() {
  let stops = DashHeaderScrimRules.maskStops(solidFraction: 0.2, extent: 0.5)
  #expect(stops.first?.opacity == 1)
  #expect(stops.contains { $0.opacity == 1 && $0.location == 0.2 })
  #expect(stops.contains { $0.opacity == 0 && $0.location == 0.5 })
  #expect(stops.last?.location == 1)
  #expect(stops.last?.opacity == 0)
  // A layer whose plateau already fills its extent still has to close out.
  let degenerate = DashHeaderScrimRules.maskStops(solidFraction: 0.9, extent: 0.4)
  #expect(degenerate.last?.opacity == 0)
  #expect(degenerate.last?.location == 1)
}

/// The band is solid across the status bar and then eases to fully clear — a
/// hard stop at the bottom is exactly the edge this gradient exists to avoid.
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
  #expect(DomainCardColors.defaultPalette.count == 20)
  #expect(Set(DomainCardColors.defaultPalette).count == 20)
  #expect(DomainCardColors.prefersLightContent(0x1B191F))
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
  #expect(parse("dash://action/purgeCache") == .action(.purgeCache))
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
  #expect(parse("dash://action/not-an-action") == nil)
  #expect(parse("dash://action/purgeCache/extra") == nil)
  #expect(parse("dash://zone") == nil)  // missing id
  #expect(parse("https://watchtower") == nil)  // wrong scheme
  #expect(parse("dash://unknownhost") == nil)
  #expect(parse("dash://watchtower?account=") == nil)
  #expect(parse("dash://watchtower?account=a&account=b") == nil)
  #expect(parse("dash://settings/extra") == nil)

  // destination mapping.
  #expect(DashRoute.settings.destination == .settings)
  #expect(DashRoute.watchtower.destination == nil)
  #expect(DashRoute.action(.purgeCache).destination == nil)
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

@Test func defaultPushProvisioningSkipsPreviewAndTestProcesses() {
  #expect(
    !PushRegistrationService.shouldAutomaticallyProvision(
      arguments: ["Dash", "-ui-preview"], environment: [:]))
  #expect(
    !PushRegistrationService.shouldAutomaticallyProvision(
      arguments: ["Dash"], environment: ["XCTestConfigurationFilePath": "/tmp/tests"]))
  #expect(
    PushRegistrationService.shouldAutomaticallyProvision(
      arguments: ["Dash"], environment: [:]))
}

@Test func pushIsReadyOnlyAfterDestinationSetupAndBuildPolicyMigration() throws {
  let suite = "dash.tests.push-ready.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let accountID = "account-a"

  defaults.set("webhook-a", forKey: PushRegistrationService.webhookIDKey(accountID: accountID))
  #expect(!PushRegistrationService.isReady(accountID: accountID, in: defaults))

  defaults.set(true, forKey: PushRegistrationService.readinessKey(accountID: accountID))
  #expect(PushRegistrationService.isReady(accountID: accountID, in: defaults))

  defaults.removeObject(forKey: PushRegistrationService.webhookIDKey(accountID: accountID))
  #expect(!PushRegistrationService.isReady(accountID: accountID, in: defaults))
}

@Test func webhookRemovalPreservesPolicyAndOtherDeliveryTargets() throws {
  let policy = try JSONDecoder().decode(
    NotificationPolicy.self,
    from: Data(
      #"{"id":"policy-1","name":"Existing","alert_type":"tunnel_health_event","enabled":false,"alert_interval":"weekly","filters":{"zones":["zone-1"]},"mechanisms":{"email":[{"id":"email-1"}],"pagerduty":[{"id":"pager-1"}],"webhooks":[{"id":"device-a"}]}}"#
        .utf8))

  let mechanisms = try #require(
    PushRegistrationService.mechanismsRemovingDelivery(
      webhookIDs: ["device-a"], from: policy))
  #expect(mechanisms.email?.map(\.id) == ["email-1"])
  #expect(mechanisms.pagerduty?.map(\.id) == ["pager-1"])
  #expect(mechanisms.webhooks?.isEmpty == true)
  #expect(
    PushRegistrationService.mechanismsRemovingDelivery(
      webhookIDs: ["device-b"], from: policy) == nil)
  #expect(
    PushRegistrationService.mechanismsRemovingDelivery(
      webhookIDs: ["  "], from: policy) == nil)

  let encoded = try JSONEncoder().encode(
    NotificationPolicyMechanismsInput(mechanisms: mechanisms))
  let object = try #require(
    JSONSerialization.jsonObject(with: encoded) as? [String: Any])
  #expect(Set(object.keys) == Set(["mechanisms"]))

  let pagesPolicy = try JSONDecoder().decode(
    NotificationPolicy.self,
    from: Data(
      #"{"id":"pages","alert_type":"pages_event_alert","mechanisms":{"email":[{"id":"email-1"}],"webhooks":[{"id":"device-a"},{"id":"device-b"}]}}"#
        .utf8))
  let pagesInput = try #require(
    PushRegistrationService.mechanismsRemovingDelivery(
      webhookIDs: ["device-a", "device-b"], from: pagesPolicy))
  #expect(pagesInput.email?.map(\.id) == ["email-1"])
  #expect(pagesInput.webhooks?.isEmpty == true)
  #expect(PushRegistrationService.usesBuildActivityPath(alertType: "pages_event_alert"))
}

@Test func legacyLocalWatchtowerNotificationStateIsRemoved() throws {
  let suite = "dash.tests.legacy-watchtower-notifications.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  defaults.set(true, forKey: LegacyWatchtowerNotificationSettings.optInKey)
  defaults.set(Data([1, 2, 3]), forKey: LegacyWatchtowerNotificationSettings.baselinesKey)

  LegacyWatchtowerNotificationSettings.clear(defaults: defaults)

  #expect(defaults.object(forKey: LegacyWatchtowerNotificationSettings.optInKey) == nil)
  #expect(defaults.object(forKey: LegacyWatchtowerNotificationSettings.baselinesKey) == nil)
}

@Test func legacyGeneratedNotificationCleanupDoesNotMatchCloudflarePushes() {
  #expect(
    DashNotificationSupport.isLegacyGeneratedNotificationIdentifier(
      "dash.expiry.domain.account.example.com.7"))
  #expect(DashNotificationSupport.isLegacyGeneratedNotificationIdentifier("watchtower.alerts"))
  #expect(
    DashNotificationSupport.isLegacyGeneratedNotificationIdentifier("watchtower.alert.delivery"))
  #expect(
    !DashNotificationSupport.isLegacyGeneratedNotificationIdentifier(
      "CFNetwork-generated-remote-identifier"))
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
  let provisional = DashNotificationSupport.authorizationOptions(prominently: false)
  #expect(provisional.contains(.alert))
  #expect(provisional.contains(.sound))
  #expect(provisional.contains(.badge))
  #expect(provisional.contains(.provisional))

  let prominent = DashNotificationSupport.authorizationOptions(prominently: true)
  #expect(prominent.contains(.alert))
  #expect(prominent.contains(.sound))
  #expect(prominent.contains(.badge))
  #expect(!prominent.contains(.provisional))

  // `.notSupported` is what a real legacy install reports — the badge option
  // was never requested, so iOS never had a setting to disable. Matching only
  // `.disabled` skipped every one of them.
  let authorizedMigration = DashNotificationSupport.badgeAuthorizationMigrationOptions(
    authorizationStatus: .authorized,
    badgeSetting: .notSupported)
  #expect(authorizedMigration == [.badge])
  let provisionalMigration = DashNotificationSupport.badgeAuthorizationMigrationOptions(
    authorizationStatus: .provisional,
    badgeSetting: .notSupported)
  #expect(provisionalMigration?.contains(.badge) == true)
  #expect(provisionalMigration?.contains(.provisional) == true)
  #expect(
    DashNotificationSupport.badgeAuthorizationMigrationOptions(
      authorizationStatus: .authorized,
      badgeSetting: .disabled) == [.badge])
  #expect(
    DashNotificationSupport.badgeAuthorizationMigrationOptions(
      authorizationStatus: .authorized,
      badgeSetting: .enabled) == nil)
  #expect(
    DashNotificationSupport.badgeAuthorizationMigrationOptions(
      authorizationStatus: .denied,
      badgeSetting: .notSupported) == nil)
  #expect(
    DashNotificationSupport.badgeAuthorizationMigrationOptions(
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

@Test @MainActor func automaticPushEnsuresShareOneDesiredGeneration() {
  let accountID = "ensure-\(UUID().uuidString)"
  let first = PushRegistrationOperationGate.beginEnsureEnabled(accountID: accountID)
  let second = PushRegistrationOperationGate.beginEnsureEnabled(accountID: accountID)

  #expect(first == second)
  #expect(PushRegistrationOperationGate.isCurrent(first, enabled: true))

  _ = PushRegistrationOperationGate.beginDesiredChange(accountID: accountID, enabled: false)
  #expect(!PushRegistrationOperationGate.isCurrent(first, enabled: true))
}

@Test @MainActor func signOutPreparationInvalidatesUnstoredPushEnables() {
  let firstAccount = "enable-\(UUID().uuidString)"
  let secondAccount = "ensure-\(UUID().uuidString)"
  let first = PushRegistrationOperationGate.beginEnsureEnabled(accountID: firstAccount)
  let second = PushRegistrationOperationGate.beginEnsureEnabled(accountID: secondAccount)

  PushRegistrationService.prepareForSignOut(
    accountIDs: [firstAccount, secondAccount])

  #expect(!PushRegistrationOperationGate.isCurrent(first, enabled: true))
  #expect(!PushRegistrationOperationGate.isCurrent(second, enabled: true))
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
  let tombstone = try #require(
    PushRegistrationService.cleanupTombstone(accountID: "account-a", in: defaults))
  #expect(tombstone.webhookID == "webhook-a")
  #expect(tombstone.attempts == 2)
  #expect(tombstone.lastAttemptAt == Date(timeIntervalSince1970: 200))

  PushRegistrationService.clearCleanup(accountID: "account-a", defaults: defaults)
  #expect(PushRegistrationService.pendingCleanupAccountIDs(in: defaults).isEmpty)
}

@Test @MainActor
func remoteWatchtowerRefreshStaysAccountScopedAndRejectsOldClears() throws {
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

@Test @MainActor func accountAuthorizationAlwaysRequestsFullCore() {
  let demoGrant = DashAuthorizationScopes.initialReadOnly
  #expect(Set(["analytics.read"]).isSubset(of: demoGrant))

  let request = AppModel.accountAuthorizationRequest(
    granted: demoGrant,
    requested: ["analytics.read"]
  )
  #expect(request != nil)
  let scopes = request ?? []
  #expect(demoGrant.isSubset(of: scopes))
  #expect(DashAuthorizationScopes.core.isSubset(of: scopes))
  #expect(!scopes.isSubset(of: demoGrant))
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
  // Empty write = Dash never mutates this surface — unlocked means Read-only,
  // not Full, even when every listed read scope is present.
  let browseOnly = FeatureCapability(read: ["tunnel.read"], write: [])
  #expect(browseOnly.accessLevel(grantedScopes: ["tunnel.read"]) == .readOnly)
  #expect(
    FeatureID.tunnels.capability.accessLevel(
      grantedScopes: ["argotunnel.read", "access.read"]) == .readOnly)
  #expect(!FeatureID.tunnels.showsCatalogReadOnlyBanner)
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
      overlays: DashTrayPresentation(presented: true), navigationDepth: 0))
  #expect(shouldHideTabBar(overlays: DashTrayPresentation(), navigationDepth: 1))
  #expect(
    shouldHideTabBar(
      overlays: DashTrayPresentation(presented: true), navigationDepth: 2))
  #expect(!shouldHideTabBar(overlays: DashTrayPresentation(), navigationDepth: 0))
}

@Test func headerAvatarHidesForAnyOverlayOrPush() {
  #expect(
    shouldHideHeaderAvatar(
      overlays: DashTrayPresentation(presented: true), navigationDepth: 0))
  #expect(shouldHideHeaderAvatar(overlays: DashTrayPresentation(), navigationDepth: 1))
  #expect(!shouldHideHeaderAvatar(overlays: DashTrayPresentation(), navigationDepth: 0))
}

@Test func trayPresentationHasOneCompactState() {
  #expect(DashTrayPresentation(presented: true).presented)
  #expect(!DashTrayPresentation().presented)
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

@Test @MainActor func toastCenterQueuesAndPromotesAutomaticToasts() {
  let model = AppModel(configuration: AppConfiguration(clientID: "", redirectURI: ""))
  #expect(model.toasts.current == nil)

  model.toasts.success("Uploaded logo.png.", haptic: false)
  let first = model.toasts.current
  #expect(first?.kind == .success)
  #expect(first?.message == "Uploaded logo.png.")
  #expect(first?.duration == DashToast.Kind.success.duration)

  model.toasts.error("Permission denied.", title: "R2", haptic: false)
  #expect(model.toasts.current?.id == first?.id)

  model.toasts.dismiss(id: first!.id)
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

@Test @MainActor func deferredDeletionUndoPreemptsAutomaticWithoutRevivingQueuedUndo() {
  let toasts = DashToastCenter()
  let owner = toasts.claimDeferredDeletionOwner()
  let optimisticID = DashToast.ID.optimistic(UUID())
  toasts.show(
    DashToast(
      id: optimisticID,
      kind: .warning,
      message: "Saving settings…",
      dismissBehavior: .programmaticOnly),
    haptic: false,
    announce: false)

  let later = DashToast(kind: .success, message: "Later feedback.")
  toasts.show(later, haptic: false, announce: false)
  toasts.show(
    DashToast(
      id: .deferredDeletionBatch,
      kind: .warning,
      message: "First deletion deadline.",
      action: .undoDeferredDeletionBatch,
      dismissBehavior: .programmaticOnly),
    haptic: false,
    announce: false,
    deferredDeletionOwner: owner)
  #expect(toasts.current?.id == optimisticID)

  toasts.update(
    DashToast(id: optimisticID, kind: .success, message: "Settings saved."),
    haptic: false,
    announce: false)
  toasts.update(
    DashToast(
      id: .deferredDeletionBatch,
      kind: .warning,
      message: "Latest deletion deadline.",
      action: .undoDeferredDeletionBatch,
      dismissBehavior: .programmaticOnly),
    haptic: false,
    announce: false,
    deferredDeletionOwner: owner)
  #expect(toasts.current?.message == "Latest deletion deadline.")

  toasts.releaseDeferredDeletionToast(owner: owner)
  #expect(toasts.current?.id == later.id)
  toasts.dismiss(id: later.id)
  #expect(toasts.current == nil)
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

/// The card lifts a quiet series off the floor so the sparkline stays visible;
/// the pushed detail plots and tabulates what Cloudflare actually counted.
@Test func wafDetailPointsKeepRealCountsInAscendingHourOrder() {
  let previousLocale = DashL10n.localeOverrideForTesting
  DashL10n.localeOverrideForTesting = Locale(identifier: "en")
  defer { DashL10n.localeOverrideForTesting = previousLocale }

  let series = [
    FirewallEventsSeriesPoint(datetime: "2026-08-03T23:00:00Z", count: 7),
    FirewallEventsSeriesPoint(datetime: "not-a-datetime", count: 999),
    FirewallEventsSeriesPoint(datetime: "2026-08-03T22:00:00Z", count: 0),
  ]
  let points = WAFChartModel.detailPoints(series)

  #expect(points.count == 2)
  #expect(points.map { $0.datum["blocked"] } == [0, 7])
  #expect(points.map(\.id) == WAFChartModel.seriesData(series).map(\.id))
  // The table spells out the day — a 24-hour window crosses midnight, so two
  // rows would otherwise read the same hour.
  #expect(points.allSatisfy { $0.tableLabel.contains("Aug") })
  #expect(points.allSatisfy { !$0.datum.label.contains("Aug") })
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

// MARK: - Legal document Markdown

@Test func legalDocumentParserClassifiesEveryBlockKind() {
  let blocks = LegalBlock.blocks(
    from: """
      # Terms of Use

      Effective July 16, 2026.

      ## 1. What Dash is

      - OAuth tokens stay in the Keychain.
      - Account data travels straight to Cloudflare.
      """)

  #expect(blocks.map(\.kind) == [.title, .paragraph, .section, .bullet, .bullet])
  #expect(String(blocks[0].text.characters) == "Terms of Use")
  // Inline-only parsing, so a numbered heading keeps its literal "1." prefix
  // instead of becoming an ordered list.
  #expect(String(blocks[2].text.characters) == "1. What Dash is")
}

@Test func legalDocumentParserJoinsHardWrappedLines() {
  let blocks = LegalBlock.blocks(
    from: """
      Dash signs in to Cloudflare with OAuth using exactly the permission scopes
      you approve.

      - Operation files are removed when the operation completes, fails, or is
        cancelled.
      """)

  #expect(blocks.count == 2)
  #expect(
    String(blocks[0].text.characters)
      == "Dash signs in to Cloudflare with OAuth using exactly the permission scopes you approve.")
  #expect(
    String(blocks[1].text.characters)
      == "Operation files are removed when the operation completes, fails, or is cancelled.")
}

@Test func legalDocumentParserStylesInlineSyntax() throws {
  let blocks = LegalBlock.blocks(
    from: "Stored at `api.cloudflare.com` under **your** [policy](https://example.com/p).")
  let text = try #require(blocks.first?.text)
  #expect(String(text.characters) == "Stored at api.cloudflare.com under your policy.")

  let code = try #require(
    text.runs.first { $0.inlinePresentationIntent?.contains(.code) == true })
  #expect(String(text[code.range].characters) == "api.cloudflare.com")
  // A run background is the only way to tint inline code inside one `Text`.
  #expect(code.backgroundColor == DashTheme.recessed)

  let strong = try #require(
    text.runs.first { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
  #expect(String(text[strong.range].characters) == "your")
  #expect(strong.foregroundColor == DashTheme.strong)

  let link = try #require(text.runs.first { $0.link != nil })
  #expect(link.link == URL(string: "https://example.com/p"))
  #expect(link.foregroundColor == DashTheme.brand)
}

@Test func legalDocumentParserKeepsUnsupportedSyntaxAsText() {
  // Dash renders six constructs. Anything else must survive as readable text
  // rather than vanish from a document that has legal effect.
  let blocks = LegalBlock.blocks(
    from: """
      > A blockquote these documents never use.

      | a | b |
      """)

  #expect(blocks.map(\.kind) == [.paragraph, .paragraph])
  #expect(String(blocks[0].text.characters) == "> A blockquote these documents never use.")
  #expect(String(blocks[1].text.characters) == "| a | b |")
}

@Test func legalDocumentBlockIDsIndexTheirOwnArray() {
  let blocks = LegalBlock.blocks(
    from: """
      # Title

      One.

      ## Section

      - Item
      - Item

      Two.
      """)

  // `LegalDocumentView` finds a block's predecessor with `blocks[block.id - 1]`,
  // so the id has to stay the array index.
  #expect(blocks.map(\.id) == Array(blocks.indices))
}

@Test func legalDocumentSpacingOpensSectionsAndTightensBullets() {
  #expect(LegalBlockKind.title.spacing(after: nil) == 0)
  #expect(LegalBlockKind.section.spacing(after: .paragraph) == DashTheme.Spacing.section)
  #expect(LegalBlockKind.section.spacing(after: .title) == DashTheme.Spacing.section)
  #expect(LegalBlockKind.paragraph.spacing(after: .title) == DashTheme.Spacing.itemGap)
  #expect(LegalBlockKind.paragraph.spacing(after: .section) == DashTheme.Spacing.compact)
  #expect(LegalBlockKind.bullet.spacing(after: .bullet) == DashTheme.Spacing.rowInset)
  #expect(LegalBlockKind.paragraph.spacing(after: .paragraph) == DashTheme.Spacing.comfortable)
}

@Test func legalDocumentsShippedInTheBundleParseIntoStructuredBlocks() throws {
  for document in [LegalDocument.termsOfUse, .privacyPolicy] {
    let source = LegalDocument.markdown(for: document)
    try #require(source.contains("# Dash for Cloudflare"), "\(document.rawValue) is missing")

    let blocks = LegalBlock.blocks(from: source)
    #expect(blocks.map(\.kind).contains(.title))
    #expect(blocks.filter { $0.kind == .section }.count >= 5)
    #expect(blocks.allSatisfy { !$0.text.characters.isEmpty })
  }
}

@Test func legalDocumentsStayInsideTheSyntaxDashCanRender() {
  // The in-app documents are symlinks into `packages/legal`, and the same files
  // are rendered on the web by react-markdown, which handles far more syntax
  // than this screen. A table added there would still render on the web and
  // degrade to literal text in the app, so the contract is enforced here rather
  // than left to whoever reviews the wording.
  let unsupportedPrefixes = [
    "> ",  // blockquote
    "|",  // table row
    "```",  // fenced code block
    "![",  // image
    "### ",  // heading past h2
    "* ",  // a bullet this parser does not accept — the documents use "- "
    "+ ",
  ]

  for document in [LegalDocument.termsOfUse, .privacyPolicy] {
    let lines = LegalDocument.markdown(for: document).components(separatedBy: .newlines)
    for (offset, rawLine) in lines.enumerated() {
      let position = "\(document.rawValue):\(offset + 1)"
      let line = rawLine.trimmingCharacters(in: .whitespaces)

      for prefix in unsupportedPrefixes {
        #expect(
          !line.hasPrefix(prefix), "\(position) uses \(prefix), which this screen cannot lay out")
      }
      #expect(
        line.range(of: "^[0-9]+\\. ", options: .regularExpression) == nil,
        "\(position) starts an ordered list, which this screen flattens into a paragraph")
      #expect(
        !(rawLine.hasPrefix("  ") && line.hasPrefix("- ")),
        "\(position) nests a list, which this screen flattens into one level")
    }
  }
}
