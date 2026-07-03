import type { ReactNode } from 'react'

import { Fragment } from 'react'
import { View } from 'react-native'
import Animated from 'react-native-reanimated'

import { isForbidden } from '../lib/api-errors'
import { layoutTransition } from '../lib/motion'
import { EmptyState } from './empty-state'
import { LayoutItem } from './layout-motion'
import { ListDivider } from './nav-row'
import { Skeleton } from './skeleton'

interface QuerySectionProps<T> {
	/** Copy when the list loads fine but is empty. */
	emptyText: string
	error: unknown
	/** Copy for generic (non-permission) failures. */
	errorText: string
	isError: boolean
	isLoading: boolean
	items: T[] | undefined
	keyExtractor?: (item: T, index: number) => string
	onRetry: () => void
	renderItem: (item: T, index: number) => ReactNode
	/** Copy when the API returns 401/403 — i.e. a missing OAuth scope. */
	scopeHint: string
}

function defaultKey<T>(item: T, index: number): string {
	if (item != null && typeof item === 'object') {
		if ('id' in item && item.id != null)
			return String(item.id)
		if ('uuid' in item && item.uuid != null)
			return String(item.uuid)
		if ('name' in item && typeof item.name === 'string')
			return item.name
	}
	return String(index)
}

/**
 * Standard body for a `ListSurface`-backed query: skeletons while loading,
 * scope-aware error copy with retry, empty copy, then divider-separated rows.
 */
export function QuerySection<T>({
	emptyText,
	error,
	errorText,
	isError,
	isLoading,
	items,
	keyExtractor,
	onRetry,
	renderItem,
	scopeHint,
}: QuerySectionProps<T>) {
	if (isLoading) {
		return (
			<View className="gap-3 py-3">
				<Skeleton className="h-10 w-full" />
				<Skeleton className="h-10 w-full" />
			</View>
		)
	}
	if (isError) {
		return (
			<EmptyState onAction={onRetry}>
				{isForbidden(error) ? scopeHint : errorText}
			</EmptyState>
		)
	}
	if (!items || items.length === 0)
		return <EmptyState>{emptyText}</EmptyState>
	return (
		<Animated.View layout={layoutTransition}>
			{items.map((item, index) => {
				const key = keyExtractor ? keyExtractor(item, index) : defaultKey(item, index)
				return (
					<Fragment key={key}>
						{index > 0 ? <ListDivider /> : null}
						<LayoutItem>
							{renderItem(item, index)}
						</LayoutItem>
					</Fragment>
				)
			})}
		</Animated.View>
	)
}
