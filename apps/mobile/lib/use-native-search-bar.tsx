import type { NativeStackNavigationOptions } from 'expo-router/build/react-navigation/native-stack/types'
import type { NativeSyntheticEvent } from 'react-native'

import { useNavigation } from 'expo-router'
import { useLayoutEffect } from 'react'
import { Platform } from 'react-native'

export const NATIVE_SEARCH_BAR_PLACEHOLDER = 'Features, zones…'

/** Static search bar — integratedButton keeps the affordance in the nav bar row on iOS 26+. */
export function nativeSearchBarStaticOptions(): NativeStackNavigationOptions['headerSearchBarOptions'] {
	if (Platform.OS !== 'ios')
		return undefined

	return {
		allowToolbarIntegration: true,
		hideWhenScrolling: false,
		placeholder: NATIVE_SEARCH_BAR_PLACEHOLDER,
		placement: 'integratedButton',
	}
}

/** Native stack search bar in the header row (iOS 26+ circular button that expands on tap). */
export function useNativeSearchBar(onChangeText: (text: string) => void) {
	const navigation = useNavigation()

	useLayoutEffect(() => {
		navigation.setOptions({
			headerSearchBarOptions: {
				...nativeSearchBarStaticOptions(),
				onChangeText: (event: NativeSyntheticEvent<{ text: string }>) => {
					onChangeText(event.nativeEvent.text)
				},
			},
		})
	}, [navigation, onChangeText])
}
