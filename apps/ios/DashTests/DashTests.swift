import CloudflareAPI
import Testing
import UIKit

@testable import Dash

@Test func configurationRejectsUnexpandedBuildSettings() {
  #expect(
    !AppConfiguration(clientID: "$(DASH_CLIENT_ID)", redirectURI: "$(DASH_REDIRECT_URI)")
      .isConfigured)
}

@Test func featureCatalogContainsEveryFeatureOnce() {
  let values = FeatureCatalog.grouped.flatMap(\.1)
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

@Test @MainActor func appModelDefaultsToPublishedPermissions() {
  let model = AppModel(configuration: AppConfiguration(clientID: "", redirectURI: ""))
  #expect(model.selectedScopes == Set(CloudflareScopes.published))
  #expect(CloudflareScopes.required.allSatisfy(model.selectedScopes.contains))
  #expect(!model.selectedScopes.contains("ai-search.metadata_read"))
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
    DashListPhase.resolve(isLoading: true, error: "boom", hasContent: true) == .loading)
  #expect(
    DashListPhase.resolve(isLoading: false, error: "boom", hasContent: false)
      == .fullScreenError("boom"))
  #expect(
    DashListPhase.resolve(isLoading: false, error: "boom", hasContent: true)
      == .content(banner: "boom"))
  #expect(
    DashListPhase.resolve(isLoading: false, error: nil, hasContent: true)
      == .content(banner: nil))
  #expect(
    DashListPhase.resolve(isLoading: false, error: nil, hasContent: false)
      == .content(banner: nil))
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

@Test func recentFeaturesDedupeReorderAndCap() {
  // A repeat visit moves the feature to the front instead of duplicating it.
  #expect(
    RecentFeatures.updated(existing: "zones,workers,r2", adding: .workers)
      == "workers,zones,r2")
  // New entries prepend.
  #expect(RecentFeatures.updated(existing: "", adding: .d1) == "d1")
  // The list caps at six.
  #expect(
    RecentFeatures.updated(existing: "zones,workers,r2,kv,d1,images", adding: .stream)
      == "stream,zones,workers,r2,kv,d1")
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

@Test @MainActor func incrementalAuthorizationKeepsExistingAndRequiredScopes() {
  let scopes = AppModel.incrementalScopes(
    granted: ["zone.read"],
    requested: ["workers-scripts.read"]
  )
  #expect(scopes.contains("zone.read"))
  #expect(scopes.contains("workers-scripts.read"))
  #expect(Set(CloudflareScopes.required).isSubset(of: scopes))
}

@Test func batchOneRegistryPathsCarryTheirWrites() {
  let containers = GenericResourceCapabilities.forPath("/accounts/abc/containers/applications")
  #expect(containers.deleteMessage != nil)
  #expect(containers.create == nil)

  let catalog = GenericResourceCapabilities.forPath("/accounts/abc/r2-catalog")
  #expect(catalog.updates.count == 1)
  #expect(catalog.deleteMessage == nil)

  let dex = GenericResourceCapabilities.forPath("/accounts/abc/dex/devices/dex_tests")
  #expect(dex.deleteMessage != nil)

  let suppression = GenericResourceCapabilities.forPath(
    "/accounts/abc/email/sending/suppression")
  #expect(suppression.create != nil)
  #expect(suppression.deleteMessage != nil)

  let namespaces = GenericResourceCapabilities.forPath("/accounts/abc/artifacts/namespaces")
  #expect(namespaces.create == nil)
  #expect(namespaces.deleteMessage == nil)
  #expect(namespaces.updates.isEmpty)
}

@Test func hubRegistryPathsCarryTheirWrites() {
  let apps = GenericResourceCapabilities.forPath("/accounts/abc/calls/apps")
  #expect(apps.create != nil)
  #expect(apps.deleteMessage != nil)

  let turnKeys = GenericResourceCapabilities.forPath("/accounts/abc/calls/turn_keys")
  #expect(turnKeys.create != nil)
  #expect(turnKeys.deleteMessage != nil)

  let relays = GenericResourceCapabilities.forPath("/accounts/abc/moq/relays")
  #expect(relays.create == nil)
  #expect(relays.deleteMessage != nil)

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
