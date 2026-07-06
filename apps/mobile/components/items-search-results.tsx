import { useInfiniteQuery } from '@tanstack/react-query'
import { router } from 'expo-router'
import { useMemo } from 'react'
import { View } from 'react-native'

import { cloudflareClient } from '../lib/api'
import { searchCatalogItems } from '../lib/app-catalog'
import { recordRecentItem } from '../lib/home-shortcuts'
import { useActiveAccount } from '../lib/use-active-account'
import { CatalogItemIcon } from './catalog-item-icon'
import { EmptyState } from './empty-state'
import { LayoutGroup, LayoutItem } from './layout-motion'
import { ListGroup, NavRow } from './nav-row'
import { Skeleton } from './skeleton'

interface ItemsSearchResultsProps {
	query: string
}

export function ItemsSearchResults({ query }: ItemsSearchResultsProps) {
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

	return (
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
	)
}
