import type { IpAccessRuleMode } from '@cloudfx/api'

import { useMutation, useQueryClient } from '@tanstack/react-query'
import { router, useLocalSearchParams } from 'expo-router'
import { useState } from 'react'
import { ScrollView, Text } from 'react-native'

import { Button, ButtonText } from '../../../../components/button'
import { Input } from '../../../../components/input'
import { Segmented } from '../../../../components/segmented'
import { cloudflareClient } from '../../../../lib/api'
import { isForbidden } from '../../../../lib/api-errors'
import { hapticError, hapticSuccess } from '../../../../lib/haptics'
import { useToast } from '../../../../lib/use-toast'

const MODES: Array<{ label: string, value: IpAccessRuleMode }> = [
	{ label: 'Block', value: 'block' },
	{ label: 'Challenge', value: 'managed_challenge' },
	{ label: 'Allow', value: 'whitelist' },
]

const IPV4 = /^(?:\d{1,3}\.){3}\d{1,3}$/
const IPV6 = /^[0-9a-f:]+$/i
const CIDR = /^(?:\d{1,3}\.){3}\d{1,3}\/\d{1,2}$/

function ipTarget(value: string): null | string {
	if (CIDR.test(value))
		return 'ip_range'
	if (IPV4.test(value))
		return 'ip'
	if (value.includes(':') && IPV6.test(value))
		return 'ip6'
	return null
}

export default function NewAccessRuleScreen() {
	const { id, ip: initialIp } = useLocalSearchParams<{ id: string, ip?: string }>()
	const toast = useToast()
	const queryClient = useQueryClient()

	const [value, setValue] = useState(initialIp ?? '')
	const [mode, setMode] = useState<IpAccessRuleMode>('block')
	const [notes, setNotes] = useState('')

	const target = ipTarget(value.trim())

	const createMutation = useMutation({
		mutationFn: () => cloudflareClient.createIpAccessRule(id, {
			configuration: { target: target!, value: value.trim() },
			mode,
			notes: notes.trim() || undefined,
		}),
		onError: (error) => {
			hapticError()
			toast.show(
				isForbidden(error)
					? 'Missing permission — enable the Firewall Services write scope and sign in again.'
					: 'Failed to create the rule.',
				'error',
			)
		},
		onSuccess: () => {
			hapticSuccess()
			toast.show('Rule created.', 'success')
			void queryClient.invalidateQueries({ queryKey: ['cf', 'zone', id, 'access-rules'] })
			router.back()
		},
	})

	return (
		<ScrollView
			className="flex-1 bg-canvas"
			contentContainerStyle={{ gap: 16, padding: 16 }}
			keyboardShouldPersistTaps="handled"
		>
			<Input
				autoCapitalize="none"
				autoCorrect={false}
				keyboardType="numbers-and-punctuation"
				label="IP address or CIDR range"
				onChangeText={setValue}
				placeholder="203.0.113.7 or 203.0.113.0/24"
				value={value}
				mono
			/>
			{value.trim() && !target
				? (
						<Text className="text-xs text-danger">
							Enter a valid IPv4/IPv6 address or an IPv4 CIDR range.
						</Text>
					)
				: null}

			<Segmented
				onChange={setMode}
				options={MODES}
				value={mode}
			/>

			<Input
				label="Note (optional)"
				onChangeText={setNotes}
				placeholder="Why this rule exists"
				value={notes}
			/>

			<Button
				disabled={!target}
				loading={createMutation.isPending}
				onPress={() => createMutation.mutate()}
			>
				<ButtonText>Create rule</ButtonText>
			</Button>

			<Text className="text-center text-[11px] text-placeholder">
				The rule applies to this zone only and takes effect within seconds.
			</Text>
		</ScrollView>
	)
}
