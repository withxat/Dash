import type { ColorValue } from 'react-native'

import type { ThemePalette } from './theme'

import { AccountAvatarHeaderButton } from '../components/account-avatar-header-button'
import { StackHeaderTitle } from '../components/stack-header-title'
import { avatarHeaderSlotStyle } from './avatar-header'
import { stackScreenOptions } from './navigation'
import { SCREEN_GUTTER } from './screen-gutter'

/** Shared stack defaults — native title so large-title collapse animations work. */
export function tabStackScreenOptions(theme: ThemePalette) {
	return {
		...stackScreenOptions(theme),
		headerBackButtonDisplayMode: 'minimal' as const,
		headerLargeTitle: false,
	}
}

/** Pushed screens (no large title): HeaderTitle for Chill Heavy; no custom headerTitle on roots. */
export function tabPushedStackScreenOptions(theme: ThemePalette) {
	return {
		...tabStackScreenOptions(theme),
		headerTitle: ({ children, tintColor }: { children: string, tintColor?: ColorValue }) => (
			<StackHeaderTitle tintColor={tintColor} title={String(children)} />
		),
	}
}

export function tabRootScreenOptions(theme: ThemePalette, title: string) {
	return {
		...tabStackScreenOptions(theme),
		headerBackVisible: false,
		headerLargeTitle: true,
		headerLeft: () => <AccountAvatarHeaderButton />,
		headerLeftContainerStyle: {
			...avatarHeaderSlotStyle(),
			paddingLeft: SCREEN_GUTTER,
		},
		title,
	}
}
