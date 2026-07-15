import CloudflareAPI
import Testing
import UIKit

@testable import Dash

@Test func configurationRejectsUnexpandedBuildSettings() {
  #expect(
    !AppConfiguration(clientID: "$(DASH_CLIENT_ID)", redirectURI: "$(DASH_REDIRECT_URI)")
      .isConfigured)
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
  #expect(FeatureID.allCases.count == 39)
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

@Test @MainActor func appModelDefaultsToCorePermissions() {
  let defaults = UserDefaults.standard
  let previous = defaults.object(forKey: AppModel.experimentalFeaturesDefaultsKey)
  defaults.set(false, forKey: AppModel.experimentalFeaturesDefaultsKey)
  defer {
    if let previous {
      defaults.set(previous, forKey: AppModel.experimentalFeaturesDefaultsKey)
    } else {
      defaults.removeObject(forKey: AppModel.experimentalFeaturesDefaultsKey)
    }
  }

  let model = AppModel(configuration: AppConfiguration(clientID: "", redirectURI: ""))
  #expect(model.selectedScopes == DashAuthorizationScopes.core)
  #expect(DashAuthorizationScopes.core.count == 66)
  #expect(DashAuthorizationScopes.experimental.count == 8)
  #expect(DashAuthorizationScopes.core.isStrictSubset(of: Set(CloudflareScopes.published)))
  #expect(DashAuthorizationScopes.experimental.isDisjoint(with: DashAuthorizationScopes.core))
  #expect(
    DashAuthorizationScopes.searchResources.isSubset(of: DashAuthorizationScopes.core))
  #expect(DashAuthorizationScopes.watchtower.isSubset(of: DashAuthorizationScopes.core))
  #expect(CloudflareScopes.required.allSatisfy(model.selectedScopes.contains))
  #expect(!model.selectedScopes.contains("ai.read"))
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

@Test func watchtowerSnapshotDerivesIssueCountAndStaleness() {
  let signal = { (status: WatchtowerStatus) in
    WatchtowerSignal(
      id: UUID().uuidString, title: "t", detail: "d", status: status, destination: nil)
  }
  let now = Date(timeIntervalSince1970: 1_000_000)
  let snapshot = WatchtowerSnapshot(
    signals: [signal(.ok), signal(.warning), signal(.critical), signal(.ok)],
    alerts: [],
    alertsStatus: .ok,
    missingScopeChecks: [],
    failedChecks: [],
    fetchedAt: now)
  #expect(snapshot.issueCount == 2)
  #expect(!snapshot.isStale(now: now.addingTimeInterval(299), ttl: 300))
  #expect(!snapshot.isStale(now: now.addingTimeInterval(300), ttl: 300))
  #expect(snapshot.isStale(now: now.addingTimeInterval(301), ttl: 300))
}

/// The Features tab opens on `.available`, which is only safe because unknown
/// scopes resolve to `.full`. If that ever flips, a cold launch shows an empty
/// catalog before the token store answers.
@MainActor
@Test func featureCatalogDefaultFilterListsEverythingBeforeScopesLoad() {
  #expect(FeatureCatalogView.defaultFilter == .available)
  let coldLaunch = FeatureCatalogFiltering.features(
    filter: FeatureCatalogView.defaultFilter,
    grantedScopes: nil,
    experimentalEnabled: false)
  #expect(coldLaunch.count == FeatureCatalog.all.count - 4)
}

@Test func featureCatalogFilteringRespectsAccess() {
  let scopes: Set<String> = ["zone.read"]
  let locked = FeatureCatalogFiltering.features(
    filter: .locked, grantedScopes: scopes, experimentalEnabled: false)
  #expect(locked.contains(.workers))
  #expect(!locked.contains(.zones))

  let readOnly = FeatureCatalogFiltering.features(
    filter: .readOnly, grantedScopes: scopes, experimentalEnabled: false)
  #expect(readOnly.contains(.zones))
  #expect(!readOnly.contains(.workers))

  let fullScopes = Set(FeatureID.zones.capability.all)
  let available = FeatureCatalogFiltering.features(
    filter: .available, grantedScopes: fullScopes, experimentalEnabled: false)
  #expect(available.contains(.zones))
}

@Test func experimentalFeatureVisibilityRequiresOptIn() {
  let hidden = FeatureCatalogFiltering.features(
    filter: .all, grantedScopes: nil, experimentalEnabled: false)
  let shown = FeatureCatalogFiltering.features(
    filter: .all, grantedScopes: nil, experimentalEnabled: true)
  #expect(
    DashAuthorizationScopes.experimentalFeatures.allSatisfy {
      !hidden.contains($0) && shown.contains($0)
    })
}

/// Text search lives behind the tab-bar Search role; the catalog itself does not take a query.
@Test func featureSearchMatchesTitleSubtitleAndID() {
  #expect(FeatureCatalog.matchesSearch(.zones, query: "ZoNe"))
  #expect(FeatureCatalog.matchesSearch(.r2, query: "bucket"))
  #expect(FeatureCatalog.matchesSearch(.kv, query: "namespace"))
  #expect(!FeatureCatalog.matchesSearch(.zones, query: "queue"))
}

