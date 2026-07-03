import { ApiError } from '@cloudfx/api'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { router, useLocalSearchParams } from 'expo-router'
import { useCallback, useState } from 'react'
import { Alert, RefreshControl, ScrollView, Text, View } from 'react-native'

import { Badge } from '../../../../../../components/badge'
import { Button, ButtonText } from '../../../../../../components/button'
import { Card } from '../../../../../../components/card'
import { EmptyState } from '../../../../../../components/empty-state'
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

function stageTone(status?: string) {
	if (status === 'success')
		return 'success' as const
	if (status === 'failure' || status === 'canceled')
		return 'error' as const
	if (status === 'active')
		return 'info' as const
	return 'secondary' as const
}

function writeErrorMessage(error: unknown, fallback: string): string {
	return isForbidden(error)
		? 'Missing permission — enable the Pages write scope and sign in again.'
		: fallback
}

export default function PagesDeploymentScreen() {
	const tabScrollPadding = useTabScrollPadding()
	const { deployment: deploymentId, project } = useLocalSearchParams<{ deployment: string, project: string }>()
	const { activeAccountId } = useActiveAccount()
	const theme = useTheme()
	const toast = useToast()
	const queryClient = useQueryClient()
	const [refreshing, setRefreshing] = useState(false)

	const deploymentQuery = useQuery({
		enabled: Boolean(activeAccountId && project && deploymentId),
		queryFn: () => cloudflareClient.getPagesDeployment(activeAccountId!, project, deploymentId),
		queryKey: ['cf', 'pages-deployment', activeAccountId, project, deploymentId],
		retry: false,
	})

	const invalidate = useCallback(() => {
		void queryClient.invalidateQueries({ queryKey: ['cf', 'pages-deployments', activeAccountId, project] })
		void queryClient.invalidateQueries({ queryKey: ['cf', 'pages-deployment', activeAccountId, project, deploymentId] })
	}, [activeAccountId, deploymentId, project, queryClient])

	const retryMutation = useMutation({
		mutationFn: () => cloudflareClient.retryPagesDeployment(activeAccountId!, project, deploymentId),
		onError: (error) => {
			hapticError()
			toast.show(writeErrorMessage(error, 'Failed to retry the deployment.'), 'error')
		},
		onSuccess: () => {
			hapticSuccess()
			toast.show('Deployment retry started.', 'success')
			invalidate()
		},
	})

	const rollbackMutation = useMutation({
		mutationFn: () => cloudflareClient.rollbackPagesDeployment(activeAccountId!, project, deploymentId),
		onError: (error) => {
			hapticError()
			toast.show(writeErrorMessage(error, 'Failed to roll back to this deployment.'), 'error')
		},
		onSuccess: () => {
			hapticSuccess()
			toast.show('Production rolled back to this deployment.', 'success')
			invalidate()
		},
	})

	const deleteMutation = useMutation({
		mutationFn: () => cloudflareClient.deletePagesDeployment(activeAccountId!, project, deploymentId),
		onError: (error) => {
			hapticError()
			toast.show(writeErrorMessage(error, 'Failed to delete the deployment.'), 'error')
		},
		onSuccess: () => {
			hapticSuccess()
			toast.show('Deployment deleted.', 'success')
			void queryClient.invalidateQueries({ queryKey: ['cf', 'pages-deployments', activeAccountId, project] })
			router.back()
		},
	})

	const confirmRollback = useCallback(() => {
		Alert.alert(
			'Roll back production?',
			'Production traffic will be served from this deployment until a new one is created.',
			[
				{ style: 'cancel', text: 'Cancel' },
				{ onPress: () => rollbackMutation.mutate(), text: 'Roll back' },
			],
		)
	}, [rollbackMutation])

	const confirmDelete = useCallback(() => {
		Alert.alert('Delete deployment?', 'This cannot be undone.', [
			{ style: 'cancel', text: 'Cancel' },
			{ onPress: () => deleteMutation.mutate(), style: 'destructive', text: 'Delete' },
		])
	}, [deleteMutation])

	const onRefresh = async () => {
		setRefreshing(true)
		await deploymentQuery.refetch().catch(() => {})
		setRefreshing(false)
	}

	const deployment = deploymentQuery.data

	if (deploymentQuery.isLoading) {
		return (
			<View className="flex-1 gap-3 bg-canvas p-4">
				<Skeleton className="h-32 w-full rounded-kumo" />
				<Skeleton className="h-48 w-full rounded-kumo" />
			</View>
		)
	}
	if (deploymentQuery.isError || !deployment) {
		return (
			<View className="flex-1 items-center justify-center bg-canvas">
				<EmptyState onAction={() => void deploymentQuery.refetch()}>Failed to load this deployment.</EmptyState>
			</View>
		)
	}

	const meta = deployment.deployment_trigger?.metadata
	const status = deployment.latest_stage?.status
	const stages = deployment.stages ?? []
	const failed = status === 'failure' || status === 'canceled'

	return (
		<ScrollView
			className="flex-1 bg-canvas"
			contentContainerStyle={{ gap: 16, padding: 16, paddingBottom: tabScrollPadding }}
			contentInsetAdjustmentBehavior="automatic"
			refreshControl={<RefreshControl onRefresh={onRefresh} refreshing={refreshing} tintColor={theme.subtle} />}
		>
			<Card>
				<View className="gap-3">
					<View className="flex-row items-center justify-between gap-3">
						<Text className="min-w-0 flex-1 text-sm font-medium text-default" numberOfLines={2}>
							{meta?.commit_message ?? deployment.url ?? deployment.id}
						</Text>
						<Badge variant={stageTone(status)}>{status ?? 'unknown'}</Badge>
					</View>
					<Text className="text-xs text-subtle">
						{[
							deployment.environment,
							meta?.branch,
							meta?.commit_hash?.slice(0, 7),
							timeAgo(deployment.created_on),
						].filter(Boolean).join(' · ')}
					</Text>
					{deployment.url
						? (
								<Text className="font-mono text-xs text-subtle" numberOfLines={1} selectable>
									{deployment.url}
								</Text>
							)
						: null}
				</View>
			</Card>

			{stages.length > 0
				? (
						<Card title="Build stages">
							<View className="gap-3">
								{stages.map(stage => (
									<View className="flex-row items-center justify-between gap-3" key={stage.name}>
										<Text className="text-sm text-default">{stage.name ?? '—'}</Text>
										<View className="flex-row items-center gap-2">
											{stage.ended_on
												? <Text className="text-[11px] text-placeholder">{timeAgo(stage.ended_on)}</Text>
												: null}
											<Badge variant={stageTone(stage.status)}>{stage.status ?? 'idle'}</Badge>
										</View>
									</View>
								))}
							</View>
						</Card>
					)
				: null}

			<Card title="Actions">
				<View className="gap-3">
					{failed
						? (
								<Button loading={retryMutation.isPending} onPress={() => retryMutation.mutate()}>
									<ButtonText>Retry deployment</ButtonText>
								</Button>
							)
						: null}
					{deployment.environment === 'production'
						? (
								<Button loading={rollbackMutation.isPending} onPress={confirmRollback} variant="outline">
									<ButtonText>Roll back production to this deployment</ButtonText>
								</Button>
							)
						: null}
					<Button loading={deleteMutation.isPending} onPress={confirmDelete} variant="destructive">
						<ButtonText>Delete deployment</ButtonText>
					</Button>
				</View>
			</Card>
		</ScrollView>
	)
}
