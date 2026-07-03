import type { ViewStyle } from 'react-native'

import type { ThemePalette } from './theme'

import { StyleSheet } from 'react-native'

/** Kumo-style card elevation: soft drop shadow plus hairline edge. */
export function cardShadowStyle(theme: ThemePalette, elevated = false): ViewStyle {
	return {
		borderCurve: 'continuous',
		boxShadow: elevated ? theme.shadowElevated : theme.shadowCard,
	}
}

/**
 * Hairline outline around a surface — drawn outside the border box (RN 0.77+,
 * New Architecture) so it does not change layout width vs a sibling header.
 */
export function frameOutlineStyle(theme: ThemePalette, offset = 0): ViewStyle {
	return {
		borderCurve: 'continuous',
		outlineColor: theme.line,
		outlineOffset: offset,
		outlineStyle: 'solid',
		outlineWidth: StyleSheet.hairlineWidth,
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
