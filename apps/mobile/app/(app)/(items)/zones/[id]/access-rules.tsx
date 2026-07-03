import type { IpAccessRule } from '@cloudfx/api'

import type { BadgeTone } from '../../../../../components/badge'

import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { router, useLocalSearchParams } from 'expo-router'
import { useCallback, useState } from 'react'
import { Alert, RefreshControl, ScrollView, View } from 'react-native'

import { Badge } from '../../../../../components/badge'
import { QuerySection } from '../../../../../components/query-section'
import { ListSurface, Row } from '../../../../../components/row'
import { SectionLabel } from '../../../../../components/section-label'
import { cloudflareClient } from '../../../../../lib/api'
import { isForbidden } from '../../../../../lib/api-errors'
import { hapticError, hapticSuccess } from '../../../../../lib/haptics'
import { useTheme } from '../../../../../lib/theme'
import { useTabScrollPadding } from '../../../../../lib/use-tab-scroll-padding'
import { useToast } from '../../../../../lib/use-toast'

function modeTone(mode: IpAccessRule['mode']): BadgeTone {
	if (mode === 'block')
		return 'error'
	if (mode === 'whitelist')
		return 'success'
	return 'warning'
}

export default function ZoneAccessRulesScreen() {
	const tabScrollPadding = useTabScrollPadding()
	const { id } = useLocalSearchParams<{ id: string }>()
	const theme = useTheme()
	const toast = useToast()
	const queryClient = useQueryClient()
	const [refreshing, setRefreshing] = useState(false)

	const rulesQuery = useQuery({
		enabled: Boolean(id),
		queryFn: () => cloudflareClient.listIpAccessRules(id, { perPage: 100 }).then(p => p.items),
		queryKey: ['cf', 'zone', id, 'access-rules'],
		retry: false,
	})

	const deleteMutation = useMutation({
		mutationFn: (ruleId: string) => cloudflareClient.deleteIpAccessRule(id, ruleId),
		onError: (error) => {
			hapticError()
			toast.show(
				isForbidden(error)
					? 'Missing permission — enable the Firewall Services write scope and sign in again.'
					: 'Failed to delete the rule.',
				'error',
			)
		},
		onSuccess: () => {
			hapticSuccess()
			toast.show('Rule deleted.', 'success')
			void queryClient.invalidateQueries({ queryKey: ['cf', 'zone', id, 'access-rules'] })
		},
	})

	const confirmDelete = useCallback((rule: IpAccessRule) => {
		Alert.alert(
			'Delete rule?',
			`${rule.mode} · ${rule.configuration?.value ?? ''}`,
			[
				{ style: 'cancel', text: 'Cancel' },
				{ onPress: () => deleteMutation.mutate(rule.id), style: 'destructive', text: 'Delete' },
			],
		)
	}, [deleteMutation])

	const onRefresh = useCallback(async () => {
		setRefreshing(true)
		await rulesQuery.refetch().catch(() => {})
		setRefreshing(false)
	}, [rulesQuery])

	return (
		<ScrollView
			className="flex-1 bg-canvas"
			contentContainerStyle={{ gap: 16, padding: 16, paddingBottom: tabScrollPadding }}
			contentInsetAdjustmentBehavior="automatic"
			refreshControl={<RefreshControl onRefresh={onRefresh} refreshing={refreshing} tintColor={theme.subtle} />}
		>
			<View className="gap-2">
				<SectionLabel>Actions</SectionLabel>
				<ListSurface>
					<Row
						onPress={() => router.push(`/zones/${id}/access-rule-new`)}
						subtitle="Block, challenge, or allow an IP on this zone"
						title="New rule"
					/>
				</ListSurface>
			</View>

			<View className="gap-2">
				<SectionLabel>IP Access Rules</SectionLabel>
				<ListSurface>
					<QuerySection
						renderItem={rule => (
							<Row
								chevron={false}
								onPress={() => confirmDelete(rule)}
								right={<Badge variant={modeTone(rule.mode)}>{rule.mode}</Badge>}
								subtitle={rule.notes || rule.configuration?.target}
								title={rule.configuration?.value ?? rule.id}
							/>
						)}
						emptyText="No IP Access Rules on this zone."
						error={rulesQuery.error}
						errorText="Failed to load IP Access Rules."
						isError={rulesQuery.isError}
						isLoading={rulesQuery.isLoading}
						items={rulesQuery.data}
						onRetry={() => void rulesQuery.refetch()}
						scopeHint="Needs the Firewall Services read scope — enable it on your OAuth client and sign in again."
					/>
				</ListSurface>
			</View>
		</ScrollView>
	)
}
