import type { Healthcheck } from '@cloudfx/api'

import type { BadgeTone } from '../../../../../components/badge'

import { useQuery } from '@tanstack/react-query'
import { useLocalSearchParams } from 'expo-router'
import { useCallback, useState } from 'react'
import { RefreshControl, ScrollView, View } from 'react-native'

import { Badge } from '../../../../../components/badge'
import { QuerySection } from '../../../../../components/query-section'
import { ListSurface, Row } from '../../../../../components/row'
import { SectionLabel } from '../../../../../components/section-label'
import { cloudflareClient } from '../../../../../lib/api'
import { useTheme } from '../../../../../lib/theme'
import { useTabScrollPadding } from '../../../../../lib/use-tab-scroll-padding'

function healthTone(status: Healthcheck['status']): BadgeTone {
	if (status === 'healthy')
		return 'success'
	if (status === 'unhealthy')
		return 'error'
	if (status === 'suspended')
		return 'warning'
	return 'secondary'
}

export default function ZoneHealthchecksScreen() {
	const tabScrollPadding = useTabScrollPadding()
	const { id } = useLocalSearchParams<{ id: string }>()
	const theme = useTheme()
	const [refreshing, setRefreshing] = useState(false)

	const checksQuery = useQuery({
		enabled: Boolean(id),
		queryFn: () => cloudflareClient.listHealthchecks(id),
		queryKey: ['cf', 'zone', id, 'healthchecks'],
		retry: false,
	})

	const onRefresh = useCallback(async () => {
		setRefreshing(true)
		await checksQuery.refetch().catch(() => {})
		setRefreshing(false)
	}, [checksQuery])

	return (
		<ScrollView
			className="flex-1 bg-canvas"
			contentContainerStyle={{ gap: 16, padding: 16, paddingBottom: tabScrollPadding }}
			contentInsetAdjustmentBehavior="automatic"
			refreshControl={<RefreshControl onRefresh={onRefresh} refreshing={refreshing} tintColor={theme.subtle} />}
		>
			<View className="gap-2">
				<SectionLabel>Healthchecks</SectionLabel>
				<ListSurface>
					<QuerySection
						renderItem={check => (
							<Row
								chevron={false}
								right={<Badge variant={healthTone(check.status)}>{check.status ?? 'unknown'}</Badge>}
								subtitle={[check.address, check.failure_reason].filter(Boolean).join(' · ')}
								title={check.name ?? check.id ?? 'Healthcheck'}
							/>
						)}
						emptyText="No healthchecks on this zone."
						error={checksQuery.error}
						errorText="Failed to load healthchecks."
						isError={checksQuery.isError}
						isLoading={checksQuery.isLoading}
						items={checksQuery.data}
						onRetry={() => void checksQuery.refetch()}
						scopeHint="Needs the Healthchecks read scope — enable it on your OAuth client and sign in again."
					/>
				</ListSurface>
			</View>
		</ScrollView>
	)
}
