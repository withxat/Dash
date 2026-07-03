import { useQuery } from '@tanstack/react-query'
import { useLocalSearchParams } from 'expo-router'
import { useCallback, useState } from 'react'
import { RefreshControl, ScrollView, View } from 'react-native'

import { Badge } from '../../../../../components/badge'
import { QuerySection } from '../../../../../components/query-section'
import { ListSurface, Row } from '../../../../../components/row'
import { SectionLabel } from '../../../../../components/section-label'
import { cloudflareClient } from '../../../../../lib/api'
import { useTheme } from '../../../../../lib/theme'
import { useTabScrollPadding } from '../../../../../lib/use-tab-scroll-padding'

export default function ZoneWaitingRoomsScreen() {
	const tabScrollPadding = useTabScrollPadding()
	const { id } = useLocalSearchParams<{ id: string }>()
	const theme = useTheme()
	const [refreshing, setRefreshing] = useState(false)

	const roomsQuery = useQuery({
		enabled: Boolean(id),
		queryFn: () => cloudflareClient.listWaitingRooms(id),
		queryKey: ['cf', 'zone', id, 'waiting-rooms'],
		retry: false,
	})

	const onRefresh = useCallback(async () => {
		setRefreshing(true)
		await roomsQuery.refetch().catch(() => {})
		setRefreshing(false)
	}, [roomsQuery])

	return (
		<ScrollView
			className="flex-1 bg-canvas"
			contentContainerStyle={{ gap: 16, padding: 16, paddingBottom: tabScrollPadding }}
			contentInsetAdjustmentBehavior="automatic"
			refreshControl={<RefreshControl onRefresh={onRefresh} refreshing={refreshing} tintColor={theme.subtle} />}
		>
			<View className="gap-2">
				<SectionLabel>Waiting Rooms</SectionLabel>
				<ListSurface>
					<QuerySection
						renderItem={room => (
							<Row
								chevron={false}
								right={<Badge variant={room.suspended ? 'secondary' : 'success'}>{room.suspended ? 'Suspended' : 'Active'}</Badge>}
								subtitle={[`${room.host ?? ''}${room.path ?? ''}`, room.queueing_method].filter(Boolean).join(' · ')}
								title={room.name ?? room.id ?? 'Waiting room'}
							/>
						)}
						emptyText="No waiting rooms on this zone."
						error={roomsQuery.error}
						errorText="Failed to load waiting rooms."
						isError={roomsQuery.isError}
						isLoading={roomsQuery.isLoading}
						items={roomsQuery.data}
						onRetry={() => void roomsQuery.refetch()}
						scopeHint="Needs the Waiting Rooms read scope — enable it on your OAuth client and sign in again."
					/>
				</ListSurface>
			</View>
		</ScrollView>
	)
}
