import CloudflareAPI
import Foundation

/// Product-level OAuth profiles. The CloudflareAPI package owns the official
/// catalog; Dash owns which capabilities its mobile operations workflow asks
/// for by default.
enum DashAuthorizationScopes {
  static let coreFeatures: Set<FeatureID> = [
    .zones,
    .workers,
    .r2,
    .kv,
  ]

  /// Operational scopes used by nested screens, Watchtower, and App Intents
  /// that are not represented by a standalone FeatureID.
  ///
  /// `core` is derived from `coreFeatures`, so a scope that lives only in a
  /// feature's capability disappears from the OAuth request the moment that
  /// feature leaves the catalog — silently, and only for accounts that sign in
  /// afterwards. Anything a surviving screen calls belongs here instead.
  /// `scopesOutlivingTheirFeature` in DashTests is the guard.
  private static let coreOperations: Set<String> = [
    "zone-settings.read",
    "zone-settings.write",
    "workers-tail.read",
    "healthcheck.read",
    "load-balancing-monitors-and-pools.read",
    "registrar-domains.read",
    "dns.read",
    "dns.write",
    "cache.purge",
    "argotunnel.read",
    "notifications.read",
    "ssl-and-certificates.read",
    "account-analytics.read",
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

  static let searchResources: Set<String> = [
    "zone.read",
    "workers-scripts.read",
    "workers-r2.read",
    "workers-kv-storage.read",
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
}
