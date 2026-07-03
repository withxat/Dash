import type { ThemePalette } from './theme'

import { AccountAvatarHeaderButton } from '../components/account-avatar-header-button'
import { avatarHeaderSlotStyle } from './avatar-header'
import { stackScreenOptions } from './navigation'
import { SCREEN_GUTTER } from './screen-gutter'

export function tabStackScreenOptions(theme: ThemePalette) {
	return {
		...stackScreenOptions(theme),
		headerBackButtonDisplayMode: 'minimal' as const,
		headerLargeTitle: false,
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
