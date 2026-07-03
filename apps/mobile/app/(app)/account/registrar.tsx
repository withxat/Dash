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

export default function RegistrarScreen() {
	const tabScrollPadding = useTabScrollPadding()
	const { activeAccount } = useActiveAccount()
	const accountId = activeAccount?.id
	const theme = useTheme()
	const [refreshing, setRefreshing] = useState(false)

	const domainsQuery = useQuery({
		enabled: Boolean(accountId),
		queryFn: () => cloudflareClient.listRegistrarDomains(accountId!),
		queryKey: ['cf', 'account', accountId, 'registrar-domains'],
		retry: false,
	})

	const onRefresh = useCallback(async () => {
		setRefreshing(true)
		await domainsQuery.refetch().catch(() => {})
		setRefreshing(false)
	}, [domainsQuery])

	return (
		<ScrollView
			className="flex-1 bg-canvas"
			contentContainerStyle={{ gap: 16, padding: 16, paddingBottom: tabScrollPadding }}
			contentInsetAdjustmentBehavior="automatic"
			refreshControl={<RefreshControl onRefresh={onRefresh} refreshing={refreshing} tintColor={theme.subtle} />}
		>
			<View className="gap-2">
				<SectionLabel>Registered domains</SectionLabel>
				<ListSurface>
					<QuerySection
						renderItem={domain => (
							<Row
								chevron={false}
								right={<Badge variant={domain.auto_renew ? 'success' : 'secondary'}>{domain.auto_renew ? 'Auto-renew' : 'Manual'}</Badge>}
								subtitle={domain.expires_at ? `Expires ${new Date(domain.expires_at).toLocaleDateString()}` : undefined}
								title={domain.name ?? domain.id ?? 'Domain'}
							/>
						)}
						emptyText="No domains registered with Cloudflare Registrar."
						error={domainsQuery.error}
						errorText="Failed to load registrar domains."
						isError={domainsQuery.isError}
						isLoading={domainsQuery.isLoading}
						items={domainsQuery.data}
						onRetry={() => void domainsQuery.refetch()}
						scopeHint="Needs the Registrar Domains read scope — enable it on your OAuth client and sign in again."
					/>
				</ListSurface>
			</View>
		</ScrollView>
	)
}
