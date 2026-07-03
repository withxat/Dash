import type { StreamVideo } from '@cloudfx/api'

import type { BadgeTone } from '../../../components/badge'

import { useQuery } from '@tanstack/react-query'
import { useCallback, useState } from 'react'
import { RefreshControl, ScrollView, View } from 'react-native'

import { Badge } from '../../../components/badge'
import { QuerySection } from '../../../components/query-section'
import { ListSurface, Row } from '../../../components/row'
import { SectionLabel } from '../../../components/section-label'
import { cloudflareClient } from '../../../lib/api'
import { timeAgo } from '../../../lib/format'
import { useTheme } from '../../../lib/theme'
import { useActiveAccount } from '../../../lib/use-active-account'
import { useTabScrollPadding } from '../../../lib/use-tab-scroll-padding'

function videoTone(state: string | undefined): BadgeTone {
	if (state === 'ready')
		return 'success'
	if (state === 'error')
		return 'error'
	return 'secondary'
}

function videoTitle(video: StreamVideo): string {
	const meta = video.meta
	if (meta && typeof meta === 'object' && 'name' in meta && typeof meta.name === 'string')
		return meta.name
	return video.uid ?? 'Video'
}

function videoDuration(video: StreamVideo): string | undefined {
	if (!video.duration || video.duration < 0)
		return undefined
	const total = Math.round(video.duration)
	const minutes = Math.floor(total / 60)
	const seconds = total % 60
	return `${minutes}:${String(seconds).padStart(2, '0')}`
}

export default function StreamScreen() {
	const tabScrollPadding = useTabScrollPadding()
	const { activeAccount } = useActiveAccount()
	const accountId = activeAccount?.id
	const theme = useTheme()
	const [refreshing, setRefreshing] = useState(false)

	const videosQuery = useQuery({
		enabled: Boolean(accountId),
		queryFn: () => cloudflareClient.listStreamVideos(accountId!),
		queryKey: ['cf', 'account', accountId, 'stream-videos'],
		retry: false,
	})

	const onRefresh = useCallback(async () => {
		setRefreshing(true)
		await videosQuery.refetch().catch(() => {})
		setRefreshing(false)
	}, [videosQuery])

	return (
		<ScrollView
			className="flex-1 bg-canvas"
			contentContainerStyle={{ gap: 16, padding: 16, paddingBottom: tabScrollPadding }}
			contentInsetAdjustmentBehavior="automatic"
			refreshControl={<RefreshControl onRefresh={onRefresh} refreshing={refreshing} tintColor={theme.subtle} />}
		>
			<View className="gap-2">
				<SectionLabel>Stream videos</SectionLabel>
				<ListSurface>
					<QuerySection
						renderItem={video => (
							<Row
								chevron={false}
								right={<Badge variant={videoTone(video.status?.state)}>{video.status?.state ?? 'unknown'}</Badge>}
								subtitle={[videoDuration(video), video.created ? timeAgo(video.created) : undefined].filter(Boolean).join(' · ') || undefined}
								title={videoTitle(video)}
							/>
						)}
						emptyText="No videos on this account."
						error={videosQuery.error}
						errorText="Failed to load videos."
						isError={videosQuery.isError}
						isLoading={videosQuery.isLoading}
						items={videosQuery.data}
						onRetry={() => void videosQuery.refetch()}
						scopeHint="Needs the Stream read scope — enable it on your OAuth client and sign in again."
					/>
				</ListSurface>
			</View>
		</ScrollView>
	)
}
