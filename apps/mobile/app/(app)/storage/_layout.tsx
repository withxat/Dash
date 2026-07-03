import { Stack } from 'expo-router'

import { nestedStackScreenOptions } from '../../../lib/nested-stack'
import { useTheme } from '../../../lib/theme'
import { useSyncAppShellHeader } from '../../../lib/use-sync-app-shell-header'

const formSheetOptions = {
	headerLargeTitle: false,
	headerShown: true as const,
	presentation: 'formSheet' as const,
	sheetAllowedDetents: [0.75, 1] as number[],
	sheetGrabberVisible: true,
}

export default function StorageLayout() {
	const theme = useTheme()
	useSyncAppShellHeader()
	return (
		<Stack screenOptions={nestedStackScreenOptions(theme)}>
			<Stack.Screen name="index" />
			<Stack.Screen name="r2/index" />
			<Stack.Screen name="r2/[bucket]" />
			<Stack.Screen name="kv/index" />
			<Stack.Screen name="kv/[namespace]" />
			<Stack.Screen name="d1/index" />
			<Stack.Screen name="d1/[uuid]" />
			<Stack.Screen name="d1/console" options={{ ...formSheetOptions, title: 'SQL console' }} />
			<Stack.Screen name="queues/index" />
			<Stack.Screen name="queues/[queue]" />
			<Stack.Screen name="vectorize" />
			<Stack.Screen name="secrets/index" />
			<Stack.Screen name="secrets/[store]" />
			<Stack.Screen name="kv-entry" options={{ ...formSheetOptions, title: 'KV entry' }} />
			<Stack.Screen name="namespace-edit" options={{ ...formSheetOptions, title: 'KV namespace' }} />
			<Stack.Screen name="new-bucket" options={{ ...formSheetOptions, title: 'New bucket' }} />
			<Stack.Screen name="r2-object" options={{ ...formSheetOptions, title: 'Object' }} />
			<Stack.Screen name="r2-upload" options={{ ...formSheetOptions, title: 'Upload' }} />
		</Stack>
	)
}
