import { ApiError } from '@cloudfx/api'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { router } from 'expo-router'
import { useState } from 'react'
import { ScrollView, Text } from 'react-native'

import { Button, ButtonText } from '../../../../components/button'
import { Input } from '../../../../components/input'
import { cloudflareClient } from '../../../../lib/api'
import { hapticError, hapticSuccess } from '../../../../lib/haptics'
import { useActiveAccount } from '../../../../lib/use-active-account'
import { useTabScrollPadding } from '../../../../lib/use-tab-scroll-padding'
import { useToast } from '../../../../lib/use-toast'

/** True when the error is a Cloudflare permission failure (missing scope). */
function isForbidden(error: unknown): boolean {
	return error instanceof ApiError && (error.status === 403 || error.status === 401)
}

export default function NewBucketScreen() {
	const tabScrollPadding = useTabScrollPadding()
	const { activeAccountId } = useActiveAccount()
	const toast = useToast()
	const queryClient = useQueryClient()
	const [name, setName] = useState('')

	const createMutation = useMutation({
		mutationFn: () => cloudflareClient.createR2Bucket(activeAccountId!, name.trim()),
		onError: (error) => {
			hapticError()
			toast.show(
				isForbidden(error) ? 'Missing permission — enable the R2 write scope and sign in again.' : 'Failed to create the bucket.',
				'error',
			)
		},
		onSuccess: () => {
			hapticSuccess()
			toast.show('Bucket created.', 'success')
			void queryClient.invalidateQueries({ queryKey: ['cf', 'r2-buckets', activeAccountId] })
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
				label="Bucket name"
				onChangeText={setName}
				placeholder="my-bucket"
				value={name}
				mono
			/>
			<Text className="text-xs text-subtle">
				Lowercase letters, numbers and hyphens only. The name cannot be changed later.
			</Text>

			<Button
				disabled={!name.trim()}
				loading={createMutation.isPending}
				onPress={() => createMutation.mutate()}
			>
				<ButtonText>Create bucket</ButtonText>
			</Button>
		</ScrollView>
	)
}
