import { router } from 'expo-router'
import { useCallback } from 'react'
import { Pressable, StyleSheet, View } from 'react-native'

import { avatarHeaderPressableStyle, tabRootHeaderActionFrame } from '../lib/avatar-header'
import { useTheme } from '../lib/theme'
import { SearchIcon } from './icons'

export function TabRootHeaderSearchButton() {
	const theme = useTheme()

	const onPress = useCallback(() => {
		router.push('/search')
	}, [])

	const frame = {
		...tabRootHeaderActionFrame(),
		backgroundColor: theme.control,
		borderColor: theme.line,
		borderWidth: StyleSheet.hairlineWidth,
	}

	return (
		<Pressable
			accessibilityLabel="Search"
			accessibilityRole="button"
			className="active:opacity-80"
			onPress={onPress}
			style={avatarHeaderPressableStyle()}
		>
			<View style={frame}>
				<SearchIcon color={theme.brand} size={20} />
			</View>
		</Pressable>
	)
}
