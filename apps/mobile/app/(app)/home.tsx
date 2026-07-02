import { useQuery } from '@tanstack/react-query'
import { ActivityIndicator, FlatList, Text, View } from 'react-native'

import { Button } from '../../components/button'
import { cloudflareClient } from '../../lib/api'
import { useAuth } from '../../lib/use-auth'

export default function HomeScreen() {
	const { signOut } = useAuth()

	const userQuery = useQuery({
		queryFn: () => cloudflareClient.getUser(),
		queryKey: ['cf', 'user'],
	})
	const accountsQuery = useQuery({
		queryFn: () => cloudflareClient.listAccounts(),
		queryKey: ['cf', 'accounts'],
	})

	return (
		<View className="flex-1 bg-canvas px-4">
			<View className="gap-1 py-4">
				<Text className="text-xs uppercase tracking-wide text-white/50">Signed in as</Text>
				<Text className="text-lg font-semibold text-white">
					{userQuery.data?.email ?? (userQuery.isLoading ? 'Loading…' : '—')}
				</Text>
			</View>

			<View className="flex-row items-center justify-between py-2">
				<Text className="text-base font-semibold text-white">Accounts</Text>
				{accountsQuery.isLoading ? <ActivityIndicator color="#f6821f" /> : null}
			</View>

			{accountsQuery.isError
				? (
						<Text className="py-4 text-sm text-red-400">
							Failed to load accounts. Your session may have expired.
						</Text>
					)
				: null}

			<FlatList
				renderItem={({ item }) => (
					<View className="flex-row items-center justify-between py-3">
						<View>
							<Text className="font-medium text-white">{item.name}</Text>
							<Text className="text-xs text-white/50">
								{item.type ?? 'account'}
								{' '}
								·
								{item.id}
							</Text>
						</View>
					</View>
				)}
				className="flex-1"
				data={accountsQuery.data ?? []}
				ItemSeparatorComponent={() => <View className="h-px bg-canvas-muted" />}
				keyExtractor={item => item.id}
			/>

			<View className="py-4">
				<Button onPress={signOut} variant="outline">
					Sign out
				</Button>
			</View>
		</View>
	)
}
