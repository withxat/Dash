import type { PageRule } from '@cloudfx/api'

import { useQuery } from '@tanstack/react-query'
import { useLocalSearchParams } from 'expo-router'
import { useCallback, useState } from 'react'
import { RefreshControl, ScrollView, View } from 'react-native'

import { Badge } from '../../../../components/badge'
import { QuerySection } from '../../../../components/query-section'
import { ListSurface, Row } from '../../../../components/row'
import { SectionLabel } from '../../../../components/section-label'
import { cloudflareClient } from '../../../../lib/api'
import { useTheme } from '../../../../lib/theme'
import { useTabScrollPadding } from '../../../../lib/use-tab-scroll-padding'

function ruleTarget(rule: PageRule): string {
	return rule.targets?.[0]?.constraint?.value ?? rule.id
}

function ruleActions(rule: PageRule): string {
	return (rule.actions ?? [])
		.map(action => (action.id ?? '').replaceAll('_', ' '))
		.filter(Boolean)
		.join(', ')
}

export default function ZonePageRulesScreen() {
	const tabScrollPadding = useTabScrollPadding()
	const { id } = useLocalSearchParams<{ id: string }>()
	const theme = useTheme()
	const [refreshing, setRefreshing] = useState(false)

	const rulesQuery = useQuery({
		enabled: Boolean(id),
		queryFn: () => cloudflareClient.listPageRules(id),
		queryKey: ['cf', 'zone', id, 'page-rules'],
		retry: false,
	})

	const onRefresh = useCallback(async () => {
		setRefreshing(true)
		await rulesQuery.refetch().catch(() => {})
		setRefreshing(false)
	}, [rulesQuery])

	return (
		<ScrollView
			className="flex-1 bg-canvas"
			contentContainerStyle={{ gap: 16, padding: 16, paddingBottom: tabScrollPadding }}
			contentInsetAdjustmentBehavior="automatic"
			refreshControl={<RefreshControl onRefresh={onRefresh} refreshing={refreshing} tintColor={theme.subtle} />}
		>
			<View className="gap-2">
				<SectionLabel>Page Rules</SectionLabel>
				<ListSurface>
					<QuerySection
						renderItem={rule => (
							<Row
								chevron={false}
								right={<Badge variant={rule.status === 'active' ? 'success' : 'secondary'}>{rule.status}</Badge>}
								subtitle={ruleActions(rule) || undefined}
								title={ruleTarget(rule)}
							/>
						)}
						emptyText="No page rules on this zone."
						error={rulesQuery.error}
						errorText="Failed to load page rules."
						isError={rulesQuery.isError}
						isLoading={rulesQuery.isLoading}
						items={rulesQuery.data}
						onRetry={() => void rulesQuery.refetch()}
						scopeHint="Needs the Page Rules read scope — enable it on your OAuth client and sign in again."
					/>
				</ListSurface>
			</View>
		</ScrollView>
	)
}
