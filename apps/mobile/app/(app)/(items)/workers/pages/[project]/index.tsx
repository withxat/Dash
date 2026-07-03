import type { PagesDeployment } from '@cloudfx/api'

import { ApiError } from '@cloudfx/api'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { router, Stack, useLocalSearchParams } from 'expo-router'
import { useCallback, useState } from 'react'
import { Alert, Pressable, RefreshControl, ScrollView, Text, View } from 'react-native'

import { Badge } from '../../../../../../components/badge'
import { Button, ButtonText } from '../../../../../../components/button'
import { Card } from '../../../../../../components/card'
import { EmptyState } from '../../../../../../components/empty-state'
import { ChevronRightIcon, TrashIcon } from '../../../../../../components/icons'
import { Input } from '../../../../../../components/input'
import { SectionLabel } from '../../../../../../components/section-label'
import { Skeleton } from '../../../../../../components/skeleton'
import { cloudflareClient } from '../../../../../../lib/api'
import { timeAgo } from '../../../../../../lib/format'
import { hapticError, hapticSuccess } from '../../../../../../lib/haptics'
import { useTheme } from '../../../../../../lib/theme'
import { useActiveAccount } from '../../../../../../lib/use-active-account'
import { useTabScrollPadding } from '../../../../../../lib/use-tab-scroll-padding'
import { useToast } from '../../../../../../lib/use-toast'

/** True when the error is a Cloudflare permission failure (missing scope). */
function isForbidden(error: unknown): boolean {
	return error instanceof ApiError && (error.status === 403 || error.status === 401)
}

function deploymentTone(status?: string) {
	if (status === 'success')
		return 'success' as const
	if (status === 'failure' || status === 'canceled')
		return 'error' as const
	return 'warning' as const
}

function DeploymentRow({ deployment, onPress }: { deployment: PagesDeployment, onPress: () => void }) {
	const theme = useTheme()
	const meta = deployment.deployment_trigger?.metadata
	const status = deployment.latest_stage?.status
	return (
		<Pressable
			className="
				flex-row items-center gap-2
				active:opacity-70
			"
			accessibilityRole="button"
			onPress={onPress}
		>
			<View className="min-w-0 flex-1 gap-1">
				<View className="flex-row items-center justify-between gap-3">
					<Text className="min-w-0 flex-1 text-sm font-medium text-default" numberOfLines={1}>
						{meta?.commit_message ?? deployment.url ?? deployment.id}
					</Text>
					<Badge variant={deploymentTone(status)}>{status ?? 'unknown'}</Badge>
				</View>
				<Text className="text-xs text-subtle" numberOfLines={1}>
					{[
						deployment.environment,
						meta?.branch,
						meta?.commit_hash?.slice(0, 7),
						timeAgo(deployment.created_on),
					].filter(Boolean).join(' · ')}
				</Text>
			</View>
			<ChevronRightIcon color={theme.placeholder} size={16} />
		</Pressable>
	)
}

