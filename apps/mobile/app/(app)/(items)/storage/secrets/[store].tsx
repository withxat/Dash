import { useQuery } from '@tanstack/react-query'
import { Stack, useLocalSearchParams } from 'expo-router'
import { useCallback, useState } from 'react'
import { RefreshControl, ScrollView, Text } from 'react-native'

import { QuerySection } from '../../../../../components/query-section'
import { ListGroup, Row } from '../../../../../components/row'
import { cloudflareClient } from '../../../../../lib/api'
import { timeAgo } from '../../../../../lib/format'
import { useTheme } from '../../../../../lib/theme'
import { useActiveAccount } from '../../../../../lib/use-active-account'

export default function SecretsStoreScreen() {
	const { name, store: storeId } = useLocalSearchParams<{ name?: string, store: string }>()
	const { activeAccountId } = useActiveAccount()
	const theme = useTheme()
	const [refreshing, setRefreshing] = useState(false)

	const secretsQuery = useQuery({
		enabled: Boolean(activeAccountId && storeId),
		queryFn: () => cloudflareClient.listSecretsStoreSecrets(activeAccountId!, storeId),
		queryKey: ['cf', 'secrets-store-secrets', activeAccountId, storeId],
		retry: false,
	})

	const onRefresh = useCallback(async () => {
		setRefreshing(true)
		await secretsQuery.refetch().catch(() => {})
		setRefreshing(false)
	}, [secretsQuery])

	return (
		<ScrollView
			className="flex-1 bg-canvas"
			contentContainerStyle={{ gap: 16, padding: 16 }}
			contentInsetAdjustmentBehavior="automatic"
			refreshControl={<RefreshControl onRefresh={onRefresh} refreshing={refreshing} tintColor={theme.subtle} />}
		>
			<Stack.Screen options={{ title: name ?? 'Store' }} />

			<ListGroup title="Secrets">
				<QuerySection
					renderItem={secret => (
						<Row
							chevron={false}
							right={secret.status}
							subtitle={`Updated ${timeAgo(secret.modified)}`}
							title={secret.name}
						/>
					)}
					emptyText="No secrets in this store."
					error={secretsQuery.error}
					errorText="Failed to load secrets."
					isError={secretsQuery.isError}
					isLoading={!activeAccountId || secretsQuery.isLoading}
					items={secretsQuery.data}
					onRetry={() => void secretsQuery.refetch()}
					scopeHint="Needs the Secrets Store read scope — enable it on your OAuth client and sign in again."
				/>
			</ListGroup>

			<Text className="text-center text-[11px] text-placeholder">
				Secret values are write-only and can never be read back.
			</Text>
		</ScrollView>
	)
}
