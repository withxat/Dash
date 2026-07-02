import type { ReactNode } from 'react'

import type { AuthContextValue, AuthStatus } from './auth-context'

import { exchangeAuthorizationCode, revokeToken } from '@cloudfx/api'
import { ResponseType, useAuthRequest } from 'expo-auth-session'
import * as WebBrowser from 'expo-web-browser'
import { useCallback, useEffect, useMemo, useState } from 'react'

import { AuthContext } from './auth-context'
import { CLOUDFLARE_CLIENT_ID, CLOUDFLARE_DISCOVERY, CLOUDFLARE_REDIRECT_URI, CLOUDFLARE_SCOPES } from './config'
import { secureTokenStore } from './storage'

// Closes the in-app browser once the OAuth redirect returns to the app.
WebBrowser.maybeCompleteAuthSession()

export function AuthProvider({ children }: { children: ReactNode }) {
	const [status, setStatus] = useState<AuthStatus>('loading')
	const [exchanging, setExchanging] = useState(false)
	const [error, setError] = useState<null | string>(null)

	const [request, , promptAsync] = useAuthRequest(
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
			setError('Auth request not ready. Make sure CLOUDFLARE_CLIENT_ID is set.')
			return
		}
		try {
			const result = await promptAsync()
			if (result.type === 'success') {
				const code = result.params.code
				const codeVerifier = request.codeVerifier
				if (!code || !codeVerifier) {
					setError('OAuth response missing code or PKCE verifier.')
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
			else if (result.type === 'error') {
				setError(result.error?.description ?? result.error?.message ?? 'OAuth error')
			}
			// 'cancel' / 'dismiss' / 'locked' are no-ops.
		}
		catch (err) {
			setError(err instanceof Error ? err.message : String(err))
		}
	}, [request, promptAsync])

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
