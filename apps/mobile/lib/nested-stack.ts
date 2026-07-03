import type { ThemePalette } from './theme'

/** Nested stacks under the app shell — header is owned by `(app)/_layout`. */
export function nestedStackScreenOptions(theme: ThemePalette) {
	return {
		contentStyle: { backgroundColor: theme.canvas },
		headerShown: false,
	} as const
}
