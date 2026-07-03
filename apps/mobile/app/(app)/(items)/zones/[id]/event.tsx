import type { FirewallEvent } from '@cloudfx/api'

import type { BadgeTone } from '../../../../../components/badge'

import { router, useLocalSearchParams } from 'expo-router'
import { useMemo } from 'react'
import { ScrollView, Text, View } from 'react-native'

import { Badge } from '../../../../../components/badge'
import { Button, ButtonText } from '../../../../../components/button'
import { EmptyState } from '../../../../../components/empty-state'
import { ListSurface } from '../../../../../components/row'
import { SectionLabel } from '../../../../../components/section-label'
import { useTabScrollPadding } from '../../../../../lib/use-tab-scroll-padding'

function actionTone(action: string): BadgeTone {
	if (action === 'block')
		return 'error'
	if (action.includes('challenge'))
		return 'warning'
	if (action === 'allow' || action === 'skip')
		return 'success'
	return 'secondary'
}

function DetailRow({ label, mono = true, value }: { label: string, mono?: boolean, value?: string }) {
	if (!value)
		return null
	return (
		<View className="gap-0.5 py-2">
			<Text className="text-sm font-medium text-subtle">{label}</Text>
			<Text className={mono ? 'font-mono text-sm text-default' : 'text-sm text-default'} selectable>
				{value}
			</Text>
		</View>
	)
}

export default function FirewallEventScreen() {
	const tabScrollPadding = useTabScrollPadding()
	const { event: eventParam, id } = useLocalSearchParams<{ event?: string, id: string }>()

	const event = useMemo<FirewallEvent | null>(() => {
		if (!eventParam)
			return null
		try {
			return JSON.parse(eventParam) as FirewallEvent
		}
		catch {
			return null
		}
	}, [eventParam])

	if (!event) {
		return (
			<View className="flex-1 items-center justify-center bg-canvas">
				<EmptyState>Event details unavailable.</EmptyState>
			</View>
		)
	}

	const requestLine = [
		event.clientRequestHTTPMethodName,
		`${event.clientRequestHTTPHost ?? ''}${event.clientRequestPath ?? ''}${event.clientRequestQuery ? `?${event.clientRequestQuery}` : ''}`,
	].filter(Boolean).join(' ')

	return (
		<ScrollView
			className="flex-1 bg-canvas"
			contentContainerStyle={{ gap: 16, padding: 16, paddingBottom: tabScrollPadding }}
		>
			<View className="flex-row items-center justify-between gap-3">
				<Badge variant={actionTone(event.action)}>{event.action}</Badge>
				{event.source
					? <Text className="text-xs text-subtle">{`via ${event.source}`}</Text>
					: null}
			</View>

			<View className="gap-2">
				<SectionLabel>Request</SectionLabel>
				<ListSurface>
					<DetailRow label="Request" value={requestLine} />
					<DetailRow label="Protocol" value={event.clientRequestHTTPProtocol} />
					<DetailRow label="Time" mono={false} value={new Date(event.datetime).toLocaleString()} />
					<DetailRow label="Ray ID" value={event.rayName} />
				</ListSurface>
			</View>

			<View className="gap-2">
				<SectionLabel>Client</SectionLabel>
				<ListSurface>
					<DetailRow label="IP address" value={event.clientIP} />
					<DetailRow label="Country" mono={false} value={event.clientCountryName} />
					<DetailRow
						label="ASN"
						value={event.clientAsn ? `AS${event.clientAsn}${event.clientASNDescription ? ` · ${event.clientASNDescription}` : ''}` : undefined}
					/>
					<DetailRow label="User agent" value={event.userAgent} />
				</ListSurface>
			</View>

			<View className="gap-2">
				<SectionLabel>Mitigation</SectionLabel>
				<ListSurface>
					<DetailRow label="Service" mono={false} value={event.source} />
					<DetailRow label="Rule ID" value={event.ruleId} />
				</ListSurface>
			</View>

			{event.clientIP
				? (
						<Button
							onPress={() => router.push({
								params: { id, ip: event.clientIP },
								pathname: '/zones/[id]/access-rule-new',
							})}
							variant="secondary-destructive"
						>
							<ButtonText>{`Block ${event.clientIP}`}</ButtonText>
						</Button>
					)
				: null}
		</ScrollView>
	)
}
