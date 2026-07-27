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

  /// Read scopes used by nested screens that are not represented by a
  /// standalone FeatureID. These ship in the first OAuth grant so every catalog
  /// surface can load without giving Dash permission to mutate the account.
  ///
  /// Watchtower's client-side health checks are gone, and with them the reasons
  /// to ask for `argotunnel.read`, `load-balancing-monitors-and-pools.read`,
  /// `registrar-domains.read`, `healthcheck.read` and
  /// `ssl-and-certificates.read`. Do not add a scope back without a screen that
  /// calls the endpoint — the sign-in sheet is the user's only view of what Dash
  /// can reach.
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
  ]

  /// Mutating operations that are not represented by a FeatureID. They are
  /// requested incrementally from the concrete action that needs them.
  private static let coreWriteOperations: Set<String> = [
    "account-settings.write",
    "zone-settings.write",
    "dns.write",
    "cache.purge",
    "notifications.write",
  ]

  /// Mutations exposed outside Dash's normal feature screens. App Intents and
  /// the share extension cannot safely present OAuth themselves, so Settings
  /// offers one explicit incremental grant for this reviewed set.
  static let shortcutsAndShareWrites: Set<String> = Set([
    "zone-settings.write",
    "cache.purge",
  ]).union(R2ShareDestination.requiredWriteScopes)

  /// The first OAuth grant: enough to identify the user and browse every
  /// shipped resource, but never enough to change the account.
  static let initialReadOnly: Set<String> = {
    let reads = coreFeatures.reduce(into: Set<String>()) {
      $0.formUnion($1.capability.read)
    }
    return
      reads
      .union(coreReadOperations)
      .union(CloudflareScopes.required)
  }()

  /// Full app capability, retained as the explicit "grant everything Dash can
  /// currently do" set and as a release-gate audit surface. It is not requested
  /// during first sign-in.
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
