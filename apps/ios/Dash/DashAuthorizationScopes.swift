import CloudflareAPI
import Foundation

/// Product-level OAuth profiles. The CloudflareAPI package owns the official
/// catalog; Dash owns which capabilities its mobile operations workflow asks
/// for by default.
enum DashAuthorizationScopes {
  static let experimentalFeatures: Set<FeatureID> = [
    .workersAI, .browserRendering, .images, .stream,
  ]

  static let coreFeatures: Set<FeatureID> = [
    .zones,
    .dnsManagement,
    .workers,
    .r2,
    .kv,
    .d1,
    .queues,
    .accessApps,
    .accessGroups,
    .accessPolicies,
    .serviceTokens,
    .tunnels,
    .sslCertificates,
    .cacheSettings,
    .analytics,
    .account,
  ]

  /// Operational scopes used by nested screens, Watchtower, and App Intents
  /// that are not represented by a standalone FeatureID.
  private static let coreOperations: Set<String> = [
    "zone-settings.read",
    "zone-settings.write",
    "workers-tail.read",
    "healthcheck.read",
    "load-balancing-monitors-and-pools.read",
    "registrar-domains.read",
  ]

  static let core: Set<String> = {
    let capabilities = coreFeatures.reduce(into: Set<String>()) {
      $0.formUnion($1.capability.all)
    }
    return
      capabilities
      .union(coreOperations)
      .union(CloudflareScopes.required)
  }()

  static let experimental: Set<String> = [
    "ai.read",
    "ai.write",
    "browser-rendering.read",
    "browser-rendering.write",
    "images.read",
    "images.write",
    "stream.read",
    "stream.write",
  ]

  static let searchResources: Set<String> = [
    "zone.read",
    "workers-scripts.read",
    "workers-r2.read",
    "workers-kv-storage.read",
    "d1.read",
  ]

  static let watchtower: Set<String> = [
    "zone.read",
    "argotunnel.read",
    "load-balancing-monitors-and-pools.read",
    "registrar-domains.read",
    "page.read",
    "notifications.read",
    "ssl-and-certificates.read",
    "healthcheck.read",
  ]

  static func initial(experimentalEnabled: Bool) -> Set<String> {
    experimentalEnabled ? core.union(experimental) : core
  }

  static func isVisible(
    _ feature: FeatureID,
    experimentalEnabled: Bool
  ) -> Bool {
    experimentalEnabled || !experimentalFeatures.contains(feature)
  }
}
