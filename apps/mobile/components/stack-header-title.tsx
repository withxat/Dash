import type { ColorValue } from 'react-native'

import { Text } from 'react-native'

import { stackPushedHeaderTitleStyle } from '../lib/navigation'
import { useTheme } from '../lib/theme'

interface StackHeaderTitleProps {
	tintColor?: ColorValue
	title: string
}

/** Pushed sub-screen title — plain Text, no HeaderTitle fonts.bold merge. */
export function StackHeaderTitle({ tintColor, title }: StackHeaderTitleProps) {
	const theme = useTheme()

	return (
		<Text
			style={[
				stackPushedHeaderTitleStyle(theme),
				tintColor != null ? { color: tintColor } : null,
			]}
			numberOfLines={1}
		>
			{title}
		</Text>
	)
}
