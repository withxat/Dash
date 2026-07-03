import type { Href } from 'expo-router'

export const TAB_NAMES = ['home', 'items', 'watchtower', 'search'] as const

export type TabName = typeof TAB_NAMES[number]

export const TAB_ROUTES = TAB_NAMES.map(
	name => `/(app)/(tabs)/${name}`,
) as readonly Href[]

export function isTabRootSegment(segments: readonly string[]): boolean {
	return segments.length === 3
		&& segments[1] === '(tabs)'
		&& TAB_NAMES.includes(segments[2] as TabName)
}
