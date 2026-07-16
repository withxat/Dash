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
  #expect(FeatureID.allCases.count == 4)
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

/// The catalog is the default grant. Every feature the Resources tab shows must
/// be fully usable without an incremental authorization, so nothing can resolve
/// to `.locked` or `.readOnly` out of the box. A new FeatureID belongs in
/// `coreFeatures` at the same time it gets a descriptor, or it does not ship.
@Test func everyFeatureIsFullyUsableOnADefaultGrant() {
  #expect(DashAuthorizationScopes.coreFeatures == Set(FeatureID.allCases))
  for feature in FeatureID.allCases {
    #expect(
      feature.capability.accessLevel(grantedScopes: DashAuthorizationScopes.core) == .full)
  }
}

@Test @MainActor func appModelDefaultsToCorePermissions() {
  let model = AppModel(configuration: AppConfiguration(clientID: "", redirectURI: ""))
  #expect(model.selectedScopes == DashAuthorizationScopes.core)
  #expect(DashAuthorizationScopes.core.count == 27)
  #expect(DashAuthorizationScopes.core.isStrictSubset(of: Set(CloudflareScopes.published)))
  #expect(
    DashAuthorizationScopes.searchResources.isSubset(of: DashAuthorizationScopes.core))
  #expect(DashAuthorizationScopes.watchtower.isSubset(of: DashAuthorizationScopes.core))
  #expect(CloudflareScopes.required.allSatisfy(model.selectedScopes.contains))
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
    "argotunnel.read",  // Watchtower tunnelsSignal
    "notifications.read",  // Watchtower alerts
    "ssl-and-certificates.read",  // Watchtower certsSignal
    "account-analytics.read",  // Worker metrics card (account-scoped GraphQL)
    "page.read",  // Watchtower pagesSignal
    "zone-settings.read", "zone-settings.write",  // SetUnderAttack, ToggleDevelopmentMode
    "workers-tail.read",  // WorkerTailView
  ]
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
}

@Test func zoneSettingTitlesPreserveTechnicalAcronyms() {
  #expect(zoneSettingDisplayTitle("ssl") == "SSL")
  #expect(zoneSettingDisplayTitle("always_use_https") == "Always Use HTTPS")
  #expect(zoneSettingDisplayTitle("min_tls_version") == "Minimum TLS version")
  #expect(zoneSettingDisplayTitle("development_mode") == "Development Mode")
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

/// The Resources tab opens on `.available`, which is only safe because unknown
/// scopes resolve to `.full`. If that ever flips, a cold launch shows an empty
/// catalog before the token store answers.
@MainActor
@Test func featureCatalogDefaultFilterListsEverythingBeforeScopesLoad() {
  #expect(FeatureCatalogView.defaultFilter == .available)
  let coldLaunch = FeatureCatalogFiltering.features(
    filter: FeatureCatalogView.defaultFilter,
    grantedScopes: nil)
  #expect(coldLaunch.count == FeatureCatalog.all.count)
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
}

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
  #expect(featureID(for: .profile) == nil)
}

/// Tunnels and Pages report problems the app has no screen for, so their rows
/// no longer push anywhere. The row has to name the broken resource or it is a
/// dead end: "1 tunnel down", which one, nowhere to tap.
@MainActor
@Test func watchtowerRowsNameTheResourceTheyCannotPushTo() {
  func signal(
    _ detail: String, resource: String?, status: WatchtowerStatus = .critical
  ) -> WatchtowerSignal {
    WatchtowerSignal(
      id: "t", title: "Tunnels", detail: detail, status: status,
      destination: nil, resourceName: resource)
  }
  #expect(
    WatchtowerView.signalDetail(signal("1 tunnel down", resource: "homelab-01"))
      == "1 tunnel down · homelab-01")
  // Healthy signals have no offender to name.
  #expect(
    WatchtowerView.signalDetail(signal("All 3 healthy", resource: "x", status: .ok))
      == "All 3 healthy")
  // Pages already interpolates the project name — don't say it twice.
  #expect(
    WatchtowerView.signalDetail(signal("site: latest deployment failed", resource: "site"))
      == "site: latest deployment failed")
  #expect(WatchtowerView.signalDetail(signal("1 down", resource: nil)) == "1 down")
}

/// The scopes with no FeatureID of their own. `requiredScopes` must name them
/// literally: falling through to `.zones.capability.all` compiles clean and
/// silently drops them, and the screen 403s on save.
@Test func requiredScopesNameTheOperationalScopesLiterally() {
  #expect(requiredScopes(for: .dns("z1")).contains("dns.write"))
  #expect(requiredScopes(for: .cache("z1")).contains("cache.purge"))
  #expect(requiredScopes(for: .zoneSettings("z1")).contains("zone-settings.write"))
  #expect(requiredScopes(for: .workerTail("api")).contains("workers-tail.read"))
  // Each is absent from the feature the destination maps to.
  #expect(!FeatureID.zones.capability.all.contains("dns.write"))
  #expect(!FeatureID.zones.capability.all.contains("cache.purge"))
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
  #expect(FeatureVisualIdentity.tone(for: .workers) == .brand)
  #expect(FeatureVisualIdentity.tone(for: .r2) == .accent)
  #expect(FeatureVisualIdentity.tone(for: .kv) == .accent)

  // Every catalog section reads as one color family, and no surviving feature
  // falls through to the `default:` tone.
  for (_, features) in FeatureCatalog.grouped {
    let tones = Set(features.map { FeatureVisualIdentity.tone(for: $0) })
    #expect(tones.count == 1)
    #expect(tones != [.soft])
  }
}

