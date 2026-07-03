import { ApiError } from '@cloudfx/api'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { router, useLocalSearchParams } from 'expo-router'
import { useState } from 'react'
import { Alert, ScrollView, Text, View } from 'react-native'

import { Button, ButtonText } from '../../../components/button'
import { EmptyState } from '../../../components/empty-state'
import { Input } from '../../../components/input'
import { Skeleton } from '../../../components/skeleton'
import { cloudflareClient } from '../../../lib/api'
import { hapticError, hapticSuccess } from '../../../lib/haptics'
import { useActiveAccount } from '../../../lib/use-active-account'
import { useTabScrollPadding } from '../../../lib/use-tab-scroll-padding'
import { useToast } from '../../../lib/use-toast'

/** True when the error is a Cloudflare permission failure (missing scope). */
function isForbidden(error: unknown): boolean {
	return error instanceof ApiError && (error.status === 403 || error.status === 401)
}

export default function KvEntryScreen() {
	const tabScrollPadding = useTabScrollPadding()
	const { key: existingKey, namespace } = useLocalSearchParams<{ key?: string, namespace: string }>()
	const { activeAccountId } = useActiveAccount()
	const toast = useToast()
	const queryClient = useQueryClient()
	const isNew = existingKey == null

	const [keyDraft, setKeyDraft] = useState(existingKey ?? '')
	// undefined = user hasn't edited; fall back to the fetched value.
	const [valueDraft, setValueDraft] = useState<string | undefined>(isNew ? '' : undefined)
	const [ttlDraft, setTtlDraft] = useState('')

	const valueQuery = useQuery({
		enabled: Boolean(activeAccountId && namespace && existingKey != null),
		queryFn: () => cloudflareClient.getKvValue(activeAccountId!, namespace, existingKey!),
		queryKey: ['cf', 'kv-value', activeAccountId, namespace, existingKey],
		retry: false,
	})

	const value = valueDraft ?? valueQuery.data ?? ''
	const key = keyDraft.trim()
	const ttlSeconds = Number.parseInt(ttlDraft.trim(), 10)
	const hasTtl = ttlDraft.trim().length > 0
	const ttlValid = !hasTtl || (Number.isFinite(ttlSeconds) && ttlSeconds >= 60)

	const invalidateKeys = () => {
		void queryClient.invalidateQueries({ queryKey: ['cf', 'kv-keys', activeAccountId, namespace] })
	}

	const saveMutation = useMutation({
		mutationFn: () => cloudflareClient.putKvValue(
			activeAccountId!,
			namespace,
			key,
			value,
			hasTtl ? { expirationTtl: ttlSeconds } : undefined,
		),
		onError: (error) => {
			hapticError()
			toast.show(
				isForbidden(error) ? 'Missing permission — enable the KV Storage write scope and sign in again.' : 'Failed to save the entry.',
				'error',
			)
		},
		onSuccess: () => {
			hapticSuccess()
			toast.show('Entry saved.', 'success')
			invalidateKeys()
			void queryClient.invalidateQueries({ queryKey: ['cf', 'kv-value', activeAccountId, namespace, key] })
			router.back()
		},
	})

	const deleteMutation = useMutation({
		mutationFn: () => cloudflareClient.deleteKvKey(activeAccountId!, namespace, existingKey!),
		onError: () => {
			hapticError()
			toast.show('Failed to delete the entry.', 'error')
		},
		onSuccess: () => {
			hapticSuccess()
			toast.show('Entry deleted.', 'success')
			invalidateKeys()
			router.back()
		},
	})

	const confirmDelete = () => {
		Alert.alert('Delete entry?', existingKey, [
			{ style: 'cancel', text: 'Cancel' },
			{ onPress: () => deleteMutation.mutate(), style: 'destructive', text: 'Delete' },
		])
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
				editable={isNew}
				label="Key"
				onChangeText={setKeyDraft}
				placeholder="my-key"
				value={keyDraft}
				mono
			/>

			{!isNew && valueQuery.isLoading
				? (
						<View className="gap-2">
							<Skeleton className="h-4 w-1/4" />
							<Skeleton className="h-32 w-full" />
						</View>
					)
				: !isNew && valueQuery.isError && valueDraft == null
						? (
								<EmptyState onAction={() => void valueQuery.refetch()}>
									{isForbidden(valueQuery.error)
										? 'Needs the Workers KV scopes — enable them on your OAuth client and sign in again.'
										: 'Failed to load the value.'}
								</EmptyState>
							)
						: (
								<Input
									autoCapitalize="none"
									autoCorrect={false}
									className="min-h-40"
									label="Value"
									onChangeText={setValueDraft}
									placeholder="value"
									textAlignVertical="top"
									value={value}
									mono
									multiline
								/>
							)}

			<View className="gap-1.5">
				<Input
					autoCapitalize="none"
					autoCorrect={false}
					keyboardType="number-pad"
					label="Expiration TTL (seconds, optional)"
					onChangeText={setTtlDraft}
					placeholder="e.g. 3600"
					value={ttlDraft}
					mono
				/>
				<Text className="text-xs text-subtle">
					{ttlValid
						? 'Minimum 60 seconds. Leave empty to keep the key forever.'
						: 'TTL must be at least 60 seconds.'}
				</Text>
			</View>

			<Button
				disabled={!key || !ttlValid}
				loading={saveMutation.isPending}
				onPress={() => saveMutation.mutate()}
			>
				<ButtonText>{isNew ? 'Create entry' : 'Save changes'}</ButtonText>
			</Button>

			{!isNew
				? (
						<Button
							loading={deleteMutation.isPending}
							onPress={confirmDelete}
							variant="destructive"
						>
							<ButtonText>Delete entry</ButtonText>
						</Button>
					)
				: null}
		</ScrollView>
	)
}
