import type { ViewStyle } from 'react-native'

import type { ThemePalette } from './theme'

/** Kumo-style card elevation: soft drop shadow plus hairline edge. */
export function cardShadowStyle(theme: ThemePalette, elevated = false): ViewStyle {
	return {
		borderCurve: 'continuous',
		boxShadow: elevated ? theme.shadowElevated : theme.shadowCard,
	}
}

/** Floating overlay shadow (toasts, popovers). */
export function overlayShadowStyle(theme: ThemePalette): ViewStyle {
	return {
		borderCurve: 'continuous',
		boxShadow: theme.shadowOverlay,
	}
}

/** Kumo switch thumb shadow. */
export function thumbShadowStyle(theme: ThemePalette): ViewStyle {
	return {
		boxShadow: theme.shadowThumb,
	}
}
