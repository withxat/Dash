import { useInfiniteQuery } from '@tanstack/react-query'
import { router } from 'expo-router'
import { useMemo, useState } from 'react'
import { ScrollView, View } from 'react-native'

import { CatalogItemIcon } from '../../../components/catalog-item-icon'
import { EmptyState } from '../../../components/empty-state'
import { SearchInput } from '../../../components/kumo'
import { LayoutGroup, LayoutItem } from '../../../components/layout-motion'
import { ListGroup, NavRow } from '../../../components/nav-row'
import { Skeleton } from '../../../components/skeleton'
import { TabRootHeader } from '../../../components/tab-root-header'
import { cloudflareClient } from '../../../lib/api'
import { searchCatalogItems } from '../../../lib/app-catalog'
import { recordRecentItem } from '../../../lib/home-shortcuts'
import { SCREEN_GUTTER, tabScrollContentStyle } from '../../../lib/screen-gutter'
import { TAB_ROOT_TITLES } from '../../../lib/tab-root-titles'
import { useActiveAccount } from '../../../lib/use-active-account'
import { useTabScrollPadding } from '../../../lib/use-tab-scroll-padding'

export default function SearchScreen() {
	const tabScrollPadding = useTabScrollPadding()
	const [query, setQuery] = useState('')
	const { activeAccountId } = useActiveAccount()

	const catalogResults = useMemo(() => searchCatalogItems(query), [query])

	const zonesQuery = useInfiniteQuery({
		enabled: Boolean(activeAccountId) && query.trim().length > 0,
		getNextPageParam: (last: Awaited<ReturnType<typeof cloudflareClient.listZones>>) => {
			const { page, per_page: perPage, total_count: total } = last.resultInfo
			return page * perPage < total ? page + 1 : undefined
		},
		initialPageParam: 1,
		queryFn: ({ pageParam }) =>
			cloudflareClient.listZones({ accountId: activeAccountId!, page: pageParam, perPage: 50 }),
		queryKey: ['cf', 'zones-search', activeAccountId],
	})

	const zones = useMemo(() => {
		const all = zonesQuery.data?.pages.flatMap(p => p.items) ?? []
		const needle = query.trim().toLowerCase()
		return needle ? all.filter(z => z.name.toLowerCase().includes(needle)) : []
	}, [query, zonesQuery.data])

	const hasQuery = query.trim().length > 0

	return (
		<View className="flex-1 bg-canvas">
			<TabRootHeader title={TAB_ROOT_TITLES.search} />
			<View style={{ paddingBottom: 12, paddingHorizontal: SCREEN_GUTTER }}>
				<SearchInput
					onChangeText={setQuery}
					placeholder="Features, zones…"
					value={query}
				/>
			</View>
			<ScrollView
				className="flex-1 bg-canvas"
				contentContainerStyle={tabScrollContentStyle({ gap: 16, paddingBottom: tabScrollPadding })}
				keyboardShouldPersistTaps="handled"
			>
				{!hasQuery
					? <EmptyState>Search features or zones by name.</EmptyState>
					: (
							<>
								{catalogResults.length > 0
									? (
											<LayoutGroup>
												<ListGroup title="Features">
													{catalogResults.map(item => (
														<LayoutItem key={item.id}>
															<NavRow
																onPress={() => {
																	void recordRecentItem(item.id)
																	router.push(item.href)
																}}
																leading={<CatalogItemIcon icon={item.icon} />}
																subtitle={item.description}
																title={item.title}
															/>
														</LayoutItem>
													))}
												</ListGroup>
											</LayoutGroup>
										)
									: null}

								<LayoutGroup>
									<ListGroup title="Zones">
										{zonesQuery.isLoading
											? (
													<View className="gap-3 py-3">
														<Skeleton className="h-12 w-full" />
														<Skeleton className="h-12 w-full" />
													</View>
												)
											: zones.length === 0
												? (
														<View className="py-3">
															<EmptyState>No matching zones.</EmptyState>
														</View>
													)
												: zones.slice(0, 20).map(zone => (
														<LayoutItem key={zone.id}>
															<NavRow
																onPress={() => {
																	void recordRecentItem('zones')
																	router.push(`/zones/${zone.id}`)
																}}
																leading={<CatalogItemIcon icon="zones" />}
																subtitle={zone.status}
																title={zone.name}
															/>
														</LayoutItem>
													))}
									</ListGroup>
								</LayoutGroup>
							</>
						)}
			</ScrollView>
		</View>
	)
}
