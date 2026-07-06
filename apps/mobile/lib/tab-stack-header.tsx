import type { ColorValue } from 'react-native'

import type { ThemePalette } from './theme'

import { StackHeaderTitle } from '../components/stack-header-title'
import { stackScreenOptions } from './navigation'
import { useAccountAvatarHeaderOptions } from './use-account-avatar-header-options'

/** Shared stack defaults — native title so large-title collapse animations work. */
export function tabStackScreenOptions(theme: ThemePalette) {
	return {
		...stackScreenOptions(theme),
		headerBackButtonDisplayMode: 'minimal' as const,
		headerLargeTitle: false,
	}
}

/** Pushed screens (no large title): custom Text title; no custom headerTitle on roots. */
export function tabPushedStackScreenOptions(theme: ThemePalette) {
	return {
		...tabStackScreenOptions(theme),
		headerTitle: ({ children, tintColor }: { children: string, tintColor?: ColorValue }) => (
			<StackHeaderTitle tintColor={tintColor} title={String(children)} />
		),
	}
}

export function useTabRootScreenOptions(theme: ThemePalette, title: string) {
	const avatarHeader = useAccountAvatarHeaderOptions()

	return {
		...tabStackScreenOptions(theme),
		headerBackVisible: false,
		headerLargeTitle: true,
		title,
		...avatarHeader,
	}
}
