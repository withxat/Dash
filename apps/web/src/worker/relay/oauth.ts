/**
 * OAuth callback branch of the Dash relay.
 *
 * Cloudflare OAuth clients only accept http(s) redirect URIs, but Dash
 * captures the `dash://` custom scheme. This handler converts the OAuth
 * callback into a `dash://` redirect the app captures.
 *
 * Security: the authorization code is one-time, short-lived, and bound to the
 * PKCE code_verifier held only in the app, so neither this relay nor anyone
 * observing the redirect can exchange it. The handler is stateless and does
 * not log query parameters.
 */

// MUST match the native app's capture URI.
const APP_CALLBACK = 'dash://oauth/callback'

export function handleOAuth(request: Request, url: URL): Response {
	if (request.method !== 'GET') {
		return new Response('Method Not Allowed', { status: 405 })
	}

	// Forward the full query string (code, state, iss, …) to the app.
	const target = `${APP_CALLBACK}${url.search}`
	return new Response('Redirecting to Dash…', {
		headers: {
			// Never cache — a stale redirect must not replay an old code.
			'cache-control': 'no-store',
			'content-type': 'text/plain',
			'location': target,
		},
		status: 302,
	})
}
