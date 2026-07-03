import type { ReactNode } from 'react'

import type { AuthContextValue, AuthStatus } from './auth-context'

import { exchangeAuthorizationCode, revokeToken } from '@cloudfx/api'
import { ResponseType, useAuthRequest } from 'expo-auth-session'
import * as WebBrowser from 'expo-web-browser'
import { useCallback, useEffect, useMemo, useState } from 'react'

import { AuthContext } from './auth-context'
import { CLOUDFLARE_APP_CALLBACK, CLOUDFLARE_CLIENT_ID, CLOUDFLARE_DISCOVERY, CLOUDFLARE_REDIRECT_URI, CLOUDFLARE_SCOPES } from './config'
import { secureTokenStore } from './storage'

// Closes the in-app browser once the OAuth redirect returns to the app.
WebBrowser.maybeCompleteAuthSession()

export function AuthProvider({ children }: { children: ReactNode }) {
	const [status, setStatus] = useState<AuthStatus>('loading')
	const [exchanging, setExchanging] = useState(false)
	const [error, setError] = useState<null | string>(null)

	// expo-auth-session builds the authorize URL and manages PKCE
	// (code_verifier + code_challenge) and state. We pass the registered https
	// redirect URI (sent to Cloudflare) but capture the `cloudfx://` deep link
	// the relay Worker redirects into — so signIn() calls
	// `WebBrowser.openAuthSessionAsync(authUrl, CLOUDFLARE_APP_CALLBACK)` directly
	// instead of the hook's promptAsync(), which would watch the https URI and
	// never match the cloudfx:// capture.
	const [request] = useAuthRequest(
		{
			clientId: CLOUDFLARE_CLIENT_ID,
			redirectUri: CLOUDFLARE_REDIRECT_URI,
			responseType: ResponseType.Code,
			scopes: CLOUDFLARE_SCOPES,
			usePKCE: true,
		},
		CLOUDFLARE_DISCOVERY,
	)

	// Bootstrap: if we already hold an access token, consider the session active.
	useEffect(() => {
		void (async () => {
			const token = await secureTokenStore.getAccessToken()
			setStatus(token ? 'authenticated' : 'unauthenticated')
		})()
	}, [])

	const signIn = useCallback(async () => {
		setError(null)
		if (!request) {
			setError('Auth request not ready. Make sure CLOUDFLARE_CLIENT_ID and CLOUDFLARE_REDIRECT_URI are set.')
			return
		}
		try {
			// Library generates the PKCE pair + state and builds the authorize URL
			// with redirect_uri = the registered https relay Worker URL.
			const authUrl = await request.makeAuthUrlAsync(CLOUDFLARE_DISCOVERY)
			// The in-app browser watches for the `cloudfx://` deep link: Cloudflare
			// redirects to the https Worker, which 302s into cloudfx://, captured here.
			const result = await WebBrowser.openAuthSessionAsync(authUrl, CLOUDFLARE_APP_CALLBACK)
			if (result.type === 'success') {
				const params = new URL(result.url).searchParams
				const code = params.get('code')
				const state = params.get('state')
				if (!code) {
					// Cloudflare redirected back with an error instead of a code
					// (e.g. invalid_scope when a requested scope isn't enabled on
					// the OAuth client in the dashboard). Surface the real reason.
					const oauthError = params.get('error')
					const oauthErrorDescription = params.get('error_description')
					setError(
						oauthError
							? `OAuth error: ${oauthError}${oauthErrorDescription ? ` — ${oauthErrorDescription}` : ''}`
							: 'OAuth response missing code.',
					)
					return
				}
				// CSRF guard — the state we sent must match the state returned.
				if (!state || state !== request.state) {
					setError('OAuth state mismatch — aborting.')
					return
				}
				const codeVerifier = request.codeVerifier
				if (!codeVerifier) {
					setError('PKCE verifier missing.')
					return
				}
				setExchanging(true)
				try {
					const tokens = await exchangeAuthorizationCode({
						clientId: CLOUDFLARE_CLIENT_ID,
						code,
						codeVerifier,
						redirectUri: CLOUDFLARE_REDIRECT_URI,
					})
					await secureTokenStore.setTokens(tokens)
					setStatus('authenticated')
				}
				catch (err) {
					setError(err instanceof Error ? err.message : String(err))
				}
				finally {
					setExchanging(false)
				}
			}
			// Non-success (cancel / dismiss / opened / locked): user backed out or a
			// platform state — nothing to surface.
		}
		catch (err) {
			setError(err instanceof Error ? err.message : String(err))
		}
	}, [request])

	const signOut = useCallback(async () => {
		const accessToken = await secureTokenStore.getAccessToken()
		if (accessToken) {
			try {
				await revokeToken({
					clientId: CLOUDFLARE_CLIENT_ID,
					token: accessToken,
					tokenTypeHint: 'access_token',
				})
			}
			catch {
				// Best-effort: token may already be expired; clear locally regardless.
			}
		}
		await secureTokenStore.clear()
		setStatus('unauthenticated')
	}, [])

	const value = useMemo<AuthContextValue>(
		() => ({ error, exchanging, signIn, signOut, status }),
		[status, exchanging, error, signIn, signOut],
	)

	return <AuthContext value={value}>{children}</AuthContext>
}
