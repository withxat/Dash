import { useQuery } from '@tanstack/react-query'
import { router } from 'expo-router'
import { useCallback, useState } from 'react'
import { RefreshControl, ScrollView, View } from 'react-native'

import { AccountSwitcher } from '../../../../components/account-switcher'
import { QuerySection } from '../../../../components/query-section'
import { ListSurface, Row } from '../../../../components/row'
import { SectionLabel } from '../../../../components/section-label'
import { cloudflareClient } from '../../../../lib/api'
import { useTheme } from '../../../../lib/theme'
import { useActiveAccount } from '../../../../lib/use-active-account'

export default function KvNamespacesScreen() {
	const { activeAccountId } = useActiveAccount()
	const theme = useTheme()
	const [refreshing, setRefreshing] = useState(false)

	const namespacesQuery = useQuery({
		enabled: Boolean(activeAccountId),
		queryFn: () => cloudflareClient.listKvNamespaces(activeAccountId!, { perPage: 100 }).then(p => p.items),
		queryKey: ['cf', 'kv-namespaces', activeAccountId],
		retry: false,
	})

	const onRefresh = useCallback(async () => {
		setRefreshing(true)
		await namespacesQuery.refetch().catch(() => {})
		setRefreshing(false)
	}, [namespacesQuery])

	return (
		<ScrollView
			className="flex-1 bg-canvas"
			contentContainerStyle={{ gap: 16, padding: 16 }}
			contentInsetAdjustmentBehavior="automatic"
			refreshControl={<RefreshControl onRefresh={onRefresh} refreshing={refreshing} tintColor={theme.subtle} />}
		>
			<AccountSwitcher />

			<View className="gap-2">
				<SectionLabel>Namespaces</SectionLabel>
				<ListSurface>
					<QuerySection
						renderItem={namespace => (
							<Row
								onPress={() => router.push({
									params: { namespace: namespace.id, title: namespace.title },
									pathname: '/storage/kv/[namespace]',
								})}
								subtitle={namespace.id}
								title={namespace.title}
							/>
						)}
						emptyText="No KV namespaces in this account."
						error={namespacesQuery.error}
						errorText="Failed to load KV namespaces."
						isError={namespacesQuery.isError}
						isLoading={!activeAccountId || namespacesQuery.isLoading}
						items={namespacesQuery.data}
						onRetry={() => void namespacesQuery.refetch()}
						scopeHint="Needs the Workers KV scopes — enable them on your OAuth client and sign in again."
					/>
					<Row
						onPress={() => router.push('/storage/namespace-edit')}
						subtitle="Provision a new KV namespace"
						title="Create namespace"
					/>
				</ListSurface>
			</View>
		</ScrollView>
	)
}
