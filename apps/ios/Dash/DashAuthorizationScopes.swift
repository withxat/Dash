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
    .tunnels,
  ]

  /// Read scopes used by nested screens that are not represented by a
  /// standalone FeatureID. These keep the Demo's read-only profile able to load
  /// every catalog surface without mutation permission.
  ///
  /// Tunnels list/detail calls `argotunnel.read`; its positive Protected badge
  /// calls `access.read`; Registrar list/detail calls
  /// `registrar-domains.read`. Email Routing rules and destination addresses
  /// call their matching read scopes. The removed load-balancing, health-check,
  /// and SSL scopes remain absent because no current screen calls them. Do not
  /// add a scope without a screen that calls the endpoint — the sign-in sheet
  /// is the user's only view of what Dash can reach.
  ///
  /// `initialReadOnly` is derived from `coreFeatures`, so a read scope that
  /// lives only in a feature's capability disappears from the OAuth request
  /// when that feature leaves the catalog. Anything a surviving read surface
  /// calls belongs here instead.
  private static let coreReadOperations: Set<String> = [
    "zone-settings.read",
    "dns.read",
    "workers-routes.read",
    "notifications.read",
    "account-analytics.read",
    "analytics.read",
    "email-routing-rule.read",
    "email-routing-address.read",
    "registrar-domains.read",
    "access.read",
  ]

  /// Mutating operations that are not represented by a FeatureID. They remain
  /// explicit so `core` audits the complete real-account authorization.
  private static let coreWriteOperations: Set<String> = [
    "account-settings.write",
    "zone-settings.write",
    "dns.write",
    "cache.purge",
    "notifications.write",
    "email-routing-rule.write",
    "email-routing-address.write",
    "registrar-domains.admin",
  ]

  /// Mutations exposed outside Dash's normal feature screens. App Intents and
  /// the share extension cannot safely present OAuth themselves, so Settings
  /// checks this subset to explain whether those actions are ready. Any
  /// reauthorization still requests `core` in one reviewed grant.
  static let shortcutsAndShareWrites: Set<String> = Set([
    "zone-settings.write",
    "cache.purge",
  ]).union(R2ShareDestination.requiredWriteScopes)

  /// Read-only profile retained for Demo and capability-gating tests.
  /// Real-account authorization uses `core`.
  static let initialReadOnly: Set<String> = {
    let reads = coreFeatures.reduce(into: Set<String>()) {
      $0.formUnion($1.capability.read)
    }
    return
      reads
      .union(coreReadOperations)
      .union(CloudflareScopes.required)
  }()

  /// Full app capability and the default real-account OAuth grant. This remains
  /// the release-gate audit surface for everything Dash can currently do.
  static let core: Set<String> = {
    let capabilities = coreFeatures.reduce(into: Set<String>()) {
      $0.formUnion($1.capability.all)
    }
    return
      capabilities
      .union(coreReadOperations)
      .union(coreWriteOperations)
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

  /// Web Analytics (RUM) spans two Cloudflare permissions, and the two calls the
  /// screen makes answer under different ones: the REST site list
  /// (`/accounts/{id}/rum/site_info/list`, which maps a zone to its `siteTag`)
  /// is gated by **Account Settings Read** (`account-settings.read`), while the
  /// `rum*` GraphQL datasets are gated by **Account Analytics Read**
  /// (`account-analytics.read`). Requesting only the analytics scope 403s the
  /// site list — the original cause of "no access to this resource". Cloudflare
  /// publishes no OAuth scope for Web Analytics writes, so Dash reads only.
  static let webAnalytics: Set<String> = [
    "zone.read", "account-analytics.read", "account-settings.read",
  ]

  /// The Watchtower tab: Cloudflare's notification deliveries plus the account
  /// traffic charts. No health-check scopes — Dash no longer computes health.
  static let watchtower: Set<String> = Set([
    "notifications.read"
  ]).union(zoneAnalytics).union(accountAnalytics)
}
