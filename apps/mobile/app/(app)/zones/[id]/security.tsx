import type { FirewallEvent } from '@cloudfx/api'

import type { BadgeTone } from '../../../../components/badge'

import { LegendList } from '@legendapp/list/react-native'
import { useQuery } from '@tanstack/react-query'
import { router, useLocalSearchParams } from 'expo-router'
import { memo, useCallback, useMemo, useState } from 'react'
import { Pressable, Text, View } from 'react-native'

import { Badge } from '../../../../components/badge'
import { EmptyState } from '../../../../components/empty-state'
import { Segmented } from '../../../../components/segmented'
import { Skeleton } from '../../../../components/skeleton'
import { cloudflareClient } from '../../../../lib/api'
import { isoHoursAgo, timeAgo } from '../../../../lib/format'
import { useTabScrollPadding } from '../../../../lib/use-tab-scroll-padding'

type Range = '6h' | '24h' | '30m' | '72h'

const RANGE_OPTIONS: Array<{ label: string, value: Range }> = [
	{ label: '30 min', value: '30m' },
	{ label: '6 hours', value: '6h' },
	{ label: '24 hours', value: '24h' },
	{ label: '3 days', value: '72h' },
]

const RANGE_HOURS: Record<Range, number> = { '6h': 6, '24h': 24, '30m': 0.5, '72h': 72 }

function actionTone(action: string): BadgeTone {
	if (action === 'block')
		return 'error'
	if (action.includes('challenge'))
		return 'warning'
	if (action === 'allow' || action === 'skip')
		return 'success'
	return 'secondary'
}

function openEvent(zoneId: string, event: FirewallEvent) {
	router.push({
		params: { event: JSON.stringify(event), id: zoneId },
		pathname: '/zones/[id]/event',
	})
}

const EventRow = memo(({ event, zoneId }: { event: FirewallEvent, zoneId: string }) => {
	const onPress = useCallback(() => {
		openEvent(zoneId, event)
	}, [event, zoneId])

	const country = event.clientCountryName ?? ''
	const source = event.source ?? ''

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
				<Badge variant={actionTone(event.action)}>{event.action}</Badge>
				<Text className="text-[11px] text-placeholder">{timeAgo(event.datetime)}</Text>
			</View>
			<Text className="font-mono text-xs text-default" numberOfLines={1}>
				{`${event.clientRequestHTTPMethodName ?? ''} ${event.clientRequestHTTPHost ?? ''}${event.clientRequestPath ?? ''}`}
			</Text>
			<View className="flex-row flex-wrap gap-x-3">
				<Text className="text-[11px] text-subtle">{event.clientIP ?? ''}</Text>
				{country ? <Text className="text-[11px] text-subtle">{country}</Text> : null}
				{source ? <Text className="text-[11px] text-placeholder">{`via ${source}`}</Text> : null}
			</View>
		</Pressable>
	)
})

export default function SecurityScreen() {
	const tabScrollPadding = useTabScrollPadding()
	const { id } = useLocalSearchParams<{ id: string }>()
	const [range, setRange] = useState<Range>('24h')

	const eventsQuery = useQuery({
		enabled: Boolean(id),
		queryFn: () =>
			cloudflareClient.getFirewallEvents(id, {
				limit: 200,
				since: isoHoursAgo(RANGE_HOURS[range]),
				until: new Date().toISOString(),
			}),
		queryKey: ['cf', 'zone', id, 'firewall-events', range],
	})

	const events = useMemo(() => eventsQuery.data ?? [], [eventsQuery.data])

	const summary = useMemo(() => {
		const byAction = new Map<string, number>()
		for (const event of events)
			byAction.set(event.action, (byAction.get(event.action) ?? 0) + 1)
		return [...byAction.entries()].sort((a, b) => b[1] - a[1])
	}, [events])

	const onRefresh = useCallback(() => {
		void eventsQuery.refetch()
	}, [eventsQuery])

	const renderEvent = useCallback(({ item }: { item: FirewallEvent }) => (
		<EventRow event={item} zoneId={id} />
	), [id])

	const header = (
		<View className="gap-3 py-3">
			<Segmented onChange={setRange} options={RANGE_OPTIONS} value={range} />
			{summary.length > 0
				? (
						<View className="flex-row flex-wrap gap-2">
							{summary.map(([action, count]) => (
								<Badge key={action} variant={actionTone(action)}>
									{`${action} · ${count}`}
								</Badge>
							))}
						</View>
					)
				: null}
		</View>
	)

	if (eventsQuery.isLoading) {
		return (
			<View className="flex-1 gap-3 bg-canvas p-4">
				<Skeleton className="h-8 w-2/3" />
				<Skeleton className="h-16 w-full" />
				<Skeleton className="h-16 w-full" />
			</View>
		)
	}
	if (eventsQuery.isError) {
		return (
			<View className="flex-1 bg-canvas">
				<EmptyState onAction={onRefresh}>
					Security events unavailable. This may need the analytics scope, or the zone has no firewall data.
				</EmptyState>
			</View>
		)
	}

	return (
		<View className="flex-1 bg-canvas">
			{events.length === 0
				? (
						<View className="px-4">
							{header}
							<EmptyState onAction={onRefresh}>No firewall events in this range.</EmptyState>
						</View>
					)
				: (
						<LegendList
							contentContainerStyle={{ paddingBottom: tabScrollPadding, paddingHorizontal: 16 }}
							contentInsetAdjustmentBehavior="automatic"
							data={events}
							estimatedItemSize={88}
							ItemSeparatorComponent={Separator}
							keyExtractor={keyExtractor}
							ListHeaderComponent={header}
							onRefresh={onRefresh}
							refreshing={eventsQuery.isRefetching}
							renderItem={renderEvent}
						/>
					)}
		</View>
	)
}

function Separator() {
	return <View className="h-px bg-hairline" />
}

function keyExtractor(item: FirewallEvent, index: number) {
	return `${item.rayName ?? item.datetime}-${index}`
}
