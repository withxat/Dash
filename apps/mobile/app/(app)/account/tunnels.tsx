import type { Tunnel } from '@cloudfx/api'

import type { BadgeTone } from '../../../components/badge'

import { useQuery } from '@tanstack/react-query'
import { useCallback, useState } from 'react'
import { RefreshControl, ScrollView, View } from 'react-native'

import { Badge } from '../../../components/badge'
import { QuerySection } from '../../../components/query-section'
import { ListSurface, Row } from '../../../components/row'
import { SectionLabel } from '../../../components/section-label'
import { cloudflareClient } from '../../../lib/api'
import { useTheme } from '../../../lib/theme'
import { useActiveAccount } from '../../../lib/use-active-account'
import { useTabScrollPadding } from '../../../lib/use-tab-scroll-padding'

function tunnelTone(status: Tunnel['status']): BadgeTone {
	if (status === 'healthy')
		return 'success'
	if (status === 'degraded')
		return 'warning'
	if (status === 'down')
		return 'error'
	return 'secondary'
}

export default function TunnelsScreen() {
	const tabScrollPadding = useTabScrollPadding()
	const { activeAccount } = useActiveAccount()
	const accountId = activeAccount?.id
	const theme = useTheme()
	const [refreshing, setRefreshing] = useState(false)

	const tunnelsQuery = useQuery({
		enabled: Boolean(accountId),
		queryFn: () => cloudflareClient.listTunnels(accountId!),
		queryKey: ['cf', 'account', accountId, 'tunnels'],
		retry: false,
	})

	const onRefresh = useCallback(async () => {
		setRefreshing(true)
		await tunnelsQuery.refetch().catch(() => {})
		setRefreshing(false)
	}, [tunnelsQuery])

	return (
		<ScrollView
			className="flex-1 bg-canvas"
			contentContainerStyle={{ gap: 16, padding: 16, paddingBottom: tabScrollPadding }}
			contentInsetAdjustmentBehavior="automatic"
			refreshControl={<RefreshControl onRefresh={onRefresh} refreshing={refreshing} tintColor={theme.subtle} />}
		>
			<View className="gap-2">
				<SectionLabel>Cloudflare Tunnels</SectionLabel>
				<ListSurface>
					<QuerySection
						renderItem={tunnel => (
							<Row
								chevron={false}
								right={<Badge variant={tunnelTone(tunnel.status)}>{tunnel.status ?? 'unknown'}</Badge>}
								subtitle={`${tunnel.connections?.length ?? 0} connection${(tunnel.connections?.length ?? 0) === 1 ? '' : 's'}`}
								title={tunnel.name ?? tunnel.id ?? 'Tunnel'}
							/>
						)}
						emptyText="No tunnels on this account."
						error={tunnelsQuery.error}
						errorText="Failed to load tunnels."
						isError={tunnelsQuery.isError}
						isLoading={tunnelsQuery.isLoading}
						items={tunnelsQuery.data}
						onRetry={() => void tunnelsQuery.refetch()}
						scopeHint="Needs the Argo Tunnel read scope — enable it on your OAuth client and sign in again."
					/>
				</ListSurface>
			</View>
		</ScrollView>
	)
}
