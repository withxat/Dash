import type { AccountMember, AuditLogEntry, NotificationHistoryEntry, NotificationPolicy } from '@cloudfx/api'

import { ApiError } from '@cloudfx/api'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { router } from 'expo-router'
import { useCallback, useState } from 'react'
import { RefreshControl, ScrollView, Text, View } from 'react-native'

import { AccountSwitcher } from '../../../../components/account-switcher'
import { EmptyState } from '../../../../components/empty-state'
import { ListSurface, Row } from '../../../../components/row'
import { SectionLabel } from '../../../../components/section-label'
import { Skeleton } from '../../../../components/skeleton'
import { cloudflareClient } from '../../../../lib/api'
import { timeAgo } from '../../../../lib/format'
import { useTheme } from '../../../../lib/theme'
import { useActiveAccount } from '../../../../lib/use-active-account'

/** True when the error is a Cloudflare permission failure (missing scope). */
function isForbidden(error: unknown): boolean {
	return error instanceof ApiError && (error.status === 403 || error.status === 401)
}

function memberName(member: AccountMember): string {
	const first = member.user?.first_name ?? ''
	const last = member.user?.last_name ?? ''
	const full = `${first} ${last}`.trim()
	return full || member.user?.email || 'Member'
}

function memberRoles(member: AccountMember): string {
	const roles = (member.roles ?? [])
		.map(role => role.name)
		.filter((name): name is string => Boolean(name))
	return roles.join(', ')
}

/** `universal_ssl_event_type` → `Universal ssl event type`. */
function alertTypeLabel(alertType: string | undefined): string | undefined {
	if (!alertType)
		return undefined
	const label = alertType.replaceAll('_', ' ')
	return label.charAt(0).toUpperCase() + label.slice(1)
}

function policySubtitle(policy: NotificationPolicy): string | undefined {
	const mechanisms = policy.mechanisms
	const destinations = [
		mechanisms?.email?.length ? 'email' : undefined,
		mechanisms?.pagerduty?.length ? 'PagerDuty' : undefined,
		mechanisms?.webhooks?.length ? 'webhook' : undefined,
	].filter((part): part is string => Boolean(part))
	const parts = [alertTypeLabel(policy.alert_type), destinations.join(' + ') || undefined]
		.filter((part): part is string => Boolean(part))
	return parts.length > 0 ? parts.join(' · ') : undefined
}

function historyTitle(entry: NotificationHistoryEntry): string {
	return entry.name ?? alertTypeLabel(entry.alert_type) ?? 'Notification'
}

function historySubtitle(entry: NotificationHistoryEntry): string | undefined {
	return entry.alert_body ?? entry.mechanism ?? entry.description
}

function auditLogTitle(entry: AuditLogEntry): string {
	return entry.action?.type ?? 'Action'
}

function auditLogSubtitle(entry: AuditLogEntry): string | undefined {
	const actor = entry.actor?.email ?? entry.actor?.type
	const resource = entry.resource?.type
	const parts = [actor, resource].filter((part): part is string => Boolean(part))
	return parts.length > 0 ? parts.join(' · ') : undefined
}

