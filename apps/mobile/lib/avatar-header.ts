import { Platform } from 'react-native'

import { SCREEN_GUTTER } from './screen-gutter'

export const AVATAR_HEADER_SIZE = 36

/** Native stack bar height below the status bar (no large title). */
export const NATIVE_HEADER_BAR_HEIGHT = Platform.select({ default: 56, ios: 44 }) ?? 56

/** Width reserved in tab-root headerLeft for the profile avatar. */
export const TAB_HEADER_LEFT_WIDTH = SCREEN_GUTTER + AVATAR_HEADER_SIZE

/** Fixed width for profile avatar in native header slots. */
export function avatarHeaderSlotStyle() {
	return {
		alignItems: 'flex-start' as const,
		flexGrow: 0,
		flexShrink: 0,
		justifyContent: 'center' as const,
		maxWidth: AVATAR_HEADER_SIZE,
		minWidth: AVATAR_HEADER_SIZE,
		width: AVATAR_HEADER_SIZE,
	}
}
