import type { WorkersTelemetryEvent } from '@cloudfx/api'

import type { BadgeTone } from '../../../../components/badge'

import { useQuery } from '@tanstack/react-query'
import { useLocalSearchParams } from 'expo-router'
import { useCallback, useState } from 'react'
import { RefreshControl, ScrollView, Text, View } from 'react-native'

import { Badge } from '../../../../components/badge'
import { EmptyState } from '../../../../components/empty-state'
import { ListSurface } from '../../../../components/row'
import { SectionLabel } from '../../../../components/section-label'
import { Segmented } from '../../../../components/segmented'
import { Skeleton } from '../../../../components/skeleton'
import { cloudflareClient } from '../../../../lib/api'
import { isForbidden } from '../../../../lib/api-errors'
import { useTheme } from '../../../../lib/theme'
import { useActiveAccount } from '../../../../lib/use-active-account'

const RANGE_OPTIONS = ['1h', '24h', '7d'] as const
type RangeOption = (typeof RANGE_OPTIONS)[number]

const RANGE_MS: Record<RangeOption, number> = {
	'1h': 3_600_000,
	'7d': 7 * 24 * 3_600_000,
	'24h': 24 * 3_600_000,
}

function levelTone(level?: string): BadgeTone {
	if (level === 'error' || level === 'fatal')
		return 'error'
	if (level === 'warn' || level === 'warning')
		return 'warning'
	return 'secondary'
}

function eventMessage(event: WorkersTelemetryEvent): string {
	if (event.$metadata.error)
		return event.$metadata.error
	if (event.$metadata.message)
		return event.$metadata.message
	if (typeof event.source === 'string')
		return event.source
	return JSON.stringify(event.source ?? {})
}

const timeFormatter = new Intl.DateTimeFormat(undefined, { timeStyle: 'medium' })

export default function WorkerLogsScreen() {
	const { name } = useLocalSearchParams<{ name: string }>()
	const { activeAccountId } = useActiveAccount()
	const theme = useTheme()
	const [refreshing, setRefreshing] = useState(false)
	const [range, setRange] = useState<RangeOption>('1h')
	const [errorsOnly, setErrorsOnly] = useState(false)

	const logsQuery = useQuery({
		enabled: Boolean(activeAccountId && name),
		queryFn: () => {
			const until = Date.now()
			return cloudflareClient.queryWorkerLogs(activeAccountId!, name, {
				level: errorsOnly ? 'error' : undefined,
				limit: 100,
				since: until - RANGE_MS[range],
				until,
			})
		},
		queryKey: ['cf', 'worker-logs', activeAccountId, name, range, errorsOnly],
		retry: false,
	})

	const onRefresh = useCallback(async () => {
		setRefreshing(true)
		await logsQuery.refetch().catch(() => {})
		setRefreshing(false)
	}, [logsQuery])

	const events = logsQuery.data ?? []

	return (
		<ScrollView
			className="flex-1 bg-canvas"
			contentContainerStyle={{ gap: 16, padding: 16 }}
			contentInsetAdjustmentBehavior="automatic"
			refreshControl={<RefreshControl onRefresh={onRefresh} refreshing={refreshing} tintColor={theme.subtle} />}
		>
			<View className="flex-row items-center gap-3">
				<View className="flex-1">
					<Segmented
						onChange={setRange}
						options={RANGE_OPTIONS.map(option => ({ label: option, value: option }))}
						value={range}
					/>
				</View>
				<View className="flex-1">
					<Segmented
						onChange={value => setErrorsOnly(value === 'errors')}
						options={[{ label: 'All', value: 'all' }, { label: 'Errors', value: 'errors' }]}
						value={errorsOnly ? 'errors' : 'all'}
					/>
				</View>
			</View>

			<View className="gap-2">
				<SectionLabel>Events</SectionLabel>
				<ListSurface>
					{!activeAccountId || logsQuery.isLoading
						? (
								<View className="gap-3 py-3">
									<Skeleton className="h-10 w-full" />
									<Skeleton className="h-10 w-full" />
									<Skeleton className="h-10 w-full" />
								</View>
							)
						: logsQuery.isError
							? (
									<EmptyState onAction={() => void logsQuery.refetch()}>
										{isForbidden(logsQuery.error)
											? 'Needs the Workers Observability read scope — enable it on your OAuth client and sign in again.'
											: 'Failed to query logs. Make sure observability is enabled for this Worker.'}
									</EmptyState>
								)
							: events.length === 0
								? <EmptyState>No log events in this window. Observability must be enabled on the Worker to collect logs.</EmptyState>
								: events.map((event, index) => (
										<View
											className="gap-1 py-3"
											// eslint-disable-next-line react/no-array-index-key -- events may miss metadata ids
											key={event.$metadata.id ?? index}
										>
											<View className="flex-row items-center justify-between gap-2">
												<Text className="text-xs text-subtle">
													{timeFormatter.format(new Date(event.timestamp))}
												</Text>
												<Badge variant={levelTone(event.$metadata.level)}>
													{event.$metadata.level ?? event.$metadata.trigger ?? 'log'}
												</Badge>
											</View>
											<Text className="font-mono text-xs text-default" numberOfLines={4} selectable>
												{eventMessage(event)}
											</Text>
										</View>
									))}
				</ListSurface>
			</View>
		</ScrollView>
	)
}