@Test func destinationFeatureMappingCoversDirectRoutes() {
  #expect(featureID(for: .zone("z1")) == .zones)
  #expect(featureID(for: .dns("z1")) == .zones)
  #expect(featureID(for: .worker("api")) == .workers)
  #expect(featureID(for: .r2Bucket("media")) == .r2)
  #expect(featureID(for: .kvNamespace("ns")) == .kv)
  #expect(featureID(for: .d1Database("db", "main")) == .d1)
  #expect(featureID(for: .rulesetList(basePath: "/x", title: "Rules")) == .rulesets)
  #expect(featureID(for: .accessAppPolicies(appID: "a", appName: "App")) == .accessPolicies)
  #expect(featureID(for: .profile) == nil)
}

// `View` is a @MainActor protocol, so StatusBadge/DashNotice statics are
// isolated too — the test has to hop on as well.
@MainActor
@Test func statusBadgeAndNoticeExposeAccessibleCopy() {
  #expect(StatusBadge.accessibilityText(for: "Read-only") == "Status, Read-only")
  #expect(StatusBadge.presentation(for: "OK") == .quiet)
  #expect(StatusBadge.presentation(for: "Critical") == .capsule)
  #expect(StatusBadge.presentation(for: "Locked") == .capsule)
  #expect(
    DashNotice.accessibilityText(kind: .warning, message: "Coverage limited")
      == "Warning: Coverage limited")
  #expect(DashTheme.Spacing.scrollBottomInset == 72)
  #expect(DashTheme.Layout.minimumHitTarget == 44)
}

@Test func widgetSeverityHeadlineNamesCriticalAndWarning() {
  #expect(
    WatchtowerWidgetSnapshot.severityHeadline(criticalCount: 0, warningCount: 0) == "All clear")
  #expect(
    WatchtowerWidgetSnapshot.severityHeadline(criticalCount: 2, warningCount: 0) == "2 critical")
  #expect(
    WatchtowerWidgetSnapshot.severityHeadline(criticalCount: 0, warningCount: 1) == "1 warning")
  #expect(
    WatchtowerWidgetSnapshot.severityHeadline(criticalCount: 2, warningCount: 1)
      == "2 critical, 1 warning")
}

@Test func analyticsChartAccessibilitySummaryIncludesTotals() {
  let summary = ZoneAnalyticsChartModel.chartAccessibilitySummary(
    rangeLabel: "Last 24 hours", requests: 1200, threats: 3)
  #expect(summary.contains("Last 24 hours"))
  #expect(summary.contains("1,200") || summary.contains("1200"))
  #expect(summary.contains("3"))
  #expect(summary.contains("threats"))
}

@Test func searchCancellationIsRecognized() {
  #expect(CancellationError().dashIsCancellation)
  #expect(URLError(.cancelled).dashIsCancellation)
  #expect(!URLError(.timedOut).dashIsCancellation)
}

@Test func legalDocumentsExposeStableTitles() {
  #expect(LegalDocument.termsOfUse.title == "Terms of Use")
  #expect(LegalDocument.privacyPolicy.title == "Privacy Policy")
  #expect(LegalDocument.termsOfUse.resourceName == "TermsOfUse")
  #expect(LegalDocument.privacyPolicy.resourceName == "PrivacyPolicy")
}

@Test func featureVisualIdentityMapsStableTonesByCategory() {
  #expect(FeatureVisualIdentity.tone(for: .zones) == .success)
  #expect(FeatureVisualIdentity.tone(for: .dnsFirewall) == .success)
  #expect(FeatureVisualIdentity.tone(for: .workers) == .brand)
  #expect(FeatureVisualIdentity.tone(for: .r2) == .accent)
  #expect(FeatureVisualIdentity.tone(for: .analytics) == .accent)
  #expect(FeatureVisualIdentity.tone(for: .workersAI) == .warning)
  #expect(FeatureVisualIdentity.tone(for: .turnstile) == .danger)
  #expect(FeatureVisualIdentity.tone(for: .accessApps) == .info)
  #expect(FeatureVisualIdentity.tone(for: .tunnels) == .brand)
  #expect(FeatureVisualIdentity.tone(for: .account) == .soft)

  for (_, features) in FeatureCatalog.grouped {
    let tones = Set(features.map { FeatureVisualIdentity.tone(for: $0) })
    #expect(tones.count == 1)
  }
}

@Test func featureCatalogIconsAreUnique() {
  let duotone = FeatureCatalog.descriptors.map(\.solarAssetName)
  let outline = FeatureCatalog.descriptors.map(\.solarOutlineAssetName)
  #expect(Set(duotone).count == duotone.count)
  #expect(Set(outline).count == outline.count)
}

@Test func trayDragDecisionUsesProjectionAndVelocity() {
  #expect(
    TrayDragDecision.content(translation: 40, predictedEndTranslation: 40) == .settle)
  #expect(
    TrayDragDecision.content(translation: 130, predictedEndTranslation: 130) == .dismiss)
  #expect(
    TrayDragDecision.content(translation: 40, predictedEndTranslation: 200) == .dismiss)
  #expect(
    TrayDragDecision.content(translation: 40, predictedEndTranslation: 1000) == .dismiss)

  #expect(
    TrayDragDecision.expandable(
      baseTop: 100, predictedEndTranslation: 20, expandedTop: 80, floatingTop: 400
    ) == .settleExpanded(true))
  #expect(
    TrayDragDecision.expandable(
      baseTop: 400, predictedEndTranslation: 300, expandedTop: 80, floatingTop: 400
    ) == .dismiss)
  #expect(TrayDragDecision.rubberBand(cardTop: 50, expandedTop: 80) == 75.5)
}

