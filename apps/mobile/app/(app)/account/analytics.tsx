import { useQuery } from '@tanstack/react-query'
import { useCallback, useMemo, useState } from 'react'
import { RefreshControl, ScrollView, Text, View } from 'react-native'

import { AccountSwitcher } from '../../../components/account-switcher'
import { BarChart } from '../../../components/bar-chart'
import { Card } from '../../../components/card'
import { EmptyState } from '../../../components/empty-state'
import { SectionLabel } from '../../../components/section-label'
import { Segmented } from '../../../components/segmented'
import { Select } from '../../../components/select'
import { Skeleton } from '../../../components/skeleton'
import { Stat } from '../../../components/stat'
import { cloudflareClient } from '../../../lib/api'
import { formatBytes, formatNumber, formatPercent, isoDaysAgo } from '../../../lib/format'
import { useTheme } from '../../../lib/theme'
import { useActiveAccount } from '../../../lib/use-active-account'
import { useTabScrollPadding } from '../../../lib/use-tab-scroll-padding'

type Range = '7d' | '14d' | '30d'

const RANGE_OPTIONS: Array<{ label: string, value: Range }> = [
	{ label: '7 days', value: '7d' },
	{ label: '14 days', value: '14d' },
	{ label: '30 days', value: '30d' },
]

const RANGE_DAYS: Record<Range, number> = { '7d': 7, '14d': 14, '30d': 30 }

interface ChartPoint {
	date?: string
	sum: {
		bandwidth?: number
		cachedRequests?: number
		pageViews?: number
		requests?: number
		threats?: number
	}
}

function shortDate(iso?: string): string {
	if (!iso)
		return ''
	const d = new Date(iso)
	return Number.isNaN(d.getTime()) ? '' : `${d.getUTCDate()}/${d.getUTCMonth() + 1}`
}

function dayLabel(iso?: string): string {
	if (!iso)
		return ''
	const d = new Date(iso)
	return Number.isNaN(d.getTime()) ? '' : String(d.getUTCDate())
}

