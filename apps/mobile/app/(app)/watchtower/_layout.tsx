import { Stack } from 'expo-router'

import { tabRootScreenOptions, tabStackScreenOptions } from '../../../lib/tab-stack-header'
import { useTheme } from '../../../lib/theme'

export default function WatchtowerLayout() {
	const theme = useTheme()
	return (
		<Stack screenOptions={tabStackScreenOptions(theme)}>
			<Stack.Screen name="index" options={tabRootScreenOptions(theme, 'Watchtower')} />
			<Stack.Screen name="profile" options={{ title: 'Profile' }} />
		</Stack>
	)
}
