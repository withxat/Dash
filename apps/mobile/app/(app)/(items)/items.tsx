import type { Href } from 'expo-router'

import { router } from 'expo-router'
import { useCallback, useState } from 'react'
import { ScrollView } from 'react-native'

import { CatalogItemIcon } from '../../../components/catalog-item-icon'
import { ItemsSearchResults } from '../../../components/items-search-results'
import { ListGroup, NavRow } from '../../../components/nav-row'
import { APP_CATALOG } from '../../../lib/app-catalog'
import { recordRecentItem } from '../../../lib/home-shortcuts'
import { tabScrollContentStyle } from '../../../lib/screen-gutter'
import { useNativeSearchBar } from '../../../lib/use-native-search-bar'
import { useTabScrollPadding } from '../../../lib/use-tab-scroll-padding'

export default function ItemsScreen() {
	const tabScrollPadding = useTabScrollPadding()
	const [query, setQuery] = useState('')
	const hasQuery = query.trim().length > 0

	const onSearchChange = useCallback((text: string) => {
		setQuery(text)
	}, [])

	useNativeSearchBar(onSearchChange)

	const navigate = useCallback((id: string, href: Href) => {
		void recordRecentItem(id)
		router.push(href)
	}, [])

	return (
		<ScrollView
			contentContainerStyle={tabScrollContentStyle({
				gap: hasQuery ? 16 : undefined,
				paddingBottom: tabScrollPadding,
				tabRoot: true,
			})}
			className="flex-1 bg-canvas"
			contentInsetAdjustmentBehavior="automatic"
			keyboardShouldPersistTaps="handled"
		>
			{hasQuery
				? <ItemsSearchResults query={query} />
				: APP_CATALOG.map(category => (
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
	)
}
