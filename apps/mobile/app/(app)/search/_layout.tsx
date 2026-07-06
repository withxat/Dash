import { Stack } from 'expo-router'

import { tabPushedStackScreenOptions, tabRootScreenOptions, tabStackScreenOptions } from '../../../lib/tab-stack-header'
import { useTheme } from '../../../lib/theme'

export default function SearchLayout() {
	const theme = useTheme()
	const searchRootOptions = tabRootScreenOptions()

	return (
		<Stack
			screenOptions={({ route }) =>
				route.name === 'index'
					? tabStackScreenOptions(theme)
					: tabPushedStackScreenOptions(theme)}
		>
			<Stack.Screen name="index" options={searchRootOptions} />
			<Stack.Screen name="profile" options={{ title: 'Profile' }} />
		</Stack>
	)
}
