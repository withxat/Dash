import { useQuery } from '@tanstack/react-query'
import { router } from 'expo-router'
import { useCallback, useState } from 'react'
import { RefreshControl, ScrollView } from 'react-native'

import { AccountSwitcher } from '../../../../../components/account-switcher'
import { QuerySection } from '../../../../../components/query-section'
import { ListGroup, Row } from '../../../../../components/row'
import { cloudflareClient } from '../../../../../lib/api'
import { useTheme } from '../../../../../lib/theme'
import { useActiveAccount } from '../../../../../lib/use-active-account'

export default function QueuesListScreen() {
	const { activeAccountId } = useActiveAccount()
	const theme = useTheme()
	const [refreshing, setRefreshing] = useState(false)

	const queuesQuery = useQuery({
		enabled: Boolean(activeAccountId),
		queryFn: () => cloudflareClient.listQueues(activeAccountId!),
		queryKey: ['cf', 'queues', activeAccountId],
		retry: false,
	})

	const onRefresh = useCallback(async () => {
		setRefreshing(true)
		await queuesQuery.refetch().catch(() => {})
		setRefreshing(false)
	}, [queuesQuery])

	return (
		<ScrollView
			className="flex-1 bg-canvas"
			contentContainerStyle={{ gap: 16, padding: 16 }}
			contentInsetAdjustmentBehavior="automatic"
			refreshControl={<RefreshControl onRefresh={onRefresh} refreshing={refreshing} tintColor={theme.subtle} />}
		>
			<AccountSwitcher />

			<ListGroup title="Queues">
				<QuerySection
					renderItem={queue => (
						<Row
							onPress={() => router.push({
								params: { name: queue.queue_name, queue: queue.queue_id },
								pathname: '/storage/queues/[queue]',
							})}
							subtitle={`${queue.producers_total_count ?? 0} producers · ${queue.consumers_total_count ?? 0} consumers`}
							title={queue.queue_name ?? queue.queue_id ?? 'Queue'}
						/>
					)}
					emptyText="No queues in this account."
					error={queuesQuery.error}
					errorText="Failed to load queues."
					isError={queuesQuery.isError}
					isLoading={!activeAccountId || queuesQuery.isLoading}
					items={queuesQuery.data}
					onRetry={() => void queuesQuery.refetch()}
					scopeHint="Needs the Queues read scope — enable it on your OAuth client and sign in again."
				/>
			</ListGroup>
		</ScrollView>
	)
}
