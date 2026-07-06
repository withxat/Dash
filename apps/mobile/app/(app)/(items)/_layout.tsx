import { Stack } from 'expo-router'
import { useCallback } from 'react'

import { TabRootHeaderSearchButton } from '../../../components/tab-root-header-search-button'
import { itemsStackScreenOptions } from '../../../lib/items-stack-screen-options'
import { TAB_ROOT_TITLES } from '../../../lib/tab-root-titles'
import { useTabRootScreenOptions } from '../../../lib/tab-stack-header'
import { useTheme } from '../../../lib/theme'

// eslint-disable-next-line react-refresh/only-export-components -- Expo Router reads this route config export.
export const unstable_settings = {
	initialRouteName: 'items',
}

const formSheetOptions = {
	headerLargeTitle: false,
	headerShown: true as const,
	presentation: 'formSheet' as const,
	sheetAllowedDetents: [0.75, 1] as number[],
	sheetGrabberVisible: true,
}

export default function ItemsLayout() {
	const theme = useTheme()
	const searchHeaderRight = useCallback(() => <TabRootHeaderSearchButton />, [])
	const itemsRootOptions = useTabRootScreenOptions(theme, TAB_ROOT_TITLES.items, {
		headerRight: searchHeaderRight,
	})

	return (
		<Stack
			screenOptions={({ route }) => itemsStackScreenOptions(theme, route.name)}
		>
			<Stack.Screen name="items" options={itemsRootOptions} />
			<Stack.Screen name="profile" options={{ title: 'Profile' }} />
			<Stack.Screen
				name="zones/[id]/access-rule-new"
				options={{ ...formSheetOptions, sheetAllowedDetents: [0.6, 1], title: 'New IP rule' }}
			/>
			<Stack.Screen
				name="zones/[id]/record"
				options={{ ...formSheetOptions, title: 'DNS record' }}
			/>
			<Stack.Screen
				name="zones/[id]/event"
				options={{ ...formSheetOptions, title: 'Firewall event' }}
			/>
			<Stack.Screen name="storage/d1/console" options={{ ...formSheetOptions, title: 'SQL console' }} />
			<Stack.Screen name="storage/kv-entry" options={{ ...formSheetOptions, title: 'KV entry' }} />
			<Stack.Screen name="storage/namespace-edit" options={{ ...formSheetOptions, title: 'KV namespace' }} />
			<Stack.Screen name="storage/new-bucket" options={{ ...formSheetOptions, title: 'New bucket' }} />
			<Stack.Screen name="storage/r2-object" options={{ ...formSheetOptions, title: 'Object' }} />
			<Stack.Screen name="storage/r2-upload" options={{ ...formSheetOptions, title: 'Upload' }} />
		</Stack>
	)
}
