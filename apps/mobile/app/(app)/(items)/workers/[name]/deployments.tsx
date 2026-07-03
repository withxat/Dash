import { useQuery } from '@tanstack/react-query'
import { useLocalSearchParams } from 'expo-router'
import { useState } from 'react'
import { RefreshControl, ScrollView, Text, View } from 'react-native'

import { Badge } from '../../../../../components/badge'
import { Card } from '../../../../../components/card'
import { EmptyState } from '../../../../../components/empty-state'
import { Skeleton } from '../../../../../components/skeleton'
import { cloudflareClient } from '../../../../../lib/api'
import { timeAgo } from '../../../../../lib/format'
import { useTheme } from '../../../../../lib/theme'
import { useActiveAccount } from '../../../../../lib/use-active-account'
import { useTabScrollPadding } from '../../../../../lib/use-tab-scroll-padding'

export default function WorkerDeploymentsScreen() {
	const tabScrollPadding = useTabScrollPadding()
	const { name } = useLocalSearchParams<{ name: string }>()
	const { activeAccountId } = useActiveAccount()
	const theme = useTheme()
	const [refreshing, setRefreshing] = useState(false)

	const deploymentsQuery = useQuery({
		enabled: Boolean(activeAccountId && name),
		queryFn: () => cloudflareClient.listWorkerDeployments(activeAccountId!, name),
		queryKey: ['cf', 'worker', activeAccountId, name, 'deployments'],
		retry: false,
	})

	const onRefresh = async () => {
		setRefreshing(true)
		await deploymentsQuery.refetch().catch(() => {})
		setRefreshing(false)
	}

	const deployments = deploymentsQuery.data ?? []

	return (
		<ScrollView
			className="flex-1 bg-canvas"
			contentContainerStyle={{ gap: 16, padding: 16, paddingBottom: tabScrollPadding }}
			contentInsetAdjustmentBehavior="automatic"
			refreshControl={<RefreshControl onRefresh={onRefresh} refreshing={refreshing} tintColor={theme.subtle} />}
		>
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
						? <EmptyState onAction={() => void deploymentsQuery.refetch()}>Deployment history unavailable.</EmptyState>
						: deployments.length === 0
							? <EmptyState>No deployments yet.</EmptyState>
							: (
									<View className="gap-4">
										{deployments.map((deployment, index) => (
											<View className="gap-1" key={deployment.id}>
												<View className="flex-row items-center justify-between gap-3">
													<Text className="min-w-0 flex-1 text-sm font-medium text-default" numberOfLines={1}>
														{deployment.annotations?.['workers/message']
															?? deployment.annotations?.['workers/triggered_by']
															?? deployment.source
															?? 'Deployment'}
													</Text>
													{index === 0
														? <Badge variant="success">live</Badge>
														: null}
												</View>
												<Text className="text-xs text-subtle">
													{[
														timeAgo(deployment.created_on),
														deployment.author_email,
														deployment.source,
													].filter(Boolean).join(' · ')}
												</Text>
												{deployment.id
													? (
															<Text className="font-mono text-[11px] text-placeholder" numberOfLines={1}>
																{deployment.id}
															</Text>
														)
													: null}
											</View>
										))}
									</View>
								)}
			</Card>
		</ScrollView>
	)
}
