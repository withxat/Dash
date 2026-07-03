import type { PurgeCacheInput } from '@cloudfx/api'

import { ApiError } from '@cloudfx/api'
import { useMutation, useQuery } from '@tanstack/react-query'
import { useLocalSearchParams } from 'expo-router'
import { useCallback, useState } from 'react'
import { Alert, ScrollView, Text, View } from 'react-native'

import { Button, ButtonText } from '../../../../../components/button'
import { Card } from '../../../../../components/card'
import { Input } from '../../../../../components/input'
import { SectionLabel } from '../../../../../components/section-label'
import { Segmented } from '../../../../../components/segmented'
import { cloudflareClient } from '../../../../../lib/api'
import { hapticError, hapticSuccess } from '../../../../../lib/haptics'
import { useTabScrollPadding } from '../../../../../lib/use-tab-scroll-padding'
import { useToast } from '../../../../../lib/use-toast'

type PurgeMode = 'everything' | 'hosts' | 'prefixes' | 'tags' | 'urls'

const MODE_OPTIONS: Array<{ label: string, value: PurgeMode }> = [
	{ label: 'URLs', value: 'urls' },
	{ label: 'Hosts', value: 'hosts' },
	{ label: 'Prefixes', value: 'prefixes' },
	{ label: 'Tags', value: 'tags' },
	{ label: 'All', value: 'everything' },
]

const MODE_META: Record<Exclude<PurgeMode, 'everything'>, { hint: string, label: string, placeholder: string }> = {
	hosts: {
		hint: 'Purges every cached asset on the listed hostnames. Requires an Enterprise plan.',
		label: 'Hostnames (one per line)',
		placeholder: 'assets.example.com',
	},
	prefixes: {
		hint: 'Purges cached URLs starting with the listed prefixes. Requires an Enterprise plan.',
		label: 'URL prefixes (one per line)',
		placeholder: 'example.com/static/',
	},
	tags: {
		hint: 'Purges assets tagged with a Cache-Tag response header. Requires an Enterprise plan.',
		label: 'Cache tags (one per line)',
		placeholder: 'homepage',
	},
	urls: {
		hint: 'Purges the exact URLs listed, up to 30 per request.',
		label: 'URLs (one per line)',
		placeholder: 'https://example.com/path',
	},
}

/** True when the error is a Cloudflare permission failure (missing scope). */
function isForbidden(error: unknown): boolean {
	return error instanceof ApiError && (error.status === 403 || error.status === 401)
}

export default function ZoneCacheScreen() {
	const tabScrollPadding = useTabScrollPadding()
	const { id } = useLocalSearchParams<{ id: string }>()
	const toast = useToast()
	const [mode, setMode] = useState<PurgeMode>('urls')
	const [entries, setEntries] = useState('')

	const zoneQuery = useQuery({
		enabled: Boolean(id),
		queryFn: () => cloudflareClient.getZone(id),
		queryKey: ['cf', 'zone', id],
	})

	const purgeMutation = useMutation({
		mutationFn: (input: PurgeCacheInput) => cloudflareClient.purgeCache(id, input),
		onError: (error) => {
			hapticError()
			toast.show(
				isForbidden(error)
					? 'Missing permission — sign in again to grant it.'
					: 'Cache purge failed — this purge type may need an Enterprise plan.',
				'error',
			)
		},
		onSuccess: (_, input) => {
			hapticSuccess()
			toast.show('purge_everything' in input ? 'Entire cache purged.' : 'Purge request submitted.', 'success')
			setEntries('')
		},
	})

	const lines = entries
		.split('\n')
		.map(line => line.trim())
		.filter(Boolean)

	const purgeList = useCallback(() => {
		if (lines.length === 0)
			return
		if (mode === 'urls') {
			purgeMutation.mutate({
				files: lines.map(url => (url.startsWith('http') ? url : `https://${url}`)),
			})
			return
		}
		if (mode === 'hosts')
			purgeMutation.mutate({ hosts: lines })
		else if (mode === 'prefixes')
			purgeMutation.mutate({ prefixes: lines })
		else if (mode === 'tags')
			purgeMutation.mutate({ tags: lines })
	}, [lines, mode, purgeMutation])

	const confirmPurgeEverything = useCallback(() => {
		Alert.alert(
			'Purge everything?',
			'This removes all cached content for this zone. Traffic will hit your origin until the cache refills.',
			[
				{ style: 'cancel', text: 'Cancel' },
				{
					onPress: () => purgeMutation.mutate({ purge_everything: true }),
					style: 'destructive',
					text: 'Purge everything',
				},
			],
		)
	}, [purgeMutation])

	const meta = mode === 'everything' ? null : MODE_META[mode]

	return (
		<ScrollView
			className="flex-1 bg-canvas"
			contentContainerStyle={{ gap: 16, padding: 16, paddingBottom: tabScrollPadding }}
			contentInsetAdjustmentBehavior="automatic"
			keyboardShouldPersistTaps="handled"
		>
			<View className="gap-2">
				<SectionLabel>Purge cached content</SectionLabel>
				<Segmented onChange={setMode} options={MODE_OPTIONS} value={mode} />
				<Card>
					{meta
						? (
								<View className="gap-3">
									<Input
										autoCapitalize="none"
										autoCorrect={false}
										className="min-h-28"
										label={meta.label}
										onChangeText={setEntries}
										placeholder={mode === 'urls' && zoneQuery.data?.name ? `https://${zoneQuery.data.name}/path` : meta.placeholder}
										textAlignVertical="top"
										value={entries}
										mono
										multiline
									/>
									<Text className="text-xs text-subtle">{meta.hint}</Text>
									<Button
										disabled={lines.length === 0}
										loading={purgeMutation.isPending}
										onPress={purgeList}
									>
										<ButtonText>
											{lines.length > 1 ? `Purge ${lines.length} entries` : 'Purge'}
										</ButtonText>
									</Button>
								</View>
							)
						: (
								<View className="gap-3">
									<Text className="text-sm text-subtle">
										Remove every cached asset for this zone. Your origin will take full traffic until the cache refills.
									</Text>
									<Button
										loading={purgeMutation.isPending}
										onPress={confirmPurgeEverything}
										variant="destructive"
									>
										<ButtonText>Purge everything</ButtonText>
									</Button>
								</View>
							)}
				</Card>
			</View>
		</ScrollView>
	)
}
