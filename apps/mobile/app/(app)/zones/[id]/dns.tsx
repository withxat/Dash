import type { DnsRecord } from '@cloudfx/api'

import { LegendList } from '@legendapp/list/react-native'
import { useInfiniteQuery } from '@tanstack/react-query'
import { router, Stack, useLocalSearchParams } from 'expo-router'
import { memo, useCallback, useMemo } from 'react'
import { Pressable, Text, View } from 'react-native'

import { Badge } from '../../../../components/badge'
import { EmptyState } from '../../../../components/empty-state'
import { PlusIcon } from '../../../../components/icons'
import { Skeleton } from '../../../../components/skeleton'
import { cloudflareClient } from '../../../../lib/api'
import { useTheme } from '../../../../lib/theme'
import { useTabScrollPadding } from '../../../../lib/use-tab-scroll-padding'

function openRecord(zoneId: string, record?: DnsRecord) {
	router.push({
		params: {
			id: zoneId,
			...(record ? { record: JSON.stringify(record) } : {}),
		},
		pathname: '/zones/[id]/record',
	})
}

const DnsRow = memo(({
	record,
	zoneId,
}: {
	record: DnsRecord
	zoneId: string
}) => {
	const onPress = useCallback(() => {
		openRecord(zoneId, record)
	}, [record, zoneId])

	return (
		<Pressable
			className="
				gap-1 py-3
				active:opacity-70
			"
			accessibilityRole="button"
			onPress={onPress}
		>
			<View className="flex-row items-center justify-between gap-2">
				<Text className="min-w-0 flex-1 font-medium text-default" numberOfLines={1}>
					{record.name}
				</Text>
				<Badge variant="secondary" mono>{record.type}</Badge>
			</View>
			<Text className="font-mono text-xs text-subtle" numberOfLines={1}>
				{record.content}
			</Text>
			<View className="flex-row gap-3">
				<Text className={record.proxied ? 'text-[11px] text-accent' : 'text-[11px] text-placeholder'}>
					{record.proxied ? 'Proxied' : 'DNS only'}
				</Text>
				<Text className="text-[11px] text-placeholder">
					{record.ttl === 1 ? 'Auto TTL' : `TTL ${record.ttl}`}
				</Text>
			</View>
		</Pressable>
	)
})

export default function DnsScreen() {
	const tabScrollPadding = useTabScrollPadding()
	const { id } = useLocalSearchParams<{ id: string }>()
	const theme = useTheme()

	const dnsQuery = useInfiniteQuery({
		enabled: Boolean(id),
		getNextPageParam: (last: Awaited<ReturnType<typeof cloudflareClient.listDnsRecords>>) => {
			const { page, per_page: perPage, total_count: total } = last.resultInfo
			return page * perPage < total ? page + 1 : undefined
		},
		initialPageParam: 1,
		queryFn: ({ pageParam }) => cloudflareClient.listDnsRecords(id, { page: pageParam, perPage: 100 }),
		queryKey: ['cf', 'zone', id, 'dns'],
	})

	const records = useMemo(
		() => dnsQuery.data?.pages.flatMap(p => p.items) ?? [],
		[dnsQuery.data],
	)

	const onEndReached = useCallback(() => {
		if (dnsQuery.hasNextPage && !dnsQuery.isFetchingNextPage)
			void dnsQuery.fetchNextPage()
	}, [dnsQuery])

	const onRefresh = useCallback(() => {
		void dnsQuery.refetch()
	}, [dnsQuery])

	const addButton = useCallback(() => (
		<Pressable
			className="
				p-1
				active:opacity-70
			"
			accessibilityLabel="Add DNS record"
			accessibilityRole="button"
			onPress={() => openRecord(id)}
		>
			<PlusIcon color={theme.brand} size={22} />
		</Pressable>
	), [id, theme.brand])

	const renderRecord = useCallback(({ item }: { item: DnsRecord }) => (
		<DnsRow record={item} zoneId={id} />
	), [id])

	return (
		<View className="flex-1 bg-canvas">
			<Stack.Screen options={{ headerRight: addButton }} />
			{dnsQuery.isLoading
				? (
						<View className="gap-4 p-4">
							<Skeleton className="h-16 w-full" />
							<Skeleton className="h-16 w-full" />
							<Skeleton className="h-16 w-full" />
						</View>
					)
				: dnsQuery.isError
					? <EmptyState onAction={onRefresh}>Failed to load DNS records.</EmptyState>
					: records.length === 0
						? (
								<EmptyState
									actionLabel="Add record"
									className="flex-1"
									onAction={() => openRecord(id)}
								>
									No DNS records yet.
								</EmptyState>
							)
						: (
								<LegendList
									contentContainerStyle={{ paddingBottom: tabScrollPadding, paddingHorizontal: 16 }}
									contentInsetAdjustmentBehavior="automatic"
									data={records}
									estimatedItemSize={84}
									ItemSeparatorComponent={Separator}
									keyExtractor={keyExtractor}
									onEndReached={onEndReached}
									onRefresh={onRefresh}
									refreshing={dnsQuery.isRefetching && !dnsQuery.isFetchingNextPage}
									renderItem={renderRecord}
								/>
							)}
		</View>
	)
}

function Separator() {
	return <View className="h-px bg-hairline" />
}

function keyExtractor(item: DnsRecord) {
	return item.id
}
