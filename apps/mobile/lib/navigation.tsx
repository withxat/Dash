import type { Stack } from 'expo-router'
import type { ComponentProps } from 'react'
import type { TextStyle } from 'react-native'

import type { ThemePalette } from './theme'

type StackScreenOptions = NonNullable<ComponentProps<typeof Stack>['screenOptions']>

/** Native inline title in the pushed-screen app bar. */
export function stackHeaderTitleStyle(theme: ThemePalette): TextStyle {
	return { color: theme.default, fontSize: 17, fontWeight: '600' }
}

/** Pushed sub-screen title — system semibold, not Chill. */
export function stackPushedHeaderTitleStyle(theme: ThemePalette): TextStyle {
	return { color: theme.default, fontSize: 17, fontWeight: '600' }
}

/** Shared native-stack screen options for pushed screens and form sheets. */
export function stackScreenOptions(theme: ThemePalette): StackScreenOptions {
	return {
		contentStyle: { backgroundColor: theme.canvas },
		headerLargeTitle: false,
		headerShadowVisible: false,
		headerTintColor: theme.default,
		headerTitleStyle: stackHeaderTitleStyle(theme),
	}
}