@Test func profileTrayPhaseTitlesFollowFocus() {
  #expect(ProfileTrayPhase.menu.title == "Profile")
  #expect(ProfileTrayPhase.accounts.title == "Switch account")
  #expect(ProfileTrayPhase.signOut.title == "Sign out")
}

@Test func recentResourcesRoundTripAndFilterByAccount() {
  let worker = RecentResource.worker(accountID: "acc1", name: "api")
  let zone = RecentResource.zone(accountID: "acc2", id: "z1", title: "example.com")
  let encoded = RecentResources.updated(
    existing: RecentResources.updated(existing: "", adding: zone), adding: worker)
  let decoded = RecentResources.decode(encoded)
  #expect(decoded.map(\.title) == ["api", "example.com"])
  #expect(
    RecentResources.continueItems(recent: decoded, accountID: "acc1").map(\.title) == ["api"])
  #expect(worker.destination == .worker("api"))
  #expect(zone.destination == .zone("z1"))
}

@Test func oldAndExperimentalShortcutsDecodeSafely() {
  let decoded = "zones,apiExplorer,workersAI,magicNetworking"
    .split(separator: ",")
    .compactMap { FeatureID(rawValue: String($0)) }
  #expect(decoded == [.zones, .workersAI])
  #expect(
    decoded.filter { !DashAuthorizationScopes.experimentalFeatures.contains($0) } == [.zones])
}

@Test func searchResourceFilteringMatchesNames() {
  #expect(SearchResourceFiltering.matches("my-worker", query: "work"))
  #expect(!SearchResourceFiltering.matches("kv-prod", query: "d1"))
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
  let removed = PinnedZones.toggled(encoded, pin: a)
  #expect(!PinnedZones.isPinned(removed, zoneID: "z1"))
  #expect(PinnedZones.decode(removed) == [b])

  // Malformed entries are dropped, not crashed on.
  #expect(PinnedZones.decode("garbage,acc|only-two") == [])

  // Account filtering keeps other accounts' pins invisible.
  let mine = PinnedZones.decode(encoded).filter { $0.accountID == "acc1" }
  #expect(mine == [a])
}

@MainActor
@Test func tailBufferTrimsOldestBeyondLimit() {
  let event = { (summary: String) in
    WorkerTailEvent(timestamp: nil, outcome: "ok", summary: summary, lines: [])
  }
  var buffer: [WorkerTailEvent] = []
  for index in 0..<5 {
    buffer = WorkerTailView.appending(event("e\(index)"), to: buffer, limit: 3)
  }
  #expect(buffer.map(\.summary) == ["e2", "e3", "e4"])

  var small: [WorkerTailEvent] = []
  small = WorkerTailView.appending(event("only"), to: small, limit: 3)
  #expect(small.map(\.summary) == ["only"])
}

@Test func analyticsChartPointsParseAndSortAscending() {
  let daily = [
    ZoneAnalyticsDay(date: "2026-07-14", requests: 3, pageViews: 1, threats: 0, bytes: 30),
    ZoneAnalyticsDay(date: "2026-07-12", requests: 1, pageViews: 0, threats: 0, bytes: 10),
    ZoneAnalyticsDay(date: "not-a-date", requests: 9, pageViews: 9, threats: 9, bytes: 9),
    ZoneAnalyticsDay(date: "2026-07-13", requests: 2, pageViews: 0, threats: 1, bytes: 20),
  ]
  let dayPoints = ZoneAnalyticsChartModel.points(fromDaily: daily)
  #expect(dayPoints.map(\.requests) == [1, 2, 3])  // bad date dropped, sorted ascending

  let hourly = [
    ZoneAnalyticsPoint(
      datetime: "2026-07-14T09:00:00Z", requests: 20, pageViews: 8, threats: 0, bytes: 40),
    ZoneAnalyticsPoint(
      datetime: "2026-07-14T08:00:00.000Z", requests: 10, pageViews: 4, threats: 1, bytes: 20),
    ZoneAnalyticsPoint(datetime: "garbage", requests: 99, pageViews: 0, threats: 0, bytes: 0),
  ]
  let hourPoints = ZoneAnalyticsChartModel.points(fromHourly: hourly)
  #expect(hourPoints.map(\.requests) == [10, 20])  // fractional seconds parsed, garbage dropped
}

