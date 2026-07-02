import type { OAuthEndpoints, TokenSet } from './oauth'
import type {
	AccountAnalyticsPoint,
	AccountAnalyticsResult,
	AccountAnalyticsSum,
	ApiResult,
	CloudflareAccount,
	CloudflareUser,
	CloudflareZone,
	DnsRecord,
	GraphQLResponse,
	Page,
	Paginated,
	TokenVerifyResult,
	ZoneAnalyticsDashboard,
} from './types'

import { ApiError } from './errors'
import { CLOUDFLARE_API_BASE, CLOUDFLARE_OAUTH_ENDPOINTS, refreshAccessToken } from './oauth'

export { ApiError }
export type { TokenSet } from './oauth'

/** Storage-agnostic token access the client needs. Implement over SecureStore (RN) or similar. */
export interface TokenStore {
	clear: () => Promise<void>
	getAccessToken: () => Promise<null | string>
	getRefreshToken: () => Promise<null | string>
	setTokens: (tokens: TokenSet) => Promise<void>
}

export interface CloudflareClientConfig {
	apiBase?: string
	/** OAuth client id — required to refresh tokens. */
	clientId: string
	endpoints?: Partial<OAuthEndpoints>
	tokenStore: TokenStore
}

export class CloudflareClient {
	private readonly clientId: string
	private readonly tokenStore: TokenStore
	private readonly endpoints: OAuthEndpoints
	private readonly apiBase: string
	private refreshing: null | Promise<null | TokenSet> = null

	constructor(config: CloudflareClientConfig) {
		this.clientId = config.clientId
		this.tokenStore = config.tokenStore
		this.endpoints = { ...CLOUDFLARE_OAUTH_ENDPOINTS, ...config.endpoints }
		this.apiBase = config.apiBase ?? CLOUDFLARE_API_BASE
	}

	/**
	 * Exchange the refresh token for a fresh access token. Concurrent callers share
	 * a single in-flight refresh so a burst of 401s doesn't hammer the endpoint.
	 */
	private refresh(): Promise<null | TokenSet> {
		if (this.refreshing)
			return this.refreshing
		const p = (async () => {
			const refreshToken = await this.tokenStore.getRefreshToken()
			if (!refreshToken)
				return null
			const tokens = await refreshAccessToken({
				clientId: this.clientId,
				endpoints: this.endpoints,
				refreshToken,
			})
			await this.tokenStore.setTokens(tokens)
			return tokens
		})()
		this.refreshing = p
		void p.finally(() => {
			this.refreshing = null
		})
		return p
	}

	private async doFetch(path: string, init?: RequestInit, attempt = 0): Promise<Response> {
		const token = await this.tokenStore.getAccessToken()
		const res = await fetch(`${this.apiBase}${path}`, {
			...init,
			headers: {
				'Content-Type': 'application/json',
				...(token ? { Authorization: `Bearer ${token}` } : {}),
				...init?.headers,
			},
		})
		if (res.status === 401 && attempt === 0) {
			const refreshed = await this.refresh()
			if (refreshed)
				return this.doFetch(path, init, attempt + 1)
		}
		return res
	}

	private async request<T>(path: string, init?: RequestInit): Promise<ApiResult<T>> {
		const res = await this.doFetch(path, init)
		const data = (await res.json().catch(() => null)) as ApiResult<T> | null
		if (!res.ok || !data?.success) {
			const errors = data?.errors ?? [{ code: res.status, message: `HTTP ${res.status}` }]
			throw new ApiError(res.status, errors)
		}
		return data
	}

	private async requestList<T>(path: string, init?: RequestInit): Promise<Page<T>> {
		const res = await this.doFetch(path, init)
		const data = (await res.json().catch(() => null)) as null | Paginated<T>
		if (!res.ok || !data?.success) {
			const errors = data?.errors ?? [{ code: res.status, message: `HTTP ${res.status}` }]
			throw new ApiError(res.status, errors)
		}
		return { items: data.result, resultInfo: data.result_info }
	}

	/** Verify the current access token is valid (GET /user/tokens/verify). */
	verifyToken(): Promise<TokenVerifyResult> {
		return this.request<TokenVerifyResult>('/user/tokens/verify').then(r => r.result)
	}

	/** Get the authenticated user's profile (GET /user). */
	getUser(): Promise<CloudflareUser> {
		return this.request<CloudflareUser>('/user').then(r => r.result)
	}

	/** List accounts the user can access (GET /accounts). */
	listAccounts(): Promise<CloudflareAccount[]> {
		return this.requestList<CloudflareAccount>('/accounts').then(p => p.items)
	}

	/** List zones, optionally filtered by name or account id (GET /zones). */
	listZones(params?: {
		accountId?: string
		name?: string
		page?: number
		perPage?: number
	}): Promise<Page<CloudflareZone>> {
		const query = new URLSearchParams()
		if (params?.name)
			query.set('name', params.name)
		if (params?.accountId)
			query.set('account.id', params.accountId)
		if (params?.perPage)
			query.set('per_page', String(params.perPage))
		if (params?.page)
			query.set('page', String(params.page))
		const qs = query.toString()
		return this.requestList<CloudflareZone>(`/zones${qs ? `?${qs}` : ''}`)
	}

