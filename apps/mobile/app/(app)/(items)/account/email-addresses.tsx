import type { EmailRoutingAddress } from '@cloudfx/api'

import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useCallback, useState } from 'react'
import { Alert, RefreshControl, ScrollView, View } from 'react-native'

import { Badge } from '../../../../components/badge'
import { Button, ButtonText } from '../../../../components/button'
import { Input } from '../../../../components/input'
import { QuerySection } from '../../../../components/query-section'
import { ListSurface, Row } from '../../../../components/row'
import { SectionLabel } from '../../../../components/section-label'
import { cloudflareClient } from '../../../../lib/api'
import { isForbidden } from '../../../../lib/api-errors'
import { hapticError, hapticSuccess } from '../../../../lib/haptics'
import { useTheme } from '../../../../lib/theme'
import { useActiveAccount } from '../../../../lib/use-active-account'
import { useTabScrollPadding } from '../../../../lib/use-tab-scroll-padding'
import { useToast } from '../../../../lib/use-toast'

const EMAIL = /^[^\s@]+@[^\s@][^\s.@]*\.[^\s@]+$/

export default function EmailAddressesScreen() {
	const tabScrollPadding = useTabScrollPadding()
	const { activeAccount } = useActiveAccount()
	const accountId = activeAccount?.id
	const theme = useTheme()
	const toast = useToast()
	const queryClient = useQueryClient()
	const [refreshing, setRefreshing] = useState(false)
	const [newEmail, setNewEmail] = useState('')

	const addressesQuery = useQuery({
		enabled: Boolean(accountId),
		queryFn: () => cloudflareClient.listEmailRoutingAddresses(accountId!),
		queryKey: ['cf', 'account', accountId, 'email-addresses'],
		retry: false,
	})

	const invalidate = useCallback(() => {
		void queryClient.invalidateQueries({ queryKey: ['cf', 'account', accountId, 'email-addresses'] })
	}, [accountId, queryClient])

	const createMutation = useMutation({
		mutationFn: (email: string) => cloudflareClient.createEmailRoutingAddress(accountId!, email),
		onError: (error) => {
			hapticError()
			toast.show(
				isForbidden(error)
					? 'Missing permission — enable the Email Routing Addresses write scope and sign in again.'
					: 'Failed to add the address.',
				'error',
			)
		},
		onSuccess: () => {
			hapticSuccess()
			setNewEmail('')
			toast.show('Verification email sent.', 'success')
			invalidate()
		},
	})

	const deleteMutation = useMutation({
		mutationFn: (addressId: string) => cloudflareClient.deleteEmailRoutingAddress(accountId!, addressId),
		onError: (error) => {
			hapticError()
			toast.show(
				isForbidden(error)
					? 'Missing permission — enable the Email Routing Addresses write scope and sign in again.'
					: 'Failed to delete the address.',
				'error',
			)
		},
		onSuccess: () => {
			hapticSuccess()
			toast.show('Address deleted.', 'success')
			invalidate()
		},
	})

	const confirmDelete = useCallback((address: EmailRoutingAddress) => {
		if (!address.id)
			return
		Alert.alert(
			'Delete address?',
			`${address.email}\n\nRules forwarding to this address will stop working.`,
			[
				{ style: 'cancel', text: 'Cancel' },
				{ onPress: () => deleteMutation.mutate(address.id!), style: 'destructive', text: 'Delete' },
			],
		)
	}, [deleteMutation])

	const onRefresh = useCallback(async () => {
		setRefreshing(true)
		await addressesQuery.refetch().catch(() => {})
		setRefreshing(false)
	}, [addressesQuery])

	const emailValid = EMAIL.test(newEmail.trim())

	return (
		<ScrollView
			className="flex-1 bg-canvas"
			contentContainerStyle={{ gap: 16, padding: 16, paddingBottom: tabScrollPadding }}
			contentInsetAdjustmentBehavior="automatic"
			keyboardShouldPersistTaps="handled"
			refreshControl={<RefreshControl onRefresh={onRefresh} refreshing={refreshing} tintColor={theme.subtle} />}
		>
			<View className="gap-3">
				<SectionLabel>Add destination</SectionLabel>
				<Input
					autoCapitalize="none"
					autoCorrect={false}
					keyboardType="email-address"
					onChangeText={setNewEmail}
					placeholder="you@example.com"
					value={newEmail}
				/>
				<Button
					disabled={!emailValid}
					loading={createMutation.isPending}
					onPress={() => createMutation.mutate(newEmail.trim())}
				>
					<ButtonText>Add address</ButtonText>
				</Button>
			</View>

			<View className="gap-2">
				<SectionLabel>Destination addresses</SectionLabel>
				<ListSurface>
					<QuerySection
						renderItem={address => (
							<Row
								chevron={false}
								onPress={() => confirmDelete(address)}
								right={<Badge variant={address.verified ? 'success' : 'warning'}>{address.verified ? 'Verified' : 'Pending'}</Badge>}
								title={address.email ?? address.id ?? 'Address'}
							/>
						)}
						emptyText="No destination addresses on this account."
						error={addressesQuery.error}
						errorText="Failed to load addresses."
						isError={addressesQuery.isError}
						isLoading={addressesQuery.isLoading}
						items={addressesQuery.data}
						onRetry={() => void addressesQuery.refetch()}
						scopeHint="Needs the Email Routing Addresses read scope — enable it on your OAuth client and sign in again."
					/>
				</ListSurface>
			</View>
		</ScrollView>
	)
}
