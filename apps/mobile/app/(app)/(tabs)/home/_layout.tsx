import { Stack } from 'expo-router'

import { nestedStackScreenOptions } from '../../../../lib/nested-stack'
import { useTheme } from '../../../../lib/theme'

export default function HomeLayout() {
	const theme = useTheme()
	return (
		<Stack screenOptions={nestedStackScreenOptions(theme)}>
			<Stack.Screen name="index" />
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
