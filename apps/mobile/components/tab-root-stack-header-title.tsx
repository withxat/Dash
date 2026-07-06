import type { ColorValue } from 'react-native'

import { Text } from 'react-native'

import { chillBoldTextStyle } from '../lib/fonts'
import { useTheme } from '../lib/theme'

const TAB_ROOT_TITLE_FONT_SIZE = 24

interface TabRootStackHeaderTitleProps {
	tintColor?: ColorValue
	title: string
}

/** Chill Bold title for pushed screens that need a custom headerTitle (e.g. Search). */
export function TabRootStackHeaderTitle({ tintColor, title }: TabRootStackHeaderTitleProps) {
	const theme = useTheme()

	return (
		<Text
			style={[
				chillBoldTextStyle({
					color: tintColor ?? theme.default,
					flexShrink: 1,
					fontSize: TAB_ROOT_TITLE_FONT_SIZE,
				}),
			]}
			numberOfLines={1}
		>
			{title}
		</Text>
	)
}
