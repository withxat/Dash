import type { Stack } from 'expo-router'
import type { ComponentProps } from 'react'
import type { TextStyle } from 'react-native'

import type { ThemePalette } from './theme'

import { chillFontHeavy } from './fonts'

type StackScreenOptions = NonNullable<ComponentProps<typeof Stack>['screenOptions']>

/** Native inline title when a large title collapses (tab roots). */
export function stackHeaderTitleStyle(theme: ThemePalette): TextStyle {
	return { color: theme.default, fontSize: 17, fontWeight: '600' }
}

/** Pushed sub-screen title — system semibold, not Chill. */
export function stackPushedHeaderTitleStyle(theme: ThemePalette): TextStyle {
	return { color: theme.default, fontSize: 17, fontWeight: '600' }
}

/**
 * Shared native-stack screen options themed from the current palette. Large
 * titles collapse on iOS; Android falls back to a regular app bar.
 */
export function stackScreenOptions(theme: ThemePalette): StackScreenOptions {
	return {
		contentStyle: { backgroundColor: theme.canvas },
		// iOS 26 UIKit bug: any custom header background (headerStyle or
		// headerLargeStyle backgroundColor, or a blur effect) makes the large
		// title invisible except during the collapse transition — see
		// react-native-screens#3100. Leave the header background fully to the
		// system; the canvas color is close enough to the system background.
		headerLargeTitle: true,
		headerLargeTitleShadowVisible: false,
		headerLargeTitleStyle: {
			color: theme.default,
			fontFamily: chillFontHeavy,
			fontWeight: '800',
		},
		headerShadowVisible: false,
		headerTintColor: theme.default,
		headerTitleStyle: stackHeaderTitleStyle(theme),
	}
}
