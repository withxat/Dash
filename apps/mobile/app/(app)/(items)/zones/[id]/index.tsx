import type { BadgeTone } from '../../../../../components/badge'

import { ApiError } from '@cloudfx/api'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { router, Stack, useLocalSearchParams } from 'expo-router'
import { useCallback, useMemo, useState } from 'react'
import { RefreshControl, ScrollView, Text, View } from 'react-native'

import { Badge } from '../../../../../components/badge'
import { Card } from '../../../../../components/card'
import { EmptyState } from '../../../../../components/empty-state'
import { ListGroup, Row } from '../../../../../components/row'
import { SettingRow } from '../../../../../components/setting-row'
import { Skeleton } from '../../../../../components/skeleton'
import { cloudflareClient } from '../../../../../lib/api'
import { hapticError, hapticSuccess } from '../../../../../lib/haptics'
import { useTheme } from '../../../../../lib/theme'
import { useTabScrollPadding } from '../../../../../lib/use-tab-scroll-padding'
import { useToast } from '../../../../../lib/use-toast'

function statusTone(status: string): BadgeTone {
	if (status === 'active')
		return 'success'
	if (status === 'pending' || status === 'initializing')
		return 'warning'
	return 'secondary'
}

/** True when the error is a Cloudflare permission failure (missing scope). */
function isForbidden(error: unknown): boolean {
	return error instanceof ApiError && (error.status === 403 || error.status === 401)
}

