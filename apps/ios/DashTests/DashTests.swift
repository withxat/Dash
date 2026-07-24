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

/// The first grant must make every catalog feature browsable without allowing
/// mutations. A new FeatureID belongs in `coreFeatures` at the same time it
/// gets a descriptor, or it does not ship.
@Test func everyFeatureIsReadOnlyOnTheInitialGrant() {
  #expect(DashAuthorizationScopes.coreFeatures == Set(FeatureID.allCases))
  for feature in FeatureID.allCases {
    #expect(
      feature.capability.accessLevel(grantedScopes: DashAuthorizationScopes.initialReadOnly)
        == .readOnly)
  }
}

@Test @MainActor func appModelDefaultsToReadOnlyPermissions() {
  let model = AppModel(configuration: AppConfiguration(clientID: "", redirectURI: ""))
  #expect(model.selectedScopes == DashAuthorizationScopes.initialReadOnly)
  #expect(DashAuthorizationScopes.initialReadOnly.count == 20)
  #expect(DashAuthorizationScopes.core.count == 30)
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
  #expect(CloudflareScopes.required.allSatisfy(model.selectedScopes.contains))
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
    "argotunnel.read",  // Watchtower tunnelsSignal
    "notifications.read",  // Watchtower alerts
    "notifications.write",  // Push alerts webhook + policies
    "ssl-and-certificates.read",  // Watchtower certsSignal
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

@Test func destinationFeatureMappingCoversDirectRoutes() {
  #expect(featureID(for: .zone("z1")) == .zones)
  #expect(featureID(for: .dns("z1")) == .zones)
  #expect(featureID(for: .worker("api")) == .workers)
  #expect(featureID(for: .r2Bucket("media", prefix: "")) == .r2)
  #expect(featureID(for: .kvNamespace("ns")) == .kv)
  #expect(featureID(for: .kvKey(namespaceID: "ns", key: "flag")) == .kv)
  #expect(featureID(for: .profile) == nil)
}

/// Tunnels report problems the app has no screen for (tray opens Cloudflare).
/// The row still has to name the broken resource or it is a dead end:
/// "1 tunnel down", which one? Pages opens the project in-app.
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

/// Operational destinations split reads from mutations so the initial grant
/// can render them without accidentally authorizing a save.
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
  #expect(writeScopes(for: .cache("z1")) == ["cache.purge"])
  #expect(writeScopes(for: .zoneAnalytics("z1")).isEmpty)
  // Each is absent from the feature the destination maps to.
  #expect(!FeatureID.zones.capability.all.contains("dns.write"))
  #expect(!FeatureID.zones.capability.all.contains("cache.purge"))
}

// `View` is a @MainActor protocol, so StatusBadge/DashNotice statics are
// isolated too — the test has to hop on as well.
@MainActor
@Test func statusBadgeAndNoticeExposeAccessibleCopy() {
  let previousLocale = DashL10n.localeOverrideForTesting
  DashL10n.localeOverrideForTesting = Locale(identifier: "en")
  defer { DashL10n.localeOverrideForTesting = previousLocale }

  #expect(StatusBadge.accessibilityText(for: "Read-only") == "Status, Read-only")
  #expect(StatusBadge.presentation(for: "OK") == .quiet)
  #expect(StatusBadge.presentation(for: "Critical") == .capsule)
  #expect(StatusBadge.presentation(for: "Locked") == .capsule)
  #expect(
    DashNotice.accessibilityText(kind: .warning, message: "Coverage limited")
      == "Warning: Coverage limited")
  #expect(DashTheme.Spacing.scrollBottomInset == 80)
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

@Test @MainActor func watchtowerDragOverlayPreservesGrabOffsetAndEndsCleanly() {
  let visualState = WatchtowerMetricDragVisualState()
  visualState.begin(
    metric: .webTraffic,
    size: CGSize(width: 160, height: 220),
    location: CGPoint(x: 220, y: 360),
    grabOffset: CGPoint(x: 30, y: -20),
    isExpanded: true,
    retaining: NSObject())

  #expect(visualState.presentation?.center == CGPoint(x: 190, y: 380))

  visualState.move(to: CGPoint(x: 260, y: 410))
  #expect(visualState.presentation?.center == CGPoint(x: 230, y: 430))

  visualState.moveCenter(to: CGPoint(x: 120, y: 240))
  #expect(visualState.presentation?.center == CGPoint(x: 120, y: 240))

  visualState.beginSettling()
  #expect(visualState.isSettling)

  visualState.finish()
  #expect(visualState.presentation == nil)
  #expect(!visualState.isSettling)
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

@Test @MainActor func watchtowerChartCustomizationCommitsAndCancelsDrafts() throws {
  let suite = "dash-tests-watchtower-layout-\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
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
      == [.addDomain, .uploadR2, .addDNSRecord])
  #expect(HomeActions.decode("purgeCache,uploadR2,purgeCache,unknown") == [.purgeCache, .uploadR2])

  // Changing the fresh-install default never rewrites a previously stored choice.
  let previousSelection = HomeActions.encode([.addDomain, .uploadR2, .addDNSRecord])
  #expect(
    HomeActions.decode(previousSelection) == [.addDomain, .uploadR2, .addDNSRecord])

  let full = HomeActions.defaultValue
  #expect(HomeActions.toggled(.createKVKey, in: full) == full)

  let removed = HomeActions.toggled(.addDomain, in: full)
  #expect(HomeActions.decode(removed) == [.uploadR2, .addDNSRecord])
  #expect(HomeActions.decode(HomeActions.toggled(.createKVKey, in: removed)).last == .createKVKey)
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