export default function AccountScreen() {
	const { activeAccount, activeAccountId } = useActiveAccount()
	const theme = useTheme()
	const queryClient = useQueryClient()
	const [refreshing, setRefreshing] = useState(false)

	const membersQuery = useQuery({
		enabled: Boolean(activeAccountId),
		queryFn: () => cloudflareClient.listAccountMembers(activeAccountId!, { perPage: 25 }).then(p => p.items),
		queryKey: ['cf', 'account-members', activeAccountId],
		retry: false,
	})
	const policiesQuery = useQuery({
		enabled: Boolean(activeAccountId),
		queryFn: () => cloudflareClient.listNotificationPolicies(activeAccountId!),
		queryKey: ['cf', 'notification-policies', activeAccountId],
		retry: false,
	})
	const alertHistoryQuery = useQuery({
		enabled: Boolean(activeAccountId),
		queryFn: () => cloudflareClient.listNotificationHistory(activeAccountId!, { perPage: 10 }),
		queryKey: ['cf', 'notification-history', activeAccountId],
		retry: false,
	})
	const auditQuery = useQuery({
		enabled: Boolean(activeAccountId),
		queryFn: () => cloudflareClient.listAuditLogs(activeAccountId!, { perPage: 15 }),
		queryKey: ['cf', 'account-audit-logs', activeAccountId],
		retry: false,
	})

	const onRefresh = useCallback(async () => {
		setRefreshing(true)
		await Promise.allSettled([
			queryClient.refetchQueries({ queryKey: ['cf', 'account-members', activeAccountId] }),
			queryClient.refetchQueries({ queryKey: ['cf', 'notification-policies', activeAccountId] }),
			queryClient.refetchQueries({ queryKey: ['cf', 'notification-history', activeAccountId] }),
			queryClient.refetchQueries({ queryKey: ['cf', 'account-audit-logs', activeAccountId] }),
		])
		setRefreshing(false)
	}, [activeAccountId, queryClient])

	const members = membersQuery.data ?? []
	const policies = policiesQuery.data ?? []
	const alertHistory = alertHistoryQuery.data ?? []
	const auditLogs = auditQuery.data ?? []

	return (
		<ScrollView
			className="flex-1 bg-canvas"
			contentContainerStyle={{ gap: 16, padding: 16 }}
			contentInsetAdjustmentBehavior="automatic"
			refreshControl={<RefreshControl onRefresh={onRefresh} refreshing={refreshing} tintColor={theme.subtle} />}
		>
			<AccountSwitcher />

			<View className="gap-2">
				<SectionLabel>Account</SectionLabel>
				<ListSurface>
					<Row chevron={false} right={activeAccount?.type} subtitle={activeAccountId ?? undefined} title={activeAccount?.name ?? 'No account selected'} />
				</ListSurface>
			</View>

			<View className="gap-2">
				<SectionLabel>Services</SectionLabel>
				<ListSurface>
					<Row
						onPress={() => router.push('/account/email-addresses')}
						subtitle="Email Routing destination addresses"
						title="Email addresses"
					/>
					<Row
						onPress={() => router.push('/account/turnstile')}
						subtitle="Widgets and secret rotation"
						title="Turnstile"
					/>
					<Row
						onPress={() => router.push('/account/lb-pools')}
						subtitle="Load balancer origin pools"
						title="LB Pools"
					/>
					<Row
						onPress={() => router.push('/account/registrar')}
						subtitle="Registered domains and renewals"
						title="Registrar"
					/>
					<Row
						onPress={() => router.push('/account/tunnels')}
						subtitle="Cloudflare Tunnel health"
						title="Tunnels"
					/>
					<Row
						onPress={() => router.push('/account/access-apps')}
						subtitle="Zero Trust applications"
						title="Access apps"
					/>
					<Row
						onPress={() => router.push('/account/images')}
						subtitle="Cloudflare Images library"
						title="Images"
					/>
					<Row
						onPress={() => router.push('/account/stream')}
						subtitle="Stream video library"
						title="Stream"
					/>
				</ListSurface>
			</View>

			<View className="gap-2">
				<SectionLabel>Members</SectionLabel>
				<ListSurface>
					{!activeAccountId || membersQuery.isLoading
						? (
								<View className="gap-3 py-3">
									<Skeleton className="h-10 w-full" />
									<Skeleton className="h-10 w-full" />
								</View>
							)
						: membersQuery.isError
							? (
									<EmptyState onAction={() => void membersQuery.refetch()}>
										{isForbidden(membersQuery.error)
											? 'Needs the Account Settings Read scope — enable it on your OAuth client and sign in again.'
											: 'Failed to load members.'}
									</EmptyState>
								)
							: members.length === 0
								? <EmptyState>No members in this account.</EmptyState>
								: members.map(member => (
										<Row
											chevron={false}
											key={member.id}
											right={member.status === 'pending' ? 'Invited' : undefined}
											subtitle={memberRoles(member) || member.user?.email}
											title={memberName(member)}
										/>
									))}
				</ListSurface>
			</View>

			<View className="gap-2">
				<SectionLabel>Notification policies</SectionLabel>
				<ListSurface>
					{!activeAccountId || policiesQuery.isLoading
						? (
								<View className="gap-3 py-3">
									<Skeleton className="h-10 w-full" />
									<Skeleton className="h-10 w-full" />
								</View>
							)
						: policiesQuery.isError
							? (
									<EmptyState onAction={() => void policiesQuery.refetch()}>
										{isForbidden(policiesQuery.error)
											? 'Needs the Notifications Read scope — enable it on your OAuth client and sign in again.'
											: 'Failed to load notification policies.'}
									</EmptyState>
								)
							: policies.length === 0
								? <EmptyState>No notification policies configured.</EmptyState>
								: policies.map(policy => (
										<Row
											chevron={false}
											key={policy.id ?? policy.name ?? 'policy'}
											right={policy.enabled === false ? 'Off' : undefined}
											subtitle={policySubtitle(policy)}
											title={policy.name ?? alertTypeLabel(policy.alert_type) ?? 'Policy'}
										/>
									))}
				</ListSurface>
			</View>

			<View className="gap-2">
				<SectionLabel>Recent alerts</SectionLabel>
				<ListSurface>
					{!activeAccountId || alertHistoryQuery.isLoading
						? (
								<View className="gap-3 py-3">
									<Skeleton className="h-10 w-full" />
									<Skeleton className="h-10 w-full" />
								</View>
							)
						: alertHistoryQuery.isError
							? (
									<EmptyState onAction={() => void alertHistoryQuery.refetch()}>
										{isForbidden(alertHistoryQuery.error)
											? 'Needs the Notifications Read scope — enable it on your OAuth client and sign in again.'
											: 'Failed to load notification history.'}
									</EmptyState>
								)
							: alertHistory.length === 0
								? <EmptyState>No notifications sent recently.</EmptyState>
								: alertHistory.map((entry, index) => (
										<Row
											chevron={false}
											// eslint-disable-next-line react/no-array-index-key -- history entries can miss ids
											key={entry.id ?? index}
											right={timeAgo(entry.sent)}
											subtitle={historySubtitle(entry)}
											title={historyTitle(entry)}
										/>
									))}
				</ListSurface>
			</View>

			<View className="gap-2">
				<SectionLabel>Recent activity</SectionLabel>
				<ListSurface>
					{!activeAccountId || auditQuery.isLoading
						? (
								<View className="gap-3 py-3">
									<Skeleton className="h-10 w-full" />
									<Skeleton className="h-10 w-full" />
								</View>
							)
						: auditQuery.isError
							? (
									<EmptyState onAction={() => void auditQuery.refetch()}>
										{isForbidden(auditQuery.error)
											? 'Needs the Account Settings Read scope — enable it on your OAuth client and sign in again.'
											: 'Failed to load audit logs.'}
									</EmptyState>
								)
							: auditLogs.length === 0
								? <EmptyState>No recent account activity.</EmptyState>
								: auditLogs.map((entry, index) => (
										<Row
											chevron={false}
											// eslint-disable-next-line react/no-array-index-key -- audit entries can miss ids
											key={entry.id ?? index}
											right={timeAgo(entry.when)}
											subtitle={auditLogSubtitle(entry)}
											title={auditLogTitle(entry)}
										/>
									))}
				</ListSurface>
			</View>

			<Text className="text-center text-[11px] text-placeholder">
				Audit logs cover changes made across this Cloudflare account.
			</Text>
		</ScrollView>
	)
}
