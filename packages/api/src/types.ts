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

/** GET /user/tokens/verify */
export interface TokenVerifyResult {
	expires_on?: string
	id: string
	status: string
}

/** GET /user */
export interface CloudflareUser {
	country?: string
	created_on?: string
	email: string
	first_name?: string
	id: string
	last_name?: string
	modified_on?: string
	telephone?: string
	two_factor_authentication?: boolean
	username?: string
}

/** GET /accounts */
export interface CloudflareAccount {
	created_on?: string
	id: string
	modified_on?: string
	name: string
	type?: string
}

/** Plan attached to a zone (GET /zones, GET /zones/:id). */
export interface CloudflarePlan {
	currency?: string
	id: string
	is_subscribed?: boolean
	legacy_frequency?: string
	legacy_id?: string
	name: string
	price?: number
}

/** GET /zones, GET /zones/:id */
export interface CloudflareZone {
	account?: { id: string, name: string }
	created_on?: string
	id: string
	modified_on?: string
	name: string
	name_servers?: string[]
	original_name_servers?: string[]
	paused: boolean
	plan?: CloudflarePlan
	status: string
	type?: string
}

/** GET /zones/:zone/dns_records */
export interface DnsRecord {
	comment?: string
	content: string
	created_on?: string
	id: string
	modified_on?: string
	name: string
	proxiable?: boolean
	proxied: boolean
	ttl: number
	type: string
	zone_id: string
	zone_name: string
}

/** A single metric bucket (e.g. requests.all / requests.cached). */
export interface AnalyticsBucket {
	all?: number
	cached?: number
	caption?: string
	color?: string
	uncached?: number
}

/** Totals for a zone analytics dashboard (GET /zones/:id/analytics/dashboard). */
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

/** GET /zones/:id/analytics/dashboard result. */
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

/** Cloudflare GraphQL analytics endpoint response envelope. */
export interface GraphQLResponse<T> {
	data?: T
	errors?: Array<{ locations?: Array<{ column: number, line: number }>, message: string }>
}
