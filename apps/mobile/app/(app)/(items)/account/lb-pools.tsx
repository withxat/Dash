import { useQuery } from '@tanstack/react-query'
import { useCallback, useState } from 'react'
import { RefreshControl, ScrollView, View } from 'react-native'

import { Badge } from '../../../../components/badge'
import { QuerySection } from '../../../../components/query-section'
import { ListSurface, Row } from '../../../../components/row'
import { SectionLabel } from '../../../../components/section-label'
import { cloudflareClient } from '../../../../lib/api'
import { useTheme } from '../../../../lib/theme'
import { useActiveAccount } from '../../../../lib/use-active-account'
import { useTabScrollPadding } from '../../../../lib/use-tab-scroll-padding'

export default function LbPoolsScreen() {
	const tabScrollPadding = useTabScrollPadding()
	const { activeAccount } = useActiveAccount()
	const accountId = activeAccount?.id
	const theme = useTheme()
	const [refreshing, setRefreshing] = useState(false)

	const poolsQuery = useQuery({
		enabled: Boolean(accountId),
		queryFn: () => cloudflareClient.listLoadBalancerPools(accountId!),
		queryKey: ['cf', 'account', accountId, 'lb-pools'],
		retry: false,
	})

	const onRefresh = useCallback(async () => {
		setRefreshing(true)
		await poolsQuery.refetch().catch(() => {})
		setRefreshing(false)
	}, [poolsQuery])

	return (
		<ScrollView
			className="flex-1 bg-canvas"
			contentContainerStyle={{ gap: 16, padding: 16, paddingBottom: tabScrollPadding }}
			contentInsetAdjustmentBehavior="automatic"
			refreshControl={<RefreshControl onRefresh={onRefresh} refreshing={refreshing} tintColor={theme.subtle} />}
		>
			<View className="gap-2">
				<SectionLabel>Origin pools</SectionLabel>
				<ListSurface>
					<QuerySection
						renderItem={pool => (
							<Row
								chevron={false}
								right={<Badge variant={pool.enabled === false ? 'secondary' : 'success'}>{pool.enabled === false ? 'Disabled' : 'Enabled'}</Badge>}
								subtitle={`${pool.origins?.length ?? 0} origin${(pool.origins?.length ?? 0) === 1 ? '' : 's'}`}
								title={pool.name ?? pool.id ?? 'Pool'}
							/>
						)}
						emptyText="No load balancer pools on this account."
						error={poolsQuery.error}
						errorText="Failed to load pools."
						isError={poolsQuery.isError}
						isLoading={poolsQuery.isLoading}
						items={poolsQuery.data}
						onRetry={() => void poolsQuery.refetch()}
						scopeHint="Needs the Load Balancing Monitors and Pools read scope — enable it on your OAuth client and sign in again."
					/>
				</ListSurface>
			</View>
		</ScrollView>
	)
}