@Test func dashRouteParsesEveryGrammarForm() {
  func parse(_ string: String) -> DashRoute? {
    guard let url = URL(string: string) else { return nil }
    return DashRoute.parse(url)
  }

  #expect(parse("dash://watchtower") == .watchtower)
  #expect(parse("dash://zone/abc") == .zone("abc"))
  #expect(parse("dash://zone/abc/dns") == .zoneDNS("abc"))
  #expect(parse("dash://zone/abc/cache") == .zoneCache("abc"))
  #expect(parse("dash://zone/abc/settings") == .zoneSettings("abc"))
  #expect(parse("dash://zone/abc/analytics") == .zoneAnalytics("abc"))
  #expect(parse("dash://zone/abc/unknown") == .zone("abc"))  // unknown subpath falls back
  #expect(parse("dash://feature/workers") == .feature(.workers))
  #expect(parse("dash://worker/my%20worker") == .worker("my worker"))  // percent-decoded
  #expect(parse("dash://r2/my-bucket") == .r2("my-bucket"))
  #expect(parse("dash://kv/ns1") == .kv("ns1"))
  #expect(parse("dash://d1/db-uuid/analytics") == .d1(id: "db-uuid", name: "analytics"))
  #expect(parse("dash://d1/db-uuid") == .d1(id: "db-uuid", name: "db-uuid"))

  // Rejections.
  #expect(parse("dash://oauth/callback?code=x") == nil)  // owned by the auth session
  #expect(parse("dash://feature/bogus") == nil)  // unknown FeatureID
  #expect(parse("dash://zone") == nil)  // missing id
  #expect(parse("https://watchtower") == nil)  // wrong scheme
  #expect(parse("dash://unknownhost") == nil)

  // destination mapping.
  #expect(DashRoute.watchtower.destination == nil)
  #expect(DashRoute.zoneDNS("z").destination == .dns("z"))
  #expect(DashRoute.feature(.r2).destination == .feature(.r2))
  #expect(DashRoute.worker("w").destination == .worker("w"))
  #expect(DashRoute.r2("b").destination == .r2Bucket("b"))
  #expect(DashRoute.kv("n").destination == .kvNamespace("n"))
  #expect(DashRoute.d1(id: "i", name: "n").destination == .d1Database("i", "n"))
}

@Test func underAttackRestoreLevelFallsBackToMedium() {
  #expect(SetUnderAttackIntent.restoreLevel(stashed: "high") == "high")
  #expect(SetUnderAttackIntent.restoreLevel(stashed: "essentially_off") == "essentially_off")
  #expect(SetUnderAttackIntent.restoreLevel(stashed: nil) == "medium")
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
  let signal = { (status: WatchtowerStatus, title: String) in
    WatchtowerSignal(
      id: UUID().uuidString, title: title, detail: "d", status: status, destination: nil)
  }
  let snapshot = WatchtowerSnapshot(
    signals: [
      signal(.ok, "healthy"), signal(.warning, "cert soon"), signal(.critical, "tunnel down"),
    ],
    alerts: [], alertsStatus: .ok, missingScopeChecks: [], failedChecks: [],
    fetchedAt: Date(timeIntervalSince1970: 1_000_000))
  let widget = snapshot.widgetSnapshot(accountName: "Acme")

  #expect(widget.issueCount == 2)
  #expect(widget.criticalCount == 1)
  #expect(widget.warningCount == 1)
  #expect(widget.accountName == "Acme")
  // Non-ok only, critical first.
  #expect(widget.signals.map(\.status) == ["critical", "warning"])
  #expect(widget.signals.first?.title == "tunnel down")

  // Codable round-trips through the App Group file format.
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("watchtower-\(UUID().uuidString).json")
  try widget.write(to: url)
  let loaded = try WatchtowerWidgetSnapshot.load(from: url)
  #expect(loaded == widget)
  WatchtowerWidgetSnapshot.clear(at: url)
}

@Test func watchtowerWidgetStalenessTiers() {
  let base = WatchtowerWidgetSnapshot(
    issueCount: 0, criticalCount: 0, warningCount: 0, signals: [], accountName: nil,
    fetchedAt: Date(timeIntervalSince1970: 0))
  #expect(base.staleness(now: Date(timeIntervalSince1970: 3600)) == .fresh)
  #expect(base.staleness(now: Date(timeIntervalSince1970: 3 * 3600)) == .aging)
  #expect(base.staleness(now: Date(timeIntervalSince1970: 25 * 3600)) == .stale)
}

@Test func watchtowerCoverageSignalWarnsWhenZonesExceedFanout() {
  #expect(WatchtowerEngine.coverageSignal(totalZones: 10) == nil)
  #expect(WatchtowerEngine.coverageSignal(totalZones: 9) == nil)

  let signal = WatchtowerEngine.coverageSignal(totalZones: 15)
  #expect(signal?.id == WatchtowerEngine.coverageSignalID)
  #expect(signal?.title == WatchtowerEngine.coverageSignalTitle)
  #expect(signal?.status == .warning)
  #expect(signal?.destination == .feature(.zones))
  #expect(signal?.detail.contains("5 of 15") == true)

  let snapshot = WatchtowerSnapshot(
    signals: [signal!],
    alerts: [],
    alertsStatus: .ok,
    missingScopeChecks: [],
    failedChecks: [],
    fetchedAt: Date(timeIntervalSince1970: 0))
  #expect(snapshot.issueCount == 1)
}

@Test func watchtowerNotificationPlannerIgnoresCoverageSignal() {
  func snapshot(issues: Int, signals: [WatchtowerWidgetSnapshot.Signal])
    -> WatchtowerWidgetSnapshot
  {
    WatchtowerWidgetSnapshot(
      issueCount: issues,
      criticalCount: signals.filter { $0.status == "critical" }.count,
      warningCount: signals.filter { $0.status == "warning" }.count,
      signals: signals,
      accountName: nil,
      fetchedAt: Date(timeIntervalSince1970: 0))
  }
  let coverage = WatchtowerWidgetSnapshot.Signal(
    title: WatchtowerEngine.coverageSignalTitle,
    detail: "5 of 15 zones not checked",
    status: "warning")
  typealias Planner = WatchtowerNotificationPlanner

  // Coverage appearing alone must not fire a local notification.
  #expect(
    Planner.plans(
      previous: snapshot(issues: 0, signals: []),
      current: snapshot(issues: 1, signals: [coverage])
    ).isEmpty)

  // A real warning rise still notifies, counting only notifiable issues.
  let plans = Planner.plans(
    previous: snapshot(issues: 1, signals: [coverage]),
    current: snapshot(
      issues: 2,
      signals: [
        coverage,
        WatchtowerWidgetSnapshot.Signal(title: "tunnel", detail: "down", status: "warning"),
      ]))
  #expect(plans.map(\.identifier) == ["watchtower.issues"])
  #expect(plans.first?.body.contains("1 issue needs") == true)
}

