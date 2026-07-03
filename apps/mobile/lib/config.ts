import { CLOUDFLARE_OAUTH_ENDPOINTS, DEFAULT_CLOUDFLARE_SCOPES } from '@cloudfx/api'
import { makeRedirectUri } from 'expo-auth-session'

/**
 * Cloudflare OAuth client id.
 *
 * Create an OAuth client in the Cloudflare dashboard:
 *   My Profile → API Tokens → "Get your API token" → Create OAuth Client
 * (or via the IAM OAuth Clients API). This is a public client (PKCE) so the id
 * is not secret and may be bundled. Set it via the EXPO_PUBLIC_CLOUDFLARE_CLIENT_ID
 * env var, or hardcode it below for local development.
 */
export const CLOUDFLARE_CLIENT_ID
	= process.env.EXPO_PUBLIC_CLOUDFLARE_CLIENT_ID ?? ''

/**
 * Registered https redirect URI. Cloudflare OAuth clients only allow http(s)
 * redirect URIs, so this points at the CloudFX relay Worker (apps/relay-worker)
 * which 302-redirects the callback into the `cloudfx://` deep link the app
 * captures. Deploy the worker, then set this to its /oauth/callback URL, e.g.
 * https://cloudfx-relay.<subdomain>.workers.dev/oauth/callback.
 *
 * Sent as `redirect_uri` in both the authorize request and the token exchange.
 */
export const CLOUDFLARE_REDIRECT_URI
	= process.env.EXPO_PUBLIC_CLOUDFLARE_REDIRECT_URI ?? ''

/**
 * Custom-scheme URI the app captures from the in-app browser. The relay Worker
 * redirects the https callback here. In a dev/standalone build with the
 * `cloudfx` scheme this resolves to `cloudfx://oauth/callback`.
 */
export const CLOUDFLARE_APP_CALLBACK = makeRedirectUri({
	path: 'oauth/callback',
	scheme: 'cloudfx',
})

/** Default scopes requested at login. See packages/api scopes for the full set. */
export const CLOUDFLARE_SCOPES = [...DEFAULT_CLOUDFLARE_SCOPES]

export const CLOUDFLARE_DISCOVERY = CLOUDFLARE_OAUTH_ENDPOINTS

export const isCloudflareConfigured
	= CLOUDFLARE_CLIENT_ID.length > 0 && CLOUDFLARE_REDIRECT_URI.length > 0
