/**
 * Cloudflare OAuth 2.0 scopes.
 *
 * Third-party OAuth clients must request the exact scope IDs assigned to the
 * client (e.g. `account-settings.read`, `dns.read`). Colon-delimited scopes
 * (`account:read`) are rejected by the third-party OAuth API.
 *
 * Every ID below was verified against the "List OAuth Scopes" API
 * (`GET /oauth/scopes`) — the full snapshot lives in
 * `packages/api/scopes-reference.json`:
 * https://developers.cloudflare.com/api/resources/iam/subresources/oauth_scopes/methods/list/
 *
 * Notable gotchas discovered from that list:
 * - Write scopes use the `.write` suffix (`dns.write`), never `.edit`.
 * - There is no `billing.read` scope; subscriptions ride on
 *   `account-settings.read` (with graceful 403 degradation in the app).
 * - There is no blanket `workers.read`/`workers.edit`; Workers permissions
 *   are fine-grained per product (Scripts, Routes, KV Storage, R2 Storage,
 *   CI, Observability…).
 * - Cache purge is its own verb: `cache.purge`.
 * - R2 splits bucket-level (`workers-r2.*`) from object-level
 *   (`workers-r2-bucket-item.*`) access.
 */

/** Read the authenticated user's profile (GET /user). */
export const SCOPE_USER_READ = 'user-details.read' as const
/**
 * List and view accounts the user can access (GET /accounts). In practice
 * (verified against the live API) this also covers account membership
 * (GET /accounts/:id/members), subscriptions and account audit logs — none of
 * which have a dedicated OAuth scope.
 */
export const SCOPE_ACCOUNT_READ = 'account-settings.read' as const
/**
 * Read account notification policies and dispatch history
 * (GET /accounts/:id/alerting/v3/policies, …/history).
 */
