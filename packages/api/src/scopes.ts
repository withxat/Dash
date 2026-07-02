/**
 * Cloudflare OAuth 2.0 scopes.
 *
 * Third-party OAuth clients must request scopes as **dot-delimited** strings
 * (e.g. `account.read`, `dns.edit`). Colon-delimited scopes (`account:read`)
 * are only valid for the Wrangler CLI and are rejected by the third-party
 * OAuth API.
 *
 * Scope names map 1:1 to Cloudflare API token permission names. The full list
 * is discoverable via the "List OAuth Scopes" API:
 * https://developers.cloudflare.com/api/resources/iam/subresources/oauth_scopes/methods/list/
 */

/** Read the authenticated user's profile (GET /user). */
export const SCOPE_USER_READ = 'user.read' as const
/** List and view accounts the user can access (GET /accounts). */
export const SCOPE_ACCOUNT_READ = 'account.read' as const
/** List and view zones (GET /zones). */
export const SCOPE_ZONE_READ = 'zone.read' as const
/** Read zone DNS records (GET /zones/:zone/dns_records). */
export const SCOPE_DNS_READ = 'dns.read' as const
/** Create/edit/delete zone DNS records. */
export const SCOPE_DNS_EDIT = 'dns.edit' as const
/** Read Cloudflare Workers scripts and configuration. */
export const SCOPE_WORKERS_READ = 'workers.read' as const
/** Deploy and manage Cloudflare Workers scripts. */
export const SCOPE_WORKERS_EDIT = 'workers.edit' as const
/** Read account billing/subscription state. */
export const SCOPE_BILLING_READ = 'billing.read' as const
/** Read Cloudflare analytics (zone dashboard + GraphQL analytics). */
export const SCOPE_ANALYTICS_READ = 'analytics.read' as const

/**
 * A sensible default scope set for a personal Cloudflare client: enough to
 * browse accounts, zones and DNS, and to verify the token. Widen this in the
 * app config as more features land.
 */
export const DEFAULT_CLOUDFLARE_SCOPES = [
	SCOPE_USER_READ,
	SCOPE_ACCOUNT_READ,
	SCOPE_ZONE_READ,
	SCOPE_DNS_READ,
	SCOPE_ANALYTICS_READ,
] as const

export type CloudflareScope = (typeof DEFAULT_CLOUDFLARE_SCOPES)[number] | string
