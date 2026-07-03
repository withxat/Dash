import * as SecureStore from 'expo-secure-store'
import { Platform } from 'react-native'

import { DEFAULT_HOME_SHORTCUT_IDS } from './app-catalog'

const HOME_SHORTCUTS_KEY = 'cloudfx.home_shortcuts'
const RECENT_ITEMS_KEY = 'cloudfx.recent_items'
const FREQUENT_ITEMS_KEY = 'cloudfx.frequent_items'
const MAX_RECENT_ITEMS = 8
const MAX_FREQUENT_ITEMS = 8

interface FrequentEntry {
	count: number
	lastUsedAt: number
}

type FrequentStore = Record<string, FrequentEntry>

const webStorage = new Map<string, string>()

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

function parseStringArray(raw: null | string, fallback: readonly string[]): string[] {
	if (!raw)
		return [...fallback]

	try {
		const parsed: unknown = JSON.parse(raw)
		if (!Array.isArray(parsed))
			return [...fallback]
		return parsed.filter((entry): entry is string => typeof entry === 'string')
	}
	catch {
		return [...fallback]
	}
}

export async function getHomeShortcutIds(): Promise<string[]> {
	const raw = await getItem(HOME_SHORTCUTS_KEY)
	// Unset/invalid falls back to defaults; an explicitly emptied list stays empty.
	return parseStringArray(raw, DEFAULT_HOME_SHORTCUT_IDS)
}

export async function setHomeShortcutIds(ids: string[]): Promise<void> {
	await setItem(HOME_SHORTCUTS_KEY, JSON.stringify(ids))
}

export async function getRecentItemIds(): Promise<string[]> {
	const raw = await getItem(RECENT_ITEMS_KEY)
	return parseStringArray(raw, [])
}

function parseFrequentStore(raw: null | string): FrequentStore {
	if (!raw)
		return {}

	try {
		const parsed: unknown = JSON.parse(raw)
		if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed))
			return {}

		const store: FrequentStore = {}
		for (const [id, value] of Object.entries(parsed)) {
			if (!value || typeof value !== 'object' || Array.isArray(value))
				continue
			const count = (value as FrequentEntry).count
			const lastUsedAt = (value as FrequentEntry).lastUsedAt
			if (typeof count !== 'number' || count < 1)
				continue
			store[id] = {
				count,
				lastUsedAt: typeof lastUsedAt === 'number' ? lastUsedAt : 0,
			}
		}
		return store
	}
	catch {
		return {}
	}
}

export async function getFrequentItemIds(): Promise<string[]> {
	const raw = await getItem(FREQUENT_ITEMS_KEY)
	const store = parseFrequentStore(raw)

	return Object.entries(store)
		.sort(([, a], [, b]) => b.count - a.count || b.lastUsedAt - a.lastUsedAt)
		.slice(0, MAX_FREQUENT_ITEMS)
		.map(([id]) => id)
}

async function recordFrequentItem(id: string): Promise<void> {
	const raw = await getItem(FREQUENT_ITEMS_KEY)
	const store = parseFrequentStore(raw)
	const current = store[id]
	const now = Date.now()

	store[id] = {
		count: (current?.count ?? 0) + 1,
		lastUsedAt: now,
	}

	await setItem(FREQUENT_ITEMS_KEY, JSON.stringify(store))
}

export async function recordRecentItem(id: string): Promise<void> {
	const current = await getRecentItemIds()
	const next = [id, ...current.filter(entry => entry !== id)].slice(0, MAX_RECENT_ITEMS)
	await setItem(RECENT_ITEMS_KEY, JSON.stringify(next))
	await recordFrequentItem(id)
}
