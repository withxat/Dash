import type { TokenSet, TokenStore } from '@cloudfx/api'

import * as SecureStore from 'expo-secure-store'
import { Platform } from 'react-native'

const ACCESS_TOKEN_KEY = 'cloudfx.access_token'
const ACTIVE_ACCOUNT_KEY = 'cloudfx.active_account_id'
const REFRESH_TOKEN_KEY = 'cloudfx.refresh_token'
const EXPIRES_AT_KEY = 'cloudfx.expires_at'
const webStorage = new Map<string, string>()

async function deleteItem(key: string): Promise<void> {
	if (Platform.OS === 'web') {
		webStorage.delete(key)
		return
	}

	await SecureStore.deleteItemAsync(key)
}

async function getItem(key: string): Promise<null | string> {
	if (Platform.OS === 'web')
		return webStorage.get(key) ?? null

	return (await SecureStore.getItemAsync(key)) ?? null
}

async function setItem(key: string, value: string): Promise<void> {
	if (Platform.OS === 'web') {
		webStorage.set(key, value)
		return
	}

	await SecureStore.setItemAsync(key, value)
}

export async function getActiveAccountId(): Promise<null | string> {
	return getItem(ACTIVE_ACCOUNT_KEY)
}

export async function setActiveAccount(id: null | string): Promise<void> {
	if (id) {
		await setItem(ACTIVE_ACCOUNT_KEY, id)
		return
	}

	await deleteItem(ACTIVE_ACCOUNT_KEY)
}

/**
 * Token storage backed by the iOS Keychain / Android Keystore via
 * expo-secure-store. Values are encrypted at rest and never written to disk
 * in plaintext.
 */
export const secureTokenStore: TokenStore = {
	async clear() {
		await deleteItem(ACCESS_TOKEN_KEY)
		await deleteItem(ACTIVE_ACCOUNT_KEY)
		await deleteItem(REFRESH_TOKEN_KEY)
		await deleteItem(EXPIRES_AT_KEY)
	},
	async getAccessToken() {
		return getItem(ACCESS_TOKEN_KEY)
	},
	async getRefreshToken() {
		return getItem(REFRESH_TOKEN_KEY)
	},
	async setTokens(tokens: TokenSet) {
		await setItem(ACCESS_TOKEN_KEY, tokens.access_token)
		if (tokens.refresh_token) {
			await setItem(REFRESH_TOKEN_KEY, tokens.refresh_token)
		}
		if (typeof tokens.expires_in === 'number') {
			const expiresAt = Date.now() + tokens.expires_in * 1000
			await setItem(EXPIRES_AT_KEY, String(expiresAt))
		}
	},
}
