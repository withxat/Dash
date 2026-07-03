import { useQuery } from '@tanstack/react-query'
import { router, useLocalSearchParams } from 'expo-router'
import { useCallback, useState } from 'react'
import { RefreshControl, ScrollView } from 'react-native'

import { Badge } from '../../../../../components/badge'
import { QuerySection } from '../../../../../components/query-section'
import { ListGroup, Row } from '../../../../../components/row'
import { cloudflareClient } from '../../../../../lib/api'
import { useTheme } from '../../../../../lib/theme'
import { useTabScrollPadding } from '../../../../../lib/use-tab-scroll-padding'

export default function ZoneLoadBalancersScreen() {
	const tabScrollPadding = useTabScrollPadding()
	const { id } = useLocalSearchParams<{ id: string }>()
	const theme = useTheme()
	const [refreshing, setRefreshing] = useState(false)

	const lbQuery = useQuery({
		enabled: Boolean(id),
		queryFn: () => cloudflareClient.listLoadBalancers(id),
		queryKey: ['cf', 'zone', id, 'load-balancers'],
		retry: false,
	})

	const onRefresh = useCallback(async () => {
		setRefreshing(true)
		await lbQuery.refetch().catch(() => {})
		setRefreshing(false)
	}, [lbQuery])

	return (
		<ScrollView
			className="flex-1 bg-canvas"
			contentContainerStyle={{ gap: 16, padding: 16, paddingBottom: tabScrollPadding }}
			contentInsetAdjustmentBehavior="automatic"
			refreshControl={<RefreshControl onRefresh={onRefresh} refreshing={refreshing} tintColor={theme.subtle} />}
		>
			<ListGroup title="Load Balancers">
				<QuerySection
					renderItem={lb => (
						<Row
							subtitle={[
								lb.steering_policy ? `Steering: ${lb.steering_policy}` : undefined,
								lb.proxied != null ? (lb.proxied ? 'Proxied' : 'DNS only') : undefined,
							].filter(Boolean).join(' · ')}
							chevron={false}
							right={<Badge variant={lb.enabled === false ? 'secondary' : 'success'}>{lb.enabled === false ? 'Disabled' : 'Enabled'}</Badge>}
							title={lb.name ?? lb.id ?? 'Load balancer'}
						/>
					)}
					emptyText="No load balancers on this zone."
					error={lbQuery.error}
					errorText="Failed to load load balancers."
					isError={lbQuery.isError}
					isLoading={lbQuery.isLoading}
					items={lbQuery.data}
					onRetry={() => void lbQuery.refetch()}
					scopeHint="Needs the Load Balancers read scope — enable it on your OAuth client and sign in again."
				/>
			</ListGroup>

			<ListGroup title="Account">
				<Row
					onPress={() => router.push('/account/lb-pools')}
					subtitle="Origin pools and health across the account"
					title="Pools"
				/>
			</ListGroup>
		</ScrollView>
	)
}