export default function PagesProjectScreen() {
	const tabScrollPadding = useTabScrollPadding()
	const { project } = useLocalSearchParams<{ project: string }>()
	const { activeAccountId } = useActiveAccount()
	const theme = useTheme()
	const toast = useToast()
	const queryClient = useQueryClient()
	const [refreshing, setRefreshing] = useState(false)
	const [newDomain, setNewDomain] = useState('')

	const projectsQuery = useQuery({
		enabled: Boolean(activeAccountId),
		queryFn: () => cloudflareClient.listPagesProjects(activeAccountId!),
		queryKey: ['cf', 'pages-projects', activeAccountId],
		retry: false,
	})
	const domainsQuery = useQuery({
		enabled: Boolean(activeAccountId && project),
		queryFn: () => cloudflareClient.listPagesDomains(activeAccountId!, project),
		queryKey: ['cf', 'pages-domains', activeAccountId, project],
		retry: false,
	})
	const deploymentsQuery = useQuery({
		enabled: Boolean(activeAccountId && project),
		queryFn: () => cloudflareClient.listPagesDeployments(activeAccountId!, project),
		queryKey: ['cf', 'pages-deployments', activeAccountId, project],
		retry: false,
	})

	const invalidateDomains = useCallback(() => {
		void queryClient.invalidateQueries({ queryKey: ['cf', 'pages-domains', activeAccountId, project] })
	}, [activeAccountId, project, queryClient])

	const addDomainMutation = useMutation({
		mutationFn: (name: string) => cloudflareClient.addPagesDomain(activeAccountId!, project, name),
		onError: (error) => {
			hapticError()
			toast.show(
				isForbidden(error) ? 'Missing permission — enable the Pages write scope and sign in again.' : 'Failed to add the domain.',
				'error',
			)
		},
		onSuccess: () => {
			hapticSuccess()
			toast.show('Domain added — configure DNS to finish setup.', 'success')
			setNewDomain('')
			invalidateDomains()
		},
	})

	const deleteDomainMutation = useMutation({
		mutationFn: (name: string) => cloudflareClient.deletePagesDomain(activeAccountId!, project, name),
		onError: (error) => {
			hapticError()
			toast.show(
				isForbidden(error) ? 'Missing permission — enable the Pages write scope and sign in again.' : 'Failed to remove the domain.',
				'error',
			)
		},
		onSuccess: () => {
			hapticSuccess()
			toast.show('Domain removed.', 'success')
			invalidateDomains()
		},
	})

	const confirmDeleteDomain = useCallback((name: string) => {
		Alert.alert('Remove domain?', name, [
			{ style: 'cancel', text: 'Cancel' },
			{ onPress: () => deleteDomainMutation.mutate(name), style: 'destructive', text: 'Remove' },
		])
	}, [deleteDomainMutation])

	const onRefresh = useCallback(async () => {
		setRefreshing(true)
		await Promise.allSettled([
			queryClient.refetchQueries({ queryKey: ['cf', 'pages-deployments', activeAccountId, project] }),
			queryClient.refetchQueries({ queryKey: ['cf', 'pages-domains', activeAccountId, project] }),
		])
		setRefreshing(false)
	}, [activeAccountId, project, queryClient])

	const details = projectsQuery.data?.find(p => p.name === project)
	const deployments = deploymentsQuery.data ?? []
	const domains = domainsQuery.data ?? []

	return (
		<ScrollView
			className="flex-1 bg-canvas"
			contentContainerStyle={{ gap: 16, padding: 16, paddingBottom: tabScrollPadding }}
			contentInsetAdjustmentBehavior="automatic"
			keyboardShouldPersistTaps="handled"
			refreshControl={<RefreshControl onRefresh={onRefresh} refreshing={refreshing} tintColor={theme.subtle} />}
		>
			<Stack.Screen options={{ title: project }} />

			{details?.subdomain
				? (
						<Card>
							<View className="gap-1">
								<Text className="text-sm font-medium text-subtle">pages.dev</Text>
								<Text className="font-mono text-sm text-default" numberOfLines={1} selectable>
									{details.subdomain}
								</Text>
							</View>
						</Card>
					)
				: null}

			<View className="gap-2">
				<SectionLabel>Custom domains</SectionLabel>
				<Card>
					{domainsQuery.isLoading
						? <Skeleton className="h-10 w-full" />
						: (
								<View className="gap-3">
									{domains.length === 0
										? <EmptyState>No custom domains configured.</EmptyState>
										: domains.map(domain => (
												<View className="flex-row items-center gap-3" key={domain.id ?? domain.name}>
													<View className="min-w-0 flex-1 gap-0.5">
														<Text className="font-mono text-sm text-default" numberOfLines={1}>
															{domain.name}
														</Text>
														{domain.status
															? <Text className="text-xs text-placeholder">{domain.status}</Text>
															: null}
													</View>
													<Pressable
														className="
															rounded-kumo p-2
															active:bg-elevated
														"
														accessibilityLabel={`Remove ${domain.name}`}
														hitSlop={8}
														onPress={() => domain.name && confirmDeleteDomain(domain.name)}
													>
														<TrashIcon color={theme.danger} size={18} />
													</Pressable>
												</View>
											))}
									<View className="gap-3">
										<Input
											autoCapitalize="none"
											autoCorrect={false}
											keyboardType="url"
											onChangeText={setNewDomain}
											placeholder="www.example.com"
											value={newDomain}
											mono
										/>
										<Button
											disabled={!newDomain.trim()}
											loading={addDomainMutation.isPending}
											onPress={() => addDomainMutation.mutate(newDomain.trim().toLowerCase())}
											variant="outline"
										>
											<ButtonText>Add domain</ButtonText>
										</Button>
									</View>
								</View>
							)}
				</Card>
			</View>

			<View className="gap-2">
				<SectionLabel>Deployments</SectionLabel>
				<Card>
					{deploymentsQuery.isLoading
						? (
								<View className="gap-3">
									<Skeleton className="h-10 w-full" />
									<Skeleton className="h-10 w-full" />
									<Skeleton className="h-10 w-full" />
								</View>
							)
						: deploymentsQuery.isError
							? (
									<EmptyState onAction={() => void deploymentsQuery.refetch()}>
										Failed to load deployments — the Pages Read scope may be missing.
									</EmptyState>
								)
							: deployments.length === 0
								? <EmptyState>No deployments yet.</EmptyState>
								: (
										<View className="gap-4">
											{deployments.slice(0, 20).map(deployment => (
												<DeploymentRow
													onPress={() => deployment.id && router.push(
														`/workers/pages/${encodeURIComponent(project)}/${deployment.id}`,
													)}
													deployment={deployment}
													key={deployment.id}
												/>
											))}
										</View>
									)}
				</Card>
			</View>
		</ScrollView>
	)
}