@Test func highImpactGenericTogglesRequireConfirmation() {
  let pools = GenericResourceCapabilities.forPath("/accounts/abc/load_balancers/pools")
  #expect(pools.updates.first?.confirmMessage != nil)

  let balancers = GenericResourceCapabilities.forPath("/zones/xyz/load_balancers")
  #expect(balancers.updates.first?.confirmMessage != nil)

  let pageRules = GenericResourceCapabilities.forPath("/zones/xyz/pagerules")
  #expect(pageRules.updates.first?.confirmMessage != nil)

  let waitingRooms = GenericResourceCapabilities.forPath("/zones/xyz/waiting_rooms")
  #expect(waitingRooms.updates.first?.confirmMessage != nil)

  let healthchecks = GenericResourceCapabilities.forPath("/zones/xyz/healthchecks")
  #expect(healthchecks.updates.first?.confirmMessage != nil)

  let logpush = GenericResourceCapabilities.forPath("/accounts/abc/logpush/jobs")
  #expect(logpush.updates.first?.confirmMessage != nil)

  let registrar = GenericResourceCapabilities.forPath("/accounts/abc/registrar/domains")
  #expect(registrar.updates.allSatisfy { $0.confirmMessage == nil })
}

@Test func genericDetailPhaseAllowsOnlyOneDecision() {
  #expect(GenericDetailPhase.details.title(for: "pool-1") == "pool-1")
  #expect(GenericDetailPhase.delete.title(for: "pool-1") == "Delete")
  #expect(GenericDetailPhase.update(id: "enable").title(for: "pool-1") == "Confirm")
  #expect(GenericDetailPhase.details != .delete)
  #expect(GenericDetailPhase.update(id: "a") != .update(id: "b"))
}

@Test func workerDeployAndD1RiskClassification() {
  #expect(workerSourceIsEditable(moduleCount: 1, hasWriteScope: true))
  #expect(D1SQL.destructiveKeyword(in: "DROP TABLE t;") == "DROP")
  #expect(D1SQL.destructiveKeyword(in: "SELECT 1;") == nil)
}

@MainActor
@Test func workerTailEventRowAccessibilityIncludesSummary() {
  let event = WorkerTailEvent(
    timestamp: nil, outcome: "ok", summary: "GET /", lines: ["hello"])
  #expect(WorkerTailEventRow.accessibilityLabel(for: event).contains("GET /"))
  #expect(WorkerTailEventRow.outcomeColor("exception") == DashTheme.danger)
}

@Test func genericDetailFieldMapSeparatesPrimaryAndAdvanced() {
  let json = """
    {"name":"example.com","status":"active","id":"abc","custom_meta":"x"}
    """
  let resource = try! JSONDecoder().decode(GenericResource.self, from: Data(json.utf8))
  let primary = GenericDetailFieldMap.primaryFields(from: resource)
  let advanced = GenericDetailFieldMap.advancedFields(from: resource)
  #expect(primary.contains { $0.label == "Name" })
  #expect(primary.contains { $0.label == "Status" })
  #expect(advanced.contains { $0.value == "abc" || $0.value == "x" })
  #expect(GenericDetailFieldMap.humanCategoryTitle("Workers & Pages") == "Workers")
  #expect(GenericDetailFieldMap.humanCategoryTitle("Domains & DNS") == "DNS")
}

@Test func watchtowerNotificationPlannerDiffsSnapshots() {
  func snapshot(issues: Int, critical: [String], warning: [String] = [])
    -> WatchtowerWidgetSnapshot
  {
    let signals =
      critical.map { WatchtowerWidgetSnapshot.Signal(title: $0, detail: "d", status: "critical") }
      + warning.map { WatchtowerWidgetSnapshot.Signal(title: $0, detail: "d", status: "warning") }
    return WatchtowerWidgetSnapshot(
      issueCount: issues, criticalCount: critical.count, warningCount: warning.count,
      signals: signals, accountName: nil, fetchedAt: Date(timeIntervalSince1970: 0))
  }
  typealias Planner = WatchtowerNotificationPlanner

  // First run: nothing to diff against.
  #expect(Planner.plans(previous: nil, current: snapshot(issues: 2, critical: ["a"])).isEmpty)

  // A newly-critical signal fires with a stable identifier.
  let newCritical = Planner.plans(
    previous: snapshot(issues: 1, critical: [], warning: ["w"]),
    current: snapshot(issues: 2, critical: ["tunnel"], warning: ["w"]))
  #expect(newCritical.map(\.identifier) == ["watchtower.critical.tunnel"])

  // Still-critical does not re-notify.
  #expect(
    Planner.plans(
      previous: snapshot(issues: 1, critical: ["tunnel"]),
      current: snapshot(issues: 1, critical: ["tunnel"])
    ).isEmpty)

  // Count rise without a new critical → one summary.
  let summary = Planner.plans(
    previous: snapshot(issues: 1, critical: [], warning: ["w1"]),
    current: snapshot(issues: 2, critical: [], warning: ["w1", "w2"]))
  #expect(summary.map(\.identifier) == ["watchtower.issues"])

  // Recovery → nothing.
  #expect(
    Planner.plans(
      previous: snapshot(issues: 2, critical: ["a"]),
      current: snapshot(issues: 0, critical: [])
    ).isEmpty)
}

