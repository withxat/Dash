import type { EmailRoutingRule } from '@cloudfx/api'

import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { router, useLocalSearchParams } from 'expo-router'
import { useCallback, useState } from 'react'
import { RefreshControl, ScrollView, View } from 'react-native'

import { Badge } from '../../../../components/badge'
import { EmptyState } from '../../../../components/empty-state'
import { ListSurface, Row } from '../../../../components/row'
import { SectionLabel } from '../../../../components/section-label'
import { SettingRow } from '../../../../components/setting-row'
import { Skeleton } from '../../../../components/skeleton'
import { cloudflareClient } from '../../../../lib/api'
import { isForbidden } from '../../../../lib/api-errors'
import { hapticError, hapticSuccess } from '../../../../lib/haptics'
import { useTheme } from '../../../../lib/theme'
import { useTabScrollPadding } from '../../../../lib/use-tab-scroll-padding'
import { useToast } from '../../../../lib/use-toast'

function ruleSummary(rule: EmailRoutingRule): string {
	const matcher = rule.matchers?.[0]
	const action = rule.actions?.[0]
	const from = matcher?.type === 'all' ? 'Catch-all' : matcher?.value ?? ''
	const to = action?.value?.[0] ?? action?.type ?? ''
	return [from, to].filter(Boolean).join(' → ')
}

export default function ZoneEmailRoutingScreen() {
	const tabScrollPadding = useTabScrollPadding()
	const { id } = useLocalSearchParams<{ id: string }>()
	const theme = useTheme()
	const toast = useToast()
	const queryClient = useQueryClient()
	const [refreshing, setRefreshing] = useState(false)

	const settingsQuery = useQuery({
		enabled: Boolean(id),
		queryFn: () => cloudflareClient.getEmailRoutingSettings(id),
		queryKey: ['cf', 'zone', id, 'email-routing'],
		retry: false,
	})
	const rulesQuery = useQuery({
		enabled: Boolean(id),
		queryFn: () => cloudflareClient.listEmailRoutingRules(id),
		queryKey: ['cf', 'zone', id, 'email-routing-rules'],
		retry: false,
	})

	const toggleMutation = useMutation({
		mutationFn: ({ enabled, rule }: { enabled: boolean, rule: EmailRoutingRule }) =>
			cloudflareClient.setEmailRoutingRuleEnabled(id, rule, enabled),
		onError: (error) => {
			hapticError()
			toast.show(
				isForbidden(error)
					? 'Missing permission — enable the Email Routing Rules write scope and sign in again.'
					: 'Failed to update the rule.',
				'error',
			)
		},
		onSuccess: () => {
			hapticSuccess()
			void queryClient.invalidateQueries({ queryKey: ['cf', 'zone', id, 'email-routing-rules'] })
		},
	})

	const onRefresh = useCallback(async () => {
		setRefreshing(true)
		await Promise.allSettled([settingsQuery.refetch(), rulesQuery.refetch()])
		setRefreshing(false)
	}, [rulesQuery, settingsQuery])

	const rules = rulesQuery.data ?? []

	return (
		<ScrollView
			className="flex-1 bg-canvas"
			contentContainerStyle={{ gap: 16, padding: 16, paddingBottom: tabScrollPadding }}
			contentInsetAdjustmentBehavior="automatic"
			refreshControl={<RefreshControl onRefresh={onRefresh} refreshing={refreshing} tintColor={theme.subtle} />}
		>
			<View className="gap-2">
				<SectionLabel>Status</SectionLabel>
				<ListSurface>
					{settingsQuery.isLoading
						? (
								<View className="py-3">
									<Skeleton className="h-6 w-full" />
								</View>
							)
						: settingsQuery.isError
							? (
									<EmptyState onAction={() => void settingsQuery.refetch()}>
										{isForbidden(settingsQuery.error)
											? 'Needs the Email Routing Rules read scope — enable it on your OAuth client and sign in again.'
											: 'Failed to load Email Routing status.'}
									</EmptyState>
								)
							: (
									<Row
										chevron={false}
										right={<Badge variant={settingsQuery.data?.enabled ? 'success' : 'secondary'}>{settingsQuery.data?.status ?? (settingsQuery.data?.enabled ? 'enabled' : 'disabled')}</Badge>}
										subtitle={settingsQuery.data?.name}
										title="Email Routing"
									/>
								)}
					<Row
						onPress={() => router.push('/account/email-addresses')}
						subtitle="Verified forwarding targets for the account"
						title="Destination addresses"
					/>
				</ListSurface>
			</View>

			<View className="gap-2">
				<SectionLabel>Routing rules</SectionLabel>
				<ListSurface>
					{rulesQuery.isLoading
						? (
								<View className="gap-3 py-3">
									<Skeleton className="h-6 w-full" />
									<Skeleton className="h-6 w-full" />
								</View>
							)
						: rulesQuery.isError
							? (
									<EmptyState onAction={() => void rulesQuery.refetch()}>
										{isForbidden(rulesQuery.error)
											? 'Needs the Email Routing Rules read scope — enable it on your OAuth client and sign in again.'
											: 'Failed to load routing rules.'}
									</EmptyState>
								)
							: rules.length === 0
								? <EmptyState>No routing rules on this zone.</EmptyState>
								: (
										<View>
											{rules.map(rule => (
												<SettingRow
													key={rule.id ?? rule.tag}
													loading={toggleMutation.isPending && toggleMutation.variables?.rule.id === rule.id}
													onValueChange={enabled => toggleMutation.mutate({ enabled, rule })}
													subtitle={ruleSummary(rule) || undefined}
													title={rule.name || 'Rule'}
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
