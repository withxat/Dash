import { useQuery } from '@tanstack/react-query'
import { useLocalSearchParams } from 'expo-router'
import { useState } from 'react'
import { RefreshControl, ScrollView, View } from 'react-native'

import { BarChart } from '../../../../../components/bar-chart'
import { Card } from '../../../../../components/card'
import { EmptyState } from '../../../../../components/empty-state'
import { SectionLabel } from '../../../../../components/section-label'
import { Segmented } from '../../../../../components/segmented'
import { Skeleton } from '../../../../../components/skeleton'
import { Stat } from '../../../../../components/stat'
import { cloudflareClient } from '../../../../../lib/api'
import { formatBytes, formatNumber, formatPercent, isoDaysAgo, isoHoursAgo } from '../../../../../lib/format'
import { useTheme } from '../../../../../lib/theme'
import { useTabScrollPadding } from '../../../../../lib/use-tab-scroll-padding'

type Range = '7d' | '24h' | '30d'

const RANGE_OPTIONS: Array<{ label: string, value: Range }> = [
	{ label: '24 hours', value: '24h' },
	{ label: '7 days', value: '7d' },
	{ label: '30 days', value: '30d' },
]

function rangeSince(range: Range): string {
	if (range === '24h')
		return isoHoursAgo(24)
	return isoDaysAgo(range === '7d' ? 7 : 30)
}

function bucketLabel(iso: string, range: Range): string {
	const d = new Date(iso)
	if (Number.isNaN(d.getTime()))
		return ''
	if (range === '24h')
		return String(d.getHours())
	return `${d.getUTCDate()}`
}

export default function ZoneAnalyticsScreen() {
	const tabScrollPadding = useTabScrollPadding()
	const { id } = useLocalSearchParams<{ id: string }>()
	const theme = useTheme()
	const [range, setRange] = useState<Range>('7d')
	const [refreshing, setRefreshing] = useState(false)

	const analyticsQuery = useQuery({
		enabled: Boolean(id),
		queryFn: () =>
			cloudflareClient.getZoneAnalytics(id, {
				since: rangeSince(range),
				until: new Date().toISOString(),
			}),
		queryKey: ['cf', 'zone', id, 'analytics', range],
	})

	const handleRefresh = async () => {
		setRefreshing(true)
		await analyticsQuery.refetch().catch(() => {})
		setRefreshing(false)
	}

	const totals = analyticsQuery.data?.totals
	const series = analyticsQuery.data?.timeseries ?? []
	const cacheRate = totals?.requests?.all
		? (totals.requests.cached ?? 0) / totals.requests.all
		: undefined

	return (
		<ScrollView
			className="flex-1 bg-canvas"
			contentContainerStyle={{ gap: 16, padding: 16, paddingBottom: tabScrollPadding }}
			contentInsetAdjustmentBehavior="automatic"
			refreshControl={<RefreshControl onRefresh={handleRefresh} refreshing={refreshing} tintColor={theme.subtle} />}
		>
			<Segmented onChange={setRange} options={RANGE_OPTIONS} value={range} />

			<View className="gap-2">
				<SectionLabel>Traffic</SectionLabel>
				<Card>
					{analyticsQuery.isLoading
						? (
								<View className="gap-3">
									<Skeleton className="h-6 w-2/3" />
									<Skeleton className="h-32 w-full" />
								</View>
							)
						: analyticsQuery.isError
							? <EmptyState onAction={() => void analyticsQuery.refetch()}>Analytics unavailable for this zone.</EmptyState>
							: (
									<View className="gap-4">
										<View className="flex-row flex-wrap gap-x-8 gap-y-4">
											<Stat
												hint={`cached ${formatNumber(totals?.requests?.cached)}`}
												label="Requests"
												value={formatNumber(totals?.requests?.all)}
											/>
											<Stat label="Bandwidth" value={formatBytes(totals?.bandwidth?.all)} />
											<Stat label="Cache rate" value={formatPercent(cacheRate)} />
											<Stat label="Threats" value={formatNumber(totals?.threats?.all)} />
										</View>
										{series.length > 0
											? (
													<View className="gap-4">
														<BarChart
															data={series.map(p => ({
																label: bucketLabel(p.since, range),
																value: p.requests?.all ?? 0,
															}))}
															formatValue={formatNumber}
														/>
														<BarChart
															data={series.map(p => ({
																label: bucketLabel(p.since, range),
																value: p.bandwidth?.all ?? 0,
															}))}
															formatValue={n => formatBytes(n)}
															height={80}
															opacity={0.5}
														/>
													</View>
												)
											: null}
									</View>
								)}
				</Card>
			</View>
		</ScrollView>
	)
}
