import { Stack } from 'expo-router'

import { tabPushedStackScreenOptions, tabRootScreenOptions, tabStackScreenOptions } from '../../../lib/tab-stack-header'
import { useTheme } from '../../../lib/theme'

export default function HomeLayout() {
	const theme = useTheme()
	return (
		<Stack
			screenOptions={({ route }) =>
				route.name === 'index'
					? tabStackScreenOptions(theme)
					: tabPushedStackScreenOptions(theme)}
		>
			<Stack.Screen name="index" options={tabRootScreenOptions(theme, 'Home')} />
			<Stack.Screen name="profile" options={{ title: 'Profile' }} />
			<Stack.Screen
				options={{
					headerLargeTitle: false,
					headerShown: true,
					presentation: 'formSheet',
					sheetAllowedDetents: [0.75, 1],
					sheetGrabberVisible: true,
					title: 'Edit shortcuts',
				}}
				name="edit-shortcuts"
			/>
		</Stack>
	)
}
