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
