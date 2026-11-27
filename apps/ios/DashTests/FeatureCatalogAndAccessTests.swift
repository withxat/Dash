import CloudflareAPI
import CoreText
import SwiftUI
import Testing
import UIKit

@testable import Dash

@Test func featureCatalogContainsEveryFeatureOnce() {
  let values = FeatureCatalog.grouped.flatMap(\.1)
  #expect(FeatureID.allCases.count == 7)
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

/// Core features stay browsable on the legacy read-only profile. Experimental
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
  // The registration screen has no Resources row to unlock it, so both its
  // scopes ship with sign-in — the read one because the zone card's lookup runs
  // unprompted, the admin one because auto-renew is what the screen is for. The
  // read-only profile still withholds the write.
  #expect(DashAuthorizationScopes.core.contains("registrar-domains.read"))
  #expect(DashAuthorizationScopes.core.contains("registrar-domains.admin"))
  #expect(DashAuthorizationScopes.initialReadOnly.contains("registrar-domains.read"))
  #expect(!DashAuthorizationScopes.initialReadOnly.contains("registrar-domains.admin"))
  #expect(!DashAuthorizationScopes.core.contains("argotunnel.read"))
  #expect(!DashAuthorizationScopes.core.contains("access.read"))
  #expect(
    DashAuthorizationScopes.authorizationScopes(for: .tunnels)
      == ["argotunnel.read", "access.read"])
  for feature in DashAuthorizationScopes.coreFeatures {
    let access = feature.capability.accessLevel(
      grantedScopes: DashAuthorizationScopes.initialReadOnly)
    // Legacy read-only grants omit write scopes, so every unlocked core
    // feature with mutations is Read-only. (None of coreFeatures is
    // permanently write-free — that pattern is currently Tunnels.)
    #expect(!feature.capability.write.isEmpty)
    #expect(access == .readOnly)
  }
  #expect(
    FeatureID.tunnels.capability.accessLevel(
      grantedScopes: DashAuthorizationScopes.initialReadOnly) == .locked)
}

/// Registrar left the catalog: the pushed registration screen is the only
/// surface, so its scopes are literals rather than a `FeatureID` capability and
/// nothing may re-derive them from the zone it was reached from.
@Test func registrarScopesStayLiteralAndOffTheZoneCapability() {
  let official = Set(CloudflareScopes.published)
  #expect(RegistrarAccess.read == ["registrar-domains.read"])
  #expect(RegistrarAccess.write == ["registrar-domains.admin"])
  #expect(RegistrarAccess.read.union(RegistrarAccess.write).isSubset(of: official))
  #expect(!official.contains("registrar-domains.write"))
  #expect(
    FeatureID.allCases.allSatisfy { $0.capability.all.isDisjoint(with: RegistrarAccess.write) })
}

@Test @MainActor func appModelDefaultsToFullAccountPermissions() {
  let model = AppModel(configuration: AppConfiguration(clientID: "", redirectURI: ""))
  #expect(model.selectedScopes == DashAuthorizationScopes.core)
  #expect(DashAuthorizationScopes.initialReadOnly.count == 21)
  #expect(DashAuthorizationScopes.core.count == 38)
  #expect(DashAuthorizationScopes.initialReadOnly.isStrictSubset(of: DashAuthorizationScopes.core))
  #expect(
    DashAuthorizationScopes.initialReadOnly.allSatisfy {
      !$0.hasSuffix(".write")
    })
  #expect(DashAuthorizationScopes.core.isStrictSubset(of: Set(CloudflareScopes.published)))
  #expect(DashAuthorizationScopes.watchtower.contains("notifications.read"))
  #expect(
    DashAuthorizationScopes.watchtower.isSubset(of: DashAuthorizationScopes.initialReadOnly))
  #expect(
    R2ShareDestination.requiredWriteScopes.isSubset(of: DashAuthorizationScopes.core))
  #expect(
    R2ShareDestination.requiredWriteScopes.isDisjoint(
      with: DashAuthorizationScopes.initialReadOnly))
  #expect(DashAuthorizationScopes.core.contains("zone-settings.write"))
  #expect(DashAuthorizationScopes.core.contains("account-settings.write"))
  #expect(CachePurgeAccess.write.isSubset(of: DashAuthorizationScopes.core))
  #expect(CachePurgeAccess.write.isDisjoint(with: DashAuthorizationScopes.initialReadOnly))
  #expect(!DashAuthorizationScopes.initialReadOnly.contains("account-settings.write"))
  #expect(!model.hasScopes(["dns.write"]))
  model.grantedScopes = DashAuthorizationScopes.initialReadOnly
  #expect(model.hasScopes(["dns.read"]))
  #expect(!model.hasScopes(["dns.write"]))
  #expect(CloudflareScopes.required.allSatisfy(model.selectedScopes.contains))
}