export default function AnalyticsScreen() {
	const tabScrollPadding = useTabScrollPadding()
	const { activeAccount, activeAccountId } = useActiveAccount()
	const theme = useTheme()
	const [range, setRange] = useState<Range>('7d')
	const [zoneId, setZoneId] = useState<string | undefined>(undefined)
	const [siteTag, setSiteTag] = useState<string | undefined>(undefined)
	const [refreshing, setRefreshing] = useState(false)

	const zonesQuery = useQuery({
		enabled: Boolean(activeAccountId),
		queryFn: () => cloudflareClient.listZones({ accountId: activeAccountId!, perPage: 50 }).then(p => p.items),
		queryKey: ['cf', 'zones-for-analytics', activeAccountId],
		retry: false,
	})
	const zones = zonesQuery.data ?? []
	const selectedZoneId = zones.some(z => z.id === zoneId) ? zoneId : undefined

	const rumSitesQuery = useQuery({
		enabled: Boolean(activeAccountId),
		queryFn: () => cloudflareClient.listRumSites(activeAccountId!),
		queryKey: ['cf', 'rum-sites', activeAccountId],
		retry: false,
	})
	const allRumSites = useMemo(
		() => (rumSitesQuery.data ?? []).filter(site => site.site_tag),
		[rumSitesQuery.data],
	)
	const scopedRumSites = useMemo(() => {
		if (!selectedZoneId)
			return allRumSites
		return allRumSites.filter(site => site.ruleset?.zone_tag === selectedZoneId)
	}, [allRumSites, selectedZoneId])
	const selectedRumSiteTag = scopedRumSites.some(site => site.site_tag === siteTag)
		? siteTag
		: scopedRumSites[0]?.site_tag
	const rumSite = scopedRumSites.find(site => site.site_tag === selectedRumSiteTag)

	const accountQuery = useQuery({
		enabled: Boolean(activeAccountId) && selectedZoneId == null,
		queryFn: () =>
			cloudflareClient.getAccountAnalytics(activeAccountId!, {
				since: isoDaysAgo(RANGE_DAYS[range]),
				until: new Date().toISOString(),
			}),
		queryKey: ['cf', 'account-analytics', activeAccountId, range],
	})
	const zoneQuery = useQuery({
		enabled: Boolean(selectedZoneId),
		queryFn: () =>
			cloudflareClient.getZoneAnalytics(selectedZoneId!, {
				since: isoDaysAgo(RANGE_DAYS[range]),
				until: new Date().toISOString(),
			}),
		queryKey: ['cf', 'zone', selectedZoneId, 'analytics', `${range}-daily`],
	})

	const webQuery = useQuery({
		enabled: Boolean(activeAccountId && rumSite?.site_tag),
		queryFn: () =>
			cloudflareClient.getWebAnalytics(activeAccountId!, rumSite!.site_tag!, {
				since: isoDaysAgo(RANGE_DAYS[range]),
				until: new Date().toISOString(),
			}),
		queryKey: ['cf', 'web-analytics', activeAccountId, rumSite?.site_tag, range],
		retry: false,
	})

	const activeQuery = selectedZoneId ? zoneQuery : accountQuery
	const points = useMemo<ChartPoint[]>(() => {
		if (selectedZoneId) {
			return (zoneQuery.data?.timeseries ?? []).map(p => ({
				date: p.since,
				sum: {
					bandwidth: p.bandwidth?.all,
					cachedRequests: p.requests?.cached,
					requests: p.requests?.all,
					threats: p.threats?.all,
				},
			}))
		}
		return accountQuery.data?.points ?? []
	}, [accountQuery.data, selectedZoneId, zoneQuery.data])

	const totals = useMemo(() => {
		if (selectedZoneId) {
			const t = zoneQuery.data?.totals
			return {
				bandwidth: t?.bandwidth?.all,
				cachedRequests: t?.requests?.cached,
				pageViews: undefined as number | undefined,
				requests: t?.requests?.all,
				threats: t?.threats?.all,
			}
		}
		return accountQuery.data?.totals
	}, [accountQuery.data, selectedZoneId, zoneQuery.data])

	const cacheRate = totals?.requests
		? (totals.cachedRequests ?? 0) / totals.requests
		: undefined
	const webPoints = useMemo(() => webQuery.data?.points ?? [], [webQuery.data])

	const onRefresh = useCallback(async () => {
		setRefreshing(true)
		await Promise.allSettled([
			activeQuery.refetch(),
			rumSitesQuery.refetch(),
			webQuery.refetch(),
		])
		setRefreshing(false)
	}, [activeQuery, rumSitesQuery, webQuery])

	const scopeLabel = selectedZoneId
		? zones.find(z => z.id === selectedZoneId)?.name ?? 'zone'
		: activeAccount?.name ?? 'account'

	return (
		<ScrollView
			className="flex-1 bg-canvas"
			contentContainerStyle={{ gap: 16, padding: 16, paddingBottom: tabScrollPadding }}
			contentInsetAdjustmentBehavior="automatic"
			refreshControl={<RefreshControl onRefresh={onRefresh} refreshing={refreshing} tintColor={theme.subtle} />}
		>
			<AccountSwitcher />

			{zones.length > 0
				? (
						<Select
							onChange={(next) => {
								setZoneId(next === '__all__' ? undefined : next)
								setSiteTag(undefined)
							}}
							options={[
								{ label: 'All zones', value: '__all__' },
								...zones.map(zone => ({
									label: zone.name ?? zone.id,
									value: zone.id,
								})),
							]}
							label="Scope"
							value={selectedZoneId ?? '__all__'}
						/>
					)
				: null}

			<Segmented onChange={setRange} options={RANGE_OPTIONS} value={range} />

			<View className="gap-2">
				<SectionLabel>Totals</SectionLabel>
				<Card>
					{!activeAccountId || activeQuery.isLoading
						? (
								<View className="gap-3">
									<Skeleton className="h-6 w-2/3" />
									<Skeleton className="h-6 w-1/2" />
								</View>
							)
						: activeQuery.isError
							? (
									<EmptyState onAction={() => void activeQuery.refetch()}>
										{`Analytics unavailable for this ${selectedZoneId ? 'zone' : 'account'}.\n${activeQuery.error instanceof Error ? activeQuery.error.message : ''}`.trim()}
									</EmptyState>
								)
							: (
									<View className="flex-row flex-wrap gap-x-8 gap-y-4">
										<Stat
											hint={`cached ${formatNumber(totals?.cachedRequests)}`}
											label="Requests"
											value={formatNumber(totals?.requests)}
										/>
										<Stat label="Cache rate" value={formatPercent(cacheRate)} />
										<Stat label="Bandwidth" value={formatBytes(totals?.bandwidth)} />
										<Stat label="Threats" value={formatNumber(totals?.threats)} />
										{!selectedZoneId
											? <Stat label="Page views" value={formatNumber(totals?.pageViews)} />
											: null}
									</View>
								)}
				</Card>
			</View>

			<View className="gap-2">
				<SectionLabel>Daily requests</SectionLabel>
				<Card>
					{activeQuery.isLoading
						? <Skeleton className="h-32 w-full" />
						: activeQuery.isError
							? <EmptyState>No chart data.</EmptyState>
							: points.length === 0
								? <EmptyState>No data in this range.</EmptyState>
								: (
										<View className="gap-3">
											<BarChart
												data={points.map(p => ({
													label: dayLabel(p.date),
													value: p.sum.requests ?? 0,
												}))}
												formatValue={formatNumber}
											/>
											<View className="flex-row justify-between">
												<Text className="text-[10px] text-placeholder">{shortDate(points[0]?.date)}</Text>
												<Text className="text-[10px] text-placeholder">{shortDate(points[points.length - 1]?.date)}</Text>
											</View>
										</View>
									)}
				</Card>
			</View>

			{!activeQuery.isError && points.length > 0
				? (
						<View className="gap-2">
							<SectionLabel>Daily bandwidth</SectionLabel>
							<Card>
								<BarChart
									data={points.map(p => ({
										label: dayLabel(p.date),
										value: p.sum.bandwidth ?? 0,
									}))}
									formatValue={n => formatBytes(n)}
									height={100}
									opacity={0.5}
								/>
							</Card>
						</View>
					)
				: null}

			{rumSite
				? (
						<View className="gap-2">
							<SectionLabel>{`Web Analytics · ${rumSite.ruleset?.zone_name ?? rumSite.site_tag}`}</SectionLabel>
							{scopedRumSites.length > 1
								? (
										<Select
											options={scopedRumSites.map(site => ({
												label: site.ruleset?.zone_name ?? site.site_tag ?? '—',
												value: site.site_tag!,
											}))}
											label="Web Analytics site"
											onChange={next => setSiteTag(next)}
											value={rumSite.site_tag!}
										/>
									)
								: null}
							<Card>
								{webQuery.isLoading
									? (
											<View className="gap-3">
												<Skeleton className="h-6 w-2/3" />
												<Skeleton className="h-28 w-full" />
											</View>
										)
									: webQuery.isError
										? (
												<EmptyState onAction={() => void webQuery.refetch()}>
													Web Analytics data unavailable for this site.
												</EmptyState>
											)
										: (
												<View className="gap-4">
													<View className="flex-row flex-wrap gap-x-8 gap-y-4">
														<Stat label="Page views" value={formatNumber(webQuery.data?.totals.pageViews)} />
														<Stat label="Visits" value={formatNumber(webQuery.data?.totals.visits)} />
													</View>
													{webPoints.length > 0
														? (
																<View className="gap-3">
																	<BarChart
																		data={webPoints.map(p => ({
																			label: dayLabel(p.date),
																			value: p.pageViews ?? 0,
																		}))}
																		formatValue={formatNumber}
																		height={90}
																	/>
																	<View className="flex-row justify-between">
																		<Text className="text-[10px] text-placeholder">{shortDate(webPoints[0]?.date)}</Text>
																		<Text className="text-[10px] text-placeholder">{shortDate(webPoints[webPoints.length - 1]?.date)}</Text>
																	</View>
																</View>
															)
														: <EmptyState>No pageload data in this range.</EmptyState>}
												</View>
											)}
							</Card>
						</View>
					)
				: null}

			<Text className="text-center text-[11px] text-placeholder">
				{`Showing analytics for ${scopeLabel}`}
			</Text>
		</ScrollView>
	)
}
