import { useQuery } from '@tanstack/react-query'
import { router } from 'expo-router'
import { useCallback, useState } from 'react'
import { RefreshControl, ScrollView } from 'react-native'

import { AccountSwitcher } from '../../../../../components/account-switcher'
import { QuerySection } from '../../../../../components/query-section'
import { ListGroup, Row } from '../../../../../components/row'
import { cloudflareClient } from '../../../../../lib/api'
import { formatDate } from '../../../../../lib/format'
import { useTheme } from '../../../../../lib/theme'
import { useActiveAccount } from '../../../../../lib/use-active-account'

export default function SecretsStoresScreen() {
	const { activeAccountId } = useActiveAccount()
	const theme = useTheme()
	const [refreshing, setRefreshing] = useState(false)

	const storesQuery = useQuery({
		enabled: Boolean(activeAccountId),
		queryFn: () => cloudflareClient.listSecretsStores(activeAccountId!),
		queryKey: ['cf', 'secrets-stores', activeAccountId],
		retry: false,
	})

	const onRefresh = useCallback(async () => {
		setRefreshing(true)
		await storesQuery.refetch().catch(() => {})
		setRefreshing(false)
	}, [storesQuery])

	return (
		<ScrollView
			className="flex-1 bg-canvas"
			contentContainerStyle={{ gap: 16, padding: 16 }}
			contentInsetAdjustmentBehavior="automatic"
			refreshControl={<RefreshControl onRefresh={onRefresh} refreshing={refreshing} tintColor={theme.subtle} />}
		>
			<AccountSwitcher />

			<ListGroup title="Stores">
				<QuerySection
					renderItem={store => (
						<Row
							onPress={() => router.push({
								params: { name: store.name, store: store.id },
								pathname: '/storage/secrets/[store]',
							})}
							subtitle={store.created ? `Created ${formatDate(store.created)}` : store.id}
							title={store.name ?? store.id ?? 'Store'}
						/>
					)}
					emptyText="No secret stores in this account."
					error={storesQuery.error}
					errorText="Failed to load secret stores."
					isError={storesQuery.isError}
					isLoading={!activeAccountId || storesQuery.isLoading}
					items={storesQuery.data}
					onRetry={() => void storesQuery.refetch()}
					scopeHint="Needs the Secrets Store read scope — enable it on your OAuth client and sign in again."
				/>
			</ListGroup>
		</ScrollView>
	)
}
