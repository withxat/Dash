import { ApiError } from '@cloudfx/api'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { router, useLocalSearchParams } from 'expo-router'
import { useState } from 'react'
import { ScrollView, Text } from 'react-native'

import { Button, ButtonText } from '../../../components/button'
import { Input } from '../../../components/input'
import { cloudflareClient } from '../../../lib/api'
import { hapticError, hapticSuccess } from '../../../lib/haptics'
import { useActiveAccount } from '../../../lib/use-active-account'
import { useTabScrollPadding } from '../../../lib/use-tab-scroll-padding'
import { useToast } from '../../../lib/use-toast'

/** True when the error is a Cloudflare permission failure (missing scope). */
function isForbidden(error: unknown): boolean {
	return error instanceof ApiError && (error.status === 403 || error.status === 401)
}

/** Confirm the object key before uploading a picked file to R2. */
export default function R2UploadScreen() {
	const tabScrollPadding = useTabScrollPadding()
	const { bucket, mimeType, name, uri } = useLocalSearchParams<{
		bucket: string
		mimeType?: string
		name: string
		uri: string
	}>()
	const { activeAccountId } = useActiveAccount()
	const toast = useToast()
	const queryClient = useQueryClient()
	const [key, setKey] = useState(name ?? '')

	const uploadMutation = useMutation({
		mutationFn: async () => {
			const blob = await fetch(uri).then(r => r.blob())
			await cloudflareClient.putR2Object(
				activeAccountId!,
				bucket,
				key.trim(),
				blob,
				mimeType || 'application/octet-stream',
			)
		},
		onError: (error) => {
			hapticError()
			toast.show(
				isForbidden(error) ? 'Missing permission — enable the R2 bucket item write scope and sign in again.' : 'Upload failed.',
				'error',
			)
		},
		onSuccess: () => {
			hapticSuccess()
			toast.show(`Uploaded ${key.trim()}.`, 'success')
			void queryClient.invalidateQueries({ queryKey: ['cf', 'r2-objects', activeAccountId, bucket] })
			router.back()
		},
	})

	return (
		<ScrollView
			className="flex-1 bg-canvas"
			contentContainerStyle={{ gap: 16, padding: 16, paddingBottom: tabScrollPadding }}
			keyboardShouldPersistTaps="handled"
		>
			<Input
				autoCapitalize="none"
				autoCorrect={false}
				label="Object key"
				onChangeText={setKey}
				placeholder="path/to/file.txt"
				value={key}
				mono
			/>
			<Text className="text-xs text-subtle">
				{`Uploading "${name ?? '—'}"${mimeType ? ` (${mimeType})` : ''} to ${bucket}. Use "/" in the key to place it in a folder.`}
			</Text>

			<Button
				disabled={!key.trim()}
				loading={uploadMutation.isPending}
				onPress={() => uploadMutation.mutate()}
			>
				<ButtonText>Upload</ButtonText>
			</Button>
		</ScrollView>
	)
}
