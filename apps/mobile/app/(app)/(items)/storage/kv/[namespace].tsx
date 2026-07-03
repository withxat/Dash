import type { KvKey } from '@cloudfx/api'

import { ApiError } from '@cloudfx/api'
import { LegendList } from '@legendapp/list/react-native'
import { useInfiniteQuery } from '@tanstack/react-query'
import { router, Stack, useLocalSearchParams } from 'expo-router'
import { memo, useCallback, useMemo } from 'react'
import { Pressable, Text, View } from 'react-native'

import { EmptyState } from '../../../../../components/empty-state'
import { ChevronRightIcon, PencilIcon, PlusIcon } from '../../../../../components/icons'
import { Skeleton } from '../../../../../components/skeleton'
import { cloudflareClient } from '../../../../../lib/api'
import { useTheme } from '../../../../../lib/theme'
import { useActiveAccount } from '../../../../../lib/use-active-account'
import { useTabScrollPadding } from '../../../../../lib/use-tab-scroll-padding'

/** True when the error is a Cloudflare permission failure (missing scope). */
function isForbidden(error: unknown): boolean {
	return error instanceof ApiError && (error.status === 403 || error.status === 401)
}

function openEntry(namespaceId: string, key?: string) {
	router.push({
		params: {
			namespace: namespaceId,
			...(key != null ? { key } : {}),
		},
		pathname: '/storage/kv-entry',
	})
}

const KeyRow = memo(({
	chevronColor,
	expiration,
	name,
	namespaceId,
}: {
	chevronColor: string
	expiration: number
	name: string
	namespaceId: string
}) => {
	const onPress = useCallback(() => {
		openEntry(namespaceId, name)
	}, [name, namespaceId])

	const expiresLabel = expiration > 0
		? `Expires ${new Date(expiration * 1000).toLocaleString()}`
		: ''

	return (
		<Pressable
			className="
				flex-row items-center gap-3 py-3
				active:opacity-70
			"
			accessibilityRole="button"
			onPress={onPress}
		>
			<View className="min-w-0 flex-1 gap-0.5">
				<Text className="font-mono text-sm text-default" numberOfLines={1}>
					{name}
				</Text>
				{expiresLabel
					? <Text className="text-[11px] text-placeholder">{expiresLabel}</Text>
					: null}
			</View>
			<ChevronRightIcon color={chevronColor} size={16} />
		</Pressable>
	)
})

export default function KvNamespaceScreen() {
	const tabScrollPadding = useTabScrollPadding()
	const { namespace, title } = useLocalSearchParams<{ namespace: string, title?: string }>()
	const { activeAccountId } = useActiveAccount()
	const theme = useTheme()

	const keysQuery = useInfiniteQuery({
		enabled: Boolean(activeAccountId && namespace),
		getNextPageParam: (last: Awaited<ReturnType<typeof cloudflareClient.listKvKeys>>) => last.cursor,
		initialPageParam: undefined as string | undefined,
		queryFn: ({ pageParam }) => cloudflareClient.listKvKeys(activeAccountId!, namespace, {
			cursor: pageParam,
			limit: 100,
		}),
		queryKey: ['cf', 'kv-keys', activeAccountId, namespace],
		retry: false,
	})

	const keys = useMemo(
		() => keysQuery.data?.pages.flatMap(p => p.items) ?? [],
		[keysQuery.data],
	)

	const onEndReached = useCallback(() => {
		if (keysQuery.hasNextPage && !keysQuery.isFetchingNextPage)
			void keysQuery.fetchNextPage()
	}, [keysQuery])

	const onRefresh = useCallback(() => {
		void keysQuery.refetch()
	}, [keysQuery])

	const headerButtons = useCallback(() => (
		<View className="flex-row items-center gap-2">
			<Pressable
				className="
					p-1
					active:opacity-70
				"
				onPress={() => router.push({
					params: { namespace, ...(title ? { title } : {}) },
					pathname: '/storage/namespace-edit',
				})}
				accessibilityLabel="Rename or delete this namespace"
				accessibilityRole="button"
			>
				<PencilIcon color={theme.brand} size={20} />
			</Pressable>
			<Pressable
				className="
					p-1
					active:opacity-70
				"
				accessibilityLabel="Add KV entry"
				accessibilityRole="button"
				onPress={() => openEntry(namespace)}
			>
				<PlusIcon color={theme.brand} size={22} />
			</Pressable>
		</View>
	), [namespace, theme.brand, title])

	const renderKey = useCallback(({ item }: { item: KvKey }) => (
		<KeyRow
			chevronColor={theme.placeholder}
			expiration={item.expiration ?? 0}
			name={item.name}
			namespaceId={namespace}
		/>
	), [namespace, theme.placeholder])

	return (
		<View className="flex-1 bg-canvas">
			<Stack.Screen options={{ headerRight: headerButtons, title: title || 'Namespace' }} />
			{keysQuery.isLoading
				? (
						<View className="gap-4 p-4">
							<Skeleton className="h-12 w-full" />
							<Skeleton className="h-12 w-full" />
							<Skeleton className="h-12 w-full" />
						</View>
					)
				: keysQuery.isError
					? (
							<EmptyState onAction={onRefresh}>
								{isForbidden(keysQuery.error)
									? 'Needs the Workers KV scopes — enable them on your OAuth client and sign in again.'
									: 'Failed to load keys.'}
							</EmptyState>
						)
					: keys.length === 0
						? (
								<EmptyState
									actionLabel="Add entry"
									className="flex-1"
									onAction={() => openEntry(namespace)}
								>
									This namespace is empty.
								</EmptyState>
							)
						: (
								<LegendList
									contentContainerStyle={{ paddingBottom: tabScrollPadding, paddingHorizontal: 16 }}
									contentInsetAdjustmentBehavior="automatic"
									data={keys}
									estimatedItemSize={52}
									ItemSeparatorComponent={Separator}
									keyExtractor={keyExtractor}
									onEndReached={onEndReached}
									onRefresh={onRefresh}
									refreshing={keysQuery.isRefetching && !keysQuery.isFetchingNextPage}
									renderItem={renderKey}
								/>
							)}
		</View>
	)
}

function Separator() {
	return <View className="h-px bg-hairline" />
}

function keyExtractor(item: KvKey) {
	return item.name
}
