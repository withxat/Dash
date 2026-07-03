import type { TurnstileWidget } from '@cloudfx/api'

import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useCallback, useState } from 'react'
import { Alert, RefreshControl, ScrollView } from 'react-native'

import { Badge } from '../../../../components/badge'
import { QuerySection } from '../../../../components/query-section'
import { ListGroup, Row } from '../../../../components/row'
import { cloudflareClient } from '../../../../lib/api'
import { isForbidden } from '../../../../lib/api-errors'
import { hapticError, hapticSuccess } from '../../../../lib/haptics'
import { useTheme } from '../../../../lib/theme'
import { useActiveAccount } from '../../../../lib/use-active-account'
import { useTabScrollPadding } from '../../../../lib/use-tab-scroll-padding'
import { useToast } from '../../../../lib/use-toast'

export default function TurnstileScreen() {
	const tabScrollPadding = useTabScrollPadding()
	const { activeAccount } = useActiveAccount()
	const accountId = activeAccount?.id
	const theme = useTheme()
	const toast = useToast()
	const queryClient = useQueryClient()
	const [refreshing, setRefreshing] = useState(false)

	const widgetsQuery = useQuery({
		enabled: Boolean(accountId),
		queryFn: () => cloudflareClient.listTurnstileWidgets(accountId!),
		queryKey: ['cf', 'account', accountId, 'turnstile-widgets'],
		retry: false,
	})

	const rotateMutation = useMutation({
		mutationFn: (sitekey: string) => cloudflareClient.rotateTurnstileSecret(accountId!, sitekey),
		onError: (error) => {
			hapticError()
			toast.show(
				isForbidden(error)
					? 'Missing permission — enable the Challenge Widgets write scope and sign in again.'
					: 'Failed to rotate the secret.',
				'error',
			)
		},
		onSuccess: () => {
			hapticSuccess()
			toast.show('Secret rotated. The old secret stays valid for 2 hours.', 'success')
			void queryClient.invalidateQueries({ queryKey: ['cf', 'account', accountId, 'turnstile-widgets'] })
		},
	})

	const confirmRotate = useCallback((widget: TurnstileWidget) => {
		if (!widget.sitekey)
			return
		Alert.alert(
			'Rotate secret?',
			`${widget.name ?? widget.sitekey}\n\nThe current secret keeps working for 2 hours so you can roll out the new one.`,
			[
				{ style: 'cancel', text: 'Cancel' },
				{ onPress: () => rotateMutation.mutate(widget.sitekey!), style: 'destructive', text: 'Rotate' },
			],
		)
	}, [rotateMutation])

	const onRefresh = useCallback(async () => {
		setRefreshing(true)
		await widgetsQuery.refetch().catch(() => {})
		setRefreshing(false)
	}, [widgetsQuery])

	return (
		<ScrollView
			className="flex-1 bg-canvas"
			contentContainerStyle={{ gap: 16, padding: 16, paddingBottom: tabScrollPadding }}
			contentInsetAdjustmentBehavior="automatic"
			refreshControl={<RefreshControl onRefresh={onRefresh} refreshing={refreshing} tintColor={theme.subtle} />}
		>
			<ListGroup title="Widgets">
				<QuerySection
					renderItem={widget => (
						<Row
							chevron={false}
							onPress={() => confirmRotate(widget)}
							right={widget.mode ? <Badge variant="secondary">{widget.mode}</Badge> : undefined}
							subtitle={[widget.sitekey, (widget.domains ?? []).join(', ')].filter(Boolean).join(' · ')}
							title={widget.name ?? widget.sitekey ?? 'Widget'}
						/>
					)}
					emptyText="No Turnstile widgets on this account."
					error={widgetsQuery.error}
					errorText="Failed to load Turnstile widgets."
					isError={widgetsQuery.isError}
					isLoading={widgetsQuery.isLoading}
					items={widgetsQuery.data}
					onRetry={() => void widgetsQuery.refetch()}
					scopeHint="Needs the Challenge Widgets read scope — enable it on your OAuth client and sign in again."
				/>
			</ListGroup>
		</ScrollView>
	)
}
