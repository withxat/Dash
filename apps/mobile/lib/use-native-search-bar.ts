import type { NativeSyntheticEvent } from 'react-native'

import { useFocusEffect, useNavigation } from 'expo-router'
import { useCallback } from 'react'

/** Attach a native search bar to the current tab's native stack header. */
export function useNativeSearchBar(onChangeText: (text: string) => void) {
	const navigation = useNavigation()

	useFocusEffect(
		useCallback(() => {
			navigation.setOptions({
				headerSearchBarOptions: {
					hideWhenScrolling: false,
					onChangeText: (event: NativeSyntheticEvent<{ text: string }>) => {
						onChangeText(event.nativeEvent.text)
					},
					placeholder: 'Features, zones…',
				},
			})

			return () => {
				navigation.setOptions({ headerSearchBarOptions: undefined })
			}
		}, [navigation, onChangeText]),
	)
}