export const SCOPE_NOTIFICATIONS_READ = 'notifications.read' as const
/** List and view zones (GET /zones). */
export const SCOPE_ZONE_READ = 'zone.read' as const
/** Read zone DNS records (GET /zones/:zone/dns_records). */
export const SCOPE_DNS_READ = 'dns.read' as const
/** Create/edit/delete zone DNS records. */
export const SCOPE_DNS_WRITE = 'dns.write' as const
/** Purge a zone's edge cache (POST /zones/:zone/purge_cache). */
export const SCOPE_CACHE_PURGE = 'cache.purge' as const
/** Read zone settings (GET /zones/:zone/settings). */
export const SCOPE_ZONE_SETTINGS_READ = 'zone-settings.read' as const
/** Edit zone settings (PATCH /zones/:zone/settings/:setting). */
export const SCOPE_ZONE_SETTINGS_WRITE = 'zone-settings.write' as const
/** Read Workers scripts, settings, deployments and source content. */
export const SCOPE_WORKERS_SCRIPTS_READ = 'workers-scripts.read' as const
/** Manage Workers scripts (e.g. toggle the workers.dev subdomain). */
export const SCOPE_WORKERS_SCRIPTS_WRITE = 'workers-scripts.write' as const
/** Read Workers routes and custom domains. */
export const SCOPE_WORKERS_ROUTES_READ = 'workers-routes.read' as const
/** Create/delete Workers routes. */
export const SCOPE_WORKERS_ROUTES_WRITE = 'workers-routes.write' as const
/** Read Workers Builds history (GET /accounts/:id/builds/…). */
export const SCOPE_WORKERS_CI_READ = 'workers-ci.read' as const
/** Query Workers Logs / observability telemetry (POST …/workers/observability/telemetry/query). */
export const SCOPE_WORKERS_OBSERVABILITY_READ = 'workers-observability.read' as const
/** Read Workers KV namespaces, keys and values. */
export const SCOPE_KV_READ = 'workers-kv-storage.read' as const
/** Write/delete Workers KV keys and values. */
export const SCOPE_KV_WRITE = 'workers-kv-storage.write' as const
/** List R2 buckets. */
export const SCOPE_R2_READ = 'workers-r2.read' as const
/** Create/delete R2 buckets. */
export const SCOPE_R2_WRITE = 'workers-r2.write' as const
/** List and read R2 objects within a bucket. */
export const SCOPE_R2_ITEM_READ = 'workers-r2-bucket-item.read' as const
/** Upload and delete R2 objects. */
export const SCOPE_R2_ITEM_WRITE = 'workers-r2-bucket-item.write' as const
/** List D1 databases and run queries (GET/POST /accounts/:id/d1/database…). */
export const SCOPE_D1_READ = 'd1.read' as const
/** List Queues with producers/consumers (GET /accounts/:id/queues). */
export const SCOPE_QUEUES_READ = 'queues.read' as const
/** Modify Queues — used only for purging a queue's backlog. */
export const SCOPE_QUEUES_WRITE = 'queues.write' as const
/** List Secrets Store stores and secret names (values are never readable). */
export const SCOPE_SECRETS_STORE_READ = 'secrets-store.read' as const
/** List Vectorize indexes (GET /accounts/:id/vectorize/v2/indexes). */
export const SCOPE_VECTORIZE_READ = 'vectorize.read' as const
/** Read Cloudflare Pages projects and deployments. */
export const SCOPE_PAGES_READ = 'page.read' as const
/** Manage Cloudflare Pages projects: retry/rollback deployments, domains. */
export const SCOPE_PAGES_WRITE = 'page.write' as const
/** Read zone analytics dashboard data. */
export const SCOPE_ANALYTICS_READ = 'analytics.read' as const
/** Read account-level GraphQL analytics data (incl. Web Analytics/RUM). */
export const SCOPE_ACCOUNT_ANALYTICS_READ = 'account-analytics.read' as const
/** Read SSL certificate packs and Universal SSL settings. */
export const SCOPE_SSL_READ = 'ssl-and-certificates.read' as const
/** Read IP Access Rules (GET /zones/:zone/firewall/access_rules/rules). */
export const SCOPE_FIREWALL_READ = 'firewall-services.read' as const
/** Create/delete IP Access Rules (block/challenge/whitelist an IP). */
export const SCOPE_FIREWALL_WRITE = 'firewall-services.write' as const
/** Read a zone's WAF custom rules (rulesets phase http_request_firewall_custom). */
export const SCOPE_WAF_READ = 'zone-waf.read' as const
/** Enable/disable a zone's WAF custom rules. */
export const SCOPE_WAF_WRITE = 'zone-waf.write' as const
/** List Turnstile widgets (GET /accounts/:id/challenges/widgets). */
export const SCOPE_TURNSTILE_READ = 'challenge-widgets.read' as const
/** Manage Turnstile widgets — used for rotating a widget secret. */
export const SCOPE_TURNSTILE_WRITE = 'challenge-widgets.write' as const
/** Read zone healthchecks (GET /zones/:zone/healthchecks). */
export const SCOPE_HEALTHCHECKS_READ = 'healthcheck.read' as const
/** Read zone waiting rooms (GET /zones/:zone/waiting_rooms). */
export const SCOPE_WAITING_ROOMS_READ = 'waiting-rooms.read' as const
/** Read zone load balancers (GET /zones/:zone/load_balancers). */
export const SCOPE_LOAD_BALANCERS_READ = 'load-balancers.read' as const
/** Read account load balancer monitors and origin pools. */
export const SCOPE_LB_POOLS_READ = 'load-balancing-monitors-and-pools.read' as const
/** Read zone page rules (GET /zones/:zone/pagerules). */
export const SCOPE_PAGE_RULES_READ = 'page-rules.read' as const
/** Read zone Email Routing rules (GET /zones/:zone/email/routing/rules). */
export const SCOPE_EMAIL_RULE_READ = 'email-routing-rule.read' as const
/** Enable/disable zone Email Routing rules. */
export const SCOPE_EMAIL_RULE_WRITE = 'email-routing-rule.write' as const
/** Read account Email Routing destination addresses. */
export const SCOPE_EMAIL_ADDRESS_READ = 'email-routing-address.read' as const
/** Add/remove account Email Routing destination addresses. */
export const SCOPE_EMAIL_ADDRESS_WRITE = 'email-routing-address.write' as const
/** List Registrar domains with expiry/auto-renew status. */
export const SCOPE_REGISTRAR_READ = 'registrar-domains.read' as const
/** List Cloudflare Tunnels with health and connections (GET /accounts/:id/cfd_tunnel). */
export const SCOPE_TUNNELS_READ = 'argotunnel.read' as const
/** List Zero Trust Access applications (GET /accounts/:id/access/apps). */
export const SCOPE_ACCESS_APPS_READ = 'access-app.read' as const
/** Browse Cloudflare Images (GET /accounts/:id/images/v1). */
export const SCOPE_IMAGES_READ = 'images.read' as const
/** Browse Stream videos (GET /accounts/:id/stream). */
export const SCOPE_STREAM_READ = 'stream.read' as const
/** Request a refresh token for long-lived sessions. */
export const SCOPE_OFFLINE_ACCESS = 'offline_access' as const

