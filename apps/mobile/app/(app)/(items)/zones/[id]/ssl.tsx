import type { CertificatePack } from '@cloudfx/api'

import type { BadgeTone } from '../../../../../components/badge'

import { useQuery } from '@tanstack/react-query'
import { useLocalSearchParams } from 'expo-router'
import { useCallback, useState } from 'react'
import { RefreshControl, ScrollView, View } from 'react-native'

import { Badge } from '../../../../../components/badge'
import { EmptyState } from '../../../../../components/empty-state'
import { QuerySection } from '../../../../../components/query-section'
import { ListGroup, Row } from '../../../../../components/row'
import { Skeleton } from '../../../../../components/skeleton'
import { cloudflareClient } from '../../../../../lib/api'
import { isForbidden } from '../../../../../lib/api-errors'
import { useTheme } from '../../../../../lib/theme'
import { useTabScrollPadding } from '../../../../../lib/use-tab-scroll-padding'

function packTone(status: CertificatePack['status']): BadgeTone {
	if (status === 'active')
		return 'success'
	if (status.startsWith('pending') || status === 'initializing')
		return 'warning'
	if (status.includes('failed') || status.includes('deleted') || status.includes('timed_out'))
		return 'error'
	return 'secondary'
}

function packHosts(pack: CertificatePack): string {
	return (pack.hosts ?? []).join(', ')
}

function packExpiry(pack: CertificatePack): string | undefined {
	const expiresOn = pack.certificates?.[0]?.expires_on
	if (!expiresOn)
		return undefined
	return `Expires ${new Date(expiresOn).toLocaleDateString()}`
}

export default function ZoneSslScreen() {
	const tabScrollPadding = useTabScrollPadding()
	const { id } = useLocalSearchParams<{ id: string }>()
	const theme = useTheme()
	const [refreshing, setRefreshing] = useState(false)

	const universalQuery = useQuery({
		enabled: Boolean(id),
		queryFn: () => cloudflareClient.getUniversalSslSettings(id),
		queryKey: ['cf', 'zone', id, 'universal-ssl'],
		retry: false,
	})
	const packsQuery = useQuery({
		enabled: Boolean(id),
		queryFn: () => cloudflareClient.listCertificatePacks(id),
		queryKey: ['cf', 'zone', id, 'certificate-packs'],
		retry: false,
	})

	const onRefresh = useCallback(async () => {
		setRefreshing(true)
		await Promise.allSettled([universalQuery.refetch(), packsQuery.refetch()])
		setRefreshing(false)
	}, [packsQuery, universalQuery])

	return (
		<ScrollView
			className="flex-1 bg-canvas"
			contentContainerStyle={{ gap: 16, padding: 16, paddingBottom: tabScrollPadding }}
			contentInsetAdjustmentBehavior="automatic"
			refreshControl={<RefreshControl onRefresh={onRefresh} refreshing={refreshing} tintColor={theme.subtle} />}
		>
			<ListGroup title="Universal SSL">
				{universalQuery.isLoading
					? (
							<View className="py-3">
								<Skeleton className="h-6 w-full" />
							</View>
						)
					: universalQuery.isError
						? (
								<EmptyState onAction={() => void universalQuery.refetch()}>
									{isForbidden(universalQuery.error)
										? 'Needs the SSL and Certificates read scope — enable it on your OAuth client and sign in again.'
										: 'Failed to load Universal SSL settings.'}
								</EmptyState>
							)
						: (
								<Row
									chevron={false}
									right={<Badge variant={universalQuery.data?.enabled ? 'success' : 'secondary'}>{universalQuery.data?.enabled ? 'Enabled' : 'Disabled'}</Badge>}
									subtitle="Free edge certificates issued by Cloudflare"
									title="Universal SSL"
								/>
							)}
			</ListGroup>

			<ListGroup title="Certificate packs">
				<QuerySection
					renderItem={pack => (
						<Row
							chevron={false}
							right={<Badge variant={packTone(pack.status)}>{pack.status}</Badge>}
							subtitle={[packHosts(pack), packExpiry(pack)].filter(Boolean).join(' · ') || undefined}
							title={pack.type}
						/>
					)}
					emptyText="No certificate packs on this zone."
					error={packsQuery.error}
					errorText="Failed to load certificate packs."
					isError={packsQuery.isError}
					isLoading={packsQuery.isLoading}
					items={packsQuery.data}
					onRetry={() => void packsQuery.refetch()}
					scopeHint="Needs the SSL and Certificates read scope — enable it on your OAuth client and sign in again."
				/>
			</ListGroup>
		</ScrollView>
	)
}