@Test @MainActor func demoGrantsSimulatedCoreWritesPlusExperimentalReads() {
  #expect(DashAuthorizationScopes.initialReadOnly.isStrictSubset(of: AppModel.demoGrantedScopes))
  #expect(AppModel.demoGrantedScopes.contains("registrar-domains.read"))
  #expect(AppModel.demoGrantedScopes.contains("registrar-domains.admin"))
  #expect(AppModel.demoGrantedScopes.contains("argotunnel.read"))
  #expect(AppModel.demoGrantedScopes.contains("access.read"))
  #expect(!AppModel.demoAccessRequiresConnection(["dns.read"]))
  #expect(!AppModel.demoAccessRequiresConnection(["dns.write"]))
  #expect(AppModel.demoAccessRequiresConnection(["unsupported.write"]))
  for feature in FeatureID.allCases {
    let access = feature.capability.accessLevel(
      grantedScopes: AppModel.demoGrantedScopes)
    // Tunnels remains a read-only feature; every shipped editor is unlocked.
    #expect(access == (feature == .tunnels ? .readOnly : .full))
  }
}

@Test func experimentalFeaturesStayHiddenUntilOptedIn() {
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

  let withExperimentalFeatures = FeatureCatalogFiltering.enabledFeatures(
    tunnelsExperimentalEnabled: true)
  #expect(withExperimentalFeatures == Set(FeatureID.allCases))

  let lockedCatalog = FeatureCatalogFiltering.features(
    filter: .all,
    grantedScopes: DashAuthorizationScopes.initialReadOnly,
    enabled: withExperimentalFeatures)
  #expect(lockedCatalog.contains(.tunnels))
  #expect(
    FeatureID.tunnels.capability.accessLevel(
      grantedScopes: DashAuthorizationScopes.initialReadOnly) == .locked)
}

@Test func processExternalMutationsFailClosedWithoutWriteScopes() {
  let intentWrites = CachePurgeAccess.write.union(["zone-settings.write"])
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
    "workers-routes.read",  // WorkerDetail routes rows (zone-scoped, no carrier FeatureID)
    "notifications.read",  // Watchtower inbox (Cloudflare delivery history)
    "account-analytics.read",  // Worker metrics card (account-scoped GraphQL)
    "analytics.read",  // Zone HTTP Traffic Analytics, including Watchtower charts
    "zone-settings.read", "zone-settings.write",  // SetUnderAttack, ToggleDevelopmentMode
    "cache.purge",  // Cache screen, Home quick action, PurgeCacheIntent
    "workers-ci.read", "workers-ci.write",  // Worker Builds section, build screen, Cancel build
    "firewall-services.read", "firewall-services.write",  // WAF IP Access Rules
    "ssl-and-certificates.read",  // Zone Settings Edge Certificates
    "workers-routes.write",  // Worker Detail Zone Routes create/edit/delete
    "workers-observability.write",  // Worker Logs (the telemetry query accepts Write only)
  ]
  let readOnlyOperational = operational.filter {
    !$0.hasSuffix(".write") && !CachePurgeAccess.write.contains($0)
  }
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
  // No catalog feature owns a registration; its scopes come from
  // `RegistrarAccess`, never from the zone it was reached through.
  #expect(featureID(for: .registrarDomain("example.com")) == nil)
}

