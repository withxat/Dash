import CloudflareAPI
import Foundation

/// Product-level OAuth profiles. The CloudflareAPI package owns the official
/// catalog; Dash owns which capabilities its mobile operations workflow asks
/// for by default.
enum DashAuthorizationScopes {
  static let coreFeatures: Set<FeatureID> = [
    .zones,
    .workers,
    .pages,
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
    "healthcheck.read",
    "load-balancing-monitors-and-pools.read",
    "registrar-domains.read",
    "dns.read",
    "dns.write",
    "cache.purge",
    "workers-routes.read",
    "argotunnel.read",
    "notifications.read",
    "notifications.write",
    "ssl-and-certificates.read",
    "account-analytics.read",
    "analytics.read",
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

  /// Zone HTTP Traffic Analytics is separate from account-level analytics.
  static let zoneAnalytics: Set<String> = ["zone.read", "analytics.read"]

  /// Account overview tiles + series on Watchtower
  /// (`httpRequestsOverviewAdaptiveGroups` / `workersInvocationsAdaptive`).
  static let accountAnalytics: Set<String> = [
    "account-analytics.read",
    "analytics.read",
  ]

  /// Web Analytics (RUM) lives on the account: both the site list and the
  /// `rum*` GraphQL datasets answer under `account-analytics.read`. Cloudflare
  /// publishes no OAuth scope for Web Analytics writes, so Dash reads only.
  static let webAnalytics: Set<String> = ["zone.read", "account-analytics.read"]

  static let watchtower: Set<String> = Set([
    "argotunnel.read",
    "load-balancing-monitors-and-pools.read",
    "registrar-domains.read",
    "page.read",
    "notifications.read",
    "ssl-and-certificates.read",
    "healthcheck.read",
  ]).union(zoneAnalytics).union(accountAnalytics)
}
