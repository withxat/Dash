import { useFocusEffect, useNavigation, useSegments } from 'expo-router'
import { useCallback, useLayoutEffect } from 'react'

import { appShellHeaderOptions } from './app-shell-header'
import { findAppShellNavigation } from './app-shell-navigation'
import { useTheme } from './theme'

/** Updates only the active outer screen's shared header as nested routes change. */
export function useSyncAppShellHeader() {
	const navigation = useNavigation()
	const segments = useSegments()
	const theme = useTheme()

	const apply = useCallback(() => {
		const shell = findAppShellNavigation(navigation)
		if (!shell)
			return

		shell.setOptions({
			...appShellHeaderOptions(segments, theme),
			contentStyle: { backgroundColor: theme.canvas },
		})
	}, [navigation, segments, theme])

	useLayoutEffect(() => {
		apply()
	}, [apply])

	useFocusEffect(
		useCallback(() => {
			apply()
		}, [apply]),
	)
}
