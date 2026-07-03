import { ApiError } from '@cloudfx/api'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { router, useLocalSearchParams } from 'expo-router'
import { useState } from 'react'
import { Alert, ScrollView } from 'react-native'

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

/** Create a KV namespace, or rename/delete an existing one when `namespace` is passed. */
export default function NamespaceEditScreen() {
	const tabScrollPadding = useTabScrollPadding()
	const { namespace, title: existingTitle } = useLocalSearchParams<{ namespace?: string, title?: string }>()
	const { activeAccountId } = useActiveAccount()
	const toast = useToast()
	const queryClient = useQueryClient()
	const isNew = namespace == null
	const [title, setTitle] = useState(existingTitle ?? '')

	const invalidate = () => {
		void queryClient.invalidateQueries({ queryKey: ['cf', 'kv-namespaces', activeAccountId] })
	}

	const saveMutation = useMutation({
		mutationFn: () => isNew
			? cloudflareClient.createKvNamespace(activeAccountId!, title.trim()).then(() => {})
			: cloudflareClient.renameKvNamespace(activeAccountId!, namespace, title.trim()),
		onError: (error) => {
			hapticError()
			toast.show(
				isForbidden(error) ? 'Missing permission — enable the KV Storage write scope and sign in again.' : 'Failed to save the namespace.',
				'error',
			)
		},
		onSuccess: () => {
			hapticSuccess()
			toast.show(isNew ? 'Namespace created.' : 'Namespace renamed.', 'success')
			invalidate()
			router.back()
		},
	})

	const deleteMutation = useMutation({
		mutationFn: () => cloudflareClient.deleteKvNamespace(activeAccountId!, namespace!),
		onError: (error) => {
			hapticError()
			toast.show(
				isForbidden(error) ? 'Missing permission — enable the KV Storage write scope and sign in again.' : 'Failed to delete the namespace.',
				'error',
			)
		},
		onSuccess: () => {
			hapticSuccess()
			toast.show('Namespace deleted.', 'success')
			invalidate()
			router.dismissTo('/storage/kv')
		},
	})

	const confirmDelete = () => {
		Alert.alert(
			'Delete namespace?',
			`"${existingTitle ?? namespace}" and every key in it will be permanently deleted.`,
			[
				{ style: 'cancel', text: 'Cancel' },
				{ onPress: () => deleteMutation.mutate(), style: 'destructive', text: 'Delete' },
			],
		)
	}

	return (
		<ScrollView
			className="flex-1 bg-canvas"
			contentContainerStyle={{ gap: 16, padding: 16, paddingBottom: tabScrollPadding }}
			keyboardShouldPersistTaps="handled"
		>
			<Input
				autoCapitalize="none"
				autoCorrect={false}
				label="Title"
				onChangeText={setTitle}
				placeholder="my-namespace"
				value={title}
				mono
			/>

			<Button
				disabled={!title.trim()}
				loading={saveMutation.isPending}
				onPress={() => saveMutation.mutate()}
			>
				<ButtonText>{isNew ? 'Create namespace' : 'Rename namespace'}</ButtonText>
			</Button>

			{!isNew
				? (
						<Button loading={deleteMutation.isPending} onPress={confirmDelete} variant="destructive">
							<ButtonText>Delete namespace</ButtonText>
						</Button>
					)
				: null}
		</ScrollView>
	)
}
