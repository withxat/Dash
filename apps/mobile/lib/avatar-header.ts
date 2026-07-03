import type { ViewStyle } from 'react-native'

import { Platform } from 'react-native'

import { SCREEN_GUTTER } from './screen-gutter'

/** Native stack bar height below the status bar (no large title). */
export const NATIVE_HEADER_BAR_HEIGHT = Platform.select({ default: 56, ios: 44 }) ?? 56

/**
 * Matches UIKit minimal back-button wrapper width (react-native-screens).
 * iOS native bar-button items use this width so avatar ↔ back align.
 */
export const AVATAR_HEADER_BAR_BUTTON_WIDTH = Platform.select({ default: 48, ios: 44 }) ?? 44

/** Visible avatar diameter — same as bar-button width on iOS. */
export const AVATAR_HEADER_SIZE = AVATAR_HEADER_BAR_BUTTON_WIDTH

/** @deprecated Use `AVATAR_HEADER_SIZE` */
export const AVATAR_HEADER_SLOT_SIZE = AVATAR_HEADER_SIZE

/** @deprecated Use `AVATAR_HEADER_SIZE` */
export const AVATAR_HEADER_SLOT_WIDTH = AVATAR_HEADER_SIZE

/** Width reserved in tab-root headerLeft for the profile avatar. */
export const TAB_HEADER_LEFT_WIDTH = SCREEN_GUTTER + AVATAR_HEADER_SIZE

/** Header avatar press target — square slot aligned with the native back-button wrapper. */
export function avatarHeaderPressableStyle(size = AVATAR_HEADER_SIZE): ViewStyle {
	return {
		flexGrow: 0,
		flexShrink: 0,
		height: size,
		maxHeight: size,
		maxWidth: size,
		minHeight: size,
		minWidth: size,
		width: size,
	}
}
