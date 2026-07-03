import { ApiError } from '@cloudfx/api'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useLocalSearchParams } from 'expo-router'
import { useCallback, useMemo, useState } from 'react'
import { Alert, Pressable, RefreshControl, ScrollView, Text, View } from 'react-native'

import { Button, ButtonText } from '../../../../../components/button'
import { Card } from '../../../../../components/card'
import { EmptyState } from '../../../../../components/empty-state'
import { TrashIcon } from '../../../../../components/icons'
import { Input } from '../../../../../components/input'
import { SectionLabel } from '../../../../../components/section-label'
import { Skeleton } from '../../../../../components/skeleton'
import { cloudflareClient } from '../../../../../lib/api'
import { cx } from '../../../../../lib/cx'
import { hapticError, hapticSuccess } from '../../../../../lib/haptics'
import { useTheme } from '../../../../../lib/theme'
import { useActiveAccount } from '../../../../../lib/use-active-account'
import { useTabScrollPadding } from '../../../../../lib/use-tab-scroll-padding'
import { useToast } from '../../../../../lib/use-toast'

/** True when the error is a Cloudflare permission failure (missing scope). */
function isForbidden(error: unknown): boolean {
	return error instanceof ApiError && (error.status === 403 || error.status === 401)
}

export default function WorkerDomainsScreen() {
	const tabScrollPadding = useTabScrollPadding()
	const { name } = useLocalSearchParams<{ name: string }>()
	const { activeAccountId } = useActiveAccount()
	const theme = useTheme()
	const toast = useToast()
	const queryClient = useQueryClient()
	const [hostname, setHostname] = useState('')
	const [zoneId, setZoneId] = useState<string | undefined>(undefined)
	const [refreshing, setRefreshing] = useState(false)

	const domainsQuery = useQuery({
		enabled: Boolean(activeAccountId && name),
		queryFn: () => cloudflareClient.listWorkerDomains(activeAccountId!, { service: name }),
		queryKey: ['cf', 'worker', activeAccountId, name, 'domains'],
		retry: false,
	})
	const zonesQuery = useQuery({
		enabled: Boolean(activeAccountId),
		queryFn: () => cloudflareClient.listZones({ accountId: activeAccountId!, perPage: 50 }).then(p => p.items),
		queryKey: ['cf', 'zones-for-domains', activeAccountId],
		retry: false,
	})

	const zones = useMemo(() => zonesQuery.data ?? [], [zonesQuery.data])

	// Auto-match the zone from the typed hostname when the user hasn't picked one.
	const matchedZoneId = useMemo(() => {
		const host = hostname.trim().toLowerCase()
		if (!host)
			return undefined
		const match = zones.find(z => z.name && (host === z.name || host.endsWith(`.${z.name}`)))
		return match?.id
	}, [hostname, zones])
	const selectedZoneId = zoneId ?? matchedZoneId

	const invalidate = useCallback(() => {
		void queryClient.invalidateQueries({ queryKey: ['cf', 'worker', activeAccountId, name, 'domains'] })
	}, [activeAccountId, name, queryClient])

	const attachMutation = useMutation({
		mutationFn: () => cloudflareClient.attachWorkerDomain(activeAccountId!, {
			hostname: hostname.trim().toLowerCase(),
			service: name,
			zone_id: selectedZoneId!,
		}),
		onError: (error) => {
			hapticError()
			toast.show(
				isForbidden(error) ? 'Missing permission — enable the Workers Scripts write scope and sign in again.' : 'Failed to attach the domain.',
				'error',
			)
		},
		onSuccess: () => {
			hapticSuccess()
			toast.show('Domain attached.', 'success')
			setHostname('')
			setZoneId(undefined)
			invalidate()
		},
	})

	const detachMutation = useMutation({
		mutationFn: (domainId: string) => cloudflareClient.detachWorkerDomain(activeAccountId!, domainId),
		onError: () => {
			hapticError()
			toast.show('Failed to detach the domain.', 'error')
		},
		onSuccess: () => {
			hapticSuccess()
			toast.show('Domain detached.', 'success')
			invalidate()
		},
	})

	const confirmDetach = useCallback((domainId: string, domainHostname: string) => {
		Alert.alert('Detach domain?', `${domainHostname} will stop routing to this Worker.`, [
			{ style: 'cancel', text: 'Cancel' },
			{ onPress: () => detachMutation.mutate(domainId), style: 'destructive', text: 'Detach' },
		])
	}, [detachMutation])

	const onRefresh = async () => {
		setRefreshing(true)
		await domainsQuery.refetch().catch(() => {})
		setRefreshing(false)
	}

	const domains = domainsQuery.data ?? []

	return (
		<ScrollView
			className="flex-1 bg-canvas"
			contentContainerStyle={{ gap: 16, padding: 16, paddingBottom: tabScrollPadding }}
			contentInsetAdjustmentBehavior="automatic"
			keyboardShouldPersistTaps="handled"
			refreshControl={<RefreshControl onRefresh={onRefresh} refreshing={refreshing} tintColor={theme.subtle} />}
		>
			<View className="gap-2">
				<SectionLabel>Attach a domain</SectionLabel>
				<Card>
					<View className="gap-3">
						<Input
							autoCapitalize="none"
							autoCorrect={false}
							keyboardType="url"
							label="Hostname"
							onChangeText={setHostname}
							placeholder="worker.example.com"
							value={hostname}
							mono
						/>
						{zones.length > 0
							? (
									<View className="gap-1.5">
										<Text className="text-sm font-medium text-subtle">Zone</Text>
										<View className="flex-row flex-wrap gap-2">
											{zones.map((zone) => {
												const active = zone.id === selectedZoneId
												return (
													<Pressable
														className={cx(
															`
																rounded-full px-3 py-1.5
																active:opacity-80
															`,
															active ? 'bg-brand' : 'border border-line bg-base',
														)}
														accessibilityRole="button"
														key={zone.id}
														onPress={() => setZoneId(zone.id)}
														style={{ borderCurve: 'continuous' }}
													>
														<Text className={cx('text-xs font-medium', active ? 'text-inverse' : 'text-subtle')}>
															{zone.name}
														</Text>
													</Pressable>
												)
											})}
										</View>
									</View>
								)
							: null}
						<Button
							disabled={!hostname.trim() || !selectedZoneId}
							loading={attachMutation.isPending}
							onPress={() => attachMutation.mutate()}
						>
							<ButtonText>Attach domain</ButtonText>
						</Button>
					</View>
				</Card>
			</View>

			<View className="gap-2">
				<SectionLabel>Attached domains</SectionLabel>
				<Card>
					{domainsQuery.isLoading
						? <Skeleton className="h-10 w-full" />
						: domainsQuery.isError
							? <EmptyState onAction={() => void domainsQuery.refetch()}>Custom domains unavailable.</EmptyState>
							: domains.length === 0
								? <EmptyState>No custom domains bound to this Worker.</EmptyState>
								: (
										<View className="gap-3">
											{domains.map(domain => (
												<View className="flex-row items-center gap-3" key={domain.id}>
													<View className="min-w-0 flex-1 gap-0.5">
														<Text className="font-mono text-sm text-default" numberOfLines={1}>
															{domain.hostname}
														</Text>
														{domain.zone_name
															? <Text className="text-xs text-placeholder">{domain.zone_name}</Text>
															: null}
													</View>
													<Pressable
														className="
															rounded-kumo p-2
															active:bg-elevated
														"
														accessibilityLabel={`Detach ${domain.hostname}`}
														hitSlop={8}
														onPress={() => domain.id && domain.hostname && confirmDetach(String(domain.id), domain.hostname)}
													>
														<TrashIcon color={theme.danger} size={18} />
													</Pressable>
												</View>
											))}
										</View>
									)}
				</Card>
			</View>
		</ScrollView>
	)
}
