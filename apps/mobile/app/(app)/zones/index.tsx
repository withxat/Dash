import type { BadgeTone } from '../../../components/badge'

import { LegendList } from '@legendapp/list/react-native'
import { useInfiniteQuery } from '@tanstack/react-query'
import { router } from 'expo-router'
import { memo, useCallback, useMemo } from 'react'
import { View } from 'react-native'

import { Badge } from '../../../components/badge'
import { EmptyState } from '../../../components/empty-state'
import { ListDivider, Row } from '../../../components/row'
import { Skeleton } from '../../../components/skeleton'
import { cloudflareClient } from '../../../lib/api'
import { useActiveAccount } from '../../../lib/use-active-account'
import { useTabScrollPadding } from '../../../lib/use-tab-scroll-padding'

function statusTone(status: string): BadgeTone {
	if (status === 'active')
		return 'success'
	if (status === 'pending' || status === 'initializing')
		return 'warning'
	if (status === 'moved' || status === 'deactivated')
		return 'error'
	return 'secondary'
}

const ZoneRow = memo(({
	accountName,
	id,
	name,
	status,
}: {
	accountName: string
	id: string
	name: string
	status: string
}) => {
	const onPress = useCallback(() => {
		router.push(`/zones/${id}`)
	}, [id])

	return (
		<Row
			onPress={onPress}
			right={<Badge variant={statusTone(status)}>{status}</Badge>}
			subtitle={accountName}
			title={name}
		/>
	)
})

export default function ZonesScreen() {
	const tabScrollPadding = useTabScrollPadding()
	const { activeAccountId } = useActiveAccount()

	const zonesQuery = useInfiniteQuery({
		enabled: Boolean(activeAccountId),
		getNextPageParam: (last: Awaited<ReturnType<typeof cloudflareClient.listZones>>) => {
			const { page, per_page: perPage, total_count: total } = last.resultInfo
			return page * perPage < total ? page + 1 : undefined
		},
		initialPageParam: 1,
		queryFn: ({ pageParam }) =>
			cloudflareClient.listZones({ accountId: activeAccountId!, page: pageParam, perPage: 50 }),
		queryKey: ['cf', 'zones', activeAccountId],
	})

	const zones = useMemo(
		() => zonesQuery.data?.pages.flatMap(p => p.items) ?? [],
		[zonesQuery.data],
	)

	const onEndReached = useCallback(() => {
		if (zonesQuery.hasNextPage && !zonesQuery.isFetchingNextPage)
			void zonesQuery.fetchNextPage()
	}, [zonesQuery])

	const onRefresh = useCallback(() => {
		void zonesQuery.refetch()
	}, [zonesQuery])

	if (!activeAccountId || zonesQuery.isLoading) {
		return (
			<View className="flex-1 gap-3 bg-canvas p-4">
				<Skeleton className="h-14 w-full" />
				<Skeleton className="h-14 w-full" />
				<Skeleton className="h-14 w-full" />
			</View>
		)
	}
	if (zonesQuery.isError) {
		return (
			<View className="flex-1 bg-canvas">
				<EmptyState onAction={onRefresh}>Failed to load zones.</EmptyState>
			</View>
		)
	}

	return (
		<View className="flex-1 bg-canvas">
			{zones.length === 0
				? (
						<EmptyState className="flex-1">
							No zones found in this account.
						</EmptyState>
					)
				: (
						<LegendList
							contentContainerStyle={{ paddingBottom: tabScrollPadding, paddingHorizontal: 16 }}
							contentInsetAdjustmentBehavior="automatic"
							data={zones}
							estimatedItemSize={56}
							ItemSeparatorComponent={ListDivider}
							keyExtractor={keyExtractor}
							onEndReached={onEndReached}
							onRefresh={onRefresh}
							refreshing={zonesQuery.isRefetching && !zonesQuery.isFetchingNextPage}
							renderItem={renderZone}
						/>
					)}
		</View>
	)
}

function keyExtractor(item: { id: string }) {
	return item.id
}

function renderZone({ item }: { item: Awaited<ReturnType<typeof cloudflareClient.listZones>>['items'][number] }) {
	return (
		<ZoneRow
			accountName={item.account?.name ?? ''}
			id={item.id}
			name={item.name}
			status={item.status ?? 'unknown'}
		/>
	)
}
