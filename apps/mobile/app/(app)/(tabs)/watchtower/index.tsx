import type { NotificationHistoryEntry } from '@cloudfx/api'

import type { BadgeVariant } from '../../../../components/badge'
import type { WatchtowerSignal } from '../../../../lib/use-watchtower'

import { router } from 'expo-router'
import { useCallback, useState } from 'react'
import { RefreshControl, ScrollView, Text, View } from 'react-native'

import { AccountSwitcher } from '../../../../components/account-switcher'
import { Badge } from '../../../../components/badge'
import { Card } from '../../../../components/card'
import { EmptyState } from '../../../../components/empty-state'
import { AlertTriangleIcon, ShieldIcon } from '../../../../components/icons'
import { LayoutGroup, LayoutItem } from '../../../../components/layout-motion'
import { ListGroup, NavRow } from '../../../../components/nav-row'
import { Skeleton } from '../../../../components/skeleton'
import { timeAgo } from '../../../../lib/format'
import { tabScrollContentStyle } from '../../../../lib/screen-gutter'
import { useTheme } from '../../../../lib/theme'
import { useActiveAccount } from '../../../../lib/use-active-account'
import { useTabScrollPadding } from '../../../../lib/use-tab-scroll-padding'
import { useWatchtower } from '../../../../lib/use-watchtower'

function signalBadge(status: WatchtowerSignal['status']): { label: string, variant: BadgeVariant } {
	if (status === 'critical')
		return { label: 'Attention', variant: 'error' }
	if (status === 'warning')
		return { label: 'Warning', variant: 'warning' }
	return { label: 'OK', variant: 'success' }
}

/** `universal_ssl_event_type` → `Universal ssl event type`. */
function alertTypeLabel(alertType: string | undefined): string | undefined {
	if (!alertType)
		return undefined
	const label = alertType.replaceAll('_', ' ')
	return label.charAt(0).toUpperCase() + label.slice(1)
}

function alertTitle(entry: NotificationHistoryEntry): string {
	return entry.name ?? alertTypeLabel(entry.alert_type) ?? 'Notification'
}

function alertSubtitle(entry: NotificationHistoryEntry): string | undefined {
	return entry.alert_body ?? entry.mechanism ?? entry.description
}

function SignalRow({ signal }: { signal: WatchtowerSignal }) {
	const badge = signalBadge(signal.status)
	return (
		<NavRow
			onPress={() => router.push(signal.href)}
			right={<Badge appearance={signal.status === 'ok' ? 'dot' : 'filled'} variant={badge.variant}>{badge.label}</Badge>}
			subtitle={signal.detail}
			title={signal.title}
		/>
	)
}

export default function WatchtowerScreen() {
	const tabScrollPadding = useTabScrollPadding()
	const { activeAccount, activeAccountId } = useActiveAccount()
	const theme = useTheme()
	const [refreshing, setRefreshing] = useState(false)

	const watchtower = useWatchtower()
	const { alerts, alertsStatus, isLoading, refetchAll, signals, summary, unavailableCount } = watchtower

	const onRefresh = useCallback(async () => {
		setRefreshing(true)
		await refetchAll()
		setRefreshing(false)
	}, [refetchAll])

	const issues = signals.filter(signal => signal.status !== 'ok')
	const healthy = signals.filter(signal => signal.status === 'ok')
	const issueCount = summary.critical + summary.warning
	const allClear = issueCount === 0

	return (
		<ScrollView
			className="flex-1 bg-canvas"
			contentContainerStyle={tabScrollContentStyle({ gap: 16, paddingBottom: tabScrollPadding })}
			contentInsetAdjustmentBehavior="automatic"
			refreshControl={<RefreshControl onRefresh={onRefresh} refreshing={refreshing} tintColor={theme.subtle} />}
		>
			<AccountSwitcher />

			<Card>
				{!activeAccountId
					? <EmptyState>Select an account to start watching.</EmptyState>
					: isLoading
						? (
								<View className="gap-3">
									<Skeleton className="h-6 w-2/3" />
									<Skeleton className="h-4 w-1/2" />
								</View>
							)
						: signals.length === 0
							? <EmptyState>Nothing to watch yet — no monitored resources found in this account.</EmptyState>
							: (
									<View className="flex-row items-center gap-3">
										{allClear
											? <ShieldIcon color={theme.success} size={28} />
											: <AlertTriangleIcon color={summary.critical > 0 ? theme.danger : theme.warning} size={28} />}
										<View className="min-w-0 flex-1 gap-0.5">
											<Text className="text-base font-semibold text-default">
												{allClear
													? 'All systems normal'
													: `${issueCount} issue${issueCount === 1 ? '' : 's'} need${issueCount === 1 ? 's' : ''} attention`}
											</Text>
											<Text className="text-xs text-subtle">
												{`${signals.length} check${signals.length === 1 ? '' : 's'} · ${activeAccount?.name ?? 'account'}`}
											</Text>
										</View>
									</View>
								)}
			</Card>

			{isLoading && activeAccountId
				? (
						<Card>
							<View className="gap-3 py-1">
								<Skeleton className="h-10 w-full" />
								<Skeleton className="h-10 w-full" />
								<Skeleton className="h-10 w-full" />
							</View>
						</Card>
					)
				: null}

			{!isLoading && issues.length > 0
				? (
						<LayoutGroup>
							<ListGroup title="Needs attention">
								{issues.map(signal => (
									<LayoutItem key={signal.id}>
										<SignalRow signal={signal} />
									</LayoutItem>
								))}
							</ListGroup>
						</LayoutGroup>
					)
				: null}

			{!isLoading && healthy.length > 0
				? (
						<LayoutGroup>
							<ListGroup title="All clear">
								{healthy.map(signal => (
									<LayoutItem key={signal.id}>
										<SignalRow signal={signal} />
									</LayoutItem>
								))}
							</ListGroup>
						</LayoutGroup>
					)
				: null}

			{alertsStatus === 'ok'
				? (
						<ListGroup title="Recent alerts">
							{alerts.length === 0
								? <EmptyState>No notifications sent recently.</EmptyState>
								: alerts.map((entry) => {
										const alertKey = entry.id ?? `${entry.sent ?? ''}-${entry.alert_type ?? entry.name ?? ''}`
										return (
											<LayoutItem key={alertKey}>
												<NavRow
													chevron={false}
													right={timeAgo(entry.sent)}
													subtitle={alertSubtitle(entry)}
													title={alertTitle(entry)}
												/>
											</LayoutItem>
										)
									})}
						</ListGroup>
					)
				: null}

			<Text className="text-center text-[11px] text-placeholder">
				{unavailableCount > 0
					? `Watching ${activeAccount?.name ?? 'this account'} · ${unavailableCount} check${unavailableCount === 1 ? '' : 's'} unavailable (missing scopes)`
					: `Watching ${activeAccount?.name ?? 'this account'} across zones, tunnels, certificates, and deployments`}
			</Text>
		</ScrollView>
	)
}
