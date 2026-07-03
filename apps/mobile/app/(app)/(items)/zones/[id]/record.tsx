import type { DnsRecord, DnsRecordInput } from '@cloudfx/api'

import { useMutation, useQueryClient } from '@tanstack/react-query'
import { router, useLocalSearchParams } from 'expo-router'
import { useMemo, useState } from 'react'
import { Alert, Pressable, ScrollView, Text, View } from 'react-native'

import { Button, ButtonText } from '../../../../../components/button'
import { Input } from '../../../../../components/input'
import { SettingRow } from '../../../../../components/setting-row'
import { cloudflareClient } from '../../../../../lib/api'
import { cx } from '../../../../../lib/cx'
import { hapticError, hapticSuccess } from '../../../../../lib/haptics'
import { useTabScrollPadding } from '../../../../../lib/use-tab-scroll-padding'
import { useToast } from '../../../../../lib/use-toast'

const RECORD_TYPES = ['A', 'AAAA', 'CNAME', 'TXT', 'MX', 'NS', 'SRV', 'CAA'] as const
const PROXIABLE_TYPES = new Set(['A', 'AAAA', 'CNAME'])
const PRIORITY_TYPES = new Set(['MX', 'SRV'])

const CONTENT_PLACEHOLDERS: Record<string, string> = {
	A: '203.0.113.1',
	AAAA: '2001:db8::1',
	CAA: '0 issue "letsencrypt.org"',
	CNAME: 'target.example.com',
	MX: 'mail.example.com',
	NS: 'ns1.example.com',
	SRV: '10 5060 sip.example.com',
	TXT: 'v=spf1 include:_spf.example.com ~all',
}

