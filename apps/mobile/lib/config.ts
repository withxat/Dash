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
 * Redirect URI computed for the current runtime. In a development build or
 * standalone build this resolves to `cloudfx://oauth/callback` (the app
 * scheme). Register the value printed on the login screen in your Cloudflare
 * OAuth client's allowed redirect URIs.
 */
export const CLOUDFLARE_REDIRECT_URI = makeRedirectUri({
	path: 'oauth/callback',
	scheme: 'cloudfx',
})

/** Default scopes requested at login. See packages/api scopes for the full set. */
export const CLOUDFLARE_SCOPES = [...DEFAULT_CLOUDFLARE_SCOPES]

export const CLOUDFLARE_DISCOVERY = CLOUDFLARE_OAUTH_ENDPOINTS

export const isCloudflareConfigured = CLOUDFLARE_CLIENT_ID.length > 0
