import type { Stack } from 'expo-router'
import type { NativeStackNavigationOptions } from 'expo-router/build/react-navigation/native-stack/types'
import type { ComponentProps } from 'react'
import type { TextStyle } from 'react-native'

import type { ThemePalette } from './theme'

import { Platform } from 'react-native'

import { chillFontBold } from './fonts'

type StackScreenOptions = NonNullable<ComponentProps<typeof Stack>['screenOptions']>

/** iOS material blur for pushed screens (not tab-root large titles — iOS 26 RN Screens #3100). */
export function stackPushedHeaderBlurOptions(): Pick<NativeStackNavigationOptions, 'headerBlurEffect' | 'headerTransparent'> {
	return Platform.OS === 'ios'
		? {
				headerBlurEffect: 'systemChromeMaterial',
				headerTransparent: true,
			}
		: {}
}

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
		headerLargeTitleShadowVisible: false,
		headerLargeTitleStyle: {
			color: theme.default,
			fontFamily: chillFontBold,
			fontWeight: '700',
		},
		headerShadowVisible: false,
		headerTintColor: theme.default,
		headerTitleStyle: stackHeaderTitleStyle(theme),
	}
}
