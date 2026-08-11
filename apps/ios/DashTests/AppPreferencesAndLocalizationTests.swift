import CloudflareAPI
import CoreText
import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Dash

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

@Test func cloudflareTimestampParsingAcceptsOnlySupportedShapes() throws {
  let utc = TimeZone(secondsFromGMT: 0)!
  let plain = DashDateFormatting.date(fromISO8601: "2026-06-01T00:00:00Z")
  let fractional = DashDateFormatting.date(fromISO8601: "2026-06-01T00:00:00.000Z")
  let offset = DashDateFormatting.date(fromISO8601: "2026-06-01T14:00:00+14:00")
  let bareDay = DashDateFormatting.date(
    fromISO8601: "2026-06-01",
    bareDayTimeZone: utc)

  #expect(plain != nil)
  #expect(fractional == plain)
  #expect(offset == plain)
  #expect(bareDay == plain)
  let fractionalValue = try #require(
    DashDateFormatting.date(fromISO8601: "2026-06-01T00:00:00.125Z"))
  #expect(fractionalValue.timeIntervalSince(try #require(plain)) == 0.125)

  for malformed in [
    "not a date",
    "2026-06-01trailing",
    "2026-6-1",
    "2026-02-30",
    "2026-06-01T00:00:00Ztrailing",
    "2026-02-30T00:00:00Z",
    "2026-06-01T24:00:00Z",
  ] {
    #expect(DashDateFormatting.date(fromISO8601: malformed) == nil)
  }

  #expect(
    DashDateFormatting.dateOnly(fromISO8601: "abcdefghijklm")
      == "abcdefghij")
}

@Test func bareCalendarDayRoundTripsAcrossExtremeTimeZones() throws {
  let value = "2026-06-01"
  let locale = Locale(identifier: "en_US")
  for secondsFromGMT in [-8 * 60 * 60, 14 * 60 * 60] {
    let timeZone = try #require(TimeZone(secondsFromGMT: secondsFromGMT))
    let date = try #require(
      DashDateFormatting.date(fromCalendarDay: value, timeZone: timeZone))

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    #expect(components.year == 2026)
    #expect(components.month == 6)
    #expect(components.day == 1)
    #expect(
      DashDateFormatting.dateOnly(
        fromISO8601: value,
        locale: locale,
        timeZone: timeZone
      ) == "Jun 1, 2026")
  }
}

@Test func workspaceGlowPresetResolvesStoredPreference() {
  #expect(
    DashWorkspaceGlowPreset.allCases
      == [.none, .orange, .red, .slate, .blue, .green, .pink, .purple, .teal])
  #expect(DashWorkspaceGlowPreset.storageKey == "dash.workspace_glow")
  #expect(DashWorkspaceGlowPreset.defaultPreset == .orange)
  #expect(DashWorkspaceGlowPreset.resolved(stored: "none") == .none)
  #expect(DashWorkspaceGlowPreset.resolved(stored: "orange") == .orange)
  #expect(DashWorkspaceGlowPreset.resolved(stored: "red") == .red)
  #expect(DashWorkspaceGlowPreset.resolved(stored: "slate") == .slate)
  #expect(DashWorkspaceGlowPreset.resolved(stored: "blue") == .blue)
  #expect(DashWorkspaceGlowPreset.resolved(stored: "green") == .green)
  #expect(DashWorkspaceGlowPreset.resolved(stored: "pink") == .pink)
  #expect(DashWorkspaceGlowPreset.resolved(stored: "purple") == .purple)
  #expect(DashWorkspaceGlowPreset.resolved(stored: "teal") == .teal)
  #expect(
    DashWorkspaceGlowPreset.resolved(stored: "unknown")
      == DashWorkspaceGlowPreset.defaultPreset)

  #expect(DashWorkspaceGlowPreset.none.trayTone == nil)
  for preset in DashWorkspaceGlowPreset.allCases where preset != .none {
    #expect(preset.trayTone == .workspaceGlow(preset))
  }

  #expect(DashWorkspaceGlowPreset.orange.displayName != "Cloudflare")
  #expect(DashWorkspaceGlowPreset.none.inspiration == nil)
  #expect(DashWorkspaceGlowPreset.slate.inspiration == nil)
  #expect(DashWorkspaceGlowPreset.blue.inspiration == nil)
  #expect(DashWorkspaceGlowPreset.purple.inspiration == nil)
  #expect(DashWorkspaceGlowPreset.orange.inspiration?.source == "Cloudflare")
  #expect(
    DashWorkspaceGlowPreset.red.inspiration?.source == "NetEase Cloud Music 网易云音乐")
  #expect(DashWorkspaceGlowPreset.green.inspiration?.source == "Coolapk 酷安")
  #expect(DashWorkspaceGlowPreset.pink.inspiration?.source == "bilibili 哔哩哔哩")
  #expect(DashWorkspaceGlowPreset.teal.inspiration?.source == "Netlify")
  #expect(DashTheme.workspaceCloudflareBrandHex == 0xFF5E20)
  #expect(DashTheme.workspaceNetEaseMusicBrandHex == 0xFC3C4F)
  #expect(DashTheme.workspaceNetlifyBrandHex == 0x32E6E2)
  #expect(DashTheme.workspaceCoolapkBrandHex == 0x12BF72)
  #expect(DashTheme.workspaceBilibiliBrandHex == 0xF46F95)
  #expect(
    DashWorkspaceGlowPreset.allCases.compactMap(\.inspiration).allSatisfy {
      !$0.description.isEmpty
    })

  #expect(
    DashWorkspaceGlowPreset.allCases.map(\.rawValue)
      == ["none", "orange", "red", "slate", "blue", "green", "pink", "purple", "teal"])
}

