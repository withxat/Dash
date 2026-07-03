import type { WafCustomRule } from '@cloudfx/api'

import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useLocalSearchParams } from 'expo-router'
import { useCallback, useState } from 'react'
import { RefreshControl, ScrollView, View } from 'react-native'

import { EmptyState } from '../../../../../components/empty-state'
import { ListSurface } from '../../../../../components/row'
import { SectionLabel } from '../../../../../components/section-label'
import { SettingRow } from '../../../../../components/setting-row'
import { Skeleton } from '../../../../../components/skeleton'
import { cloudflareClient } from '../../../../../lib/api'
import { isForbidden } from '../../../../../lib/api-errors'
import { hapticError, hapticSuccess } from '../../../../../lib/haptics'
import { useTheme } from '../../../../../lib/theme'
import { useTabScrollPadding } from '../../../../../lib/use-tab-scroll-padding'
import { useToast } from '../../../../../lib/use-toast'

export default function ZoneWafScreen() {
	const tabScrollPadding = useTabScrollPadding()
	const { id } = useLocalSearchParams<{ id: string }>()
	const theme = useTheme()
	const toast = useToast()
	const queryClient = useQueryClient()
	const [refreshing, setRefreshing] = useState(false)

	const rulesetQuery = useQuery({
		enabled: Boolean(id),
		queryFn: () => cloudflareClient.getWafCustomRuleset(id),
		queryKey: ['cf', 'zone', id, 'waf-custom-ruleset'],
		retry: false,
	})

	const toggleMutation = useMutation({
		mutationFn: ({ enabled, rule }: { enabled: boolean, rule: WafCustomRule }) =>
			cloudflareClient.setWafCustomRuleEnabled(id, rulesetQuery.data!.id!, rule, enabled),
		onError: (error) => {
			hapticError()
			toast.show(
				isForbidden(error)
					? 'Missing permission — enable the Zone WAF write scope and sign in again.'
					: 'Failed to update the rule.',
				'error',
			)
		},
		onSuccess: () => {
			hapticSuccess()
			void queryClient.invalidateQueries({ queryKey: ['cf', 'zone', id, 'waf-custom-ruleset'] })
		},
	})

	const onRefresh = useCallback(async () => {
		setRefreshing(true)
		await rulesetQuery.refetch().catch(() => {})
		setRefreshing(false)
	}, [rulesetQuery])

	const rules = rulesetQuery.data?.rules ?? []

	return (
		<ScrollView
			className="flex-1 bg-canvas"
			contentContainerStyle={{ gap: 16, padding: 16, paddingBottom: tabScrollPadding }}
			contentInsetAdjustmentBehavior="automatic"
			refreshControl={<RefreshControl onRefresh={onRefresh} refreshing={refreshing} tintColor={theme.subtle} />}
		>
			<View className="gap-2">
				<SectionLabel>Custom rules</SectionLabel>
				<ListSurface>
					{rulesetQuery.isLoading
						? (
								<View className="gap-3 py-3">
									<Skeleton className="h-6 w-full" />
									<Skeleton className="h-6 w-full" />
								</View>
							)
						: rulesetQuery.isError
							? (
									<EmptyState onAction={() => void rulesetQuery.refetch()}>
										{isForbidden(rulesetQuery.error)
											? 'Needs the Zone WAF read scope — enable it on your OAuth client and sign in again.'
											: 'Failed to load WAF rules.'}
									</EmptyState>
								)
							: rules.length === 0
								? <EmptyState>No custom WAF rules on this zone.</EmptyState>
								: (
										<View>
											{rules.map(rule => (
												<SettingRow
													key={rule.id}
													loading={toggleMutation.isPending && toggleMutation.variables?.rule.id === rule.id}
													onValueChange={enabled => toggleMutation.mutate({ enabled, rule })}
													subtitle={rule.action ? `Action: ${rule.action}` : rule.expression}
													title={rule.description || rule.id || 'Rule'}
													value={rule.enabled ?? false}
												/>
											))}
										</View>
									)}
				</ListSurface>
			</View>
		</ScrollView>
	)
}
