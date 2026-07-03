import { ApiError } from '@cloudfx/api'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { router, useLocalSearchParams } from 'expo-router'
import { Alert, Image, ScrollView, Text, View } from 'react-native'

import { Button, ButtonText } from '../../../components/button'
import { Card } from '../../../components/card'
import { EmptyState } from '../../../components/empty-state'
import { KUMO_RADIUS } from '../../../components/kumo/radius'
import { SectionLabel } from '../../../components/section-label'
import { Skeleton } from '../../../components/skeleton'
import { cloudflareClient } from '../../../lib/api'
import { formatBytes, timeAgo } from '../../../lib/format'
import { hapticError, hapticSuccess } from '../../../lib/haptics'
import { useActiveAccount } from '../../../lib/use-active-account'
import { useTabScrollPadding } from '../../../lib/use-tab-scroll-padding'
import { useToast } from '../../../lib/use-toast'

/** Objects above this size are not downloaded for preview. */
const MAX_PREVIEW_BYTES = 5 * 1024 * 1024
/** Text previews are capped at this many characters. */
const MAX_TEXT_CHARS = 100_000

interface Preview {
	contentType: string
	/** Data URI for images, raw text for text files. */
	data?: string
	kind: 'image' | 'none' | 'text'
	truncated?: boolean
}

/** True when the error is a Cloudflare permission failure (missing scope). */
function isForbidden(error: unknown): boolean {
	return error instanceof ApiError && (error.status === 403 || error.status === 401)
}

function isTextLike(contentType: string): boolean {
	return contentType.startsWith('text/')
		|| contentType.includes('json')
		|| contentType.includes('xml')
		|| contentType.includes('javascript')
		|| contentType.includes('yaml')
}

function blobToDataUrl(blob: Blob): Promise<string> {
	return new Promise((resolve, reject) => {
		const reader = new FileReader()
		reader.onload = () => resolve(String(reader.result))
		reader.onerror = () => reject(reader.error ?? new Error('Failed to read blob'))
		reader.readAsDataURL(blob)
	})
}

export default function R2ObjectScreen() {
	const tabScrollPadding = useTabScrollPadding()
	const { bucket, key, modified, size } = useLocalSearchParams<{
		bucket: string
		key: string
		modified?: string
		size?: string
	}>()
	const { activeAccountId } = useActiveAccount()
	const toast = useToast()
	const queryClient = useQueryClient()
	const sizeBytes = size ? Number(size) : undefined

	const previewQuery = useQuery({
		enabled: Boolean(activeAccountId && bucket && key),
		queryFn: async (): Promise<Preview> => {
			if (sizeBytes != null && sizeBytes > MAX_PREVIEW_BYTES)
				return { contentType: '', kind: 'none' }
			const res = await cloudflareClient.getR2Object(activeAccountId!, bucket, key)
			const contentType = res.headers.get('content-type') ?? ''
			if (contentType.startsWith('image/')) {
				const blob = await res.blob()
				return { contentType, data: await blobToDataUrl(blob), kind: 'image' }
			}
			if (isTextLike(contentType) || contentType === '' || contentType === 'application/octet-stream') {
				const text = await res.text()
				// Binary data sneaks through generic content types — bail if it isn't printable.
				if (text.includes('\u0000'))
					return { contentType, kind: 'none' }
				return {
					contentType,
					data: text.slice(0, MAX_TEXT_CHARS),
					kind: 'text',
					truncated: text.length > MAX_TEXT_CHARS,
				}
			}
			return { contentType, kind: 'none' }
		},
		queryKey: ['cf', 'r2-object', activeAccountId, bucket, key],
		retry: false,
		staleTime: 60_000,
	})

	const deleteMutation = useMutation({
		mutationFn: () => cloudflareClient.deleteR2Object(activeAccountId!, bucket, key),
		onError: (error) => {
			hapticError()
			toast.show(
				isForbidden(error) ? 'Missing permission — enable the R2 bucket item write scope and sign in again.' : 'Failed to delete the object.',
				'error',
			)
		},
		onSuccess: () => {
			hapticSuccess()
			toast.show('Object deleted.', 'success')
			void queryClient.invalidateQueries({ queryKey: ['cf', 'r2-objects', activeAccountId, bucket] })
			router.back()
		},
	})

	const confirmDelete = () => {
		Alert.alert('Delete object?', key, [
			{ style: 'cancel', text: 'Cancel' },
			{ onPress: () => deleteMutation.mutate(), style: 'destructive', text: 'Delete' },
		])
	}

	const preview = previewQuery.data

	return (
		<ScrollView
			className="flex-1 bg-canvas"
			contentContainerStyle={{ gap: 16, padding: 16, paddingBottom: tabScrollPadding }}
		>
			<Card>
				<View className="gap-1">
					<Text className="font-mono text-sm text-default" selectable>{key}</Text>
					<Text className="text-xs text-subtle">
						{[
							sizeBytes != null ? formatBytes(sizeBytes) : undefined,
							modified ? timeAgo(modified) : undefined,
							preview?.contentType || undefined,
						].filter(Boolean).join(' · ')}
					</Text>
				</View>
			</Card>

			<View className="gap-2">
				<SectionLabel>Preview</SectionLabel>
				<Card>
					{previewQuery.isLoading
						? (
								<View className="gap-2">
									<Skeleton className="h-4 w-full" />
									<Skeleton className="h-4 w-5/6" />
									<Skeleton className="h-4 w-2/3" />
								</View>
							)
						: previewQuery.isError
							? (
									<EmptyState onAction={() => void previewQuery.refetch()}>
										{isForbidden(previewQuery.error)
											? 'Needs the R2 bucket item read scope — enable it on your OAuth client and sign in again.'
											: 'Failed to download the object.'}
									</EmptyState>
								)
							: preview?.kind === 'image' && preview.data
								? (
										<Image
											accessibilityLabel={key}
											resizeMode="contain"
											source={{ uri: preview.data }}
											style={{ borderRadius: KUMO_RADIUS, height: 280, width: '100%' }}
										/>
									)
								: preview?.kind === 'text'
									? (
											<View className="gap-2">
												<ScrollView showsHorizontalScrollIndicator={false} horizontal>
													<Text className="font-mono text-xs leading-5 text-subtle" selectable>
														{preview.data ?? ''}
													</Text>
												</ScrollView>
												{preview.truncated
													? <Text className="text-[11px] text-placeholder">Preview truncated.</Text>
													: null}
											</View>
										)
									: (
											<EmptyState>
												{sizeBytes != null && sizeBytes > MAX_PREVIEW_BYTES
													? 'This object is too large to preview on device.'
													: 'No preview available for this file type.'}
											</EmptyState>
										)}
				</Card>
			</View>

			<Button loading={deleteMutation.isPending} onPress={confirmDelete} variant="destructive">
				<ButtonText>Delete object</ButtonText>
			</Button>
		</ScrollView>
	)
}
