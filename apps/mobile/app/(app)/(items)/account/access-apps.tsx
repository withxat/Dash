import type { AccessApplication } from '@cloudfx/api'

import { useQuery } from '@tanstack/react-query'
import { useCallback, useState } from 'react'
import { RefreshControl, ScrollView } from 'react-native'

import { Badge } from '../../../../components/badge'
import { QuerySection } from '../../../../components/query-section'
import { ListGroup, Row } from '../../../../components/row'
import { cloudflareClient } from '../../../../lib/api'
import { useTheme } from '../../../../lib/theme'
import { useActiveAccount } from '../../../../lib/use-active-account'
import { useTabScrollPadding } from '../../../../lib/use-tab-scroll-padding'

function appDomain(app: AccessApplication): string | undefined {
	if ('domain' in app && typeof app.domain === 'string')
		return app.domain
	return undefined
}

function appType(app: AccessApplication): string | undefined {
	if ('type' in app && typeof app.type === 'string')
		return app.type
	return undefined
}

export default function AccessAppsScreen() {
	const tabScrollPadding = useTabScrollPadding()
	const { activeAccount } = useActiveAccount()
	const accountId = activeAccount?.id
	const theme = useTheme()
	const [refreshing, setRefreshing] = useState(false)

	const appsQuery = useQuery({
		enabled: Boolean(accountId),
		queryFn: () => cloudflareClient.listAccessApplications(accountId!),
		queryKey: ['cf', 'account', accountId, 'access-apps'],
		retry: false,
	})

	const onRefresh = useCallback(async () => {
		setRefreshing(true)
		await appsQuery.refetch().catch(() => {})
		setRefreshing(false)
	}, [appsQuery])

	return (
		<ScrollView
			className="flex-1 bg-canvas"
			contentContainerStyle={{ gap: 16, padding: 16, paddingBottom: tabScrollPadding }}
			contentInsetAdjustmentBehavior="automatic"
			refreshControl={<RefreshControl onRefresh={onRefresh} refreshing={refreshing} tintColor={theme.subtle} />}
		>
			<ListGroup title="Zero Trust applications">
				<QuerySection
					renderItem={(app) => {
						const type = appType(app)
						return (
							<Row
								chevron={false}
								right={type ? <Badge variant="secondary">{type}</Badge> : undefined}
								subtitle={appDomain(app)}
								title={('name' in app ? app.name : undefined) ?? app.id ?? 'Application'}
							/>
						)
					}}
					emptyText="No Access applications on this account."
					error={appsQuery.error}
					errorText="Failed to load Access applications."
					isError={appsQuery.isError}
					isLoading={appsQuery.isLoading}
					items={appsQuery.data}
					onRetry={() => void appsQuery.refetch()}
					scopeHint="Needs the Access Apps read scope — enable it on your OAuth client and sign in again."
				/>
			</ListGroup>
		</ScrollView>
	)
}
