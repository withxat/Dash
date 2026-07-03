import { useQuery } from '@tanstack/react-query'
import { router } from 'expo-router'
import { useCallback, useState } from 'react'
import { RefreshControl, ScrollView, View } from 'react-native'

import { AccountSwitcher } from '../../../../components/account-switcher'
import { QuerySection } from '../../../../components/query-section'
import { ListSurface, Row } from '../../../../components/row'
import { SectionLabel } from '../../../../components/section-label'
import { cloudflareClient } from '../../../../lib/api'
import { formatDate } from '../../../../lib/format'
import { useTheme } from '../../../../lib/theme'
import { useActiveAccount } from '../../../../lib/use-active-account'

export default function R2BucketsScreen() {
	const { activeAccountId } = useActiveAccount()
	const theme = useTheme()
	const [refreshing, setRefreshing] = useState(false)

	const bucketsQuery = useQuery({
		enabled: Boolean(activeAccountId),
		queryFn: () => cloudflareClient.listR2Buckets(activeAccountId!),
		queryKey: ['cf', 'r2-buckets', activeAccountId],
		retry: false,
	})

	const onRefresh = useCallback(async () => {
		setRefreshing(true)
		await bucketsQuery.refetch().catch(() => {})
		setRefreshing(false)
	}, [bucketsQuery])

	return (
		<ScrollView
			className="flex-1 bg-canvas"
			contentContainerStyle={{ gap: 16, padding: 16 }}
			contentInsetAdjustmentBehavior="automatic"
			refreshControl={<RefreshControl onRefresh={onRefresh} refreshing={refreshing} tintColor={theme.subtle} />}
		>
			<AccountSwitcher />

			<View className="gap-2">
				<SectionLabel>Buckets</SectionLabel>
				<ListSurface>
					<QuerySection
						renderItem={(bucket) => {
							const name = bucket.name ?? '—'
							return (
								<Row
									onPress={() => router.push(`/storage/r2/${encodeURIComponent(name)}`)}
									right={bucket.location}
									subtitle={bucket.creation_date ? `Created ${formatDate(bucket.creation_date)}` : undefined}
									title={name}
								/>
							)
						}}
						emptyText="No R2 buckets in this account."
						error={bucketsQuery.error}
						errorText="Failed to load R2 buckets."
						isError={bucketsQuery.isError}
						isLoading={!activeAccountId || bucketsQuery.isLoading}
						items={bucketsQuery.data}
						onRetry={() => void bucketsQuery.refetch()}
						scopeHint="Needs the R2 scopes — enable them on your OAuth client and sign in again."
					/>
					<Row
						onPress={() => router.push('/storage/new-bucket')}
						subtitle="Provision a new R2 bucket"
						title="Create bucket"
					/>
				</ListSurface>
			</View>
		</ScrollView>
	)
}
