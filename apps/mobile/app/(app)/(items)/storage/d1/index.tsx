import { useQuery } from '@tanstack/react-query'
import { router } from 'expo-router'
import { useCallback, useState } from 'react'
import { RefreshControl, ScrollView, View } from 'react-native'

import { AccountSwitcher } from '../../../../../components/account-switcher'
import { QuerySection } from '../../../../../components/query-section'
import { ListSurface, Row } from '../../../../../components/row'
import { SectionLabel } from '../../../../../components/section-label'
import { cloudflareClient } from '../../../../../lib/api'
import { formatDate } from '../../../../../lib/format'
import { useTheme } from '../../../../../lib/theme'
import { useActiveAccount } from '../../../../../lib/use-active-account'

export default function D1ListScreen() {
	const { activeAccountId } = useActiveAccount()
	const theme = useTheme()
	const [refreshing, setRefreshing] = useState(false)

	const databasesQuery = useQuery({
		enabled: Boolean(activeAccountId),
		queryFn: () => cloudflareClient.listD1Databases(activeAccountId!, { perPage: 100 }).then(p => p.items),
		queryKey: ['cf', 'd1-databases', activeAccountId],
		retry: false,
	})

	const onRefresh = useCallback(async () => {
		setRefreshing(true)
		await databasesQuery.refetch().catch(() => {})
		setRefreshing(false)
	}, [databasesQuery])

	return (
		<ScrollView
			className="flex-1 bg-canvas"
			contentContainerStyle={{ gap: 16, padding: 16 }}
			contentInsetAdjustmentBehavior="automatic"
			refreshControl={<RefreshControl onRefresh={onRefresh} refreshing={refreshing} tintColor={theme.subtle} />}
		>
			<AccountSwitcher />

			<View className="gap-2">
				<SectionLabel>Databases</SectionLabel>
				<ListSurface>
					<QuerySection
						renderItem={database => (
							<Row
								onPress={() => router.push({
									params: { name: database.name, uuid: database.uuid },
									pathname: '/storage/d1/[uuid]',
								})}
								right={database.version}
								subtitle={database.created_at ? `Created ${formatDate(database.created_at)}` : database.uuid}
								title={database.name ?? database.uuid ?? 'Database'}
							/>
						)}
						emptyText="No D1 databases in this account."
						error={databasesQuery.error}
						errorText="Failed to load D1 databases."
						isError={databasesQuery.isError}
						isLoading={!activeAccountId || databasesQuery.isLoading}
						items={databasesQuery.data}
						onRetry={() => void databasesQuery.refetch()}
						scopeHint="Needs the D1 read scope — enable it on your OAuth client and sign in again."
					/>
				</ListSurface>
			</View>
		</ScrollView>
	)
}
