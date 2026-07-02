/** Cloudflare OAuth 2.0 authorization-server endpoints (dash.cloudflare.com). */
export const CLOUDFLARE_OAUTH_ENDPOINTS = {
	authorizationEndpoint: 'https://dash.cloudflare.com/oauth2/authorize',
	revocationEndpoint: 'https://dash.cloudflare.com/oauth2/revoke',
	tokenEndpoint: 'https://dash.cloudflare.com/oauth2/token',
} as const

/** Cloudflare REST API v4 base. OAuth access tokens are used as Bearer tokens here. */
export const CLOUDFLARE_API_BASE = 'https://api.cloudflare.com/client/v4'

/** A token set returned by the Cloudflare OAuth token endpoint. */
export interface TokenSet {
	access_token: string
	/** Lifetime in seconds. */
	expires_in?: number
	/** Present when the OAuth client has the `refresh_token` grant type enabled. */
	refresh_token?: string
	/** Scope actually granted (may differ from requested). */
	scope?: string
	token_type?: string
}

export interface OAuthEndpoints {
	authorizationEndpoint: string
	revocationEndpoint: string
	tokenEndpoint: string
}

export interface ExchangeCodeParams {
	/** The OAuth client id registered in the Cloudflare dashboard. */
	clientId: string
	/** Authorization code from the callback. */
	code: string
	/** PKCE code verifier paired with the challenge sent at authorize time. */
	codeVerifier: string
	endpoints?: OAuthEndpoints
	/** Must match the redirect URI registered on the OAuth client. */
	redirectUri: string
}

export interface RefreshParams {
	clientId: string
	endpoints?: OAuthEndpoints
	refreshToken: string
}

export interface RevokeParams {
	clientId: string
	endpoints?: OAuthEndpoints
	token: string
	/** Hint whether the token is an access or refresh token. */
	tokenTypeHint?: 'access_token' | 'refresh_token'
}

export class OAuthError extends Error {
	readonly error: string
	readonly errorDescription?: string
	constructor(error: string, errorDescription?: string) {
		super(errorDescription ? `${error}: ${errorDescription}` : error)
		this.name = 'OAuthError'
		this.error = error
		this.errorDescription = errorDescription
	}
}

function resolveEndpoints(endpoints?: Partial<OAuthEndpoints>): OAuthEndpoints {
	return { ...CLOUDFLARE_OAUTH_ENDPOINTS, ...endpoints }
}

async function postForm(url: string, params: Record<string, string>): Promise<Record<string, unknown>> {
	const body = new URLSearchParams(params)
	const res = await fetch(url, {
		body,
		headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
		method: 'POST',
	})
	const data: unknown = await res.json().catch(() => null)

	// OAuth2 error responses are flat: { error, error_description }.
	if (data && typeof data === 'object' && 'error' in data) {
		const err = data as { error?: string, error_description?: string }
		throw new OAuthError(
			typeof err.error === 'string' ? err.error : 'oauth_error',
			typeof err.error_description === 'string' ? err.error_description : undefined,
		)
	}

	if (!res.ok) {
		throw new OAuthError('http_error', `token endpoint returned ${res.status}`)
	}

	return (data ?? {}) as Record<string, unknown>
}

function toTokenSet(data: Record<string, unknown>): TokenSet {
	const access_token = data.access_token
	if (typeof access_token !== 'string') {
		throw new OAuthError('invalid_token_response', 'access_token missing in response')
	}
	return {
		access_token,
		expires_in: typeof data.expires_in === 'number' ? data.expires_in : undefined,
		refresh_token: typeof data.refresh_token === 'string' ? data.refresh_token : undefined,
		scope: typeof data.scope === 'string' ? data.scope : undefined,
		token_type: typeof data.token_type === 'string' ? data.token_type : undefined,
	}
}

/** Exchange an authorization code for an access (and refresh) token using PKCE. */
export async function exchangeAuthorizationCode(params: ExchangeCodeParams): Promise<TokenSet> {
	const endpoints = resolveEndpoints(params.endpoints)
	const data = await postForm(endpoints.tokenEndpoint, {
		client_id: params.clientId,
		code: params.code,
		code_verifier: params.codeVerifier,
		grant_type: 'authorization_code',
		redirect_uri: params.redirectUri,
	})
	return toTokenSet(data)
}

/** Refresh an access token using a refresh token. */
export async function refreshAccessToken(params: RefreshParams): Promise<TokenSet> {
	const endpoints = resolveEndpoints(params.endpoints)
	const data = await postForm(endpoints.tokenEndpoint, {
		client_id: params.clientId,
		grant_type: 'refresh_token',
		refresh_token: params.refreshToken,
	})
	return toTokenSet(data)
}

/** Revoke an access or refresh token so it can no longer be used. */
export async function revokeToken(params: RevokeParams): Promise<void> {
	const endpoints = resolveEndpoints(params.endpoints)
	const body: Record<string, string> = {
		client_id: params.clientId,
		token: params.token,
	}
	if (params.tokenTypeHint)
		body.token_type_hint = params.tokenTypeHint
	await postForm(endpoints.revocationEndpoint, body)
}
