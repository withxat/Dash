import type { Stack } from 'expo-router'
import type { ComponentProps } from 'react'
import type { TextStyle } from 'react-native'

import type { ThemePalette } from './theme'

import { chillFaceStyle, chillFonts, chillNativeHeaderStyle } from './fonts'

type StackScreenOptions = NonNullable<ComponentProps<typeof Stack>['screenOptions']>

/** Native inline title when a large title collapses (tab roots). */
export function stackHeaderTitleStyle(theme: ThemePalette): TextStyle {
	return chillNativeHeaderStyle('bold', { color: theme.default, fontSize: 17 })
}

/** Pushed sub-screen title — one Chill step below heavy (bold). */
export function stackPushedHeaderTitleStyle(theme: ThemePalette): TextStyle {
	return chillFaceStyle('bold', { color: theme.default, fontSize: 17 })
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
		headerLargeTitleStyle: { color: theme.default, fontFamily: chillFonts.heavy, fontWeight: '800' },
		headerShadowVisible: false,
		headerTintColor: theme.default,
		headerTitleStyle: stackHeaderTitleStyle(theme),
	}
}
