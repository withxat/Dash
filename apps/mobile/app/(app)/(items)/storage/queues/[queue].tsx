import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Stack, useLocalSearchParams } from 'expo-router'
import { useCallback, useState } from 'react'
import { Alert, RefreshControl, ScrollView, Text, View } from 'react-native'

import { Button, ButtonText } from '../../../../../components/button'
import { Card } from '../../../../../components/card'
import { EmptyState } from '../../../../../components/empty-state'
import { ListSurface, Row } from '../../../../../components/row'
import { SectionLabel } from '../../../../../components/section-label'
import { Skeleton } from '../../../../../components/skeleton'
import { Stat } from '../../../../../components/stat'
import { cloudflareClient } from '../../../../../lib/api'
import { isForbidden } from '../../../../../lib/api-errors'
import { formatDate } from '../../../../../lib/format'
import { hapticError, hapticSuccess } from '../../../../../lib/haptics'
import { useTheme } from '../../../../../lib/theme'
import { useActiveAccount } from '../../../../../lib/use-active-account'
import { useToast } from '../../../../../lib/use-toast'

export default function QueueDetailScreen() {
	const { name, queue: queueId } = useLocalSearchParams<{ name?: string, queue: string }>()
	const { activeAccountId } = useActiveAccount()
	const theme = useTheme()
	const toast = useToast()
	const queryClient = useQueryClient()
	const [refreshing, setRefreshing] = useState(false)

	const queueQuery = useQuery({
		enabled: Boolean(activeAccountId && queueId),
		queryFn: () => cloudflareClient.getQueue(activeAccountId!, queueId),
		queryKey: ['cf', 'queue', activeAccountId, queueId],
		retry: false,
	})

	const purgeMutation = useMutation({
		mutationFn: () => cloudflareClient.purgeQueue(activeAccountId!, queueId),
		onError: (error) => {
			hapticError()
			toast.show(
				isForbidden(error)
					? 'Missing permission — enable the Queues write scope and sign in again.'
					: 'Failed to purge the queue.',
				'error',
			)
		},
		onSuccess: () => {
			hapticSuccess()
			toast.show('Queue purged.', 'success')
			void queryClient.invalidateQueries({ queryKey: ['cf', 'queue', activeAccountId, queueId] })
		},
	})

	const confirmPurge = useCallback(() => {
		Alert.alert(
			'Purge queue?',
			'All messages in this queue will be deleted permanently. Consumers will stop receiving the purged messages.',
			[
				{ style: 'cancel', text: 'Cancel' },
				{ onPress: () => purgeMutation.mutate(), style: 'destructive', text: 'Purge' },
			],
		)
	}, [purgeMutation])

	const onRefresh = useCallback(async () => {
		setRefreshing(true)
		await queueQuery.refetch().catch(() => {})
		setRefreshing(false)
	}, [queueQuery])

	const queue = queueQuery.data
	const producers = queue?.producers ?? []
	const consumers = queue?.consumers ?? []

	return (
		<ScrollView
			className="flex-1 bg-canvas"
			contentContainerStyle={{ gap: 16, padding: 16 }}
			contentInsetAdjustmentBehavior="automatic"
			refreshControl={<RefreshControl onRefresh={onRefresh} refreshing={refreshing} tintColor={theme.subtle} />}
		>
			<Stack.Screen options={{ title: name ?? queue?.queue_name ?? 'Queue' }} />

			<Card>
				{queueQuery.isLoading
					? <Skeleton className="h-16 w-full" />
					: queueQuery.isError
						? (
								<EmptyState onAction={() => void queueQuery.refetch()}>
									{isForbidden(queueQuery.error)
										? 'Needs the Queues read scope — enable it on your OAuth client and sign in again.'
										: 'Failed to load queue details.'}
								</EmptyState>
							)
						: (
								<View className="flex-row flex-wrap gap-x-8 gap-y-4">
									<Stat label="Producers" value={String(queue?.producers_total_count ?? 0)} />
									<Stat label="Consumers" value={String(queue?.consumers_total_count ?? 0)} />
									<Stat label="Created" value={formatDate(queue?.created_on)} />
								</View>
							)}
			</Card>

			{producers.length > 0
				? (
						<View className="gap-2">
							<SectionLabel>Producers</SectionLabel>
							<ListSurface>
								{producers.map((producer, index) => (
									<Row
										chevron={false}
										// eslint-disable-next-line react/no-array-index-key -- producers have no id
										key={index}
										right={producer.type}
										title={('script' in producer ? producer.script : 'bucket_name' in producer ? producer.bucket_name : undefined) ?? 'Producer'}
									/>
								))}
							</ListSurface>
						</View>
					)
				: null}

			{consumers.length > 0
				? (
						<View className="gap-2">
							<SectionLabel>Consumers</SectionLabel>
							<ListSurface>
								{consumers.map((consumer, index) => (
									<Row
										chevron={false}
										// eslint-disable-next-line react/no-array-index-key -- consumers may miss ids
										key={consumer.consumer_id ?? index}
										right={consumer.type}
										title={('script_name' in consumer ? consumer.script_name : undefined) ?? consumer.consumer_id ?? 'Consumer'}
									/>
								))}
							</ListSurface>
						</View>
					)
				: null}

			<View className="gap-2 py-2">
				<Button
					disabled={queueQuery.isLoading || queueQuery.isError}
					loading={purgeMutation.isPending}
					onPress={confirmPurge}
					variant="secondary-destructive"
				>
					<ButtonText>Purge queue</ButtonText>
				</Button>
				<Text className="text-center text-[11px] text-placeholder">
					Purging deletes every queued message permanently.
				</Text>
			</View>
		</ScrollView>
	)
}