@Test @MainActor func incrementalAuthorizationKeepsExistingAndRequiredScopes() {
  let scopes = AppModel.incrementalScopes(
    granted: ["zone.read"],
    requested: ["workers-scripts.read"]
  )
  #expect(scopes.contains("zone.read"))
  #expect(scopes.contains("workers-scripts.read"))
  #expect(Set(CloudflareScopes.required).isSubset(of: scopes))
}

@Test func remainingRegistryPathsCarryTheirWrites() {
  let containers = GenericResourceCapabilities.forPath("/accounts/abc/containers/applications")
  #expect(containers.deleteMessage != nil)
  #expect(containers.create == nil)
}

@Test func hubRegistryPathsCarryTheirWrites() {
  let warp = GenericResourceCapabilities.forPath("/accounts/abc/warp_connector")
  #expect(warp.deleteMessage != nil)

  let virtualNetworks = GenericResourceCapabilities.forPath(
    "/accounts/abc/teamnet/virtual_networks")
  #expect(virtualNetworks.create != nil)
  #expect(virtualNetworks.deleteMessage != nil)

  let queries = GenericResourceCapabilities.forPath(
    "/accounts/abc/workers/observability/queries")
  #expect(queries.deleteMessage != nil)

  let destinations = GenericResourceCapabilities.forPath(
    "/accounts/abc/workers/observability/destinations")
  #expect(destinations.deleteMessage != nil)
  #expect(destinations.deletePath != nil)
}

@Test func teamnetRoutesStayDistinctFromWorkerRoutes() {
  // Both end in "/routes"; each must resolve to its own capabilities.
  let teamnet = GenericResourceCapabilities.forPath("/accounts/abc/teamnet/routes")
  #expect(teamnet.create == nil)
  #expect(teamnet.deleteMessage != nil)

  let workerRoutes = GenericResourceCapabilities.forPath("/zones/xyz/workers/routes")
  #expect(workerRoutes.create != nil)
  #expect(workerRoutes.deleteMessage != nil)
}

@Test func zonePickerRoutesEachFeatureToItsSurface() {
  #expect(
    zoneDestination(for: .sslCertificates, zoneID: "z1", zoneName: "example.com")
      == .zoneFeatureHub(feature: .sslCertificates, zoneID: "z1", zoneName: "example.com"))
  #expect(
    zoneDestination(for: .apiSecurity, zoneID: "z1", zoneName: "example.com")
      == .zoneFeatureHub(feature: .apiSecurity, zoneID: "z1", zoneName: "example.com"))
  #expect(
    zoneDestination(for: .botManagement, zoneID: "z1", zoneName: "example.com")
      == .botManagement(zoneID: "z1", zoneName: "example.com"))
  #expect(
    zoneDestination(for: .cacheSettings, zoneID: "z1", zoneName: "example.com")
      == .cachePerformance(zoneID: "z1", zoneName: "example.com"))
}

@Test func zoneHubRegistryPathsCarryTheirWrites() {
  let views = GenericResourceCapabilities.forPath("/accounts/abc/dns_settings/views")
  #expect(views.create != nil)
  #expect(views.deleteMessage != nil)

  let hostnames = GenericResourceCapabilities.forPath("/zones/xyz/custom_hostnames")
  #expect(hostnames.create != nil)
  #expect(hostnames.deleteMessage != nil)

  let certificates = GenericResourceCapabilities.forPath("/zones/xyz/custom_certificates")
  #expect(certificates.create == nil)
  #expect(certificates.deleteMessage != nil)

  // The query suffix must not defeat path matching.
  let packs = GenericResourceCapabilities.forPath(
    "/zones/xyz/ssl/certificate_packs?status=all")
  #expect(packs.deleteMessage != nil)
}

@Test func onlyUnmanagedRulesetsAreEditable() {
  #expect(rulesetKindIsEditable("custom"))
  #expect(rulesetKindIsEditable("root"))
  #expect(rulesetKindIsEditable("zone"))
  #expect(!rulesetKindIsEditable("managed"))
  #expect(!rulesetKindIsEditable(nil))
}

@Test func accessIncludeRulesBuildDocumentedShapes() {
  let rules = accessIncludeRules([
    (kind: "Everyone", value: ""),
    (kind: "Email", value: "i@xat.sh"),
    (kind: "Email domain", value: "xat.sh"),
  ])
  #expect(
    rules == [
      .object(["everyone": .object([:])]),
      .object(["email": .object(["email": .string("i@xat.sh")])]),
      .object(["email_domain": .object(["domain": .string("xat.sh")])]),
    ])
  // Empty values drop the row instead of sending an invalid rule.
  #expect(accessIncludeRules([(kind: "Email", value: "")]).isEmpty)
}

