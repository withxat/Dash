import { useQuery } from '@tanstack/react-query'
import { useCallback, useState } from 'react'
import { RefreshControl, ScrollView } from 'react-native'

import { Badge } from '../../../../components/badge'
import { QuerySection } from '../../../../components/query-section'
import { ListGroup, Row } from '../../../../components/row'
import { cloudflareClient } from '../../../../lib/api'
import { timeAgo } from '../../../../lib/format'
import { useTheme } from '../../../../lib/theme'
import { useActiveAccount } from '../../../../lib/use-active-account'
import { useTabScrollPadding } from '../../../../lib/use-tab-scroll-padding'

export default function ImagesScreen() {
	const tabScrollPadding = useTabScrollPadding()
	const { activeAccount } = useActiveAccount()
	const accountId = activeAccount?.id
	const theme = useTheme()
	const [refreshing, setRefreshing] = useState(false)

	const imagesQuery = useQuery({
		enabled: Boolean(accountId),
		queryFn: () => cloudflareClient.listImages(accountId!, { perPage: 50 }),
		queryKey: ['cf', 'account', accountId, 'images'],
		retry: false,
	})

	const onRefresh = useCallback(async () => {
		setRefreshing(true)
		await imagesQuery.refetch().catch(() => {})
		setRefreshing(false)
	}, [imagesQuery])

	return (
		<ScrollView
			className="flex-1 bg-canvas"
			contentContainerStyle={{ gap: 16, padding: 16, paddingBottom: tabScrollPadding }}
			contentInsetAdjustmentBehavior="automatic"
			refreshControl={<RefreshControl onRefresh={onRefresh} refreshing={refreshing} tintColor={theme.subtle} />}
		>
			<ListGroup title="Cloudflare Images">
				<QuerySection
					renderItem={image => (
						<Row
							chevron={false}
							right={image.requireSignedURLs ? <Badge variant="secondary">Signed</Badge> : undefined}
							subtitle={image.uploaded ? `Uploaded ${timeAgo(image.uploaded)}` : undefined}
							title={image.filename ?? image.id ?? 'Image'}
						/>
					)}
					emptyText="No images on this account."
					error={imagesQuery.error}
					errorText="Failed to load images."
					isError={imagesQuery.isError}
					isLoading={imagesQuery.isLoading}
					items={imagesQuery.data}
					onRetry={() => void imagesQuery.refetch()}
					scopeHint="Needs the Images read scope — enable it on your OAuth client and sign in again."
				/>
			</ListGroup>
		</ScrollView>
	)
}
