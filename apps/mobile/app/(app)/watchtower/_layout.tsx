import { Stack } from 'expo-router'

import { TAB_ROOT_TITLES } from '../../../lib/tab-root-titles'
import { tabPushedStackScreenOptions, tabStackScreenOptions, useTabRootScreenOptions } from '../../../lib/tab-stack-header'
import { useTheme } from '../../../lib/theme'

export default function WatchtowerLayout() {
	const theme = useTheme()
	const watchtowerRootOptions = useTabRootScreenOptions(theme, TAB_ROOT_TITLES.watchtower)

	return (
		<Stack
			screenOptions={({ route }) =>
				route.name === 'index'
					? tabStackScreenOptions(theme)
					: tabPushedStackScreenOptions(theme)}
		>
			<Stack.Screen name="index" options={watchtowerRootOptions} />
			<Stack.Screen name="profile" options={{ title: 'Profile' }} />
		</Stack>
	)
}
