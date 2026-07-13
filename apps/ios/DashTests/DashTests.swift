import CloudflareAPI
import Testing

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
    zoneDestination(for: .dnsManagement, zoneID: "z1", zoneName: "example.com")
      == .dns("z1"))
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

@Test func d1QuotedIdentifierEscapesKeywordsAndEmbeddedQuotes() {
  #expect(d1QuotedIdentifier("users") == "\"users\"")
  #expect(d1QuotedIdentifier("order") == "\"order\"")
  #expect(d1QuotedIdentifier("has space") == "\"has space\"")
  #expect(d1QuotedIdentifier("weird\"name") == "\"weird\"\"name\"")
  #expect(d1QuotedIdentifier("a\"b\"c") == "\"a\"\"b\"\"c\"")
}
