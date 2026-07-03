import { Stack } from 'expo-router'

import { nestedStackScreenOptions } from '../../../lib/nested-stack'
import { useTheme } from '../../../lib/theme'
import { useSyncAppShellHeader } from '../../../lib/use-sync-app-shell-header'

const formSheetOptions = {
	headerLargeTitle: false,
	headerShown: true as const,
	presentation: 'formSheet' as const,
	sheetAllowedDetents: [0.6, 1] as number[],
	sheetGrabberVisible: true,
}

export default function ZonesLayout() {
	const theme = useTheme()
	useSyncAppShellHeader()
	return (
		<Stack screenOptions={nestedStackScreenOptions(theme)}>
			<Stack.Screen name="index" />
			<Stack.Screen name="[id]/index" />
			<Stack.Screen name="[id]/dns" />
			<Stack.Screen name="[id]/settings" />
			<Stack.Screen name="[id]/cache" />
			<Stack.Screen name="[id]/security" />
			<Stack.Screen name="[id]/analytics" />
			<Stack.Screen name="[id]/routes" />
			<Stack.Screen name="[id]/ssl" />
			<Stack.Screen name="[id]/access-rules" />
			<Stack.Screen name="[id]/waf" />
			<Stack.Screen name="[id]/healthchecks" />
			<Stack.Screen name="[id]/waiting-rooms" />
			<Stack.Screen name="[id]/load-balancers" />
			<Stack.Screen name="[id]/page-rules" />
			<Stack.Screen name="[id]/email-routing" />
			<Stack.Screen
				name="[id]/access-rule-new"
				options={{ ...formSheetOptions, sheetAllowedDetents: [0.6, 1], title: 'New IP rule' }}
			/>
			<Stack.Screen
				name="[id]/record"
				options={{ ...formSheetOptions, sheetAllowedDetents: [0.75, 1], title: 'DNS record' }}
			/>
			<Stack.Screen
				name="[id]/event"
				options={{ ...formSheetOptions, sheetAllowedDetents: [0.75, 1], title: 'Firewall event' }}
			/>
		</Stack>
	)
}
