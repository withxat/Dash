import CloudflareAPI
import CoreText
import SwiftUI
import Testing
import UIKit

@testable import Dash

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
      == [.enableUnderAttackMode, .uploadR2, .addDomain])
  #expect(
    HomeActions.decode("enableUnderAttackMode,uploadR2,enableUnderAttackMode,unknown")
      == [.enableUnderAttackMode, .uploadR2])
  // Retired quick actions drop out of a previously stored selection.
  #expect(HomeActions.decode("purgeCache,uploadR2") == [.uploadR2])

  // Changing the fresh-install default never rewrites a previously stored choice.
  let previousSelection = HomeActions.encode([.addDomain, .uploadR2, .addDNSRecord])
  #expect(
    HomeActions.decode(previousSelection) == [.addDomain, .uploadR2, .addDNSRecord])

  let full = HomeActions.defaultValue
  #expect(HomeActions.toggled(.createKVKey, in: full) == full)

  let removed = HomeActions.toggled(.enableUnderAttackMode, in: full)
  #expect(HomeActions.decode(removed) == [.uploadR2, .addDomain])
  #expect(HomeActions.decode(HomeActions.toggled(.createKVKey, in: removed)).last == .createKVKey)

  let scopedURL = HomeActions.deepLink(action: .uploadR2, accountID: " account one ")
  #expect(scopedURL?.absoluteString == "dash://action/uploadR2?account=account%20one")
  #expect(scopedURL.flatMap(DashRoute.parse) == .action(.uploadR2).scoped(to: "account one"))
  #expect(HomeActions.deepLink(action: .uploadR2, accountID: "  ") == nil)

  let accountA = AccountRequestContext(accountID: "account-a", generation: 1)
  let accountB = AccountRequestContext(accountID: "account-b", generation: 2)
  let pending = PendingHomeAction(action: .uploadR2, context: accountA)
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

@Test func dashRouteParsesEveryGrammarForm() {
  func parse(_ string: String) -> DashRoute? {
    guard let url = URL(string: string) else { return nil }
    return DashRoute.parse(url)
  }

  #expect(parse("dash://settings") == .settings)
  #expect(parse("dash://watchtower?account=account-1") == .watchtower.scoped(to: "account-1"))
  #expect(
    parse("dash://action/uploadR2?account=account-1")
      == .action(.uploadR2).scoped(to: "account-1"))
  #expect(parse("dash://action/purgeCache") == nil)  // retired HomeActionID
  #expect(parse("dash://zone/abc?account=account-1") == .zone("abc").scoped(to: "account-1"))
  #expect(
    parse("dash://zone/abc/dns?account=account-1") == .zoneDNS("abc").scoped(to: "account-1"))
  #expect(
    parse("dash://zone/abc/cache?account=account-1")
      == .zoneCache("abc").scoped(to: "account-1"))
  #expect(
    parse("dash://zone/abc/settings?account=account-1")
      == .zoneSettings("abc").scoped(to: "account-1"))
  #expect(
    parse("dash://zone/abc/analytics?account=account-1")
      == .zoneAnalytics("abc").scoped(to: "account-1"))
  #expect(
    parse("dash://zone/abc/waf?account=account-1")
      == .zoneWAF("abc").scoped(to: "account-1"))
  #expect(
    parse("dash://zone/abc/unknown?account=account-1")
      == .zone("abc").scoped(to: "account-1"))  // unknown subpath falls back
  #expect(
    parse("dash://feature/workers?account=account-1")
      == .feature(.workers).scoped(to: "account-1"))
  #expect(
    parse("dash://worker/my%20worker?account=account-1")
      == .worker("my worker").scoped(to: "account-1"))  // percent-decoded
  #expect(
    parse("dash://pages/docs?account=account-1")
      == .pagesProject("docs").scoped(to: "account-1"))
  #expect(
    parse("dash://pages/docs/deployments/dep-1?account=account-1")
      == .pagesDeployment(project: "docs", deploymentID: "dep-1").scoped(to: "account-1"))
  #expect(
    parse("dash://pages/docs/domains?account=account-1")
      == .pagesDomains("docs").scoped(to: "account-1"))
  #expect(
    parse("dash://r2/my-bucket?account=account-1")
      == .r2("my-bucket").scoped(to: "account-1"))
  #expect(parse("dash://kv/ns1?account=account-1") == .kv("ns1").scoped(to: "account-1"))
  #expect(
    parse("dash://registrar/Example.COM?account=account-1")
      == .registrarDomain("example.com").scoped(to: "account-1"))

  // Required account scope is parsed without changing the destination.
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
  #expect(parse("dash://action/uploadR2/extra") == nil)
  #expect(parse("dash://zone") == nil)  // missing id
  #expect(parse("https://watchtower") == nil)  // wrong scheme
  #expect(parse("dash://unknownhost") == nil)
  #expect(parse("dash://watchtower?account=") == nil)
  #expect(parse("dash://watchtower?account=a&account=b") == nil)
  #expect(parse("dash://settings/extra") == nil)
  #expect(parse("dash://settings?account=account-1") == nil)
  #expect(parse("dash://watchtower") == nil)
  #expect(parse("dash://action/uploadR2") == nil)
  #expect(parse("dash://zone/abc") == nil)
  #expect(parse("dash://feature/workers") == nil)
  #expect(parse("dash://worker/my%20worker") == nil)
  #expect(parse("dash://pages/docs") == nil)
  #expect(parse("dash://r2/my-bucket") == nil)
  #expect(parse("dash://kv/ns1") == nil)
  #expect(parse("dash://registrar/example.com") == nil)

  // destination mapping.
  #expect(DashRoute.settings.destination == .settings)
  #expect(DashRoute.watchtower.destination == nil)
  #expect(DashRoute.action(.uploadR2).destination == nil)
  #expect(DashRoute.zoneCache("z").destination == .cache("z"))
  #expect(DashRoute.zoneDNS("z").destination == .dns("z"))
  #expect(DashRoute.feature(.r2).destination == .feature(.r2))
  #expect(DashRoute.worker("w").destination == .worker("w"))
  #expect(DashRoute.r2("b").destination == .r2Bucket("b", prefix: ""))
  #expect(DashRoute.kv("n").destination == .kvNamespace("n"))
}

@Test func dashRouteRequiresConfirmationBeforeSwitchingAccounts() throws {
  let route = try #require(DashRoute.r2("assets").scoped(to: "account-a"))

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

  #expect(
    DashRoute.r2("assets").accountResolution(
      activeAccountID: "account-b",
      availableAccountIDs: ["account-a", "account-b"])
      == .rejectMissingAccount)
  #expect(
    DashRoute.settings.accountResolution(
      activeAccountID: "account-b",
      availableAccountIDs: ["account-a", "account-b"])
      == .open(.settings))
  #expect(DashRoute.r2("assets").scoped(to: "  ") == nil)
  #expect(DashRoute.settings.scoped(to: "account-a") == nil)
}
