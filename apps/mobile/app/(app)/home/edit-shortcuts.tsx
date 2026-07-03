import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useCallback } from 'react'
import { ScrollView, Text, View } from 'react-native'

import { ListSurface } from '../../../components/nav-row'
import { SettingRow } from '../../../components/setting-row'
import { Skeleton } from '../../../components/skeleton'
import { APP_CATALOG } from '../../../lib/app-catalog'
import { getHomeShortcutIds, setHomeShortcutIds } from '../../../lib/home-shortcuts'

const EDITABLE_ITEMS = APP_CATALOG.flatMap(category => category.items)

export default function EditShortcutsScreen() {
	const queryClient = useQueryClient()

	const shortcutsQuery = useQuery({
		queryFn: getHomeShortcutIds,
		queryKey: ['app', 'home-shortcuts'],
	})

	const shortcutIds = shortcutsQuery.data

	const onToggle = useCallback((id: string, enabled: boolean) => {
		const current = queryClient.getQueryData<string[]>(['app', 'home-shortcuts']) ?? []
		const next = enabled
			? [...current.filter(entry => entry !== id), id]
			: current.filter(entry => entry !== id)
		queryClient.setQueryData(['app', 'home-shortcuts'], next)
		void setHomeShortcutIds(next)
	}, [queryClient])

	return (
		<ScrollView
			className="flex-1 bg-canvas"
			contentContainerStyle={{ gap: 12, padding: 16 }}
			contentInsetAdjustmentBehavior="automatic"
		>
			{shortcutIds == null
				? (
						<View className="gap-3 py-3">
							<Skeleton className="h-12 w-full" />
							<Skeleton className="h-12 w-full" />
						</View>
					)
				: (
						<ListSurface>
							{EDITABLE_ITEMS.map(item => (
								<SettingRow
									key={item.id}
									onValueChange={enabled => onToggle(item.id, enabled)}
									subtitle={item.description}
									title={item.title}
									value={shortcutIds.includes(item.id)}
								/>
							))}
						</ListSurface>
					)}

			<Text className="text-center text-[11px] text-placeholder">
				Shortcuts appear on Home in the order you enable them.
			</Text>
		</ScrollView>
	)
}
