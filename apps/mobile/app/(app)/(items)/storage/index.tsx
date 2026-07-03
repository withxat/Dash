import { router } from 'expo-router'
import { ScrollView, View } from 'react-native'

import { AccountSwitcher } from '../../../../components/account-switcher'
import { ListSurface, Row } from '../../../../components/row'
import { SectionLabel } from '../../../../components/section-label'
import { useTabScrollPadding } from '../../../../lib/use-tab-scroll-padding'

export default function StorageScreen() {
	const tabScrollPadding = useTabScrollPadding()

	return (
		<ScrollView
			className="flex-1 bg-canvas"
			contentContainerStyle={{ gap: 16, padding: 16, paddingBottom: tabScrollPadding }}
			contentInsetAdjustmentBehavior="automatic"
		>
			<AccountSwitcher />

			<View className="gap-2">
				<SectionLabel>Object &amp; key-value</SectionLabel>
				<ListSurface>
					<Row
						onPress={() => router.push('/storage/r2')}
						subtitle="Object storage buckets"
						title="R2"
					/>
					<Row
						onPress={() => router.push('/storage/kv')}
						subtitle="Workers KV namespaces"
						title="KV"
					/>
				</ListSurface>
			</View>

			<View className="gap-2">
				<SectionLabel>Data services</SectionLabel>
				<ListSurface>
					<Row
						onPress={() => router.push('/storage/d1')}
						subtitle="Serverless SQL databases"
						title="D1"
					/>
					<Row
						onPress={() => router.push('/storage/queues')}
						subtitle="Message queues, producers, and consumers"
						title="Queues"
					/>
					<Row
						onPress={() => router.push('/storage/vectorize')}
						subtitle="Vector indexes for AI workloads"
						title="Vectorize"
					/>
					<Row
						onPress={() => router.push('/storage/secrets')}
						subtitle="Account-level secrets (names only)"
						title="Secrets Store"
					/>
				</ListSurface>
			</View>
		</ScrollView>
	)
}
