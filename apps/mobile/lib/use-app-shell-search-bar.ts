import type { NativeSyntheticEvent } from 'react-native'

import { useFocusEffect, useNavigation } from 'expo-router'
import { useCallback } from 'react'

import { findAppShellNavigation } from './app-shell-navigation'

/** Attach a native search bar to the shared app-shell header while this screen is focused. */
export function useAppShellSearchBar(onChangeText: (text: string) => void) {
	const navigation = useNavigation()

	useFocusEffect(
		useCallback(() => {
			const shell = findAppShellNavigation(navigation)
			if (!shell)
				return

			shell.setOptions({
				headerSearchBarOptions: {
					hideWhenScrolling: false,
					onChangeText: (event: NativeSyntheticEvent<{ text: string }>) => {
						onChangeText(event.nativeEvent.text)
					},
					placeholder: 'Features, zones…',
				},
			})

			return () => {
				shell.setOptions({ headerSearchBarOptions: undefined })
			}
		}, [navigation, onChangeText]),
	)
}
