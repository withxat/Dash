import type { ColorValue } from 'react-native'

import type { ThemePalette } from './theme'

import { StackHeaderTitle } from '../components/stack-header-title'
import { stackScreenOptions } from './navigation'

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
		headerTitle: ({ children, tintColor }: { children: string, tintColor?: ColorValue }) => (
			<StackHeaderTitle tintColor={tintColor} title={String(children)} />
		),
	}
}

/** Tab roots render avatar + title in-screen; hide the native stack header. */
export function tabRootScreenOptions() {
	return {
		headerShown: false as const,
	}
}
