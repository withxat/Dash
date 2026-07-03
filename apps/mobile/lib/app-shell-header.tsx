import type { TabName } from './tab-routes'
import type { ThemePalette } from './theme'

import { AccountAvatarHeaderButton } from '../components/account-avatar-header-button'
import { HeaderBackButton } from '../components/header-back-button'
import { appShellHeaderPolicy } from './app-shell-header-policy'
import { avatarHeaderSlotStyle } from './avatar-header'
import { stackScreenOptions } from './navigation'
import { SCREEN_GUTTER } from './screen-gutter'
import { isTabRootSegment, TAB_NAMES } from './tab-routes'

function backHeaderLeft() {
	return {
		headerBackVisible: false,
		headerLeft: () => <HeaderBackButton />,
		headerLeftContainerStyle: { paddingLeft: SCREEN_GUTTER },
	}
}

function avatarHeaderLeft() {
	return {
		headerBackVisible: false,
		headerLeft: () => <AccountAvatarHeaderButton />,
		headerLeftContainerStyle: {
			...avatarHeaderSlotStyle(),
			paddingLeft: SCREEN_GUTTER,
		},
	}
}

/** One native header for tabs + pushed feature stacks (avatar on tab roots, back elsewhere). */
export function appShellHeaderOptions(
	segments: readonly string[],
	theme: ThemePalette,
) {
	const policy = appShellHeaderPolicy(segments)
	if (policy.kind === 'preserve')
		return {}

	const base = stackScreenOptions(theme)

	return {
		...base,
		...(policy.usesAvatar ? avatarHeaderLeft() : backHeaderLeft()),
		headerLargeTitle: policy.headerLargeTitle,
		headerShown: true,
		title: policy.title,
	}
}

export function isAppTabRoot(segments: readonly string[]): boolean {
	return isTabRootSegment(segments)
}

export function tabNameFromSegments(segments: readonly string[]): TabName | undefined {
	if (!isTabRootSegment(segments))
		return undefined
	const tab = segments[2]
	return TAB_NAMES.includes(tab as TabName) ? tab as TabName : undefined
}
