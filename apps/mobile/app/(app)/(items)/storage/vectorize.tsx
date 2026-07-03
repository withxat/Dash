import { useQuery } from '@tanstack/react-query'
import { useCallback, useState } from 'react'
import { RefreshControl, ScrollView } from 'react-native'

import { AccountSwitcher } from '../../../../components/account-switcher'
import { QuerySection } from '../../../../components/query-section'
import { ListGroup, Row } from '../../../../components/row'
import { cloudflareClient } from '../../../../lib/api'
import { formatDate } from '../../../../lib/format'
import { useTheme } from '../../../../lib/theme'
import { useActiveAccount } from '../../../../lib/use-active-account'

export default function VectorizeScreen() {
	const { activeAccountId } = useActiveAccount()
	const theme = useTheme()
	const [refreshing, setRefreshing] = useState(false)

	const indexesQuery = useQuery({
		enabled: Boolean(activeAccountId),
		queryFn: () => cloudflareClient.listVectorizeIndexes(activeAccountId!),
		queryKey: ['cf', 'vectorize-indexes', activeAccountId],
		retry: false,
	})

	const onRefresh = useCallback(async () => {
		setRefreshing(true)
		await indexesQuery.refetch().catch(() => {})
		setRefreshing(false)
	}, [indexesQuery])

	return (
		<ScrollView
			className="flex-1 bg-canvas"
			contentContainerStyle={{ gap: 16, padding: 16 }}
			contentInsetAdjustmentBehavior="automatic"
			refreshControl={<RefreshControl onRefresh={onRefresh} refreshing={refreshing} tintColor={theme.subtle} />}
		>
			<AccountSwitcher />

			<ListGroup title="Vectorize indexes">
				<QuerySection
					renderItem={index => (
						<Row
							chevron={false}
							right={index.config ? `${index.config.dimensions}d · ${index.config.metric}` : undefined}
							subtitle={index.created_on ? `Created ${formatDate(index.created_on)}` : index.description}
							title={index.name ?? 'Index'}
						/>
					)}
					emptyText="No Vectorize indexes in this account."
					error={indexesQuery.error}
					errorText="Failed to load Vectorize indexes."
					isError={indexesQuery.isError}
					isLoading={!activeAccountId || indexesQuery.isLoading}
					items={indexesQuery.data}
					onRetry={() => void indexesQuery.refetch()}
					scopeHint="Needs the Vectorize read scope — enable it on your OAuth client and sign in again."
				/>
			</ListGroup>
		</ScrollView>
	)
}