/**
 * Default scopes requested at login. Covers browsing accounts/zones/DNS,
 * editing DNS, purging cache, toggling zone settings, the Workers platform
 * (scripts/routes/KV/R2/D1/Queues/CI/logs/secrets/Vectorize), zone security
 * (SSL/IP rules/WAF/healthchecks/waiting rooms/load balancers/page rules),
 * Turnstile, Email Routing, notifications, Registrar, Tunnels, Access apps,
 * Images/Stream, and analytics. Every scope listed here must also be enabled
 * on the OAuth client in the Cloudflare dashboard, or the authorize step
 * fails. Existing sessions must sign out/in to pick up newly added scopes.
 */
export const DEFAULT_CLOUDFLARE_SCOPES = [
	SCOPE_USER_READ,
	SCOPE_ACCOUNT_READ,
	SCOPE_NOTIFICATIONS_READ,
	SCOPE_ZONE_READ,
	SCOPE_DNS_READ,
	SCOPE_DNS_WRITE,
	SCOPE_CACHE_PURGE,
	SCOPE_ZONE_SETTINGS_READ,
	SCOPE_ZONE_SETTINGS_WRITE,
	SCOPE_WORKERS_SCRIPTS_READ,
	SCOPE_WORKERS_SCRIPTS_WRITE,
	SCOPE_WORKERS_ROUTES_READ,
	SCOPE_WORKERS_ROUTES_WRITE,
	SCOPE_WORKERS_CI_READ,
	SCOPE_WORKERS_OBSERVABILITY_READ,
	SCOPE_KV_READ,
	SCOPE_KV_WRITE,
	SCOPE_R2_READ,
	SCOPE_R2_WRITE,
	SCOPE_R2_ITEM_READ,
	SCOPE_R2_ITEM_WRITE,
	SCOPE_D1_READ,
	SCOPE_QUEUES_READ,
	SCOPE_QUEUES_WRITE,
	SCOPE_SECRETS_STORE_READ,
	SCOPE_VECTORIZE_READ,
	SCOPE_PAGES_READ,
	SCOPE_PAGES_WRITE,
	SCOPE_ANALYTICS_READ,
	SCOPE_ACCOUNT_ANALYTICS_READ,
	SCOPE_SSL_READ,
	SCOPE_FIREWALL_READ,
	SCOPE_FIREWALL_WRITE,
	SCOPE_WAF_READ,
	SCOPE_WAF_WRITE,
	SCOPE_TURNSTILE_READ,
	SCOPE_TURNSTILE_WRITE,
	SCOPE_HEALTHCHECKS_READ,
	SCOPE_WAITING_ROOMS_READ,
	SCOPE_LOAD_BALANCERS_READ,
	SCOPE_LB_POOLS_READ,
	SCOPE_PAGE_RULES_READ,
	SCOPE_EMAIL_RULE_READ,
	SCOPE_EMAIL_RULE_WRITE,
	SCOPE_EMAIL_ADDRESS_READ,
	SCOPE_EMAIL_ADDRESS_WRITE,
	SCOPE_REGISTRAR_READ,
	SCOPE_TUNNELS_READ,
	SCOPE_ACCESS_APPS_READ,
	SCOPE_IMAGES_READ,
	SCOPE_STREAM_READ,
	SCOPE_OFFLINE_ACCESS,
] as const

export type CloudflareScope = (typeof DEFAULT_CLOUDFLARE_SCOPES)[number] | string
