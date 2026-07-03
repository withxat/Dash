import type { OAuthEndpoints, TokenSet } from './oauth'
import type {
	AccessApplication,
	AccountAnalyticsPoint,
	AccountAnalyticsResult,
	AccountAnalyticsSum,
	AccountMember,
	ApiResult,
	AuditLogEntry,
	CertificatePack,
	CloudflareAccount,
	CloudflareUser,
	CloudflareWorkerScript,
	CloudflareZone,
	CursorPage,
	D1Database,
	D1DatabaseSummary,
	D1QueryResult,
	DnsRecord,
	DnsRecordInput,
	EmailRoutingAddress,
	EmailRoutingRule,
	EmailRoutingSettings,
	FirewallEvent,
	GraphQLResponse,
	Healthcheck,
	ImagesImage,
	IpAccessRule,
	IpAccessRuleMode,
	KvKey,
	KvNamespace,
	LoadBalancer,
	LoadBalancerPool,
	NotificationHistoryEntry,
	NotificationPolicy,
	Page,
	PageRule,
	PagesDeployment,
	PagesDomain,
	PagesProject,
	Paginated,
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
	WafCustomRule,
	WafEntrypointRuleset,
	WaitingRoom,
	WebAnalyticsPoint,
	WebAnalyticsResult,
	WorkerDeployment,
	WorkerDomain,
	WorkerRoute,
	WorkersBuild,
	WorkerScriptSettings,
	WorkersTelemetryEvent,
	WorkerSubdomainStatus,
	ZoneAnalyticsDashboard,
	ZoneAnalyticsPoint,
	ZoneAnalyticsTotal,
	ZoneSetting,
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

	/**
	 * List members of an account, including pending invitations
	 * (GET /accounts/:id/members). Covered by the account settings read scope.
	 */
	listAccountMembers(accountId: string, params?: { page?: number, perPage?: number }): Promise<Page<AccountMember>> {
		const query = new URLSearchParams()
		if (params?.page)
			query.set('page', String(params.page))
		if (params?.perPage)
			query.set('per_page', String(params.perPage))
		const qs = query.toString()
		return this.requestList<AccountMember>(`/accounts/${accountId}/members${qs ? `?${qs}` : ''}`)
	}

	/**
	 * List an account's notification policies
	 * (GET /accounts/:id/alerting/v3/policies). Requires the notifications
	 * read scope.
	 */
	listNotificationPolicies(accountId: string): Promise<NotificationPolicy[]> {
		return this.requestList<NotificationPolicy>(`/accounts/${accountId}/alerting/v3/policies`).then(p => p.items)
	}

	/**
	 * Recently dispatched notifications, newest first
	 * (GET /accounts/:id/alerting/v3/history). Requires the notifications
	 * read scope.
	 */
	listNotificationHistory(accountId: string, params?: { perPage?: number }): Promise<NotificationHistoryEntry[]> {
		const query = new URLSearchParams()
		if (params?.perPage)
			query.set('per_page', String(params.perPage))
		const qs = query.toString()
		return this.requestList<NotificationHistoryEntry>(`/accounts/${accountId}/alerting/v3/history${qs ? `?${qs}` : ''}`).then(p => p.items)
	}

	/**
	 * Recent audit log entries for an account, newest first
	 * (GET /accounts/:id/audit_logs). Covered by the account settings read scope.
	 */
	listAuditLogs(accountId: string, params?: { perPage?: number }): Promise<AuditLogEntry[]> {
		const query = new URLSearchParams()
		query.set('direction', 'desc')
		if (params?.perPage)
			query.set('per_page', String(params.perPage))
		return this.requestList<AuditLogEntry>(`/accounts/${accountId}/audit_logs?${query.toString()}`).then(p => p.items)
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

	/** Create a DNS record (POST /zones/:zone/dns_records). */
	createDnsRecord(zoneId: string, input: DnsRecordInput): Promise<DnsRecord> {
		return this.request<DnsRecord>(`/zones/${zoneId}/dns_records`, {
			body: JSON.stringify(input),
			method: 'POST',
		}).then(r => r.result)
	}

	/** Replace a DNS record (PUT /zones/:zone/dns_records/:id). */
	updateDnsRecord(zoneId: string, id: string, input: DnsRecordInput): Promise<DnsRecord> {
		return this.request<DnsRecord>(`/zones/${zoneId}/dns_records/${id}`, {
			body: JSON.stringify(input),
			method: 'PUT',
		}).then(r => r.result)
	}

	/** Delete a DNS record (DELETE /zones/:zone/dns_records/:id). */
	async deleteDnsRecord(zoneId: string, id: string): Promise<void> {
		await this.request<{ id: string }>(`/zones/${zoneId}/dns_records/${id}`, { method: 'DELETE' })
	}

	/**
	 * Purge a zone's edge cache (POST /zones/:zone/purge_cache). Pass
	 * `{ purge_everything: true }` or `{ files: [...] }` (max 30 URLs).
	 * Requires the cache purge scope.
	 */
	async purgeCache(zoneId: string, input: PurgeCacheInput): Promise<void> {
		await this.request<{ id: string }>(`/zones/${zoneId}/purge_cache`, {
			body: JSON.stringify(input),
			method: 'POST',
		})
	}

	/** List all settings for a zone (GET /zones/:zone/settings). Requires the zone settings read scope. */
	listZoneSettings(zoneId: string): Promise<ZoneSetting[]> {
		return this.requestList<ZoneSetting>(`/zones/${zoneId}/settings`).then(p => p.items)
	}

	/**
	 * Update one zone setting (PATCH /zones/:zone/settings/:setting), e.g.
	 * `development_mode` → `"on"`, `security_level` → `"under_attack"`.
	 * Requires the zone settings edit scope.
	 */
	updateZoneSetting(
		zoneId: string,
		settingId: string,
		value: boolean | number | Record<string, unknown> | string,
	): Promise<ZoneSetting> {
		return this.request<ZoneSetting>(`/zones/${zoneId}/settings/${settingId}`, {
			body: JSON.stringify({ value }),
			method: 'PATCH',
		}).then(r => r.result)
	}

	/** List Workers scripts in an account (GET /accounts/:id/workers/scripts). */
	listWorkers(accountId: string): Promise<CloudflareWorkerScript[]> {
		return this.requestList<CloudflareWorkerScript>(`/accounts/${accountId}/workers/scripts`).then(p => p.items)
	}

	/** Get whether a Worker serves on its workers.dev subdomain. */
	getWorkerSubdomain(accountId: string, name: string): Promise<WorkerSubdomainStatus> {
		return this.request<WorkerSubdomainStatus>(
			`/accounts/${accountId}/workers/scripts/${encodeURIComponent(name)}/subdomain`,
		).then(r => r.result)
	}

	/** Enable/disable a Worker on its workers.dev subdomain (quick start/pause). */
	setWorkerSubdomain(accountId: string, name: string, enabled: boolean): Promise<WorkerSubdomainStatus> {
		return this.request<WorkerSubdomainStatus>(
			`/accounts/${accountId}/workers/scripts/${encodeURIComponent(name)}/subdomain`,
			{ body: JSON.stringify({ enabled }), method: 'POST' },
		).then(r => r.result)
	}

	/** List custom domains attached to Workers, optionally for one script (GET /accounts/:id/workers/domains). */
	listWorkerDomains(accountId: string, params?: { service?: string }): Promise<WorkerDomain[]> {
		const query = new URLSearchParams()
		if (params?.service)
			query.set('service', params.service)
		const qs = query.toString()
		return this.requestList<WorkerDomain>(`/accounts/${accountId}/workers/domains${qs ? `?${qs}` : ''}`).then(p => p.items)
	}

	/** List a Worker's deployments, newest (live) first. */
	listWorkerDeployments(accountId: string, name: string): Promise<WorkerDeployment[]> {
		return this.request<{ deployments: WorkerDeployment[] }>(
			`/accounts/${accountId}/workers/scripts/${encodeURIComponent(name)}/deployments`,
		).then(r => r.result.deployments ?? [])
	}

	/** List Workers routes on a zone (GET /zones/:zone/workers/routes). */
	listWorkerRoutes(zoneId: string): Promise<WorkerRoute[]> {
		return this.requestList<WorkerRoute>(`/zones/${zoneId}/workers/routes`).then(p => p.items)
	}

	/** Create a Workers route on a zone (POST /zones/:zone/workers/routes). */
	createWorkerRoute(zoneId: string, input: { pattern: string, script?: string }): Promise<WorkerRoute> {
		return this.request<WorkerRoute>(`/zones/${zoneId}/workers/routes`, {
			body: JSON.stringify(input),
			method: 'POST',
		}).then(r => r.result)
	}

	/** Replace a Workers route in place (PUT /zones/:zone/workers/routes/:id). */
	updateWorkerRoute(zoneId: string, routeId: string, input: { pattern: string, script?: string }): Promise<WorkerRoute> {
		return this.request<WorkerRoute>(`/zones/${zoneId}/workers/routes/${routeId}`, {
			body: JSON.stringify(input),
			method: 'PUT',
		}).then(r => r.result)
	}

	/** Delete a Workers route (DELETE /zones/:zone/workers/routes/:id). */
	async deleteWorkerRoute(zoneId: string, routeId: string): Promise<void> {
		await this.request<{ id: string }>(`/zones/${zoneId}/workers/routes/${routeId}`, { method: 'DELETE' })
	}

	/**
	 * Attach a custom domain to a Worker (PUT /accounts/:id/workers/domains).
	 * The hostname must belong to a zone on the same account.
	 */
	attachWorkerDomain(accountId: string, input: {
		environment?: string
		hostname: string
		service: string
		zone_id: string
	}): Promise<WorkerDomain> {
		return this.request<WorkerDomain>(`/accounts/${accountId}/workers/domains`, {
			body: JSON.stringify({ environment: 'production', ...input }),
			method: 'PUT',
		}).then(r => r.result)
	}

	/** Detach a custom domain from its Worker (DELETE /accounts/:id/workers/domains/:domainId). */
	async detachWorkerDomain(accountId: string, domainId: string): Promise<void> {
		const res = await this.doFetch(`/accounts/${accountId}/workers/domains/${domainId}`, { method: 'DELETE' })
		if (!res.ok) {
			const data = (await res.json().catch(() => null)) as ApiResult<unknown> | null
			const errors = data?.errors ?? [{ code: res.status, message: `HTTP ${res.status}` }]
			throw new ApiError(res.status, errors)
		}
	}

	/** List KV namespaces in an account (GET /accounts/:id/storage/kv/namespaces). */
	listKvNamespaces(accountId: string, params?: { page?: number, perPage?: number }): Promise<Page<KvNamespace>> {
		const query = new URLSearchParams()
		if (params?.page)
			query.set('page', String(params.page))
		if (params?.perPage)
			query.set('per_page', String(params.perPage))
		const qs = query.toString()
		return this.requestList<KvNamespace>(`/accounts/${accountId}/storage/kv/namespaces${qs ? `?${qs}` : ''}`)
	}

	/** Create a KV namespace (POST /accounts/:id/storage/kv/namespaces). */
	createKvNamespace(accountId: string, title: string): Promise<KvNamespace> {
		return this.request<KvNamespace>(`/accounts/${accountId}/storage/kv/namespaces`, {
			body: JSON.stringify({ title }),
			method: 'POST',
		}).then(r => r.result)
	}

	/** Rename a KV namespace (PUT /accounts/:id/storage/kv/namespaces/:ns). */
	async renameKvNamespace(accountId: string, namespaceId: string, title: string): Promise<void> {
		await this.request<unknown>(`/accounts/${accountId}/storage/kv/namespaces/${namespaceId}`, {
			body: JSON.stringify({ title }),
			method: 'PUT',
		})
	}

	/** Delete a KV namespace and all its keys (DELETE /accounts/:id/storage/kv/namespaces/:ns). */
	async deleteKvNamespace(accountId: string, namespaceId: string): Promise<void> {
		await this.request<unknown>(`/accounts/${accountId}/storage/kv/namespaces/${namespaceId}`, {
			method: 'DELETE',
		})
	}

	/** List keys in a KV namespace with cursor pagination (GET …/namespaces/:ns/keys). */
	async listKvKeys(accountId: string, namespaceId: string, params?: {
		cursor?: string
		limit?: number
		prefix?: string
	}): Promise<CursorPage<KvKey>> {
		const query = new URLSearchParams()
		if (params?.cursor)
			query.set('cursor', params.cursor)
		if (params?.limit)
			query.set('limit', String(params.limit))
		if (params?.prefix)
			query.set('prefix', params.prefix)
		const qs = query.toString()
		const res = await this.doFetch(`/accounts/${accountId}/storage/kv/namespaces/${namespaceId}/keys${qs ? `?${qs}` : ''}`)
		const data = (await res.json().catch(() => null)) as null | {
			errors?: Array<{ code: number, message: string }>
			result?: KvKey[]
			result_info?: { cursor?: string }
			success?: boolean
		}
		if (!res.ok || !data?.success) {
			const errors = data?.errors ?? [{ code: res.status, message: `HTTP ${res.status}` }]
			throw new ApiError(res.status, errors)
		}
		return { cursor: data.result_info?.cursor || undefined, items: data.result ?? [] }
	}

	/** Read a KV value as text (GET …/namespaces/:ns/values/:key). */
	async getKvValue(accountId: string, namespaceId: string, key: string): Promise<string> {
		const res = await this.doFetch(
			`/accounts/${accountId}/storage/kv/namespaces/${namespaceId}/values/${encodeURIComponent(key)}`,
		)
		if (!res.ok) {
			const data = (await res.json().catch(() => null)) as ApiResult<unknown> | null
			const errors = data?.errors ?? [{ code: res.status, message: `HTTP ${res.status}` }]
			throw new ApiError(res.status, errors)
		}
		return res.text()
	}

	/**
	 * Write a KV value (PUT …/namespaces/:ns/values/:key). Pass
	 * `expirationTtl` (seconds, min 60) to auto-expire the key.
	 */
	async putKvValue(accountId: string, namespaceId: string, key: string, value: string, options?: {
		expirationTtl?: number
	}): Promise<void> {
		const query = new URLSearchParams()
		if (options?.expirationTtl)
			query.set('expiration_ttl', String(options.expirationTtl))
		const qs = query.toString()
		await this.request<unknown>(
			`/accounts/${accountId}/storage/kv/namespaces/${namespaceId}/values/${encodeURIComponent(key)}${qs ? `?${qs}` : ''}`,
			{ body: value, headers: { 'Content-Type': 'text/plain' }, method: 'PUT' },
		)
	}

	/** Delete a KV key (DELETE …/namespaces/:ns/values/:key). */
	async deleteKvKey(accountId: string, namespaceId: string, key: string): Promise<void> {
		await this.request<unknown>(
			`/accounts/${accountId}/storage/kv/namespaces/${namespaceId}/values/${encodeURIComponent(key)}`,
			{ method: 'DELETE' },
		)
	}

	/** List R2 buckets in an account (GET /accounts/:id/r2/buckets). */
	listR2Buckets(accountId: string): Promise<R2Bucket[]> {
		return this.request<{ buckets?: R2Bucket[] }>(`/accounts/${accountId}/r2/buckets`)
			.then(r => r.result.buckets ?? [])
	}

	/** Create an R2 bucket (POST /accounts/:id/r2/buckets). Requires the R2 write scope. */
	createR2Bucket(accountId: string, name: string): Promise<R2Bucket> {
		return this.request<R2Bucket>(`/accounts/${accountId}/r2/buckets`, {
			body: JSON.stringify({ name }),
			method: 'POST',
		}).then(r => r.result)
	}

	/** Delete an empty R2 bucket (DELETE /accounts/:id/r2/buckets/:bucket). Requires the R2 write scope. */
	async deleteR2Bucket(accountId: string, bucket: string): Promise<void> {
		await this.request<unknown>(`/accounts/${accountId}/r2/buckets/${encodeURIComponent(bucket)}`, {
			method: 'DELETE',
		})
	}

	/** List objects in an R2 bucket with cursor pagination (GET …/r2/buckets/:bucket/objects). */
	async listR2Objects(accountId: string, bucket: string, params?: {
		cursor?: string
		perPage?: number
		prefix?: string
	}): Promise<CursorPage<R2Object>> {
		const query = new URLSearchParams()
		if (params?.cursor)
			query.set('cursor', params.cursor)
		if (params?.perPage)
			query.set('per_page', String(params.perPage))
		if (params?.prefix)
			query.set('prefix', params.prefix)
		const qs = query.toString()
		const res = await this.doFetch(`/accounts/${accountId}/r2/buckets/${encodeURIComponent(bucket)}/objects${qs ? `?${qs}` : ''}`)
		const data = (await res.json().catch(() => null)) as null | {
			errors?: Array<{ code: number, message: string }>
			result?: R2Object[]
			result_info?: { cursor?: string, is_truncated?: boolean }
			success?: boolean
		}
		if (!res.ok || !data?.success) {
			const errors = data?.errors ?? [{ code: res.status, message: `HTTP ${res.status}` }]
			throw new ApiError(res.status, errors)
		}
		const truncated = data.result_info?.is_truncated ?? false
		return { cursor: truncated ? data.result_info?.cursor || undefined : undefined, items: data.result ?? [] }
	}

	/**
	 * Download an R2 object (GET …/r2/buckets/:bucket/objects/:key). Returns the
	 * raw `Response` so callers can stream, read text, or convert to a blob.
	 */
	async getR2Object(accountId: string, bucket: string, key: string): Promise<Response> {
		const res = await this.doFetch(
			`/accounts/${accountId}/r2/buckets/${encodeURIComponent(bucket)}/objects/${encodeURIComponent(key)}`,
		)
		if (!res.ok) {
			const data = (await res.json().catch(() => null)) as ApiResult<unknown> | null
			const errors = data?.errors ?? [{ code: res.status, message: `HTTP ${res.status}` }]
			throw new ApiError(res.status, errors)
		}
		return res
	}

	/** Upload an object to an R2 bucket (PUT …/r2/buckets/:bucket/objects/:key). */
	async putR2Object(accountId: string, bucket: string, key: string, body: Blob | string, contentType?: string): Promise<void> {
		const res = await this.doFetch(
			`/accounts/${accountId}/r2/buckets/${encodeURIComponent(bucket)}/objects/${encodeURIComponent(key)}`,
			{
				body,
				headers: { 'Content-Type': contentType ?? 'application/octet-stream' },
				method: 'PUT',
			},
		)
		if (!res.ok) {
			const data = (await res.json().catch(() => null)) as ApiResult<unknown> | null
			const errors = data?.errors ?? [{ code: res.status, message: `HTTP ${res.status}` }]
			throw new ApiError(res.status, errors)
		}
	}

	/** Delete an object from an R2 bucket (DELETE …/r2/buckets/:bucket/objects/:key). */
	async deleteR2Object(accountId: string, bucket: string, key: string): Promise<void> {
		const res = await this.doFetch(
			`/accounts/${accountId}/r2/buckets/${encodeURIComponent(bucket)}/objects/${encodeURIComponent(key)}`,
			{ method: 'DELETE' },
		)
		if (!res.ok) {
			const data = (await res.json().catch(() => null)) as ApiResult<unknown> | null
			const errors = data?.errors ?? [{ code: res.status, message: `HTTP ${res.status}` }]
			throw new ApiError(res.status, errors)
		}
	}

	/** List Pages projects in an account (GET /accounts/:id/pages/projects). */
	listPagesProjects(accountId: string): Promise<PagesProject[]> {
		return this.requestList<PagesProject>(`/accounts/${accountId}/pages/projects`).then(p => p.items)
	}

	/** List a Pages project's deployments, newest first (GET …/pages/projects/:project/deployments). */
	listPagesDeployments(accountId: string, project: string): Promise<PagesDeployment[]> {
		return this.requestList<PagesDeployment>(
			`/accounts/${accountId}/pages/projects/${encodeURIComponent(project)}/deployments`,
		).then(p => p.items)
	}

	/** Get a single Pages deployment (GET …/deployments/:id). */
	getPagesDeployment(accountId: string, project: string, deploymentId: string): Promise<PagesDeployment> {
		return this.request<PagesDeployment>(
			`/accounts/${accountId}/pages/projects/${encodeURIComponent(project)}/deployments/${deploymentId}`,
		).then(r => r.result)
	}

	/** Retry a failed/canceled Pages deployment (POST …/deployments/:id/retry). Requires the Pages write scope. */
	retryPagesDeployment(accountId: string, project: string, deploymentId: string): Promise<PagesDeployment> {
		return this.request<PagesDeployment>(
			`/accounts/${accountId}/pages/projects/${encodeURIComponent(project)}/deployments/${deploymentId}/retry`,
			{ method: 'POST' },
		).then(r => r.result)
	}

	/** Roll back production to a previous Pages deployment (POST …/deployments/:id/rollback). Requires the Pages write scope. */
	rollbackPagesDeployment(accountId: string, project: string, deploymentId: string): Promise<PagesDeployment> {
		return this.request<PagesDeployment>(
			`/accounts/${accountId}/pages/projects/${encodeURIComponent(project)}/deployments/${deploymentId}/rollback`,
			{ method: 'POST' },
		).then(r => r.result)
	}

	/** Delete a Pages deployment (DELETE …/deployments/:id). Requires the Pages write scope. */
	async deletePagesDeployment(accountId: string, project: string, deploymentId: string): Promise<void> {
		await this.request<unknown>(
			`/accounts/${accountId}/pages/projects/${encodeURIComponent(project)}/deployments/${deploymentId}`,
			{ method: 'DELETE' },
		)
	}

	/** List a Pages project's custom domains (GET …/pages/projects/:project/domains). */
	listPagesDomains(accountId: string, project: string): Promise<PagesDomain[]> {
		return this.requestList<PagesDomain>(
			`/accounts/${accountId}/pages/projects/${encodeURIComponent(project)}/domains`,
		).then(p => p.items)
	}

	/** Add a custom domain to a Pages project (POST …/pages/projects/:project/domains). Requires the Pages write scope. */
	addPagesDomain(accountId: string, project: string, name: string): Promise<PagesDomain> {
		return this.request<PagesDomain>(
			`/accounts/${accountId}/pages/projects/${encodeURIComponent(project)}/domains`,
			{ body: JSON.stringify({ name }), method: 'POST' },
		).then(r => r.result)
	}

	/** Remove a custom domain from a Pages project (DELETE …/domains/:domain). Requires the Pages write scope. */
	async deletePagesDomain(accountId: string, project: string, name: string): Promise<void> {
		await this.request<unknown>(
			`/accounts/${accountId}/pages/projects/${encodeURIComponent(project)}/domains/${encodeURIComponent(name)}`,
			{ method: 'DELETE' },
		)
	}

	/** List Web Analytics (RUM) sites in an account (GET /accounts/:id/rum/site_info/list). */
	listRumSites(accountId: string): Promise<RumSite[]> {
		return this.requestList<RumSite>(`/accounts/${accountId}/rum/site_info/list`).then(p => p.items)
	}

	/** Fetch a Worker's settings/metadata (GET /accounts/:id/workers/scripts/:name/settings). */
	getWorkerSettings(accountId: string, name: string): Promise<WorkerScriptSettings> {
		return this.request<WorkerScriptSettings>(
			`/accounts/${accountId}/workers/scripts/${encodeURIComponent(name)}/settings`,
		).then(r => r.result)
	}

	/** Fetch a Worker's raw script content (GET /accounts/:id/workers/scripts/:name/content). */
	async getWorkerContent(accountId: string, name: string): Promise<string> {
		const res = await this.doFetch(`/accounts/${accountId}/workers/scripts/${encodeURIComponent(name)}/content`)
		if (!res.ok) {
			const data = (await res.json().catch(() => null)) as ApiResult<unknown> | null
			const errors = data?.errors ?? [{ code: res.status, message: `HTTP ${res.status}` }]
			throw new ApiError(res.status, errors)
		}
		return res.text()
	}

	/** List D1 databases in an account (GET /accounts/:id/d1/database). Requires the D1 read scope. */
	listD1Databases(accountId: string, params?: { page?: number, perPage?: number }): Promise<Page<D1DatabaseSummary>> {
		const query = new URLSearchParams()
		if (params?.page)
			query.set('page', String(params.page))
		if (params?.perPage)
			query.set('per_page', String(params.perPage))
		const qs = query.toString()
		return this.requestList<D1DatabaseSummary>(`/accounts/${accountId}/d1/database${qs ? `?${qs}` : ''}`)
	}

	/** Get a D1 database's details incl. size and table count (GET …/d1/database/:uuid). */
	getD1Database(accountId: string, databaseId: string): Promise<D1Database> {
		return this.request<D1Database>(`/accounts/${accountId}/d1/database/${databaseId}`).then(r => r.result)
	}

	/**
	 * Run SQL against a D1 database (POST …/d1/database/:uuid/query). Returns
	 * one result set per statement. The scope (`d1.read`) technically allows
	 * writes too — callers should restrict input to read-only statements.
	 */
	queryD1Database(accountId: string, databaseId: string, sql: string): Promise<D1QueryResult[]> {
		return this.requestList<D1QueryResult>(`/accounts/${accountId}/d1/database/${databaseId}/query`, {
			body: JSON.stringify({ sql }),
			method: 'POST',
		}).then(p => p.items)
	}

	/** List queues with producers/consumers (GET /accounts/:id/queues). Requires the queues read scope. */
	listQueues(accountId: string): Promise<QueueSummary[]> {
		return this.requestList<QueueSummary>(`/accounts/${accountId}/queues`).then(p => p.items)
	}

	/** Get one queue's details (GET /accounts/:id/queues/:queueId). */
	getQueue(accountId: string, queueId: string): Promise<QueueSummary> {
		return this.request<QueueSummary>(`/accounts/${accountId}/queues/${queueId}`).then(r => r.result)
	}

	/** Delete all messages in a queue (POST …/queues/:queueId/purge). Requires the queues write scope. */
	async purgeQueue(accountId: string, queueId: string): Promise<void> {
		await this.request<unknown>(`/accounts/${accountId}/queues/${queueId}/purge`, {
			body: JSON.stringify({ delete_messages_permanently: true }),
			method: 'POST',
		})
	}

	/**
	 * List Workers Builds for a Worker, newest first
	 * (GET /accounts/:id/builds/workers/:tag/builds). `scriptTag` is the
	 * system-generated `tag` from the scripts list — not the script name.
	 * Requires the Workers CI read scope.
	 */
	listWorkerBuilds(accountId: string, scriptTag: string, params?: { perPage?: number }): Promise<WorkersBuild[]> {
		const query = new URLSearchParams()
		if (params?.perPage)
			query.set('per_page', String(params.perPage))
		const qs = query.toString()
		return this.requestList<WorkersBuild>(
			`/accounts/${accountId}/builds/workers/${encodeURIComponent(scriptTag)}/builds${qs ? `?${qs}` : ''}`,
		).then(p => p.items)
	}

	/**
	 * Recent Workers Logs events for one script, newest first
	 * (POST /accounts/:id/workers/observability/telemetry/query). Requires the
	 * Workers observability read scope, and the Worker must have observability
	 * enabled.
	 */
	async queryWorkerLogs(accountId: string, scriptName: string, params: {
		/** Only return events at this level, e.g. `error`. */
		level?: string
		limit?: number
		since: number
		until: number
	}): Promise<WorkersTelemetryEvent[]> {
		const filters: Array<Record<string, unknown>> = [
			{ key: '$metadata.service', operation: 'eq', type: 'string', value: scriptName },
		]
		if (params.level)
			filters.push({ key: '$metadata.level', operation: 'eq', type: 'string', value: params.level })
		const body = {
			limit: params.limit ?? 50,
			parameters: {
				datasets: ['cloudflare-workers'],
				filters,
				orderBy: { order: 'desc', value: 'timestamp' },
			},
			queryId: 'cloudfx-worker-logs',
			timeframe: { from: params.since, to: params.until },
			view: 'events',
		}
		const data = await this.request<{ events?: { events?: WorkersTelemetryEvent[] } }>(
			`/accounts/${accountId}/workers/observability/telemetry/query`,
			{ body: JSON.stringify(body), method: 'POST' },
		)
		return data.result.events?.events ?? []
	}

	/** List Secrets Store stores (GET /accounts/:id/secrets_store/stores). Requires the secrets store read scope. */
	listSecretsStores(accountId: string): Promise<SecretsStore[]> {
		return this.requestList<SecretsStore>(`/accounts/${accountId}/secrets_store/stores`).then(p => p.items)
	}

	/** List secret names in a store — values are never readable (GET …/stores/:store/secrets). */
	listSecretsStoreSecrets(accountId: string, storeId: string): Promise<SecretsStoreSecret[]> {
		return this.requestList<SecretsStoreSecret>(
			`/accounts/${accountId}/secrets_store/stores/${storeId}/secrets`,
		).then(p => p.items)
	}

	/** List Vectorize indexes (GET /accounts/:id/vectorize/v2/indexes). Requires the Vectorize read scope. */
	listVectorizeIndexes(accountId: string): Promise<VectorizeIndex[]> {
		return this.requestList<VectorizeIndex>(`/accounts/${accountId}/vectorize/v2/indexes`).then(p => p.items)
	}

	/** List a zone's SSL certificate packs (GET /zones/:zone/ssl/certificate_packs). Requires the SSL read scope. */
	listCertificatePacks(zoneId: string): Promise<CertificatePack[]> {
		return this.requestList<CertificatePack>(`/zones/${zoneId}/ssl/certificate_packs?status=all`).then(p => p.items)
	}

	/** Get a zone's Universal SSL settings (GET /zones/:zone/ssl/universal/settings). */
	getUniversalSslSettings(zoneId: string): Promise<UniversalSslSettings> {
		return this.request<UniversalSslSettings>(`/zones/${zoneId}/ssl/universal/settings`).then(r => r.result)
	}

	/** List a zone's IP Access Rules (GET /zones/:zone/firewall/access_rules/rules). Requires the firewall read scope. */
	listIpAccessRules(zoneId: string, params?: { page?: number, perPage?: number }): Promise<Page<IpAccessRule>> {
		const query = new URLSearchParams()
		if (params?.page)
			query.set('page', String(params.page))
		if (params?.perPage)
			query.set('per_page', String(params.perPage))
		const qs = query.toString()
		return this.requestList<IpAccessRule>(`/zones/${zoneId}/firewall/access_rules/rules${qs ? `?${qs}` : ''}`)
	}

	/**
	 * Create an IP Access Rule on a zone (POST …/firewall/access_rules/rules),
	 * e.g. block or challenge one IP. Requires the firewall write scope.
	 */
	createIpAccessRule(zoneId: string, input: {
		/** e.g. `{ target: 'ip', value: '1.2.3.4' }` or `{ target: 'ip_range', value: '1.2.3.0/24' }`. */
		configuration: { target: string, value: string }
		mode: IpAccessRuleMode
		notes?: string
	}): Promise<IpAccessRule> {
		return this.request<IpAccessRule>(`/zones/${zoneId}/firewall/access_rules/rules`, {
			body: JSON.stringify(input),
			method: 'POST',
		}).then(r => r.result)
	}

	/** Delete an IP Access Rule (DELETE …/firewall/access_rules/rules/:id). Requires the firewall write scope. */
	async deleteIpAccessRule(zoneId: string, ruleId: string): Promise<void> {
		await this.request<unknown>(`/zones/${zoneId}/firewall/access_rules/rules/${ruleId}`, { method: 'DELETE' })
	}

	/**
	 * Get a zone's WAF custom rules entrypoint ruleset
	 * (GET /zones/:zone/rulesets/phases/http_request_firewall_custom/entrypoint).
	 * Returns null when the zone has no custom rules yet (the API 404s).
	 * Requires the zone WAF read scope.
	 */
	async getWafCustomRuleset(zoneId: string): Promise<null | WafEntrypointRuleset> {
		try {
			const r = await this.request<WafEntrypointRuleset>(
				`/zones/${zoneId}/rulesets/phases/http_request_firewall_custom/entrypoint`,
			)
			return r.result
		}
		catch (error) {
			if (error instanceof ApiError && error.status === 404)
				return null
			throw error
		}
	}

	/**
	 * Enable/disable one WAF custom rule in place
	 * (PATCH /zones/:zone/rulesets/:ruleset/rules/:rule). Sends the rule's
	 * existing action/expression back because the endpoint replaces the rule.
	 * Requires the zone WAF write scope.
	 */
	setWafCustomRuleEnabled(zoneId: string, rulesetId: string, rule: WafCustomRule, enabled: boolean): Promise<WafEntrypointRuleset> {
		return this.request<WafEntrypointRuleset>(`/zones/${zoneId}/rulesets/${rulesetId}/rules/${rule.id}`, {
			body: JSON.stringify({
				action: rule.action,
				description: rule.description,
				enabled,
				expression: rule.expression,
			}),
			method: 'PATCH',
		}).then(r => r.result)
	}

	/** List Turnstile widgets (GET /accounts/:id/challenges/widgets). Requires the Turnstile read scope. */
	listTurnstileWidgets(accountId: string): Promise<TurnstileWidget[]> {
		return this.requestList<TurnstileWidget>(`/accounts/${accountId}/challenges/widgets`).then(p => p.items)
	}

	/**
	 * Rotate a Turnstile widget's secret (POST …/widgets/:sitekey/rotate_secret).
	 * With `invalidateImmediately: false` the old secret stays valid for two
	 * hours to allow for a graceful rollover. Requires the Turnstile write scope.
	 */
	rotateTurnstileSecret(accountId: string, sitekey: string, options?: { invalidateImmediately?: boolean }): Promise<TurnstileWidget> {
		return this.request<TurnstileWidget>(
			`/accounts/${accountId}/challenges/widgets/${encodeURIComponent(sitekey)}/rotate_secret`,
			{
				body: JSON.stringify({ invalidate_immediately: options?.invalidateImmediately ?? false }),
				method: 'POST',
			},
		).then(r => r.result)
	}

	/** List a zone's healthchecks (GET /zones/:zone/healthchecks). Requires the healthchecks read scope. */
	listHealthchecks(zoneId: string): Promise<Healthcheck[]> {
		return this.requestList<Healthcheck>(`/zones/${zoneId}/healthchecks`).then(p => p.items)
	}

	/** List a zone's waiting rooms (GET /zones/:zone/waiting_rooms). Requires the waiting rooms read scope. */
	listWaitingRooms(zoneId: string): Promise<WaitingRoom[]> {
		return this.requestList<WaitingRoom>(`/zones/${zoneId}/waiting_rooms`).then(p => p.items)
	}

	/** List a zone's load balancers (GET /zones/:zone/load_balancers). Requires the load balancers read scope. */
	listLoadBalancers(zoneId: string): Promise<LoadBalancer[]> {
		return this.requestList<LoadBalancer>(`/zones/${zoneId}/load_balancers`).then(p => p.items)
	}

	/** List account origin pools (GET /accounts/:id/load_balancers/pools). Requires the LB monitors/pools read scope. */
	listLoadBalancerPools(accountId: string): Promise<LoadBalancerPool[]> {
		return this.requestList<LoadBalancerPool>(`/accounts/${accountId}/load_balancers/pools`).then(p => p.items)
	}

	/** List a zone's page rules (GET /zones/:zone/pagerules). Requires the page rules read scope. */
	listPageRules(zoneId: string): Promise<PageRule[]> {
		return this.requestList<PageRule>(`/zones/${zoneId}/pagerules`).then(p => p.items)
	}

	/** Get a zone's Email Routing status (GET /zones/:zone/email/routing). Requires the email rule read scope. */
	getEmailRoutingSettings(zoneId: string): Promise<EmailRoutingSettings> {
		return this.request<EmailRoutingSettings>(`/zones/${zoneId}/email/routing`).then(r => r.result)
	}

	/** List a zone's Email Routing rules (GET /zones/:zone/email/routing/rules). Requires the email rule read scope. */
	listEmailRoutingRules(zoneId: string): Promise<EmailRoutingRule[]> {
		return this.requestList<EmailRoutingRule>(`/zones/${zoneId}/email/routing/rules`).then(p => p.items)
	}

	/**
	 * Enable/disable one Email Routing rule in place
	 * (PUT /zones/:zone/email/routing/rules/:id). Sends the rule's existing
	 * matchers/actions back because the endpoint replaces the rule.
	 * Requires the email rule write scope.
	 */
	setEmailRoutingRuleEnabled(zoneId: string, rule: EmailRoutingRule, enabled: boolean): Promise<EmailRoutingRule> {
		return this.request<EmailRoutingRule>(`/zones/${zoneId}/email/routing/rules/${rule.id}`, {
			body: JSON.stringify({
				actions: rule.actions,
				enabled,
				matchers: rule.matchers,
				name: rule.name,
				priority: rule.priority,
			}),
			method: 'PUT',
		}).then(r => r.result)
	}

	/** List account Email Routing destination addresses (GET /accounts/:id/email/routing/addresses). */
	listEmailRoutingAddresses(accountId: string): Promise<EmailRoutingAddress[]> {
		return this.requestList<EmailRoutingAddress>(`/accounts/${accountId}/email/routing/addresses`).then(p => p.items)
	}

	/** Add a destination address — triggers a verification email (POST …/email/routing/addresses). */
	createEmailRoutingAddress(accountId: string, email: string): Promise<EmailRoutingAddress> {
		return this.request<EmailRoutingAddress>(`/accounts/${accountId}/email/routing/addresses`, {
			body: JSON.stringify({ email }),
			method: 'POST',
		}).then(r => r.result)
	}

	/** Remove a destination address (DELETE …/email/routing/addresses/:id). */
	async deleteEmailRoutingAddress(accountId: string, addressId: string): Promise<void> {
		await this.request<unknown>(`/accounts/${accountId}/email/routing/addresses/${addressId}`, { method: 'DELETE' })
	}

	/** List Registrar domains (GET /accounts/:id/registrar/domains). Requires the registrar read scope. */
	listRegistrarDomains(accountId: string): Promise<RegistrarDomain[]> {
		return this.requestList<RegistrarDomain>(`/accounts/${accountId}/registrar/domains`).then(p => p.items)
	}

	/** List Cloudflare Tunnels with health/connections (GET /accounts/:id/cfd_tunnel). Requires the tunnel read scope. */
	listTunnels(accountId: string, params?: { isDeleted?: boolean }): Promise<Tunnel[]> {
		const query = new URLSearchParams()
		query.set('is_deleted', String(params?.isDeleted ?? false))
		return this.requestList<Tunnel>(`/accounts/${accountId}/cfd_tunnel?${query.toString()}`).then(p => p.items)
	}

	/** List Zero Trust Access applications (GET /accounts/:id/access/apps). Requires the Access apps read scope. */
	listAccessApplications(accountId: string): Promise<AccessApplication[]> {
		return this.requestList<AccessApplication>(`/accounts/${accountId}/access/apps`).then(p => p.items)
	}

	/** Browse Cloudflare Images (GET /accounts/:id/images/v1). Requires the images read scope. */
	listImages(accountId: string, params?: { page?: number, perPage?: number }): Promise<ImagesImage[]> {
		const query = new URLSearchParams()
		if (params?.page)
			query.set('page', String(params.page))
		if (params?.perPage)
			query.set('per_page', String(params.perPage))
		const qs = query.toString()
		return this.request<{ images?: ImagesImage[] }>(`/accounts/${accountId}/images/v1${qs ? `?${qs}` : ''}`)
			.then(r => r.result.images ?? [])
	}

	/** Browse Stream videos (GET /accounts/:id/stream). Requires the Stream read scope. */
	listStreamVideos(accountId: string): Promise<StreamVideo[]> {
		return this.requestList<StreamVideo>(`/accounts/${accountId}/stream`).then(p => p.items)
	}

	/**
	 * Zone HTTP analytics via GraphQL (replaces the deprecated REST dashboard API).
	 * Uses hourly roll-ups for short ranges and daily roll-ups for longer ones.
	 * Requires the `analytics.read` scope. Daily groups work on all plans; hourly
	 * may fall back to daily on Free.
	 */
	async getZoneAnalytics(zoneId: string, params: { since: string, until: string }): Promise<ZoneAnalyticsDashboard> {
		const hours = (Date.parse(params.until) - Date.parse(params.since)) / 3_600_000
		if (hours <= 72) {
			try {
				return await this.getZoneAnalyticsHourly(zoneId, params)
			}
			catch {
				// Hourly datasets can be plan-gated — daily roll-ups work everywhere.
			}
		}
		return this.getZoneAnalyticsDaily(zoneId, params)
	}

	private async getZoneAnalyticsHourly(
		zoneId: string,
		params: { since: string, until: string },
	): Promise<ZoneAnalyticsDashboard> {
		const query = /* GraphQL */ `
			query ZoneAnalyticsHourly($zoneTag: String!, $since: Time!, $until: Time!, $limit: Int!) {
				viewer {
					zones(filter: { zoneTag: $zoneTag }) {
						httpRequests1hGroups(
							limit: $limit
							orderBy: [datetimeHour_ASC]
							filter: { datetime_geq: $since, datetime_lt: $until }
						) {
							dimensions { datetimeHour }
							sum { requests cachedRequests bytes threats }
						}
					}
				}
			}`
		interface Row {
			dimensions: { datetimeHour: string }
			sum: { bytes?: number, cachedRequests?: number, requests?: number, threats?: number }
		}
		interface Data {
			viewer: { zones: Array<{ httpRequests1hGroups: Row[] }> }
		}
		const data = await this.graphql<Data>(query, {
			limit: 100,
			since: params.since,
			until: params.until,
			zoneTag: zoneId,
		})
		const rows = data.viewer.zones[0]?.httpRequests1hGroups ?? []
		const timeseries = rows.map((row) => {
			const since = row.dimensions.datetimeHour
			return {
				bandwidth: { all: row.sum.bytes },
				requests: { all: row.sum.requests, cached: row.sum.cachedRequests },
				since,
				threats: { all: row.sum.threats },
				until: addHoursIso(since, 1),
			}
		})
		return { timeseries, totals: rollupZoneTotals(timeseries) }
	}

	private async getZoneAnalyticsDaily(
		zoneId: string,
		params: { since: string, until: string },
	): Promise<ZoneAnalyticsDashboard> {
		const dateGeq = params.since.slice(0, 10)
		const dateLeq = params.until.slice(0, 10)
		const query = /* GraphQL */ `
			query ZoneAnalyticsDaily($zoneTag: String!, $dateGeq: Date!, $dateLeq: Date!, $limit: Int!) {
				viewer {
					zones(filter: { zoneTag: $zoneTag }) {
						httpRequests1dGroups(
							limit: $limit
							orderBy: [date_ASC]
							filter: { date_geq: $dateGeq, date_leq: $dateLeq }
						) {
							dimensions { date }
							sum { requests cachedRequests bytes threats }
						}
					}
				}
			}`
		interface Row {
			dimensions: { date: string }
			sum: { bytes?: number, cachedRequests?: number, requests?: number, threats?: number }
		}
		interface Data {
			viewer: { zones: Array<{ httpRequests1dGroups: Row[] }> }
		}
		const data = await this.graphql<Data>(query, {
			dateGeq,
			dateLeq,
			limit: 1000,
			zoneTag: zoneId,
		})
		const rows = data.viewer.zones[0]?.httpRequests1dGroups ?? []
		const timeseries = rows.map((row) => {
			const since = `${row.dimensions.date}T00:00:00Z`
			return {
				bandwidth: { all: row.sum.bytes },
				requests: { all: row.sum.requests, cached: row.sum.cachedRequests },
				since,
				threats: { all: row.sum.threats },
				until: addDaysIso(since, 1),
			}
		})
		return { timeseries, totals: rollupZoneTotals(timeseries) }
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
	 * Requires the `account-analytics.read` scope.
	 *
	 * Uses `httpRequests1dGroups` — the daily roll-up available on all plans
	 * (1m/1h roll-ups are gated to higher plans). Bandwidth is the `bytes` sum;
	 * there is no `bandwidth` field in the GraphQL schema.
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
						httpRequests1dGroups(limit: $limit, filter: { date_geq: $dateGeq, date_leq: $dateLeq }) {
							sum { requests cachedRequests bytes cachedBytes threats pageViews }
							dimensions { date }
						}
					}
				}
			}`
		interface Row {
			dimensions: { date: string }
			sum: {
				bytes?: number
				cachedBytes?: number
				cachedRequests?: number
				pageViews?: number
				requests?: number
				threats?: number
			}
		}
		interface AccountAnalyticsData {
			viewer: {
				accounts: Array<{ httpRequests1dGroups: Row[] }>
			}
		}
		const data = await this.graphql<AccountAnalyticsData>(query, {
			accountTag: accountId,
			dateGeq,
			dateLeq,
			limit,
		})
		const rows = data.viewer.accounts[0]?.httpRequests1dGroups ?? []
		const points: AccountAnalyticsPoint[] = rows
			.map(row => ({
				date: row.dimensions.date,
				sum: {
					bandwidth: row.sum.bytes,
					cachedRequests: row.sum.cachedRequests,
					pageViews: row.sum.pageViews,
					requests: row.sum.requests,
					threats: row.sum.threats,
				},
			}))
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

	/**
	 * Recent firewall/security events for a zone via GraphQL
	 * (`firewallEventsAdaptive`), newest first. `since`/`until` are ISO 8601
	 * timestamps. Requires the `analytics.read` scope.
	 */
	async getFirewallEvents(zoneId: string, params: { limit?: number, since: string, until: string }): Promise<FirewallEvent[]> {
		const query = /* GraphQL */ `
			query FirewallEvents($zoneTag: String!, $since: Time!, $until: Time!, $limit: Int!) {
				viewer {
					zones(filter: { zoneTag: $zoneTag }) {
						firewallEventsAdaptive(
							limit: $limit
							filter: { datetime_geq: $since, datetime_leq: $until }
							orderBy: [datetime_DESC]
						) {
							action
							clientASNDescription
							clientAsn
							clientCountryName
							clientIP
							clientRequestHTTPHost
							clientRequestHTTPMethodName
							clientRequestHTTPProtocol
							clientRequestPath
							clientRequestQuery
							datetime
							rayName
							ruleId
							source
							userAgent
						}
					}
				}
			}`
		interface FirewallEventsData {
			viewer: {
				zones: Array<{ firewallEventsAdaptive: FirewallEvent[] }>
			}
		}
		const data = await this.graphql<FirewallEventsData>(query, {
			limit: params.limit ?? 100,
			since: params.since,
			until: params.until,
			zoneTag: zoneId,
		})
		return data.viewer.zones[0]?.firewallEventsAdaptive ?? []
	}

	/**
	 * Web Analytics (RUM) daily page views + visits for a site via GraphQL
	 * (`rumPageloadEventsAdaptiveGroups`). Requires the `account-analytics.read`
	 * scope and a Web Analytics site (`listRumSites`).
	 */
	async getWebAnalytics(accountId: string, siteTag: string, params: { since: string, until: string }): Promise<WebAnalyticsResult> {
		const query = /* GraphQL */ `
			query WebAnalytics($accountTag: String!, $siteTag: String!, $since: Time!, $until: Time!, $limit: Int!) {
				viewer {
					accounts(filter: { accountTag: $accountTag }) {
						rumPageloadEventsAdaptiveGroups(
							limit: $limit
							filter: { siteTag: $siteTag, datetime_geq: $since, datetime_leq: $until }
						) {
							count
							sum { visits }
							dimensions { date }
						}
					}
				}
			}`
		interface Row {
			count: number
			dimensions: { date: string }
			sum: { visits?: number }
		}
		interface WebAnalyticsData {
			viewer: {
				accounts: Array<{ rumPageloadEventsAdaptiveGroups: Row[] }>
			}
		}
		const data = await this.graphql<WebAnalyticsData>(query, {
			accountTag: accountId,
			limit: 1000,
			since: params.since,
			siteTag,
			until: params.until,
		})
		const rows = data.viewer.accounts[0]?.rumPageloadEventsAdaptiveGroups ?? []
		const points: WebAnalyticsPoint[] = rows
			.map(row => ({ date: row.dimensions.date, pageViews: row.count, visits: row.sum.visits }))
			.sort((a, b) => (a.date ?? '').localeCompare(b.date ?? ''))
		let pageViews = 0
		let visits = 0
		for (const p of points) {
			pageViews += p.pageViews ?? 0
			visits += p.visits ?? 0
		}
		return { points, totals: { pageViews, visits } }
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

function addHoursIso(iso: string, hours: number): string {
	return new Date(Date.parse(iso) + hours * 3_600_000).toISOString()
}

function addDaysIso(iso: string, days: number): string {
	const d = new Date(iso)
	d.setUTCDate(d.getUTCDate() + days)
	return d.toISOString()
}

function rollupZoneTotals(timeseries: ZoneAnalyticsPoint[]): ZoneAnalyticsTotal {
	let reqAll = 0
	let reqCached = 0
	let bw = 0
	let threats = 0
	let any = false
	for (const p of timeseries) {
		if (typeof p.requests?.all === 'number') {
			reqAll += p.requests.all
			any = true
		}
		if (typeof p.requests?.cached === 'number')
			reqCached += p.requests.cached
		if (typeof p.bandwidth?.all === 'number')
			bw += p.bandwidth.all
		if (typeof p.threats?.all === 'number')
			threats += p.threats.all
	}
	if (!any)
		return {}
	return {
		bandwidth: { all: bw },
		requests: { all: reqAll, cached: reqCached },
		threats: { all: threats },
	}
}
