import type { R2Object } from '@cloudfx/api'

import { ApiError } from '@cloudfx/api'
import { LegendList } from '@legendapp/list/react-native'
import { useInfiniteQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { router, Stack, useLocalSearchParams } from 'expo-router'
import { memo, useCallback, useMemo } from 'react'
import { Alert, Pressable, Text, View } from 'react-native'

import { EmptyState } from '../../../../components/empty-state'
import { ChevronRightIcon, PlusIcon, TrashIcon } from '../../../../components/icons'
import { Skeleton } from '../../../../components/skeleton'
import { cloudflareClient } from '../../../../lib/api'
import { pickDocumentAsync } from '../../../../lib/document-picker'
import { formatBytes, timeAgo } from '../../../../lib/format'
import { hapticError, hapticSuccess } from '../../../../lib/haptics'
import { useTheme } from '../../../../lib/theme'
import { useActiveAccount } from '../../../../lib/use-active-account'
import { useTabScrollPadding } from '../../../../lib/use-tab-scroll-padding'
import { useToast } from '../../../../lib/use-toast'

/** True when the error is a Cloudflare permission failure (missing scope). */
function isForbidden(error: unknown): boolean {
	return error instanceof ApiError && (error.status === 403 || error.status === 401)
}

function openObject(bucket: string, object: { key: string, lastModified: string, size: number }) {
	router.push({
		params: {
			bucket,
			key: object.key,
			modified: object.lastModified,
			size: String(object.size),
		},
		pathname: '/storage/r2-object',
	})
}

const ObjectRow = memo(({
	bucket,
	chevronColor,
	lastModified,
	objectKey,
	size,
}: {
	bucket: string
	chevronColor: string
	lastModified: string
	objectKey: string
	size: number
}) => {
	const onPress = useCallback(() => {
		openObject(bucket, { key: objectKey, lastModified, size })
	}, [bucket, lastModified, objectKey, size])

	return (
		<Pressable
			className="
				flex-row items-center gap-3 py-3
				active:opacity-70
			"
			accessibilityRole="button"
			onPress={onPress}
		>
			<View className="min-w-0 flex-1 gap-1">
				<Text className="font-mono text-sm text-default" numberOfLines={1}>
					{objectKey}
				</Text>
				<Text className="text-[11px] text-subtle">
					{`${formatBytes(size)}${lastModified ? ` · ${timeAgo(lastModified)}` : ''}`}
				</Text>
			</View>
			<ChevronRightIcon color={chevronColor} size={16} />
		</Pressable>
	)
})

export default function R2BucketScreen() {
	const tabScrollPadding = useTabScrollPadding()
	const { bucket } = useLocalSearchParams<{ bucket: string }>()
	const { activeAccountId } = useActiveAccount()
	const theme = useTheme()
	const toast = useToast()
	const queryClient = useQueryClient()

	const objectsQuery = useInfiniteQuery({
		enabled: Boolean(activeAccountId && bucket),
		getNextPageParam: (last: Awaited<ReturnType<typeof cloudflareClient.listR2Objects>>) => last.cursor,
		initialPageParam: undefined as string | undefined,
		queryFn: ({ pageParam }) => cloudflareClient.listR2Objects(activeAccountId!, bucket, {
			cursor: pageParam,
			perPage: 100,
		}),
		queryKey: ['cf', 'r2-objects', activeAccountId, bucket],
		retry: false,
	})

	const pickAndUpload = useCallback(async () => {
		const picked = await pickDocumentAsync()
		if (picked.canceled || picked.assets.length === 0)
			return
		const asset = picked.assets[0]
		router.push({
			params: {
				bucket,
				mimeType: asset.mimeType ?? '',
				name: asset.name,
				uri: asset.uri,
			},
			pathname: '/storage/r2-upload',
		})
	}, [bucket])

	const deleteBucketMutation = useMutation({
		mutationFn: () => cloudflareClient.deleteR2Bucket(activeAccountId!, bucket),
		onError: (error) => {
			hapticError()
			toast.show(
				isForbidden(error)
					? 'Missing permission — enable the R2 write scope and sign in again.'
					: 'Failed to delete the bucket — it must be empty first.',
				'error',
			)
		},
		onSuccess: () => {
			hapticSuccess()
			toast.show('Bucket deleted.', 'success')
			void queryClient.invalidateQueries({ queryKey: ['cf', 'r2-buckets', activeAccountId] })
			router.back()
		},
	})

	const confirmDeleteBucket = useCallback(() => {
		Alert.alert('Delete bucket?', `"${bucket}" will be deleted. Buckets must be empty before deletion.`, [
			{ style: 'cancel', text: 'Cancel' },
			{ onPress: () => deleteBucketMutation.mutate(), style: 'destructive', text: 'Delete' },
		])
	}, [bucket, deleteBucketMutation])

	const objects = useMemo(
		() => objectsQuery.data?.pages.flatMap(p => p.items) ?? [],
		[objectsQuery.data],
	)

	const onEndReached = useCallback(() => {
		if (objectsQuery.hasNextPage && !objectsQuery.isFetchingNextPage)
			void objectsQuery.fetchNextPage()
	}, [objectsQuery])

	const onRefresh = useCallback(() => {
		void objectsQuery.refetch()
	}, [objectsQuery])

	const headerButtons = useCallback(() => (
		<View className="flex-row items-center gap-2">
			<Pressable
				className="
					p-1
					active:opacity-70
				"
				accessibilityLabel="Upload a file"
				accessibilityRole="button"
				onPress={() => void pickAndUpload()}
			>
				<PlusIcon color={theme.brand} size={22} />
			</Pressable>
			<Pressable
				className="
					p-1
					active:opacity-70
				"
				accessibilityLabel="Delete this bucket"
				accessibilityRole="button"
				onPress={confirmDeleteBucket}
			>
				<TrashIcon color={theme.danger} size={20} />
			</Pressable>
		</View>
	), [confirmDeleteBucket, pickAndUpload, theme.brand, theme.danger])

	const renderObject = useCallback(({ item }: { item: R2Object }) => (
		<ObjectRow
			bucket={bucket}
			chevronColor={theme.placeholder}
			lastModified={item.last_modified ?? ''}
			objectKey={item.key ?? ''}
			size={item.size ?? 0}
		/>
	), [bucket, theme.placeholder])

	return (
		<View className="flex-1 bg-canvas">
			<Stack.Screen options={{ headerRight: headerButtons, title: bucket }} />
			{objectsQuery.isLoading
				? (
						<View className="gap-4 p-4">
							<Skeleton className="h-14 w-full" />
							<Skeleton className="h-14 w-full" />
							<Skeleton className="h-14 w-full" />
						</View>
					)
				: objectsQuery.isError
					? (
							<EmptyState onAction={onRefresh}>
								{isForbidden(objectsQuery.error)
									? 'Needs the R2 scopes — enable them on your OAuth client and sign in again.'
									: 'Failed to load objects.'}
							</EmptyState>
						)
					: objects.length === 0
						? (
								<EmptyState
									actionLabel="Upload a file"
									className="flex-1"
									onAction={() => void pickAndUpload()}
								>
									This bucket is empty.
								</EmptyState>
							)
						: (
								<LegendList
									contentContainerStyle={{ paddingBottom: tabScrollPadding, paddingHorizontal: 16 }}
									contentInsetAdjustmentBehavior="automatic"
									data={objects}
									estimatedItemSize={64}
									ItemSeparatorComponent={Separator}
									keyExtractor={keyExtractor}
									onEndReached={onEndReached}
									onRefresh={onRefresh}
									refreshing={objectsQuery.isRefetching && !objectsQuery.isFetchingNextPage}
									renderItem={renderObject}
								/>
							)}
		</View>
	)
}

function Separator() {
	return <View className="h-px bg-hairline" />
}

function keyExtractor(item: R2Object) {
	return item.key ?? ''
}
