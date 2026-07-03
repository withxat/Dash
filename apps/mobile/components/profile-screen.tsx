import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useCallback, useState } from 'react'
import { RefreshControl, ScrollView, Text, View } from 'react-native'

import { cloudflareClient } from '../lib/api'
import { useTheme } from '../lib/theme'
import { useActiveAccount } from '../lib/use-active-account'
import { useAuth } from '../lib/use-auth'
import { AccountSwitcher } from './account-switcher'
import { Button, ButtonText } from './button'
import { Card } from './card'
import { Skeleton } from './skeleton'
import { Stat } from './stat'
import { UserAvatar } from './user-avatar'

export default function AccountScreen() {
	const { signOut } = useAuth()
	const { accounts, activeAccount, activeAccountId } = useActiveAccount()
	const theme = useTheme()
	const queryClient = useQueryClient()
	const [refreshing, setRefreshing] = useState(false)

	const userQuery = useQuery({
		queryFn: () => cloudflareClient.getUser(),
		queryKey: ['cf', 'user'],
	})
	const zonesQuery = useQuery({
		enabled: Boolean(activeAccountId),
		queryFn: () =>
			cloudflareClient
				.listZones({ accountId: activeAccountId!, perPage: 1 })
				.then(p => p.resultInfo?.total_count ?? p.items.length),
		queryKey: ['cf', 'zone-count', activeAccountId],
	})

	const onRefresh = useCallback(async () => {
		setRefreshing(true)
		await queryClient.refetchQueries({ queryKey: ['cf'] }).catch(() => {})
		setRefreshing(false)
	}, [queryClient])

	const email = userQuery.data?.email ?? ''

	return (
		<ScrollView
			refreshControl={(
				<RefreshControl onRefresh={onRefresh} refreshing={refreshing} tintColor={theme.subtle} />
			)}
			className="flex-1 bg-canvas"
			contentContainerStyle={{ gap: 16, padding: 16 }}
			contentInsetAdjustmentBehavior="automatic"
		>
			<View className="items-center gap-3 py-2">
				{userQuery.isLoading
					? <Skeleton className="size-20 rounded-full" />
					: <UserAvatar email={email} size={80} />}
				{userQuery.isLoading
					? <Skeleton className="h-6 w-48" />
					: (
							<Text className="text-lg font-semibold text-default">
								{email || '—'}
							</Text>
						)}
			</View>

			<AccountSwitcher />

			<Card>
				<View className="gap-1">
					<Text className="text-sm font-medium text-subtle">Active account</Text>
					<Text className="text-lg font-semibold text-default">
						{activeAccount?.name ?? 'No account selected'}
					</Text>
					<Text className="text-xs text-subtle">{activeAccount?.type ?? '—'}</Text>
				</View>
			</Card>

			<Card title="At a glance">
				<View className="flex-row gap-8">
					<Stat
						hint="in this account"
						label="Zones"
						value={zonesQuery.isPending ? '…' : String(zonesQuery.data ?? 0)}
					/>
					<Stat
						hint="accessible"
						label="Accounts"
						value={String(accounts.length)}
					/>
				</View>
			</Card>

			<View className="py-2">
				<Button onPress={signOut} size="lg" variant="secondary-destructive">
					<ButtonText>Sign out</ButtonText>
				</Button>
			</View>
		</ScrollView>
	)
}