/// Operational destinations keep reads and mutations explicit so Demo and
/// per-control UI gating stay read-only even though real sign-in requests both.
@Test func destinationScopesSeparateReadsFromWrites() {
  #expect(requiredScopes(for: .dns("z1")).contains("dns.write"))
  #expect(requiredScopes(for: .cache("z1")).contains("zone-settings.write"))
  #expect(requiredScopes(for: .zoneSettings("z1")).contains("zone-settings.write"))
  #expect(requiredScopes(for: .zoneAnalytics("z1")).contains("analytics.read"))
  #expect(requiredScopes(for: .zoneWAF("z1")).contains("analytics.read"))
  #expect(requiredScopes(for: .auditLogs).contains("account-settings.read"))
  #expect(readScopes(for: .dns("z1")) == ["zone.read", "dns.read"])
  #expect(writeScopes(for: .dns("z1")) == ["dns.write"])
  #expect(readScopes(for: .cache("z1")) == ["zone.read", "zone-settings.read"])
  #expect(
    readScopes(for: .zoneWAF("z1"))
      == ["zone.read", "analytics.read", "zone-settings.read"])
  // Purge is gated by `CachePurgeAccess` alone: a grant without `cache.purge`
  // must not turn the Cache screen's switches read-only.
  #expect(writeScopes(for: .cache("z1")) == ["zone-settings.write"])
  #expect(writeScopes(for: .zoneAnalytics("z1")).isEmpty)
  #expect(writeScopes(for: .zoneWAF("z1")) == ["zone-settings.write"])
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
  // Workers Builds is Workers CI, not workers-scripts: the build screen must
  // ask for the scope its endpoints answer under, and Cancel build must not
  // light up on a script-write grant that cannot perform it.
  let build = Destination.workerBuild(worker: "api", buildID: "b-1")
  #expect(featureID(for: build) == .workers)
  #expect(readScopes(for: build) == ["workers-scripts.read", "workers-ci.read"])
  #expect(writeScopes(for: build) == ["workers-ci.write"])
  #expect(requiredScopes(for: build).isSubset(of: DashAuthorizationScopes.core))
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
}

@Test func featureVisualIdentityMapsStableTonesPerFeature() {
  #expect(FeatureVisualIdentity.tone(for: .zones) == .success)
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

@Test func workerConfigurationUsesExistingWorkersScopesOnly() {
  let destination = Destination.workerConfiguration("api-worker")
  #expect(featureID(for: destination) == .workers)
  #expect(readScopes(for: destination) == ["workers-scripts.read"])
  #expect(writeScopes(for: destination) == ["workers-scripts.write"])
  #expect(readScopes(for: destination).isSubset(of: DashAuthorizationScopes.core))
  #expect(writeScopes(for: destination).isSubset(of: DashAuthorizationScopes.core))
}

@Test func pagesConfigurationUsesExistingPagesScopesOnly() {
  let destination = Destination.pagesConfiguration("marketing-site")
  #expect(featureID(for: destination) == .pages)
  #expect(readScopes(for: destination) == ["page.read"])
  #expect(writeScopes(for: destination) == ["page.write"])
  #expect(readScopes(for: destination).isSubset(of: DashAuthorizationScopes.core))
  #expect(writeScopes(for: destination).isSubset(of: DashAuthorizationScopes.core))
}

@Test func ipAccessRulesSSLCertsAndWorkerRoutesScopesStayRequestableAndNonLocking() {
  let newScopes = ZoneIPAccessRulesAccess.all
    .union(ZoneSSLCertificatesAccess.read)
    .union(WorkerRoutesAccess.write)
  #expect(newScopes.isSubset(of: DashAuthorizationScopes.core))
  #expect(newScopes.isSubset(of: CloudflareScopes.requestable))
  #expect(CloudflareScopes.invalid(in: Array(newScopes)).isEmpty)
  #expect(CloudflareScopes.unsupported(in: Array(newScopes)).isEmpty)

  // Legacy grants must still open WAF, Zone Settings, and Worker Detail.
  #expect(readScopes(for: .zoneWAF("z-1")).isDisjoint(with: ZoneIPAccessRulesAccess.all))
  #expect(readScopes(for: .zoneSettings("z-1")).isDisjoint(with: ZoneSSLCertificatesAccess.read))
  #expect(writeScopes(for: .worker("api")).isDisjoint(with: WorkerRoutesAccess.write))
}

@Test func workerLogsScopesStayRequestableAndNonLocking() {
  #expect(WorkerLogsAccess.query == ["workers-observability.write"])
  #expect(WorkerLogsAccess.query.isSubset(of: DashAuthorizationScopes.core))
  #expect(!DashAuthorizationScopes.core.contains("workers-observability.read"))
  #expect(WorkerLogsAccess.query.isSubset(of: CloudflareScopes.requestable))
  #expect(CloudflareScopes.invalid(in: Array(WorkerLogsAccess.query)).isEmpty)
  #expect(CloudflareScopes.unsupported(in: Array(WorkerLogsAccess.query)).isEmpty)
  #expect(readScopes(for: .worker("api")).isDisjoint(with: WorkerLogsAccess.query))
  #expect(readScopes(for: .workerLogs("api")).isDisjoint(with: WorkerLogsAccess.query))
}