@Test func accessAppsRegistryOffersCreateAndDelete() {
  let apps = GenericResourceCapabilities.forPath("/accounts/abc/access/apps")
  #expect(apps.create != nil)
  #expect(apps.deleteMessage != nil)
}

@Test func workerEditingRequiresScopeAndSingleModule() {
  #expect(workerSourceIsEditable(moduleCount: 0, hasWriteScope: true))
  #expect(workerSourceIsEditable(moduleCount: 1, hasWriteScope: true))
  #expect(!workerSourceIsEditable(moduleCount: 2, hasWriteScope: true))
  #expect(!workerSourceIsEditable(moduleCount: 1, hasWriteScope: false))
}

@Test func certificatePackOrderAndServiceTokenRegistryEntries() {
  let packs = GenericResourceCapabilities.forPath("/zones/xyz/ssl/certificate_packs?status=all")
  #expect(packs.create != nil)
  #expect(
    packs.createPath?("/zones/xyz/ssl/certificate_packs")
      == "/zones/xyz/ssl/certificate_packs/order")
  #expect(packs.create?.revealResult != nil)
  let orderBody = packs.create?.body([
    "hosts": "example.com, www.example.com",
    "certificate_authority": "lets_encrypt",
    "validation_method": "txt",
    "validity_days": "90",
  ])
  #expect(orderBody?["type"] == .string("advanced"))
  #expect(orderBody?["hosts"] == .array([.string("example.com"), .string("www.example.com")]))
  #expect(orderBody?["validity_days"] == .number(90))

  let tokens = GenericResourceCapabilities.forPath("/accounts/abc/access/service_tokens")
  #expect(tokens.create != nil)
  #expect(tokens.deleteMessage != nil)
  let revealed = tokens.create?.revealResult?(
    .object([
      "id": .string("t1"),
      "client_id": .string("cid.access"),
      "client_secret": .string("shh"),
    ]))
  #expect(revealed == "CF-Access-Client-Id: cid.access\nCF-Access-Client-Secret: shh")
}

@Test func featureAccessDistinguishesLockedReadOnlyAndFull() {
  let capability = FeatureCapability(read: ["product.read"], write: ["product.write"])
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

@Test func watchtowerMuteStoreSnoozesAndExpires() {
  let suite = "dash.tests.mute.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }

  WatchtowerMuteStore.mute("sig-1", title: "Tunnel down", for: 60, defaults: defaults)
  #expect(WatchtowerMuteStore.isMuted("sig-1", defaults: defaults))
  #expect(WatchtowerMuteStore.mutedTitles(defaults: defaults).contains("Tunnel down"))

  WatchtowerMuteStore.unmute("sig-1", defaults: defaults)
  #expect(!WatchtowerMuteStore.isMuted("sig-1", defaults: defaults))

  // Already-expired entries are filtered out on read.
  WatchtowerMuteStore.mute("sig-2", title: "Cert", for: -1, defaults: defaults)
  #expect(!WatchtowerMuteStore.isMuted("sig-2", defaults: defaults))
}

@Test func dashCapabilityStatusMapsAPIErrors() {
  #expect(DashCapabilityStatus.from(apiError: nil) == .unknown)
  let forbidden = CloudflareAPIError.request(status: 403, errors: [])
  #expect(DashCapabilityStatus.from(apiError: forbidden) == .needsPermission)
  let plan = CloudflareAPIError.transport("Account not entitled")
  #expect(DashCapabilityStatus.from(apiError: plan) == .needsPlan)
}

@Test func tabBarNavigationVisibilityChangesAnimateAndIgnoreDuplicates() {
  let hide = tabBarVisibilityChange(
    currentlyHidden: false,
    targetHidden: true,
    transition: .navigation
  )
  let duplicate = tabBarVisibilityChange(
    currentlyHidden: true,
    targetHidden: true,
    transition: .navigation
  )
  let initial = tabBarVisibilityChange(
    currentlyHidden: true,
    targetHidden: false,
    transition: .initial
  )

  #expect(hide == TabBarVisibilityChange(hidden: true, animated: true))
  #expect(duplicate == nil)
  #expect(initial == TabBarVisibilityChange(hidden: false, animated: false))
}

@Test func tabBarHideRulesRespectSizeClassAndOverlays() {
  #expect(
    shouldHideTabBar(overlaysPresented: true, usesSplitDetail: true, navigationDepth: 0))
  #expect(
    shouldHideTabBar(overlaysPresented: false, usesSplitDetail: false, navigationDepth: 1))
  #expect(
    !shouldHideTabBar(overlaysPresented: false, usesSplitDetail: true, navigationDepth: 2))
  #expect(
    !shouldHideTabBar(overlaysPresented: false, usesSplitDetail: false, navigationDepth: 0))
}

