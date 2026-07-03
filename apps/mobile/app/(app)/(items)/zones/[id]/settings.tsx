import type { ReactElement } from 'react'

import { ApiError } from '@cloudfx/api'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useLocalSearchParams } from 'expo-router'
import { useMemo, useState } from 'react'
import { RefreshControl, ScrollView, Text, View } from 'react-native'

import { EmptyState } from '../../../../../components/empty-state'
import { PickerSettingRow } from '../../../../../components/picker-setting-row'
import { ListSurface } from '../../../../../components/row'
import { SectionLabel } from '../../../../../components/section-label'
import { SettingRow } from '../../../../../components/setting-row'
import { Skeleton } from '../../../../../components/skeleton'
import { cloudflareClient } from '../../../../../lib/api'
import { hapticError, hapticSuccess } from '../../../../../lib/haptics'
import { useTheme } from '../../../../../lib/theme'
import { useTabScrollPadding } from '../../../../../lib/use-tab-scroll-padding'
import { useToast } from '../../../../../lib/use-toast'

type SettingValue = boolean | number | Record<string, unknown> | string

interface EnumOption {
	label: string
	value: number | string
}

/** True when the error is a Cloudflare permission failure (missing scope). */
function isForbidden(error: unknown): boolean {
	return error instanceof ApiError && (error.status === 403 || error.status === 401)
}

const SSL_MODES: EnumOption[] = [
	{ label: 'Off', value: 'off' },
	{ label: 'Flexible', value: 'flexible' },
	{ label: 'Full', value: 'full' },
	{ label: 'Strict', value: 'strict' },
]

const MIN_TLS_VERSIONS: EnumOption[] = [
	{ label: 'TLS 1.0', value: '1.0' },
	{ label: 'TLS 1.1', value: '1.1' },
	{ label: 'TLS 1.2', value: '1.2' },
	{ label: 'TLS 1.3', value: '1.3' },
]

const SECURITY_LEVELS: EnumOption[] = [
	{ label: 'Essentially off', value: 'essentially_off' },
	{ label: 'Low', value: 'low' },
	{ label: 'Medium', value: 'medium' },
	{ label: 'High', value: 'high' },
	{ label: 'Under attack', value: 'under_attack' },
]

const CHALLENGE_TTLS: EnumOption[] = [
	{ label: '5 min', value: 300 },
	{ label: '15 min', value: 900 },
	{ label: '30 min', value: 1800 },
	{ label: '1 hour', value: 3600 },
	{ label: '1 day', value: 86400 },
	{ label: '1 week', value: 604800 },
]

const CACHE_LEVELS: EnumOption[] = [
	{ label: 'No query string', value: 'basic' },
	{ label: 'Ignore query string', value: 'simplified' },
	{ label: 'Standard', value: 'aggressive' },
]

const BROWSER_CACHE_TTLS: EnumOption[] = [
	{ label: 'Respect headers', value: 0 },
	{ label: '30 min', value: 1800 },
	{ label: '1 hour', value: 3600 },
	{ label: '4 hours', value: 14400 },
	{ label: '1 day', value: 86400 },
	{ label: '1 week', value: 604800 },
]

