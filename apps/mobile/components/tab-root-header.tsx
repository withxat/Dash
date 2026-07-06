import { useQuery } from '@tanstack/react-query'
import { router, useSegments } from 'expo-router'
import { useCallback, useMemo } from 'react'
import { Platform, Text, View } from 'react-native'
import { useSafeAreaInsets } from 'react-native-safe-area-context'

import { cloudflareClient } from '../lib/api'
import { AVATAR_HEADER_SIZE } from '../lib/avatar-header'
import { chillBoldTextStyle } from '../lib/fonts'
import { gravatarUrlForEmail } from '../lib/gravatar'
import { SCREEN_GUTTER, TAB_ROOT_TITLE_GAP } from '../lib/screen-gutter'
import { useTheme } from '../lib/theme'
import { AccountAvatarHeaderButton } from './account-avatar-header-button'

const TAB_ROOT_TITLE_FONT_SIZE = 28

function profileHrefForSegments(segments: readonly string[]) {
	if (segments[1] === 'home')
		return '/home/profile'
	if (segments[1] === 'watchtower')
		return '/watchtower/profile'
	if (segments[1] === 'search')
		return '/search/profile'
	return '/profile'
}

interface TabRootHeaderProps {
	title: string
}

/** Tab-root chrome — profile avatar with Chill Bold title centered on the same row. */
export function TabRootHeader({ title }: TabRootHeaderProps) {
	const theme = useTheme()
	const insets = useSafeAreaInsets()
	const segments = useSegments() as readonly string[]
	const profileHref = useMemo(() => profileHrefForSegments(segments), [segments])

	const userQuery = useQuery({
		queryFn: () => cloudflareClient.getUser(),
		queryKey: ['cf', 'user'],
	})

	const email = userQuery.data?.email ?? ''
	const trimmed = email.trim()
	const gravatarQuery = useQuery({
		enabled: trimmed.length > 0,
		queryFn: () => gravatarUrlForEmail(trimmed, AVATAR_HEADER_SIZE * 2),
		queryKey: ['gravatar', trimmed, AVATAR_HEADER_SIZE],
		staleTime: Infinity,
	})

	const onPress = useCallback(() => {
		router.push(profileHref)
	}, [profileHref])

	return (
		<View
			style={{
				paddingBottom: TAB_ROOT_TITLE_GAP,
				paddingHorizontal: SCREEN_GUTTER,
				paddingTop: insets.top,
			}}
		>
			<View
				className="flex-row items-center gap-3"
				style={{ minHeight: AVATAR_HEADER_SIZE }}
			>
				<AccountAvatarHeaderButton email={email} onPress={onPress} uri={gravatarQuery.data} />
				<Text
					style={[
						chillBoldTextStyle({
							color: theme.default,
							flexShrink: 1,
							fontSize: TAB_ROOT_TITLE_FONT_SIZE,
							lineHeight: AVATAR_HEADER_SIZE,
							...(Platform.OS === 'android' ? { includeFontPadding: false } : null),
						}),
					]}
					numberOfLines={1}
				>
					{title}
				</Text>
			</View>
		</View>
	)
}
