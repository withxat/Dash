import { useCallback, useState } from 'react'
import { ScrollView } from 'react-native'

import { EmptyState } from '../../../../components/empty-state'
import { ItemsSearchResults } from '../../../../components/items-search-results'
import { tabScrollContentStyle } from '../../../../lib/screen-gutter'
import { useNativeSearchBar } from '../../../../lib/use-native-search-bar'
import { useTabScrollPadding } from '../../../../lib/use-tab-scroll-padding'

export default function SearchScreen() {
	const tabScrollPadding = useTabScrollPadding()
	const [query, setQuery] = useState('')

	const onSearchChange = useCallback((text: string) => {
		setQuery(text)
	}, [])

	useNativeSearchBar(onSearchChange)

	const hasQuery = query.trim().length > 0

	return (
		<ScrollView
			className="flex-1 bg-canvas"
			contentContainerStyle={tabScrollContentStyle({ gap: 16, paddingBottom: tabScrollPadding })}
			contentInsetAdjustmentBehavior="automatic"
			keyboardShouldPersistTaps="handled"
		>
			{hasQuery
				? <ItemsSearchResults query={query} />
				: <EmptyState>Search features or zones by name.</EmptyState>}
		</ScrollView>
	)
}