export default function ZoneDetailScreen() {
	const tabScrollPadding = useTabScrollPadding()
	const { id } = useLocalSearchParams<{ id: string }>()
	const theme = useTheme()
	const toast = useToast()
	const queryClient = useQueryClient()

	const zoneQuery = useQuery({
		enabled: Boolean(id),
		queryFn: () => cloudflareClient.getZone(id),
		queryKey: ['cf', 'zone', id],
	})
	const settingsQuery = useQuery({
		enabled: Boolean(id),
		queryFn: () => cloudflareClient.listZoneSettings(id),
		queryKey: ['cf', 'zone', id, 'settings'],
		retry: false,
	})
	const dnsCountQuery = useQuery({
		enabled: Boolean(id),
		queryFn: () => cloudflareClient.listDnsRecords(id, { perPage: 1 }).then(p => p.resultInfo?.total_count ?? 0),
		queryKey: ['cf', 'zone', id, 'dns-count'],
	})

	const settings = useMemo(() => {
		const map = new Map<string, boolean | number | Record<string, unknown> | string>()
		for (const s of settingsQuery.data ?? [])
			map.set(s.id, s.value as boolean | number | Record<string, unknown> | string)
		return map
	}, [settingsQuery.data])

	const updateSetting = useMutation({
		mutationFn: ({ settingId, value }: { settingId: string, value: string }) =>
			cloudflareClient.updateZoneSetting(id, settingId, value),
		onError: (error) => {
			hapticError()
			toast.show(isForbidden(error) ? 'Missing permission — sign in again to grant it.' : 'Failed to update setting.', 'error')
		},
		onSuccess: () => {
			hapticSuccess()
			void queryClient.invalidateQueries({ queryKey: ['cf', 'zone', id, 'settings'] })
		},
	})

	const [refreshing, setRefreshing] = useState(false)
	const handleRefresh = useCallback(async () => {
		setRefreshing(true)
		await queryClient.refetchQueries({ queryKey: ['cf', 'zone', id] }).catch(() => {})
		setRefreshing(false)
	}, [id, queryClient])

	const zone = zoneQuery.data

	if (zoneQuery.isLoading) {
		return (
			<View className="flex-1 gap-3 bg-canvas p-4">
				<Skeleton className="h-32 w-full rounded-kumo" />
				<Skeleton className="h-48 w-full rounded-kumo" />
			</View>
		)
	}
	if (zoneQuery.isError || !zone) {
		return (
			<View className="flex-1 items-center justify-center bg-canvas">
				<EmptyState onAction={() => void zoneQuery.refetch()}>Failed to load this zone.</EmptyState>
			</View>
		)
	}

	const devMode = settings.get('development_mode') === 'on'
	const underAttack = settings.get('security_level') === 'under_attack'
	const settingsForbidden = settingsQuery.isError && isForbidden(settingsQuery.error)

	return (
		<ScrollView
			className="flex-1 bg-canvas"
			contentContainerStyle={{ gap: 16, padding: 16, paddingBottom: tabScrollPadding }}
			contentInsetAdjustmentBehavior="automatic"
			refreshControl={<RefreshControl onRefresh={handleRefresh} refreshing={refreshing} tintColor={theme.subtle} />}
		>
			<Stack.Screen options={{ title: zone.name }} />

			<Card>
				<View className="flex-row items-start justify-between gap-3">
					<View className="min-w-0 flex-1 gap-1">
						<Text className="text-lg font-semibold text-default" numberOfLines={1}>{zone.name}</Text>
						<Text className="text-xs text-subtle">
							{`${zone.account?.name ?? '—'} · ${zone.plan?.name ?? '—'}`}
						</Text>
					</View>
					<Badge variant={statusTone(zone.status ?? 'pending')}>{zone.status ?? 'unknown'}</Badge>
				</View>
				{zone.name_servers?.length
					? (
							<View className="mt-4 gap-1">
								<Text className="text-sm font-medium text-subtle">Nameservers</Text>
								{zone.name_servers.map(ns => (
									<Text className="font-mono text-xs text-subtle" key={ns}>
										{ns}
									</Text>
								))}
							</View>
						)
					: null}
			</Card>

			<ListGroup title="Quick actions">
				{settingsQuery.isLoading
					? (
							<View className="gap-3 py-3">
								<Skeleton className="h-6 w-full" />
								<Skeleton className="h-6 w-full" />
							</View>
						)
					: settingsForbidden
						? (
								<EmptyState>
									Zone settings need extra permissions. Sign out and back in after enabling the zone settings scopes on your OAuth client.
								</EmptyState>
							)
						: settingsQuery.isError
							? <EmptyState onAction={() => void settingsQuery.refetch()}>Failed to load settings.</EmptyState>
							: (
									<View>
										<SettingRow
											loading={updateSetting.isPending && updateSetting.variables?.settingId === 'development_mode'}
											onValueChange={on => updateSetting.mutate({ settingId: 'development_mode', value: on ? 'on' : 'off' })}
											subtitle="Bypass cache for 3 hours"
											title="Development mode"
											value={devMode}
										/>
										<SettingRow
											loading={updateSetting.isPending && updateSetting.variables?.settingId === 'security_level'}
											onValueChange={on => updateSetting.mutate({ settingId: 'security_level', value: on ? 'under_attack' : 'medium' })}
											subtitle="Challenge all visitors (I'm Under Attack)"
											title="Under attack mode"
											value={underAttack}
										/>
									</View>
								)}
			</ListGroup>

			<ListGroup title="Manage">
				<Row
					onPress={() => router.push(`/zones/${id}/dns`)}
					right={dnsCountQuery.data != null ? String(dnsCountQuery.data) : undefined}
					subtitle="Manage records"
					title="DNS records"
				/>
				<Row
					onPress={() => router.push(`/zones/${id}/settings`)}
					subtitle="SSL/TLS, security, speed, caching"
					title="Settings"
				/>
				<Row
					onPress={() => router.push(`/zones/${id}/cache`)}
					subtitle="Purge by URL, hostname, prefix or tag"
					title="Cache"
				/>
				<Row
					onPress={() => router.push(`/zones/${id}/security`)}
					subtitle="Firewall events"
					title="Security"
				/>
				<Row
					onPress={() => router.push(`/zones/${id}/analytics`)}
					subtitle="Requests, bandwidth, threats"
					title="Traffic analytics"
				/>
				<Row
					onPress={() => router.push(`/zones/${id}/routes`)}
					subtitle="Map URL patterns to Workers"
					title="Workers routes"
				/>
			</ListGroup>

			<ListGroup title="Security & network">
				<Row
					onPress={() => router.push(`/zones/${id}/ssl`)}
					subtitle="Certificates and Universal SSL"
					title="SSL/TLS"
				/>
				<Row
					onPress={() => router.push(`/zones/${id}/access-rules`)}
					subtitle="Block, challenge or allow IPs"
					title="IP Access Rules"
				/>
				<Row
					onPress={() => router.push(`/zones/${id}/waf`)}
					subtitle="Custom rules on this zone"
					title="WAF rules"
				/>
				<Row
					onPress={() => router.push(`/zones/${id}/healthchecks`)}
					subtitle="Origin health monitors"
					title="Healthchecks"
				/>
				<Row
					onPress={() => router.push(`/zones/${id}/waiting-rooms`)}
					subtitle="Queue visitors during traffic spikes"
					title="Waiting Rooms"
				/>
				<Row
					onPress={() => router.push(`/zones/${id}/load-balancers`)}
					subtitle="Traffic steering across origins"
					title="Load Balancers"
				/>
				<Row
					onPress={() => router.push(`/zones/${id}/page-rules`)}
					subtitle="Legacy URL-based rules"
					title="Page Rules"
				/>
				<Row
					onPress={() => router.push(`/zones/${id}/email-routing`)}
					subtitle="Route mail to destination addresses"
					title="Email Routing"
				/>
			</ListGroup>
		</ScrollView>
	)
}