export default function DnsRecordScreen() {
	const tabScrollPadding = useTabScrollPadding()
	const { id, record: recordParam } = useLocalSearchParams<{ id: string, record?: string }>()
	const toast = useToast()
	const queryClient = useQueryClient()

	const existing = useMemo<DnsRecord | null>(() => {
		if (!recordParam)
			return null
		try {
			return JSON.parse(recordParam) as DnsRecord
		}
		catch {
			return null
		}
	}, [recordParam])

	const [type, setType] = useState(existing?.type ?? 'A')
	const [name, setName] = useState(existing?.name ?? '')
	const [content, setContent] = useState(existing?.content ?? '')
	const [ttl, setTtl] = useState(existing && existing.ttl !== 1 ? String(existing.ttl) : '')
	const [proxied, setProxied] = useState(existing?.proxied ?? false)
	const [priority, setPriority] = useState(
		existing && 'priority' in existing && typeof (existing as { priority?: number }).priority === 'number'
			? String((existing as { priority?: number }).priority)
			: '',
	)
	const [comment, setComment] = useState(existing?.comment ?? '')

	const proxiable = PROXIABLE_TYPES.has(type)
	const needsPriority = PRIORITY_TYPES.has(type)

	const invalidate = () => {
		void queryClient.invalidateQueries({ queryKey: ['cf', 'zone', id, 'dns'] })
		void queryClient.invalidateQueries({ queryKey: ['cf', 'zone', id, 'dns-count'] })
	}

	const buildInput = (): DnsRecordInput => ({
		content: content.trim(),
		name: name.trim() || '@',
		type,
		...(proxiable ? { proxied } : {}),
		...(ttl.trim() && !(proxiable && proxied) ? { ttl: Number(ttl.trim()) } : { ttl: 1 }),
		...(needsPriority && priority.trim() ? { priority: Number(priority.trim()) } : {}),
		...(comment.trim() ? { comment: comment.trim() } : {}),
	})

	const saveMutation = useMutation({
		mutationFn: (input: DnsRecordInput) =>
			existing
				? cloudflareClient.updateDnsRecord(id, existing.id, input)
				: cloudflareClient.createDnsRecord(id, input),
		onError: (error) => {
			hapticError()
			toast.show(error instanceof Error ? error.message : 'Failed to save record.', 'error')
		},
		onSuccess: () => {
			hapticSuccess()
			toast.show(existing ? 'Record updated.' : 'Record created.', 'success')
			invalidate()
			router.back()
		},
	})

	const deleteMutation = useMutation({
		mutationFn: () => cloudflareClient.deleteDnsRecord(id, existing!.id),
		onError: () => {
			hapticError()
			toast.show('Failed to delete record.', 'error')
		},
		onSuccess: () => {
			hapticSuccess()
			toast.show('Record deleted.', 'success')
			invalidate()
			router.back()
		},
	})

	const confirmDelete = () => {
		Alert.alert(
			'Delete record?',
			`${existing?.type} ${existing?.name} will be removed permanently.`,
			[
				{ style: 'cancel', text: 'Cancel' },
				{ onPress: () => deleteMutation.mutate(), style: 'destructive', text: 'Delete' },
			],
		)
	}

	const canSave = content.trim().length > 0 && (!needsPriority || priority.trim().length > 0)

	return (
		<ScrollView
			className="flex-1 bg-canvas"
			contentContainerStyle={{ gap: 16, padding: 16, paddingBottom: tabScrollPadding }}
			keyboardShouldPersistTaps="handled"
		>
			{/* Record type */}
			<View className="gap-1.5">
				<Text className="text-sm font-medium text-subtle">Type</Text>
				<ScrollView contentContainerStyle={{ gap: 8 }} showsHorizontalScrollIndicator={false} horizontal>
					{RECORD_TYPES.map(t => (
						<Pressable
							className={cx(
								`
									rounded-full px-4 py-2
									active:opacity-80
								`,
								t === type ? 'bg-brand' : 'border border-line bg-base',
							)}
							accessibilityRole="button"
							disabled={Boolean(existing)}
							key={t}
							onPress={() => setType(t)}
						>
							<Text className={cx('font-mono text-sm font-medium', t === type ? 'text-inverse' : 'text-subtle')}>
								{t}
							</Text>
						</Pressable>
					))}
				</ScrollView>
			</View>

			<Input
				autoCapitalize="none"
				autoCorrect={false}
				label="Name"
				onChangeText={setName}
				placeholder="@ for root, or a subdomain"
				value={name}
				mono
			/>

			<Input
				autoCapitalize="none"
				autoCorrect={false}
				label="Content"
				multiline={type === 'TXT'}
				onChangeText={setContent}
				placeholder={CONTENT_PLACEHOLDERS[type] ?? ''}
				value={content}
				mono
			/>

			{needsPriority
				? (
						<Input
							keyboardType="number-pad"
							label="Priority"
							onChangeText={setPriority}
							placeholder="10"
							value={priority}
						/>
					)
				: null}

			{proxiable
				? (
						<SettingRow
							onValueChange={setProxied}
							subtitle="Route traffic through Cloudflare"
							title="Proxied"
							value={proxied}
						/>
					)
				: null}

			{!(proxiable && proxied)
				? (
						<Input
							keyboardType="number-pad"
							label="TTL (seconds)"
							onChangeText={setTtl}
							placeholder="Auto"
							value={ttl}
						/>
					)
				: null}

			<Input
				label="Comment"
				onChangeText={setComment}
				placeholder="Optional note"
				value={comment}
			/>

			<View className="gap-3 pt-2">
				<Button
					disabled={!canSave}
					loading={saveMutation.isPending}
					onPress={() => saveMutation.mutate(buildInput())}
					size="lg"
				>
					<ButtonText>{existing ? 'Save changes' : 'Create record'}</ButtonText>
				</Button>
				{existing
					? (
							<Button
								loading={deleteMutation.isPending}
								onPress={confirmDelete}
								variant="outline"
							>
								<ButtonText className="text-danger">Delete record</ButtonText>
							</Button>
						)
					: null}
			</View>
		</ScrollView>
	)
}