@Test func featureCatalogIconsAreUnique() {
  let duotone = FeatureCatalog.descriptors.map(\.solarAssetName)
  let outline = FeatureCatalog.descriptors.map(\.solarOutlineAssetName)
  #expect(Set(duotone).count == duotone.count)
  #expect(Set(outline).count == outline.count)
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

@Test func homeWatchtowerCheckedTextUsesReadableAgeBuckets() {
  let now = Date(timeIntervalSince1970: 200_000)
  #expect(
    homeWatchtowerCheckedText(fetchedAt: nil, now: now)
      == "Open Watchtower to check this account")
  #expect(
    homeWatchtowerCheckedText(fetchedAt: now.addingTimeInterval(-30), now: now)
      == "Checked just now")
  #expect(
    homeWatchtowerCheckedText(fetchedAt: now.addingTimeInterval(-120), now: now)
      == "Checked 2 min ago")
  #expect(
    homeWatchtowerCheckedText(fetchedAt: now.addingTimeInterval(-7_200), now: now)
      == "Checked 2 hr ago")
  #expect(
    homeWatchtowerCheckedText(fetchedAt: now.addingTimeInterval(-172_800), now: now)
      == "Checked 2 days ago · Refresh now")
}

/// Raw values of removed features must drop out of a persisted shortcut list
/// rather than break Home. `compactMap` is the only migration path there is.
@Test func oldShortcutsDecodeSafely() {
  let decoded = "zones,apiExplorer,workersAI,magicNetworking"
    .split(separator: ",")
    .compactMap { FeatureID(rawValue: String($0)) }
  #expect(decoded == [.zones])
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

@Test func homeZonesTrailingPullRequiresThresholdDistance() {
  #expect(HomeZonesPullDecision.progress(distance: 0) == 0)
  #expect(HomeZonesPullDecision.progress(distance: 32) == 0.5)
  #expect(HomeZonesPullDecision.progress(distance: 80) == 1)
  #expect(!HomeZonesPullDecision.shouldOpen(distance: 63))
  #expect(HomeZonesPullDecision.shouldOpen(distance: 64))
}

@Test func homeZonesOverscrollCountsOnlyRubberBandPastTrailingEdge() {
  // Mid-scroll and exactly at the end are not overscroll.
  #expect(
    HomeZonesPullDecision.overscroll(
      contentOffsetX: 200, containerWidth: 360, contentWidth: 760) == 0)
  #expect(
    HomeZonesPullDecision.overscroll(
      contentOffsetX: 400, containerWidth: 360, contentWidth: 760) == 0)
  // Rubber-banding past the end reports the exposed distance.
  #expect(
    HomeZonesPullDecision.overscroll(
      contentOffsetX: 472, containerWidth: 360, contentWidth: 760) == 72)
  // A leading bounce is not overscroll.
  #expect(
    HomeZonesPullDecision.overscroll(
      contentOffsetX: -30, containerWidth: 360, contentWidth: 760) == 0)
  // A strip too short to scroll rests at zero; any leftward pull is
  // overscroll so short strips can still open the full list.
  #expect(
    HomeZonesPullDecision.overscroll(
      contentOffsetX: 0, containerWidth: 360, contentWidth: 300) == 0)
  #expect(
    HomeZonesPullDecision.overscroll(
      contentOffsetX: 40, containerWidth: 360, contentWidth: 300) == 40)
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

  // Rejections.
  #expect(parse("dash://oauth/callback?code=x") == nil)  // owned by the auth session
  #expect(parse("dash://feature/bogus") == nil)  // unknown FeatureID
  #expect(parse("dash://feature/d1") == nil)  // retired FeatureID
  #expect(parse("dash://d1/db-uuid") == nil)  // retired host; stale Spotlight items land here
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
  #expect(
    WatchtowerFreshness.checkedText(
      fetchedAt: base.fetchedAt,
      now: Date(timeIntervalSince1970: 3 * 3_600))
      == "Checked 3 hr ago · Refresh recommended")
  #expect(
    WatchtowerFreshness.checkedText(
      fetchedAt: base.fetchedAt,
      now: Date(timeIntervalSince1970: 25 * 3_600))
      == "Checked 1 day ago · Refresh now")
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

@MainActor
@Test func workerTailEventRowAccessibilityIncludesSummary() {
  let event = WorkerTailEvent(
    timestamp: nil, outcome: "ok", summary: "GET /", lines: ["hello"])
  #expect(WorkerTailEventRow.accessibilityLabel(for: event).contains("GET /"))
  #expect(WorkerTailEventRow.outcomeColor("exception") == DashTheme.danger)
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
