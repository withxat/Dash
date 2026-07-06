import type { NativeStackNavigationOptions } from 'expo-router/build/react-navigation/native-stack/types'
import type { ColorValue } from 'react-native'

import type { ThemePalette } from './theme'

import { useMemo } from 'react'

import { StackHeaderTitle } from '../components/stack-header-title'
import { stackPushedHeaderBlurOptions, stackScreenOptions } from './navigation'
import { useAccountAvatarHeaderOptions } from './use-account-avatar-header-options'

/** Shared stack defaults for tab stacks (pushed screens keep the native app bar). */
export function tabStackScreenOptions(theme: ThemePalette) {
	return {
		...stackScreenOptions(theme),
		headerBackButtonDisplayMode: 'minimal' as const,
		headerLargeTitle: false,
	}
}

/** Pushed screens: custom Text title in the native app bar. */
export function tabPushedStackScreenOptions(theme: ThemePalette) {
	return {
		...tabStackScreenOptions(theme),
		...stackPushedHeaderBlurOptions(),
		headerTitle: ({ children, tintColor }: { children: string, tintColor?: ColorValue }) => (
			<StackHeaderTitle tintColor={tintColor} title={String(children)} />
		),
	}
}

type TabRootExtraOptions = Pick<NativeStackNavigationOptions, 'headerRight'>

/**
 * Tab roots use the native stack bar so iOS can morph avatar ↔ back on push.
 * Title renders as a native large title below the avatar row.
 */
export function useTabRootScreenOptions(
	theme: ThemePalette,
	title: string,
	extra?: TabRootExtraOptions,
) {
	const avatarHeader = useAccountAvatarHeaderOptions()

	return useMemo(
		() => ({
			...tabStackScreenOptions(theme),
			headerBackVisible: false,
			headerLargeTitle: true as const,
			headerShown: true as const,
			title,
			...avatarHeader,
			...extra,
		}),
		[avatarHeader, extra, theme, title],
	)
}
