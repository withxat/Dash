import { useQuery } from '@tanstack/react-query'
import { router, Stack, useLocalSearchParams } from 'expo-router'
import { useCallback, useState } from 'react'
import { RefreshControl, ScrollView, View } from 'react-native'

import { Card } from '../../../../../components/card'
import { EmptyState } from '../../../../../components/empty-state'
import { QuerySection } from '../../../../../components/query-section'
import { ListSurface, Row } from '../../../../../components/row'
import { SectionLabel } from '../../../../../components/section-label'
import { Skeleton } from '../../../../../components/skeleton'
import { Stat } from '../../../../../components/stat'
import { cloudflareClient } from '../../../../../lib/api'
import { isForbidden } from '../../../../../lib/api-errors'
import { formatBytes, formatDate, formatNumber } from '../../../../../lib/format'
import { useTheme } from '../../../../../lib/theme'
import { useActiveAccount } from '../../../../../lib/use-active-account'

interface TableRow {
	name?: string
}

export default function D1DatabaseScreen() {
	const { name, uuid } = useLocalSearchParams<{ name?: string, uuid: string }>()
	const { activeAccountId } = useActiveAccount()
	const theme = useTheme()
	const [refreshing, setRefreshing] = useState(false)

	const databaseQuery = useQuery({
		enabled: Boolean(activeAccountId && uuid),
		queryFn: () => cloudflareClient.getD1Database(activeAccountId!, uuid),
		queryKey: ['cf', 'd1-database', activeAccountId, uuid],
		retry: false,
	})
	const tablesQuery = useQuery({
		enabled: Boolean(activeAccountId && uuid),
		queryFn: () => cloudflareClient.queryD1Database(
			activeAccountId!,
			uuid,
			'SELECT name FROM sqlite_schema WHERE type = \'table\' AND name NOT LIKE \'sqlite_%\' AND name NOT LIKE \'_cf_%\' ORDER BY name',
		).then(results => (results[0]?.results ?? []) as TableRow[]),
		queryKey: ['cf', 'd1-tables', activeAccountId, uuid],
		retry: false,
	})

	const onRefresh = useCallback(async () => {
		setRefreshing(true)
		await Promise.allSettled([databaseQuery.refetch(), tablesQuery.refetch()])
		setRefreshing(false)
	}, [databaseQuery, tablesQuery])

	const database = databaseQuery.data

	return (
		<ScrollView
			className="flex-1 bg-canvas"
			contentContainerStyle={{ gap: 16, padding: 16 }}
			contentInsetAdjustmentBehavior="automatic"
			refreshControl={<RefreshControl onRefresh={onRefresh} refreshing={refreshing} tintColor={theme.subtle} />}
		>
			<Stack.Screen options={{ title: name ?? database?.name ?? 'Database' }} />

			<Card>
				{databaseQuery.isLoading
					? <Skeleton className="h-16 w-full" />
					: databaseQuery.isError
						? (
								<EmptyState onAction={() => void databaseQuery.refetch()}>
									{isForbidden(databaseQuery.error)
										? 'Needs the D1 read scope — enable it on your OAuth client and sign in again.'
										: 'Failed to load database details.'}
								</EmptyState>
							)
						: (
								<View className="flex-row flex-wrap gap-x-8 gap-y-4">
									<Stat label="Size" value={formatBytes(database?.file_size)} />
									<Stat label="Tables" value={formatNumber(database?.num_tables)} />
									<Stat label="Created" value={formatDate(database?.created_at)} />
								</View>
							)}
			</Card>

			<View className="gap-2">
				<SectionLabel>Query</SectionLabel>
				<ListSurface>
					<Row
						onPress={() => router.push({
							params: { name: name ?? database?.name, uuid },
							pathname: '/storage/d1/console',
						})}
						subtitle="Run read-only SQL against this database"
						title="SQL console"
					/>
				</ListSurface>
			</View>

			<View className="gap-2">
				<SectionLabel>Tables</SectionLabel>
				<ListSurface>
					<QuerySection
						renderItem={table => (
							<Row
								onPress={() => router.push({
									params: { name: name ?? database?.name, sql: `SELECT * FROM "${table.name ?? ''}" LIMIT 25`, uuid },
									pathname: '/storage/d1/console',
								})}
								subtitle="Preview first 25 rows"
								title={table.name ?? 'table'}
							/>
						)}
						emptyText="No tables in this database."
						error={tablesQuery.error}
						errorText="Failed to list tables."
						isError={tablesQuery.isError}
						isLoading={!activeAccountId || tablesQuery.isLoading}
						items={tablesQuery.data}
						onRetry={() => void tablesQuery.refetch()}
						scopeHint="Needs the D1 read scope — enable it on your OAuth client and sign in again."
					/>
				</ListSurface>
			</View>
		</ScrollView>
	)
}
