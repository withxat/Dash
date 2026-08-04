import CloudflareAPI
import Foundation

/// Product-level OAuth profiles. The CloudflareAPI package owns the official
/// catalog; Dash owns which capabilities its mobile operations workflow asks
/// for by default.
enum DashAuthorizationScopes {
  /// Features requested on every real-account sign-in. Experimental catalog
  /// features stay out of this set — they appear in Resources only after an
  /// opt-in, and their scopes are appended when the user grants that feature.
  static let coreFeatures: Set<FeatureID> = [
    .zones,
    .emailRouting,
    .workers,
    .pages,
    .r2,
    .kv,
  ]

  /// Catalog features gated behind Settings → Experimental. Not part of
  /// `core` / sign-in; enabling one only reveals the Resources row (usually
  /// locked) until the user authorizes it.
  static let experimentalFeatures: Set<FeatureID> = [
    .tunnels
  ]

  /// Read scopes used by nested screens that are not represented by a
  /// standalone FeatureID. These keep the Demo's read-only profile able to load
  /// every core catalog surface without mutation permission.
  ///
  /// Email Routing rules and destination addresses call their matching read
  /// scopes. `registrar-domains.read` is here because the zone screen's
  /// Registration card asks Cloudflare whether *this* domain is a first-party
  /// registration on every zone visit: that lookup has no row to unlock and no
  /// Grant access button of its own, so a scope requested on demand would never
  /// be requested at all and the card would silently stay on RDAP forever.
  /// Tunnels' `argotunnel.read` / `access.read` still live on that experimental
  /// feature (and its Grant access request), not here. The removed
  /// load-balancing, health-check, and SSL scopes remain absent because no
  /// current screen calls them. Do not add a scope without a screen that calls
  /// the endpoint — the sign-in sheet is the user's only view of what Dash can
  /// reach.
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
  ]

  /// Scopes requested when unlocking an experimental (or otherwise locked)
  /// feature. Tunnels list/detail need `argotunnel.read`; the positive
  /// Protected badge also needs `access.read`, so one Grant access covers both.
  static func authorizationScopes(for feature: FeatureID) -> Set<String> {
    switch feature {
    case .tunnels:
      feature.capability.read.union(["access.read"])
    default:
      feature.capability.read
    }
  }

  /// Mutating operations that are not represented by a FeatureID. They remain
  /// explicit so `core` audits the complete real-account authorization.
  /// Email Routing writes live on that feature's capability (Resources
  /// Read-only badge); its browse-only index suppresses the catalog banner via
  /// `FeatureID.showsCatalogReadOnlyBanner`. `registrar-domains.admin` is here
  /// with the read scope for the same reason: auto-renew and the transfer lock
  /// are the two things the registration screen exists to change, and it is
  /// reached by tapping one icon on a domain the user already opened — sending
  /// them back through consent to flip a switch they came for is a wall, not a
  /// safeguard. The screen keeps its `FeatureWriteAccessNotice` for grants that
  /// predate this (or were narrowed by hand).
  private static let coreWriteOperations: Set<String> = [
    "account-settings.write",
    "zone-settings.write",
    "dns.write",
    "cache.purge",
    "notifications.write",
    "registrar-domains.admin",
  ]

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
