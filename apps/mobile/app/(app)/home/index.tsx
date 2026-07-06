import type { Href } from 'expo-router'

import { useQuery } from '@tanstack/react-query'
import { router } from 'expo-router'
import { useCallback } from 'react'
import { Pressable, RefreshControl, ScrollView, Text, View } from 'react-native'

import { CatalogItemIcon } from '../../../components/catalog-item-icon'
import { EmptyState } from '../../../components/empty-state'
import { LayoutGroup, LayoutItem } from '../../../components/layout-motion'
import { ListGroup, NavRow } from '../../../components/nav-row'
import { Skeleton } from '../../../components/skeleton'
import { TabRootHeader } from '../../../components/tab-root-header'
import { getCatalogItems } from '../../../lib/app-catalog'
import { getFrequentItemIds, getHomeShortcutIds, getRecentItemIds, recordRecentItem } from '../../../lib/home-shortcuts'
import { tabScrollContentStyle } from '../../../lib/screen-gutter'
import { TAB_ROOT_TITLES } from '../../../lib/tab-root-titles'
import { useTheme } from '../../../lib/theme'
import { useHomeListFocusRefresh } from '../../../lib/use-home-list-focus'
import { useTabScrollPadding } from '../../../lib/use-tab-scroll-padding'

function useCatalogNavigation() {
	return useCallback((id: string, href: Href) => {
		void recordRecentItem(id)
		router.push(href)
	}, [])
}

export default function HomeScreen() {
	const tabScrollPadding = useTabScrollPadding()
	const theme = useTheme()
	const navigate = useCatalogNavigation()

	useHomeListFocusRefresh()

	const shortcutsQuery = useQuery({
		queryFn: getHomeShortcutIds,
		queryKey: ['app', 'home-shortcuts'],
	})

	const recentQuery = useQuery({
		queryFn: getRecentItemIds,
		queryKey: ['app', 'recent-items'],
	})

	const frequentQuery = useQuery({
		queryFn: getFrequentItemIds,
		queryKey: ['app', 'frequent-items'],
	})

	const shortcuts = getCatalogItems(shortcutsQuery.data ?? [])
	const recentItems = getCatalogItems(recentQuery.data ?? [])
	const frequentItems = getCatalogItems(frequentQuery.data ?? [])

	const onRefresh = useCallback(async () => {
		await Promise.allSettled([
			shortcutsQuery.refetch(),
			recentQuery.refetch(),
			frequentQuery.refetch(),
		])
	}, [frequentQuery, recentQuery, shortcutsQuery])

	const onEditShortcuts = useCallback(() => {
		router.push('/home/edit-shortcuts')
	}, [])

	const refreshing = shortcutsQuery.isFetching || recentQuery.isFetching || frequentQuery.isFetching

	return (
		<View className="flex-1 bg-canvas">
			<TabRootHeader title={TAB_ROOT_TITLES.home} />
			<ScrollView
				className="flex-1 bg-canvas"
				contentContainerStyle={tabScrollContentStyle({ paddingBottom: tabScrollPadding })}
				refreshControl={<RefreshControl onRefresh={onRefresh} refreshing={refreshing} tintColor={theme.subtle} />}
			>
				<ListGroup
					headerAction={(
						<Pressable accessibilityRole="button" className="active:opacity-70" hitSlop={8} onPress={onEditShortcuts}>
							<Text className="text-sm font-medium text-brand">Edit</Text>
						</Pressable>
					)}
					title="Shortcuts"
				>
					{shortcutsQuery.isPending
						? (
								<View className="gap-3 py-3">
									<Skeleton className="h-12 w-full" />
									<Skeleton className="h-12 w-full" />
								</View>
							)
						: shortcuts.length === 0
							? (
									<View className="py-3">
										<EmptyState>No shortcuts yet. Tap Edit to add some.</EmptyState>
									</View>
								)
							: shortcuts.map(item => (
									<LayoutItem key={item.id}>
										<NavRow
											leading={<CatalogItemIcon icon={item.icon} />}
											onPress={() => navigate(item.id, item.href)}
											subtitle={item.description}
											title={item.title}
										/>
									</LayoutItem>
								))}
				</ListGroup>

				<ListGroup title="Frequently used">
					{frequentQuery.isPending
						? (
								<View className="gap-3 py-3">
									<Skeleton className="h-12 w-full" />
									<Skeleton className="h-12 w-full" />
								</View>
							)
						: frequentItems.length === 0
							? (
									<View className="py-3">
										<EmptyState>Features you open often will show up here.</EmptyState>
									</View>
								)
							: frequentItems.map(item => (
									<LayoutItem key={item.id}>
										<NavRow
											leading={<CatalogItemIcon icon={item.icon} />}
											onPress={() => navigate(item.id, item.href)}
											subtitle={item.description}
											title={item.title}
										/>
									</LayoutItem>
								))}
				</ListGroup>

				{recentItems.length > 0
					? (
							<LayoutGroup>
								<ListGroup title="Recently opened">
									{recentItems.map(item => (
										<LayoutItem key={item.id}>
											<NavRow
												leading={<CatalogItemIcon icon={item.icon} />}
												onPress={() => navigate(item.id, item.href)}
												subtitle={item.description}
												title={item.title}
											/>
										</LayoutItem>
									))}
								</ListGroup>
							</LayoutGroup>
						)
					: null}

				<Text className="text-center text-[11px] text-placeholder">
					Open Items to browse every feature by category.
				</Text>
			</ScrollView>
		</View>
	)
}
