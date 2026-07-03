export type {
	AccessApplication,
	CertificatePack,
	CloudflareAccount,
	CloudflarePlan,
	CloudflareUser,
	CloudflareWorkerScript,
	CloudflareZone,
	D1Database,
	D1DatabaseSummary,
	D1QueryResult,
	DnsRecord,
	DnsRecordInput,
	EmailRoutingAddress,
	EmailRoutingRule,
	EmailRoutingSettings,
	Healthcheck,
	ImagesImage,
	IpAccessRule,
	IpAccessRuleMode,
	KvKey,
	KvNamespace,
	LoadBalancer,
	LoadBalancerPool,
	PageRule,
	PagesDeployment,
	PagesDomain,
	PagesProject,
	PurgeCacheInput,
	QueueSummary,
	R2Bucket,
	R2Object,
	RegistrarDomain,
	RumSite,
	SecretsStore,
	SecretsStoreSecret,
	StreamVideo,
	TokenVerifyResult,
	Tunnel,
	TurnstileWidget,
	UniversalSslSettings,
	VectorizeIndex,
	WaitingRoom,
	WorkerDeployment,
	WorkerDomain,
	WorkerRoute,
	WorkerScriptSettings,
	WorkerSubdomainStatus,
	ZoneSetting,
} from './sdk-types'

/** Cloudflare API v4 response envelope. */
export interface ApiResult<T> {
	errors: Array<{ code: number, message: string }>
	messages: Array<{ code: number, message: string }>
	result: T
	success: boolean
}

export interface ResultInfo {
	count: number
	page: number
	per_page: number
	total_count: number
}

export interface Paginated<T> {
	errors: Array<{ code: number, message: string }>
	messages: Array<{ code: number, message: string }>
	result: T[]
	result_info: ResultInfo
	success: boolean
}

/** A list page: the items plus the pagination metadata. */
export interface Page<T> {
	items: T[]
	resultInfo: ResultInfo
}

/** A cursor-paginated list page (KV keys, R2 objects). */
export interface CursorPage<T> {
	/** Pass to the next call to fetch the following page; absent on the last page. */
	cursor?: string
	items: T[]
}

/** One daily Web Analytics point (GraphQL / RUM — not in the REST SDK). */
export interface WebAnalyticsPoint {
	date?: string
	pageViews?: number
	visits?: number
}

/** Aggregated Web Analytics: per-day points + totals. */
export interface WebAnalyticsResult {
	points: WebAnalyticsPoint[]
	totals: { pageViews?: number, visits?: number }
}

/** A single metric bucket (e.g. requests.all / requests.cached). */
export interface AnalyticsBucket {
	all?: number
	cached?: number
	caption?: string
	color?: string
	uncached?: number
}

/** Totals for zone HTTP analytics (GraphQL httpRequests1h/1d groups). */
export interface ZoneAnalyticsTotal {
	bandwidth?: AnalyticsBucket
	cache_status?: Record<string, number>
	page_load_time?: AnalyticsBucket
	requests?: AnalyticsBucket
	threats?: AnalyticsBucket
	unique?: AnalyticsBucket
}

/** One timeseries bucket. */
export interface ZoneAnalyticsPoint {
	bandwidth?: AnalyticsBucket
	requests?: AnalyticsBucket
	since: string
	threats?: AnalyticsBucket
	unique?: AnalyticsBucket
	until: string
}

/** Zone HTTP analytics timeseries + totals (GraphQL). */
export interface ZoneAnalyticsDashboard {
	timeseries: ZoneAnalyticsPoint[]
	totals: ZoneAnalyticsTotal
}

/** Aggregated metric sum for an account over a range (GraphQL analytics). */
export interface AccountAnalyticsSum {
	bandwidth?: number
	cachedRequests?: number
	pageViews?: number
	requests?: number
	threats?: number
}

/** One daily analytics point for an account. */
export interface AccountAnalyticsPoint {
	date?: string
	sum: AccountAnalyticsSum
}

/** Aggregated account analytics: per-day points + a totals roll-up. */
export interface AccountAnalyticsResult {
	points: AccountAnalyticsPoint[]
	totals: AccountAnalyticsSum
}

