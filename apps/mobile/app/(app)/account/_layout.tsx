import { Stack } from 'expo-router'

import { nestedStackScreenOptions } from '../../../lib/nested-stack'
import { useTheme } from '../../../lib/theme'
import { useSyncAppShellHeader } from '../../../lib/use-sync-app-shell-header'

export default function AccountLayout() {
	const theme = useTheme()
	useSyncAppShellHeader()
	return (
		<Stack screenOptions={nestedStackScreenOptions(theme)}>
			<Stack.Screen name="index" />
			<Stack.Screen name="analytics" />
			<Stack.Screen name="turnstile" />
			<Stack.Screen name="lb-pools" />
			<Stack.Screen name="email-addresses" />
			<Stack.Screen name="registrar" />
			<Stack.Screen name="tunnels" />
			<Stack.Screen name="access-apps" />
			<Stack.Screen name="images" />
			<Stack.Screen name="stream" />
		</Stack>
	)
}
