import { useQuery } from '@tanstack/react-query'
import { useLocalSearchParams } from 'expo-router'
import { ScrollView, Text, View } from 'react-native'

import { Card } from '../../../../../components/card'
import { EmptyState } from '../../../../../components/empty-state'
import { Skeleton } from '../../../../../components/skeleton'
import { cloudflareClient } from '../../../../../lib/api'
import { useActiveAccount } from '../../../../../lib/use-active-account'
import { useTabScrollPadding } from '../../../../../lib/use-tab-scroll-padding'

export default function WorkerSourceScreen() {
	const tabScrollPadding = useTabScrollPadding()
	const { name } = useLocalSearchParams<{ name: string }>()
	const { activeAccountId } = useActiveAccount()

	const contentQuery = useQuery({
		enabled: Boolean(activeAccountId && name),
		queryFn: () => cloudflareClient.getWorkerContent(activeAccountId!, name),
		queryKey: ['cf', 'worker', activeAccountId, name, 'content'],
		retry: false,
	})

	return (
		<ScrollView
			className="flex-1 bg-canvas"
			contentContainerStyle={{ gap: 16, padding: 16, paddingBottom: tabScrollPadding }}
			contentInsetAdjustmentBehavior="automatic"
		>
			<Card>
				{contentQuery.isLoading
					? (
							<View className="gap-2">
								<Skeleton className="h-4 w-full" />
								<Skeleton className="h-4 w-5/6" />
								<Skeleton className="h-4 w-2/3" />
							</View>
						)
					: contentQuery.isError
						? (
								<EmptyState onAction={() => void contentQuery.refetch()}>
									Source unavailable — modules-format Workers may not expose raw content.
								</EmptyState>
							)
						: (
								<ScrollView showsHorizontalScrollIndicator={false} horizontal>
									<Text className="font-mono text-xs leading-5 text-subtle" selectable>
										{contentQuery.data ?? ''}
									</Text>
								</ScrollView>
							)}
			</Card>
		</ScrollView>
	)
}