@Test @MainActor func homeWashClipLiftStopsAtContentControllerBoundary() {
  let outsideTransitionContainer = UIView()
  outsideTransitionContainer.clipsToBounds = true

  let contentController = UIViewController()
  contentController.loadViewIfNeeded()
  contentController.view.clipsToBounds = true
  outsideTransitionContainer.addSubview(contentController.view)

  let hostingWrapper = UIView()
  hostingWrapper.clipsToBounds = true
  let washProbe = UIView()
  contentController.view.addSubview(hostingWrapper)
  hostingWrapper.addSubview(washProbe)

  HomeWashClipScope.lift(from: washProbe)

  #expect(!hostingWrapper.clipsToBounds)
  #expect(contentController.view.clipsToBounds)
  #expect(outsideTransitionContainer.clipsToBounds)
}

@Test @MainActor func homeWashClipLiftDoesNothingWithoutContentController() {
  let unknownContainer = UIView()
  unknownContainer.clipsToBounds = true
  let washProbe = UIView()
  unknownContainer.addSubview(washProbe)

  HomeWashClipScope.lift(from: washProbe)

  #expect(unknownContainer.clipsToBounds)
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

@Test func underAttackRestoreLevelFallsBackToMedium() {
  #expect(SetUnderAttackIntent.restoreLevel(stashed: "high") == "high")
  #expect(SetUnderAttackIntent.restoreLevel(stashed: "essentially_off") == "essentially_off")
  #expect(SetUnderAttackIntent.restoreLevel(stashed: nil) == "medium")
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

@Test func watchtowerDashboardLinksBuildAccountScopedURLs() {
  let accountID = "abc123"
  #expect(
    WatchtowerDashboardLinks.tunnels(accountID: accountID)?.absoluteString
      == "https://one.dash.cloudflare.com/abc123/networks/tunnels")
  #expect(
    WatchtowerDashboardLinks.pools(accountID: accountID)?.absoluteString
      == "https://dash.cloudflare.com/abc123/traffic/load-balancing/pools")
  #expect(
    WatchtowerDashboardLinks.registrar(accountID: accountID)?.absoluteString
      == "https://dash.cloudflare.com/abc123/domains")
}

@Test func watchtowerDashboardLinksReturnNilForEmptyAccountID() {
  #expect(WatchtowerDashboardLinks.tunnels(accountID: "") == nil)
  #expect(WatchtowerDashboardLinks.pools(accountID: "") == nil)
  #expect(WatchtowerDashboardLinks.registrar(accountID: "") == nil)
}

@Test func watchtowerTunnelsSignalAttachesDashboardExternalURL() throws {
  let tunnel = try JSONDecoder().decode(
    CloudflareTunnel.self,
    from: Data(#"{"id":"tun-1","name":"homelab","status":"healthy"}"#.utf8))
  let signal = WatchtowerEngine.tunnelsSignal([tunnel], accountID: "acc-9")
  #expect(signal?.id == "tunnels")
  #expect(signal?.destination == nil)
  #expect(
    signal?.externalURL?.absoluteString
      == "https://one.dash.cloudflare.com/acc-9/networks/tunnels")
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
    detail: "5 of 15 domains not checked",
    status: "warning")
  typealias Planner = WatchtowerNotificationPlanner

  // Coverage appearing alone must not fire a local notification.
  #expect(
    Planner.plans(
      previous: snapshot(issues: 0, signals: []),
      current: snapshot(issues: 1, signals: [coverage])
    ).isEmpty)

  // A real warning includes its actionable detail.
  let plans = Planner.plans(
    previous: snapshot(issues: 1, signals: [coverage]),
    current: snapshot(
      issues: 2,
      signals: [
        coverage,
        WatchtowerWidgetSnapshot.Signal(title: "tunnel", detail: "down", status: "warning"),
      ]))
  #expect(plans.map(\.identifier) == ["watchtower.warning.tunnel"])
  #expect(plans.first?.title == "tunnel")
  #expect(plans.first?.body == "down")
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

  // A newly-critical signal fires with a stable identifier and its detail.
  let newCritical = Planner.plans(
    previous: snapshot(issues: 1, critical: [], warning: ["w"]),
    current: snapshot(issues: 2, critical: ["tunnel"], warning: ["w"]))
  #expect(newCritical.map(\.identifier) == ["watchtower.critical.tunnel"])
  #expect(newCritical.first?.body == "d")

  // Still-critical does not re-notify.
  #expect(
    Planner.plans(
      previous: snapshot(issues: 1, critical: ["tunnel"]),
      current: snapshot(issues: 1, critical: ["tunnel"])
    ).isEmpty)

  // A new warning gets its own actionable notification.
  let warning = Planner.plans(
    previous: snapshot(issues: 1, critical: [], warning: ["w1"]),
    current: snapshot(issues: 2, critical: [], warning: ["w1", "w2"]))
  #expect(warning.map(\.identifier) == ["watchtower.warning.w2"])
  #expect(warning.first?.title == "w2")

  // Multiple new issues are combined, keeping the first issue's detail.
  let summary = Planner.plans(
    previous: snapshot(issues: 0, critical: []),
    current: snapshot(issues: 2, critical: ["tunnel"], warning: ["pages"]))
  #expect(summary.map(\.identifier) == ["watchtower.issues"])
  #expect(summary.first?.title == "tunnel")
  #expect(summary.first?.body == "d · 1 more issue needs attention.")

  // Escalating from warning to critical re-notifies with the critical detail.
  let escalation = Planner.plans(
    previous: snapshot(issues: 1, critical: [], warning: ["tunnel"]),
    current: snapshot(issues: 1, critical: ["tunnel"]))
  #expect(escalation.map(\.identifier) == ["watchtower.critical.tunnel"])

  // Muted issues never leak into a generic summary.
  #expect(
    Planner.plans(
      previous: snapshot(issues: 0, critical: []),
      current: snapshot(issues: 1, critical: ["tunnel"]),
      mutedTitles: ["tunnel"]
    ).isEmpty)

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

