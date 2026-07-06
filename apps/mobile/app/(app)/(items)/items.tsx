import type { Href } from 'expo-router'

import { router } from 'expo-router'
import { useCallback } from 'react'
import { ScrollView, View } from 'react-native'

import { CatalogItemIcon } from '../../../components/catalog-item-icon'
import { ListGroup, NavRow } from '../../../components/nav-row'
import { TabRootHeader } from '../../../components/tab-root-header'
import { APP_CATALOG } from '../../../lib/app-catalog'
import { recordRecentItem } from '../../../lib/home-shortcuts'
import { tabScrollContentStyle } from '../../../lib/screen-gutter'
import { TAB_ROOT_TITLES } from '../../../lib/tab-root-titles'
import { useTabScrollPadding } from '../../../lib/use-tab-scroll-padding'

export default function ItemsScreen() {
	const tabScrollPadding = useTabScrollPadding()

	const navigate = useCallback((id: string, href: Href) => {
		void recordRecentItem(id)
		router.push(href)
	}, [])

	return (
		<View className="flex-1 bg-canvas">
			<TabRootHeader title={TAB_ROOT_TITLES.items} />
			<ScrollView
				className="flex-1 bg-canvas"
				contentContainerStyle={tabScrollContentStyle({ paddingBottom: tabScrollPadding })}
			>
				{APP_CATALOG.map(category => (
					<ListGroup key={category.id} title={category.title}>
						{category.items.map(item => (
							<NavRow
								key={item.id}
								leading={<CatalogItemIcon icon={item.icon} />}
								onPress={() => navigate(item.id, item.href)}
								subtitle={item.description}
								title={item.title}
							/>
						))}
					</ListGroup>
				))}
			</ScrollView>
		</View>
	)
}