@Test @MainActor func workspaceGlowActionLabelsMeetMinimumContrast() throws {
  let appearances = [
    UITraitCollection(traitsFrom: [
      UITraitCollection(userInterfaceStyle: .light),
      UITraitCollection(accessibilityContrast: .normal),
    ]),
    UITraitCollection(traitsFrom: [
      UITraitCollection(userInterfaceStyle: .dark),
      UITraitCollection(accessibilityContrast: .normal),
    ]),
    UITraitCollection(traitsFrom: [
      UITraitCollection(userInterfaceStyle: .light),
      UITraitCollection(accessibilityContrast: .high),
    ]),
    UITraitCollection(traitsFrom: [
      UITraitCollection(userInterfaceStyle: .dark),
      UITraitCollection(accessibilityContrast: .high),
    ]),
  ]

  for preset in DashWorkspaceGlowPreset.allCases where preset != .none {
    let tone = try #require(preset.trayTone)
    for appearance in appearances {
      let ratio = try #require(
        colorContrastRatio(
          foreground: UIColor(tone.vividLabel),
          background: UIColor(tone.vivid),
          traits: appearance))
      #expect(ratio >= 4.5)
    }
  }
}

private func colorContrastRatio(
  foreground: UIColor,
  background: UIColor,
  traits: UITraitCollection
) -> Double? {
  guard
    let foregroundLuminance = relativeLuminance(foreground, traits: traits),
    let backgroundLuminance = relativeLuminance(background, traits: traits)
  else { return nil }
  let lighter = max(foregroundLuminance, backgroundLuminance)
  let darker = min(foregroundLuminance, backgroundLuminance)
  return (lighter + 0.05) / (darker + 0.05)
}

private func relativeLuminance(_ color: UIColor, traits: UITraitCollection) -> Double? {
  var red: CGFloat = 0
  var green: CGFloat = 0
  var blue: CGFloat = 0
  var alpha: CGFloat = 0
  guard
    color.resolvedColor(with: traits).getRed(
      &red, green: &green, blue: &blue, alpha: &alpha)
  else { return nil }

  func linearized(_ component: CGFloat) -> Double {
    let value = Double(component)
    return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
  }

  return 0.2126 * linearized(red)
    + 0.7152 * linearized(green)
    + 0.0722 * linearized(blue)
}

@Test func workspaceGlowPickerKeepsPortraitCardsCenteredPastItsEdgeFade() {
  #expect(WorkspaceGlowPickerMetrics.cardHeight > WorkspaceGlowPickerMetrics.cardWidth)
  #expect(WorkspaceGlowPickerMetrics.horizontalInset(viewportWidth: 390) == 132)
  #expect(
    WorkspaceGlowPickerMetrics.horizontalInset(viewportWidth: 150)
      == WorkspaceGlowPickerMetrics.edgeFadeWidth)
  // The viewport has to outgrow the card, or a selection ring is clipped by the
  // scroll's own bounds.
  #expect(
    WorkspaceGlowPickerMetrics.viewportHeight > WorkspaceGlowPickerMetrics.cardHeight)
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

  @Test(arguments: ["en", "zh-Hans"])
  func fullRelativeTimeUsesFullUnitsAndExplicitLocale(_ localeIdentifier: String) {
    let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
    let earlier = now.addingTimeInterval(-2 * 60 * 60)
    let locale = Locale(identifier: localeIdentifier)
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = locale
    formatter.unitsStyle = .full

    #expect(
      DashDateFormatting.fullRelativeTime(earlier, relativeTo: now, locale: locale)
        == formatter.localizedString(for: earlier, relativeTo: now))
  }

  @Test func abbreviatedRelativeTimeFollowsInAppLanguageChanges() {
    let previous = DashL10n.localeOverrideForTesting
    defer { DashL10n.localeOverrideForTesting = previous }
    let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
    let earlier = now.addingTimeInterval(-2 * 60 * 60)

    func expected(locale: Locale) -> String {
      let formatter = RelativeDateTimeFormatter()
      formatter.locale = locale
      formatter.unitsStyle = .abbreviated
      return formatter.localizedString(for: earlier, relativeTo: now)
    }

    let englishLocale = Locale(identifier: "en")
    DashL10n.localeOverrideForTesting = englishLocale
    let english = DashDateFormatting.abbreviatedRelativeTime(earlier, relativeTo: now)

    let chineseLocale = Locale(identifier: "zh-Hans")
    DashL10n.localeOverrideForTesting = chineseLocale
    let chinese = DashDateFormatting.abbreviatedRelativeTime(earlier, relativeTo: now)

    DashL10n.localeOverrideForTesting = englishLocale
    let englishAgain = DashDateFormatting.abbreviatedRelativeTime(earlier, relativeTo: now)

    #expect(english == expected(locale: englishLocale))
    #expect(chinese == expected(locale: chineseLocale))
    #expect(chinese != english)
    #expect(englishAgain == english)
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
    #expect(DashTheme.Layout.twoToneListRow == 60)
    #expect(DashTheme.Layout.subtitledListRow == 72)
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