@Test func watchtowerInboxMergesLiveSignalsWithCloudflareHistory() {
  let suite = "dash.tests.inbox.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  let account = "acct-1"

  let downTunnels = WatchtowerSignal(
    id: "tunnels", title: "Tunnels", detail: "1 tunnel down", status: .critical,
    destination: nil, resourceName: "homelab-01")
  let healthyPages = WatchtowerSignal(
    id: "pages", title: "Pages", detail: "All clear", status: .ok, destination: nil)

  let alerts = [
    NotificationHistoryEntry(
      historyID: "hist-1",
      policyID: "pol-1",
      name: "Tunnel health",
      alertType: "tunnel_health_event",
      mechanism: "email",
      alertBody: "homelab-01 disconnected from Cloudflare",
      description: nil,
      sent: ISO8601DateFormatter().string(from: .now))
  ]
  let feed = WatchtowerInboxStore.build(
    accountID: account, alerts: alerts, signals: [downTunnels, healthyPages],
    defaults: defaults)
  // Live Dash warning + matching CF delivery collapse to one row.
  #expect(feed.count == 1)
  #expect(feed.first?.sources == [.cloudflare, .dash])
  #expect(feed.first?.signalID == "tunnels")
  #expect(feed.first?.primarySource == .dash)

  let entryID = feed[0].id
  WatchtowerInboxStore.ignore([entryID], accountID: account, defaults: defaults)
  #expect(WatchtowerInboxStore.isIgnored(entryID, accountID: account, defaults: defaults))
  #expect(
    WatchtowerInboxStore.activeCount(
      accountID: account, alerts: alerts, signals: [downTunnels], defaults: defaults) == 0)

  WatchtowerInboxStore.unignore(entryID, accountID: account, defaults: defaults)
  #expect(
    WatchtowerInboxStore.activeCount(
      accountID: account, alerts: alerts, signals: [downTunnels], defaults: defaults) == 1)
}

@Test func dashCapabilityStatusMapsAPIErrors() {
  #expect(DashCapabilityStatus.from(apiError: nil) == .unknown)
  let forbidden = CloudflareAPIError.request(status: 403, errors: [])
  #expect(DashCapabilityStatus.from(apiError: forbidden) == .needsPermission)
  let plan = CloudflareAPIError.transport("Account not entitled")
  #expect(DashCapabilityStatus.from(apiError: plan) == .needsPlan)
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

@Test func wafChartModelKeepsShortListsAndMapsData() {
  let buckets = [
    FirewallEventsBucket(label: "US", count: 64),
    FirewallEventsBucket(label: "CN", count: 38),
    FirewallEventsBucket(label: "RU", count: 21),
  ]
  let top = WAFChartModel.topCountries(buckets)
  #expect(top.count == 3)

  let data = WAFChartModel.data(from: top)
  #expect(data.map(\.id) == ["US", "CN", "RU"])
  #expect(data.map(\.label) == ["US", "CN", "RU"])
  #expect(data[0].values["blocks"] == 64)
  #expect(data[2].values["blocks"] == 21)
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

  let empty = WAFChartModel.countriesAccessibilitySummary(buckets: [])
  #expect(empty.contains("No blocked events"))
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
    DNSChartModel.records(records, in: $0.id).count == $0.count
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
