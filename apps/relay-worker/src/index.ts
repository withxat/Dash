/**
 * Dash relay worker.
 *
 * Serves the HTTPS OAuth callback Cloudflare requires, and reserves `/push/*`
 * for the APNs notification bridge (added in later commits). Stateless: does
 * not persist authorization state, Cloudflare credentials, or the PKCE
 * verifier.
 */

import { handleOAuth } from './oauth'

export default {
	async fetch(request: Request): Promise<Response> {
		const url = new URL(request.url)

		// Liveness probe — verify the worker is reachable before registering it
		// as a redirect URI. `GET /` with no query returns 200.
		if (url.pathname === '/' && url.search === '') {
			return new Response('Dash OAuth relay OK\n', {
				headers: { 'content-type': 'text/plain' },
			})
		}

		// Push routes must be claimed before the OAuth catch-all, otherwise
		// every `/push/*` request would 302 to `dash://`.
		if (url.pathname.startsWith('/push/')) {
			return new Response('Not Found', { status: 404 })
		}

		return handleOAuth(request, url)
	},
}
