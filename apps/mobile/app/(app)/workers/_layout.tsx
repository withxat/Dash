import { Stack } from 'expo-router'

import { nestedStackScreenOptions } from '../../../lib/nested-stack'
import { useTheme } from '../../../lib/theme'
import { useSyncAppShellHeader } from '../../../lib/use-sync-app-shell-header'

export default function WorkersLayout() {
	const theme = useTheme()
	useSyncAppShellHeader()
	return (
		<Stack screenOptions={nestedStackScreenOptions(theme)}>
			<Stack.Screen name="index" />
			<Stack.Screen name="[name]/index" />
			<Stack.Screen name="[name]/deployments" />
			<Stack.Screen name="[name]/domains" />
			<Stack.Screen name="[name]/source" />
			<Stack.Screen name="[name]/builds" />
			<Stack.Screen name="[name]/logs" />
			<Stack.Screen name="pages/[project]/index" />
			<Stack.Screen name="pages/[project]/[deployment]" />
		</Stack>
	)
}
