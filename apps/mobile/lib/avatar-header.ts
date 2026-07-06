import type { ViewStyle } from 'react-native'

import { Platform } from 'react-native'

import { SCREEN_GUTTER } from './screen-gutter'

/** Native stack bar height below the status bar (no large title). */
export const NATIVE_HEADER_BAR_HEIGHT = Platform.select({ default: 56, ios: 44 }) ?? 56

/**
 * iOS navigation bar row fits ~44pt controls — use the full square slot so the avatar
 * stays circular (Liquid Glass bar buttons target this size on iOS 26).
 */
export const IOS_HEADER_BAR_BUTTON_SIZE = 44

/** Whether the current iOS version uses Liquid Glass header bar buttons. */
export function isIosLiquidGlassHeader() {
	return Platform.OS === 'ios' && Number(Platform.Version) >= 26
}

/** Header avatar / bar-button size — matches UIKit minimal back-button slot on iOS. */
export const AVATAR_HEADER_BAR_BUTTON_WIDTH = Platform.select({
	default: 48,
	ios: IOS_HEADER_BAR_BUTTON_SIZE,
}) ?? 48

/** Visible avatar diameter — same as bar-button width on iOS. */
export const AVATAR_HEADER_SIZE = AVATAR_HEADER_BAR_BUTTON_WIDTH

/** @deprecated Use `AVATAR_HEADER_SIZE` */
export const AVATAR_HEADER_SLOT_SIZE = AVATAR_HEADER_SIZE

/** @deprecated Use `AVATAR_HEADER_SIZE` */
export const AVATAR_HEADER_SLOT_WIDTH = AVATAR_HEADER_SIZE

/** Width reserved in tab-root headerLeft for the profile avatar. */
export const TAB_HEADER_LEFT_WIDTH = SCREEN_GUTTER + AVATAR_HEADER_SIZE

/** Fixed square frame for native header bar-button intrinsic size (iOS 26 Liquid Glass). */
export function avatarHeaderSlotStyle(size = AVATAR_HEADER_SIZE): ViewStyle {
	return {
		alignItems: 'center',
		flexGrow: 0,
		flexShrink: 0,
		height: size,
		justifyContent: 'center',
		maxHeight: size,
		maxWidth: size,
		minHeight: size,
		minWidth: size,
		width: size,
	}
}

/** Circular control — matches tab-root header action slot height. */
export function tabRootHeaderActionFrame(size = AVATAR_HEADER_SIZE) {
	return {
		alignItems: 'center' as const,
		borderCurve: 'continuous' as const,
		borderRadius: size / 2,
		height: size,
		justifyContent: 'center' as const,
		width: size,
	}
}

/** Header avatar press target — fills the square slot exactly. */
export function avatarHeaderPressableStyle(size = AVATAR_HEADER_SIZE): ViewStyle {
	return {
		...avatarHeaderSlotStyle(size),
		borderCurve: 'continuous',
		borderRadius: size / 2,
		overflow: 'hidden',
	}
}
