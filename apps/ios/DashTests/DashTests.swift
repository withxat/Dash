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
}

@Test func defaultShortcutsMatchOriginalApp() {
  #expect(FeatureCatalog.defaults == [.zones, .workers, .r2, .kv])
}
