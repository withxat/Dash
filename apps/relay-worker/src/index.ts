/**
 * Dash OAuth relay.
 *
 * Cloudflare OAuth clients only accept http(s) redirect URIs, but Dash
 * captures the `dash://`
 * custom scheme. This worker is deployed at the registered https redirect URI
 * and converts the OAuth callback into a `dash://` redirect the app captures.
 *
 * Security: the authorization code is one-time, short-lived, and bound to the
 * PKCE code_verifier held only in the app, so neither this relay nor anyone
 * observing the redirect can exchange it. The worker is stateless and logs
 * nothing.
 */

// MUST match the native app's capture URI.
const APP_CALLBACK = 'dash://oauth/callback'

export default {
	async fetch(request: Request): Promise<Response> {
		if (request.method !== 'GET') {
			return new Response('Method Not Allowed', { status: 405 })
		}

		const url = new URL(request.url)

		// Liveness probe — verify the worker is reachable before registering it
		// as a redirect URI. `GET /` with no query returns 200.
		if (url.pathname === '/' && url.search === '') {
			return new Response('Dash OAuth relay OK\n', {
				headers: { 'content-type': 'text/plain' },
			})
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
	},
}
