import { router } from 'expo-router'
import { ScrollView } from 'react-native'

import { AccountSwitcher } from '../../../../components/account-switcher'
import { ListGroup, Row } from '../../../../components/row'
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

			<ListGroup title="Object & key-value">
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
			</ListGroup>

			<ListGroup title="Data services">
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
			</ListGroup>
		</ScrollView>
	)
}