	/** Get a single zone's details (GET /zones/:id). */
	getZone(zoneId: string): Promise<CloudflareZone> {
		return this.request<CloudflareZone>(`/zones/${zoneId}`).then(r => r.result)
	}

	/** List DNS records for a zone (GET /zones/:zone/dns_records). */
	listDnsRecords(zoneId: string, params?: {
		page?: number
		perPage?: number
		type?: string
	}): Promise<Page<DnsRecord>> {
		const query = new URLSearchParams()
		if (params?.type)
			query.set('type', params.type)
		if (params?.perPage)
			query.set('per_page', String(params.perPage))
		if (params?.page)
			query.set('page', String(params.page))
		const qs = query.toString()
		return this.requestList<DnsRecord>(`/zones/${zoneId}/dns_records${qs ? `?${qs}` : ''}`)
	}

	/**
	 * Zone analytics dashboard (GET /zones/:id/analytics/dashboard). `since` and
	 * `until` are ISO 8601 timestamps; timeseries buckets are auto-sized to the
	 * range. Requires the `analytics.read` scope.
	 */
	getZoneAnalytics(zoneId: string, params: { since: string, until: string }): Promise<ZoneAnalyticsDashboard> {
		const query = new URLSearchParams({
			continuous: 'true',
			since: params.since,
			until: params.until,
		})
		return this.request<ZoneAnalyticsDashboard>(`/zones/${zoneId}/analytics/dashboard?${query}`).then(r => r.result)
	}

	/**
	 * Run a raw GraphQL query against `POST /client/v4/graphql`. Returns the
	 * `data` field. Throws `ApiError` on HTTP errors or GraphQL-level errors.
	 */
	async graphql<T>(query: string, variables?: Record<string, unknown>): Promise<T> {
		const res = await this.doFetch('/graphql', {
			body: JSON.stringify({ query, variables: variables ?? {} }),
			method: 'POST',
		})
		const data = (await res.json().catch(() => null)) as GraphQLResponse<T> | null
		if (!res.ok || !data || data.errors?.length) {
			throw new ApiError(res.status, [{
				code: res.status,
				message: data?.errors?.[0]?.message ?? `HTTP ${res.status}`,
			}])
		}
		if (!data.data)
			throw new ApiError(res.status, [{ code: 0, message: 'GraphQL response had no data' }])
		return data.data
	}

	/**
	 * Account-wide HTTP analytics (daily buckets) via GraphQL. `since`/`until`
	 * are ISO 8601 timestamps; the date part is used as the daily filter.
	 * Requires the `analytics.read` scope.
	 */
	async getAccountAnalytics(accountId: string, params: { since: string, until: string }): Promise<AccountAnalyticsResult> {
		const dateGeq = params.since.slice(0, 10)
		const dateLeq = params.until.slice(0, 10)
		// Generous limit so multi-day ranges return every daily bucket.
		const limit = 1000
		const query = /* GraphQL */ `
			query AccountAnalytics($accountTag: String!, $dateGeq: Date!, $dateLeq: Date!, $limit: Int!) {
				viewer {
					accounts(filter: { accountTag: $accountTag }) {
						httpRequests1mGroups(limit: $limit, filter: { date_geq: $dateGeq, date_leq: $dateLeq }) {
							sum { requests cachedRequests bandwidth threats pageViews }
							dimensions { date }
						}
					}
				}
			}`
		interface Row {
			dimensions: { date: string }
			sum: AccountAnalyticsSum
		}
		interface AccountAnalyticsData {
			viewer: {
				accounts: Array<{ httpRequests1mGroups: Row[] }>
			}
		}
		const data = await this.graphql<AccountAnalyticsData>(query, {
			accountTag: accountId,
			dateGeq,
			dateLeq,
			limit,
		})
		const rows = data.viewer.accounts[0]?.httpRequests1mGroups ?? []
		const points: AccountAnalyticsPoint[] = rows
			.map(row => ({ date: row.dimensions.date, sum: row.sum }))
			.sort((a, b) => (a.date ?? '').localeCompare(b.date ?? ''))
		const totals: AccountAnalyticsSum = {
			bandwidth: sumNum(points, p => p.sum.bandwidth),
			cachedRequests: sumNum(points, p => p.sum.cachedRequests),
			pageViews: sumNum(points, p => p.sum.pageViews),
			requests: sumNum(points, p => p.sum.requests),
			threats: sumNum(points, p => p.sum.threats),
		}
		return { points, totals }
	}
}

function sumNum(points: AccountAnalyticsPoint[], pick: (p: AccountAnalyticsPoint) => number | undefined): number | undefined {
	let total = 0
	let any = false
	for (const p of points) {
		const v = pick(p)
		if (typeof v === 'number') {
			total += v
			any = true
		}
	}
	return any ? total : undefined
}
