import { ApiError } from '@cloudfx/api'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { router, Stack, useLocalSearchParams } from 'expo-router'
import { useCallback, useState } from 'react'
import { RefreshControl, ScrollView, Text, View } from 'react-native'

import { Badge } from '../../../../components/badge'
import { Card } from '../../../../components/card'
import { EmptyState } from '../../../../components/empty-state'
import { ListSurface, Row } from '../../../../components/row'
import { SectionLabel } from '../../../../components/section-label'
import { SettingRow } from '../../../../components/setting-row'
import { Skeleton } from '../../../../components/skeleton'
import { Stat } from '../../../../components/stat'
import { cloudflareClient } from '../../../../lib/api'
import { formatDate, timeAgo } from '../../../../lib/format'
import { hapticError, hapticSuccess } from '../../../../lib/haptics'
import { useTheme } from '../../../../lib/theme'
import { useActiveAccount } from '../../../../lib/use-active-account'
import { useTabScrollPadding } from '../../../../lib/use-tab-scroll-padding'
import { useToast } from '../../../../lib/use-toast'

/** True when the error is a Cloudflare permission failure (missing scope). */
function isForbidden(error: unknown): boolean {
	return error instanceof ApiError && (error.status === 403 || error.status === 401)
}

export default function WorkerDetailScreen() {
	const tabScrollPadding = useTabScrollPadding()
	const { name } = useLocalSearchParams<{ name: string }>()
	const { activeAccountId } = useActiveAccount()
	const theme = useTheme()
	const toast = useToast()
	const queryClient = useQueryClient()
	const [refreshing, setRefreshing] = useState(false)

	const settingsQuery = useQuery({
		enabled: Boolean(activeAccountId && name),
		queryFn: () => cloudflareClient.getWorkerSettings(activeAccountId!, name),
		queryKey: ['cf', 'worker', activeAccountId, name, 'settings'],
		retry: false,
	})
	const subdomainQuery = useQuery({
		enabled: Boolean(activeAccountId && name),
		queryFn: () => cloudflareClient.getWorkerSubdomain(activeAccountId!, name),
		queryKey: ['cf', 'worker', activeAccountId, name, 'subdomain'],
		retry: false,
	})
	const domainsQuery = useQuery({
		enabled: Boolean(activeAccountId && name),
		queryFn: () => cloudflareClient.listWorkerDomains(activeAccountId!, { service: name }),
		queryKey: ['cf', 'worker', activeAccountId, name, 'domains'],
		retry: false,
	})
	const deploymentsQuery = useQuery({
		enabled: Boolean(activeAccountId && name),
		queryFn: () => cloudflareClient.listWorkerDeployments(activeAccountId!, name),
		queryKey: ['cf', 'worker', activeAccountId, name, 'deployments'],
		retry: false,
	})

	const subdomainMutation = useMutation({
		mutationFn: (enabled: boolean) => cloudflareClient.setWorkerSubdomain(activeAccountId!, name, enabled),
		onError: (error) => {
			hapticError()
			toast.show(
				isForbidden(error) ? 'Missing permission — enable the Workers Scripts write scope and sign in again.' : 'Failed to update the subdomain.',
				'error',
			)
		},
		onSuccess: (_, enabled) => {
			hapticSuccess()
			toast.show(enabled ? 'Worker is live on workers.dev.' : 'Worker paused on workers.dev.', 'success')
			void queryClient.invalidateQueries({ queryKey: ['cf', 'worker', activeAccountId, name, 'subdomain'] })
		},
	})

	const onRefresh = useCallback(async () => {
		setRefreshing(true)
		await queryClient.refetchQueries({ queryKey: ['cf', 'worker', activeAccountId, name] }).catch(() => {})
		setRefreshing(false)
	}, [activeAccountId, name, queryClient])

	const settings = settingsQuery.data
	const bindings = settings?.bindings ?? []
	const domainCount = domainsQuery.data?.length
	const deployments = deploymentsQuery.data ?? []
	const latestDeployment = deployments[0]

	return (
		<ScrollView
			className="flex-1 bg-canvas"
			contentContainerStyle={{ gap: 16, padding: 16, paddingBottom: tabScrollPadding }}
			contentInsetAdjustmentBehavior="automatic"
			refreshControl={<RefreshControl onRefresh={onRefresh} refreshing={refreshing} tintColor={theme.subtle} />}
		>
			<Stack.Screen options={{ title: name }} />

			<Card>
				{settingsQuery.isLoading
					? <Skeleton className="h-16 w-full" />
					: settingsQuery.isError
						? <EmptyState>Worker metadata unavailable.</EmptyState>
						: (
								<View className="gap-4">
									<View className="flex-row flex-wrap gap-x-8 gap-y-4">
										<Stat
											label="Compat date"
											value={settings?.compatibility_date ? formatDate(settings.compatibility_date) : '—'}
										/>
										<Stat label="Usage model" value={settings?.usage_model ?? 'standard'} />
									</View>
									{bindings.length > 0
										? (
												<View className="gap-2">
													<Text className="text-sm font-medium text-subtle">Bindings</Text>
													<View className="flex-row flex-wrap gap-2">
														{bindings.map((binding, i) => (
															<Badge key={`${binding.type}-${binding.name ?? i}`} variant="info" mono>
																{binding.name ? `${binding.name} (${binding.type})` : binding.type}
															</Badge>
														))}
													</View>
												</View>
											)
										: null}
								</View>
							)}
			</Card>

			{/* Service availability */}
			<View className="gap-2">
				<SectionLabel>Service</SectionLabel>
				<ListSurface>
					{subdomainQuery.isLoading
						? (
								<View className="py-3">
									<Skeleton className="h-6 w-full" />
								</View>
							)
						: subdomainQuery.isError
							? (
									<EmptyState>
										{isForbidden(subdomainQuery.error)
											? 'Needs the Workers Scripts write scope — enable it on your OAuth client and sign in again.'
											: 'Subdomain status unavailable.'}
									</EmptyState>
								)
							: (
									<SettingRow
										loading={subdomainMutation.isPending}
										onValueChange={enabled => subdomainMutation.mutate(enabled)}
										subtitle="Serve this Worker on its workers.dev URL"
										title="workers.dev subdomain"
										value={subdomainQuery.data?.enabled ?? false}
									/>
								)}
				</ListSurface>
			</View>

			{/* Browse */}
			<View className="gap-2">
				<SectionLabel>Manage</SectionLabel>
				<ListSurface>
					<Row
						onPress={() => router.push(`/workers/${encodeURIComponent(name)}/deployments`)}
						subtitle={latestDeployment?.created_on ? `Last deployed ${timeAgo(latestDeployment.created_on)}` : 'Deployment history'}
						title="Deployments"
					/>
					<Row
						onPress={() => router.push(`/workers/${encodeURIComponent(name)}/domains`)}
						right={domainCount != null ? String(domainCount) : undefined}
						subtitle="Attach or detach hostnames"
						title="Custom domains"
					/>
					<Row
						onPress={() => router.push(`/workers/${encodeURIComponent(name)}/source`)}
						subtitle="View the deployed script"
						title="Source"
					/>
					<Row
						onPress={() => router.push(`/workers/${encodeURIComponent(name)}/builds`)}
						subtitle="Workers Builds history"
						title="Builds"
					/>
					<Row
						onPress={() => router.push(`/workers/${encodeURIComponent(name)}/logs`)}
						subtitle="Recent logs and errors"
						title="Logs"
					/>
				</ListSurface>
			</View>
		</ScrollView>
	)
}