@Test func d1DestructiveDetectorFlagsWritesNotReads() {
  // Read-safe statements run without a confirm.
  #expect(D1SQL.destructiveKeyword(in: "SELECT * FROM users;") == nil)
  #expect(D1SQL.destructiveKeyword(in: "PRAGMA table_info(users);") == nil)
  #expect(D1SQL.destructiveKeyword(in: "CREATE TABLE t (id INTEGER);") == nil)
  #expect(D1SQL.destructiveKeyword(in: "EXPLAIN QUERY PLAN SELECT 1;") == nil)
  #expect(D1SQL.destructiveKeyword(in: "INSERT INTO t VALUES (1);") == nil)
  #expect(D1SQL.destructiveKeyword(in: "") == nil)

  // Destructive statements are flagged with their keyword.
  #expect(D1SQL.destructiveKeyword(in: "DROP TABLE users;") == "DROP")
  #expect(D1SQL.destructiveKeyword(in: "delete from users where id = 1") == "DELETE")
  #expect(D1SQL.destructiveKeyword(in: "Update users SET name = 'x';") == "UPDATE")
  #expect(D1SQL.destructiveKeyword(in: "ALTER TABLE t ADD COLUMN c;") == "ALTER")
  #expect(D1SQL.destructiveKeyword(in: "REPLACE INTO t VALUES (1);") == "REPLACE")

  // Multi-statement input: any destructive statement flags the batch.
  #expect(D1SQL.destructiveKeyword(in: "SELECT 1; DROP TABLE x;") == "DROP")

  // Comments and whitespace do not hide the verb.
  #expect(D1SQL.destructiveKeyword(in: "-- cleanup\ndrop table x") == "DROP")
  #expect(D1SQL.destructiveKeyword(in: "/* audit */ DELETE FROM t;") == "DELETE")
  // A commented-out write stays read-safe.
  #expect(D1SQL.destructiveKeyword(in: "-- DROP TABLE x\nSELECT 1;") == nil)

  // CTEs and upserts get the word-boundary scan.
  #expect(
    D1SQL.destructiveKeyword(in: "WITH old AS (SELECT id FROM t) DELETE FROM t;") == "DELETE")
  #expect(D1SQL.destructiveKeyword(in: "INSERT OR REPLACE INTO t VALUES (1);") == "REPLACE")
  #expect(
    D1SQL.destructiveKeyword(
      in: "INSERT INTO t VALUES (1) ON CONFLICT DO UPDATE SET x = 2;") == "UPDATE")

  // Identifiers containing keyword substrings stay safe.
  #expect(D1SQL.destructiveKeyword(in: "SELECT * FROM legacy_update;") == nil)
  #expect(
    D1SQL.destructiveKeyword(in: "WITH d AS (SELECT * FROM audit_delete_log) SELECT * FROM d;")
      == nil)
}

@Test func d1QuotedIdentifierEscapesKeywordsAndEmbeddedQuotes() {
  #expect(d1QuotedIdentifier("users") == "\"users\"")
  #expect(d1QuotedIdentifier("order") == "\"order\"")
  #expect(d1QuotedIdentifier("has space") == "\"has space\"")
  #expect(d1QuotedIdentifier("weird\"name") == "\"weird\"\"name\"")
  #expect(d1QuotedIdentifier("a\"b\"c") == "\"a\"\"b\"\"c\"")
}

// MARK: - AvatarStore

/// Serialized because the mock protocol's handler is a shared static.
@Suite(.serialized) struct AvatarStoreTests {
  @MainActor
  private func makeStore(
    handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)
  ) -> AvatarStore {
    AvatarMockURLProtocol.handler = handler
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AvatarMockURLProtocol.self]
    return AvatarStore(session: URLSession(configuration: configuration))
  }

  @MainActor
  private func waitForImage(in store: AvatarStore, email: String) async throws -> Bool {
    for _ in 0..<200 {
      if store.image(for: email) != nil { return true }
      try await Task.sleep(for: .milliseconds(10))
    }
    return false
  }

  private var pixel: Data {
    UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).pngData { context in
      UIColor.orange.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
  }

  @Test @MainActor func singleFlightsAndNormalizesRepeatRequests() async throws {
    let log = RequestLog()
    let image = pixel
    let store = makeStore { _ in
      _ = log.next()
      return (200, image)
    }
    store.ensureLoaded("i@xat.sh")
    store.ensureLoaded(" I@XAT.SH ")
    #expect(try await waitForImage(in: store, email: "i@xat.sh"))
    store.ensureLoaded("i@xat.sh")
    #expect(store.image(for: " I@Xat.sh ") != nil)
    #expect(log.count == 1)
  }

  @Test @MainActor func treats404AsDefinitiveNoAvatar() async throws {
    let log = RequestLog()
    let store = makeStore { _ in
      _ = log.next()
      return (404, Data())
    }
    store.ensureLoaded("i@xat.sh")
    for _ in 0..<20 {
      store.ensureLoaded("i@xat.sh")
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(store.image(for: "i@xat.sh") == nil)
    #expect(log.count == 1)
  }

  @Test @MainActor func retriesAfterTransientFailure() async throws {
    let log = RequestLog()
    let image = pixel
    let store = makeStore { _ in
      if log.next() == 1 { throw URLError(.notConnectedToInternet) }
      return (200, image)
    }
    for _ in 0..<200 {
      store.ensureLoaded("i@xat.sh")
      if store.image(for: "i@xat.sh") != nil { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(store.image(for: "i@xat.sh") != nil)
    #expect(log.count == 2)
  }
}

private final class RequestLog: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  var count: Int { lock.withLock { value } }
  func next() -> Int {
    lock.withLock {
      value += 1
      return value
    }
  }
}

private final class AvatarMockURLProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?
  override class func canInit(with _: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      let (status, data) = try Self.handler?(request) ?? (500, Data())
      let response = HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() {}
}