export default function ZoneSettingsScreen() {
	const tabScrollPadding = useTabScrollPadding()
	const { id } = useLocalSearchParams<{ id: string }>()
	const theme = useTheme()
	const toast = useToast()
	const queryClient = useQueryClient()
	const [refreshing, setRefreshing] = useState(false)

	const settingsQuery = useQuery({
		enabled: Boolean(id),
		queryFn: () => cloudflareClient.listZoneSettings(id),
		queryKey: ['cf', 'zone', id, 'settings'],
		retry: false,
	})

	const settings = useMemo(() => {
		const map = new Map<string, SettingValue>()
		for (const s of settingsQuery.data ?? [])
			map.set(s.id, s.value as SettingValue)
		return map
	}, [settingsQuery.data])

	const updateSetting = useMutation({
		mutationFn: ({ settingId, value }: { settingId: string, value: SettingValue }) =>
			cloudflareClient.updateZoneSetting(id, settingId, value),
		onError: (error) => {
			hapticError()
			toast.show(
				isForbidden(error)
					? 'Missing permission — sign in again to grant it.'
					: 'Failed to update setting — it may not be available on this plan.',
				'error',
			)
		},
		onSuccess: () => {
			hapticSuccess()
			void queryClient.invalidateQueries({ queryKey: ['cf', 'zone', id, 'settings'] })
		},
	})

	const handleRefresh = async () => {
		setRefreshing(true)
		await settingsQuery.refetch().catch(() => {})
		setRefreshing(false)
	}

	if (settingsQuery.isLoading) {
		return (
			<View className="flex-1 gap-3 bg-canvas p-4">
				<Skeleton className="h-40 w-full rounded-kumo" />
				<Skeleton className="h-40 w-full rounded-kumo" />
				<Skeleton className="h-40 w-full rounded-kumo" />
			</View>
		)
	}
	if (settingsQuery.isError) {
		return (
			<View className="flex-1 items-center justify-center bg-canvas">
				<EmptyState onAction={() => void settingsQuery.refetch()}>
					{isForbidden(settingsQuery.error)
						? 'Zone settings need extra permissions. Sign out and back in after enabling the zone settings scopes on your OAuth client.'
						: 'Failed to load zone settings.'}
				</EmptyState>
			</View>
		)
	}

	const pendingId = updateSetting.isPending ? updateSetting.variables?.settingId : undefined

	const toggle = (settingId: string, title: string, subtitle?: string) => {
		if (!settings.has(settingId))
			return null
		const raw = settings.get(settingId)
		// tls_1_3 reports "zrt" (0-RTT enabled) which still means "on".
		const value = raw === 'on' || raw === 'zrt'

		return (
			<SettingRow
				loading={pendingId === settingId}
				onValueChange={on => updateSetting.mutate({ settingId, value: on ? 'on' : 'off' })}
				subtitle={subtitle}
				title={title}
				value={value}
			/>
		)
	}

	const enumSetting = (settingId: string, title: string, options: EnumOption[], subtitle?: string) => {
		if (!settings.has(settingId))
			return null
		const value = settings.get(settingId) as number | string

		return (
			<PickerSettingRow
				loading={pendingId === settingId}
				onChange={next => updateSetting.mutate({ settingId, value: next })}
				options={options}
				subtitle={subtitle}
				title={title}
				value={value}
			/>
		)
	}

	const sections: Array<[string, Array<[string, null | ReactElement]>]> = [
		['SSL/TLS', [
			['ssl', enumSetting('ssl', 'SSL/TLS mode', SSL_MODES, 'How traffic between visitors and your origin is encrypted')],
			['min_tls_version', enumSetting('min_tls_version', 'Minimum TLS version', MIN_TLS_VERSIONS)],
			['tls_1_3', toggle('tls_1_3', 'TLS 1.3', 'Enable the latest TLS protocol')],
			['always_use_https', toggle('always_use_https', 'Always use HTTPS', 'Redirect all HTTP requests')],
			['automatic_https_rewrites', toggle('automatic_https_rewrites', 'Automatic HTTPS rewrites', 'Rewrite insecure links to HTTPS')],
			['opportunistic_encryption', toggle('opportunistic_encryption', 'Opportunistic encryption', 'Advertise HTTP/2 over TLS to HTTP visitors')],
		]],
		['Security', [
			['security_level', enumSetting('security_level', 'Security level', SECURITY_LEVELS, 'How aggressively visitors are challenged')],
			['browser_check', toggle('browser_check', 'Browser integrity check', 'Block requests with abusive headers')],
			['challenge_ttl', enumSetting('challenge_ttl', 'Challenge validity', CHALLENGE_TTLS, 'How long a passed challenge is remembered')],
			['email_obfuscation', toggle('email_obfuscation', 'Email obfuscation', 'Hide emails from bots and scrapers')],
			['hotlink_protection', toggle('hotlink_protection', 'Hotlink protection', 'Stop other sites embedding your images')],
		]],
		['Speed', [
			['brotli', toggle('brotli', 'Brotli compression', 'Compress responses with Brotli')],
			['early_hints', toggle('early_hints', 'Early hints', 'Send 103 hints while the origin responds')],
			['http3', toggle('http3', 'HTTP/3 (QUIC)', 'Serve traffic over HTTP/3')],
			['0rtt', toggle('0rtt', '0-RTT connection resumption', 'Resume TLS sessions without a round trip')],
			['rocket_loader', toggle('rocket_loader', 'Rocket Loader', 'Defer JavaScript to speed up paint')],
		]],
		['Caching', [
			['development_mode', toggle('development_mode', 'Development mode', 'Bypass cache for 3 hours')],
			['cache_level', enumSetting('cache_level', 'Cache level', CACHE_LEVELS, 'How query strings affect caching')],
			['browser_cache_ttl', enumSetting('browser_cache_ttl', 'Browser cache TTL', BROWSER_CACHE_TTLS, 'How long browsers keep cached files')],
			['always_online', toggle('always_online', 'Always Online', 'Serve cached pages when the origin is down')],
		]],
	]

	const footer = (
		<Text className="text-center text-[11px] text-placeholder">
			Settings not available on this zone's plan are hidden.
		</Text>
	)

	return (
		<ScrollView
			className="flex-1 bg-canvas"
			contentContainerStyle={{ gap: 16, padding: 16, paddingBottom: tabScrollPadding }}
			contentInsetAdjustmentBehavior="automatic"
			refreshControl={<RefreshControl onRefresh={handleRefresh} refreshing={refreshing} tintColor={theme.subtle} />}
		>
			{sections.map(([label, children]) => {
				const visible = children.filter((entry): entry is [string, ReactElement] => entry[1] != null)
				if (visible.length === 0)
					return null
				return (
					<View className="gap-2" key={label}>
						<SectionLabel>{label}</SectionLabel>
						<ListSurface>
							{visible.map(([key, child]) => (
								<View key={key}>{child}</View>
							))}
						</ListSurface>
					</View>
				)
			})}
			{footer}
		</ScrollView>
	)
}