/** One firewall event (GraphQL `firewallEventsAdaptive`). */
export interface FirewallEvent {
	/** Mitigation action taken, e.g. `block`, `challenge`, `managed_challenge`, `log`. */
	action: string
	clientAsn?: string
	clientASNDescription?: string
	clientCountryName?: string
	clientIP?: string
	clientRequestHTTPHost?: string
	clientRequestHTTPMethodName?: string
	clientRequestHTTPProtocol?: string
	clientRequestPath?: string
	clientRequestQuery?: string
	/** ISO 8601 timestamp of the event. */
	datetime: string
	/** Cloudflare Ray ID of the request. */
	rayName?: string
	/** Identifier of the rule that matched. */
	ruleId?: string
	/** Which product produced the event, e.g. `waf`, `firewallrules`, `ratelimit`. */
	source?: string
	userAgent?: string
}

/** Cloudflare GraphQL analytics endpoint response envelope. */
export interface GraphQLResponse<T> {
	data?: T
	errors?: Array<{ locations?: Array<{ column: number, line: number }>, message: string }>
}

/** A member of an account (GET /accounts/:id/members). */
export interface AccountMember {
	id: string
	roles?: Array<{ description?: string, id?: string, name?: string }>
	/** `accepted` for active members, `pending` for open invitations. */
	status?: string
	user?: {
		email?: string
		first_name?: null | string
		id?: string
		last_name?: null | string
		two_factor_authentication_enabled?: boolean
	}
}

/** A notification policy (GET /accounts/:id/alerting/v3/policies). */
export interface NotificationPolicy {
	/** Which event triggers the notification, e.g. `universal_ssl_event_type`. */
	alert_type?: string
	description?: string
	enabled?: boolean
	id?: string
	/** Delivery destinations configured for the policy. */
	mechanisms?: {
		email?: Array<{ id?: string }>
		pagerduty?: Array<{ id?: string }>
		webhooks?: Array<{ id?: string }>
	}
	modified?: string
	name?: string
}

/** One dispatched notification (GET /accounts/:id/alerting/v3/history). */
export interface NotificationHistoryEntry {
	alert_body?: string
	alert_type?: string
	description?: string
	id?: string
	/** Destination the notification went to, e.g. an email address. */
	mechanism?: string
	mechanism_type?: 'email' | 'pagerduty' | 'webhook' | ({} & string)
	/** Name of the policy that fired. */
	name?: string
	policy_id?: string
	/** ISO 8601 timestamp of dispatch. */
	sent?: string
}

/**
 * One Workers Builds run (GET /accounts/:id/builds/workers/:tag/builds).
 * Not covered by the `cloudflare` SDK yet, so typed by hand from the API docs.
 */
export interface WorkersBuild {
	build_outcome?: 'canceled' | 'fail' | 'skipped' | 'success' | ({} & string)
	build_trigger_metadata?: {
		author?: string
		branch?: string
		build_command?: string
		commit_hash?: string
		commit_message?: string
		provider_type?: string
		repo_name?: string
		trigger_name?: string
	}
	build_uuid?: string
	created_on?: string
	initializing_on?: string
	modified_on?: string
	running_on?: string
	status?: 'initializing' | 'queued' | 'running' | 'stopped' | ({} & string)
	stopped_on?: string
}

/**
 * One Workers Logs telemetry event
 * (POST /accounts/:id/workers/observability/telemetry/query, view `events`).
 * Slimmed down from the SDK's deeply nested response type.
 */
export interface WorkersTelemetryEvent {
	$metadata: {
		error?: string
		id?: string
		level?: string
		message?: string
		service?: string
		trigger?: string
	}
	dataset?: string
	/** Raw log payload — a string or a structured object. */
	source?: Record<string, unknown> | string
	/** Unix epoch in milliseconds. */
	timestamp: number
}

/**
 * A WAF custom rule inside the zone entrypoint ruleset
 * (GET /zones/:zone/rulesets/phases/http_request_firewall_custom/entrypoint).
 * The SDK models rules as a large discriminated union; the app only needs
 * these common fields.
 */
export interface WafCustomRule {
	action?: string
	description?: string
	enabled?: boolean
	expression?: string
	id?: string
	last_updated?: string
}

/** The zone WAF custom-rules entrypoint ruleset. */
export interface WafEntrypointRuleset {
	description?: string
	id?: string
	last_updated?: string
	name?: string
	phase?: string
	rules?: WafCustomRule[]
}

/** One account audit log entry (GET /accounts/:id/audit_logs). */
export interface AuditLogEntry {
	action?: { result?: boolean, type?: string }
	actor?: { email?: string, id?: string, ip?: string, type?: string }
	id?: string
	/** Extra context, e.g. the zone name the action applied to. */
	metadata?: Record<string, unknown>
	newValue?: string
	oldValue?: string
	resource?: { id?: string, type?: string }
	/** ISO 8601 timestamp of the action. */
	when?: string
}
