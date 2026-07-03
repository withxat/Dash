import { ActivityIndicator, Pressable, ScrollView, Text } from 'react-native'

import { cx } from '../lib/cx'
import { useTheme } from '../lib/theme'
import { useActiveAccount } from '../lib/use-active-account'
import { EmptyState } from './empty-state'

/**
 * Horizontal pills for switching the active Cloudflare account. Hidden when
 * the user only has one account — nothing to switch.
 */
export function AccountSwitcher() {
	const { accounts, activeAccountId, isLoading, setActiveAccountId } = useActiveAccount()
	const theme = useTheme()

	if (isLoading)
		return <ActivityIndicator color={theme.brand} />
	if (accounts.length === 0)
		return <EmptyState>No accounts available.</EmptyState>
	if (accounts.length === 1)
		return null

	return (
		<ScrollView
			contentContainerStyle={{ gap: 8 }}
			showsHorizontalScrollIndicator={false}
			horizontal
		>
			{accounts.map((account) => {
				const active = account.id === activeAccountId
				return (
					<Pressable
						className={cx(
							`
								rounded-full px-4 py-2
								active:opacity-80
							`,
							active ? 'bg-brand' : 'border border-line bg-base',
						)}
						accessibilityRole="button"
						key={account.id}
						onPress={() => setActiveAccountId(account.id)}
					>
						<Text className={cx('text-sm font-medium', active ? 'text-inverse' : 'text-subtle')}>
							{account.name}
						</Text>
					</Pressable>
				)
			})}
		</ScrollView>
	)
}
