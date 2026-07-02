import type { TokenSet, TokenStore } from '@cloudfx/api'

import * as SecureStore from 'expo-secure-store'

const ACCESS_TOKEN_KEY = 'cloudfx.access_token'
const ACTIVE_ACCOUNT_KEY = 'cloudfx.active_account_id'
const REFRESH_TOKEN_KEY = 'cloudfx.refresh_token'
const EXPIRES_AT_KEY = 'cloudfx.expires_at'

export async function getActiveAccountId(): Promise<null | string> {
	return (await SecureStore.getItemAsync(ACTIVE_ACCOUNT_KEY)) ?? null
}

export async function setActiveAccount(id: null | string): Promise<void> {
	if (id) {
		await SecureStore.setItemAsync(ACTIVE_ACCOUNT_KEY, id)
		return
	}

	await SecureStore.deleteItemAsync(ACTIVE_ACCOUNT_KEY)
}

/**
 * Token storage backed by the iOS Keychain / Android Keystore via
 * expo-secure-store. Values are encrypted at rest and never written to disk
 * in plaintext.
 */
export const secureTokenStore: TokenStore = {
	async clear() {
		await SecureStore.deleteItemAsync(ACCESS_TOKEN_KEY)
		await SecureStore.deleteItemAsync(ACTIVE_ACCOUNT_KEY)
		await SecureStore.deleteItemAsync(REFRESH_TOKEN_KEY)
		await SecureStore.deleteItemAsync(EXPIRES_AT_KEY)
	},
	async getAccessToken() {
		return (await SecureStore.getItemAsync(ACCESS_TOKEN_KEY)) ?? null
	},
	async getRefreshToken() {
		return (await SecureStore.getItemAsync(REFRESH_TOKEN_KEY)) ?? null
	},
	async setTokens(tokens: TokenSet) {
		await SecureStore.setItemAsync(ACCESS_TOKEN_KEY, tokens.access_token)
		if (tokens.refresh_token) {
			await SecureStore.setItemAsync(REFRESH_TOKEN_KEY, tokens.refresh_token)
		}
		if (typeof tokens.expires_in === 'number') {
			const expiresAt = Date.now() + tokens.expires_in * 1000
			await SecureStore.setItemAsync(EXPIRES_AT_KEY, String(expiresAt))
		}
	},
}
