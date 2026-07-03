import { Stack } from 'expo-router'

import { nestedStackScreenOptions } from '../../../../lib/nested-stack'
import { useTheme } from '../../../../lib/theme'

export default function WatchtowerLayout() {
	const theme = useTheme()
	return (
		<Stack screenOptions={nestedStackScreenOptions(theme)}>
			<Stack.Screen name="index" />
		</Stack>
	)
}
