import type { NativeStackNavigationOptions } from 'expo-router/build/react-navigation/native-stack/types'

import { useQuery } from '@tanstack/react-query'
import { router, useSegments } from 'expo-router'
import { useCallback, useMemo } from 'react'
import { Platform } from 'react-native'

import { AccountAvatarHeaderButtonSlot } from '../components/account-avatar-header-button'
import { cloudflareClient } from './api'
import { AVATAR_HEADER_BAR_BUTTON_WIDTH } from './avatar-header'
import { gravatarUrlForEmail } from './gravatar'

type AvatarHeaderOptions = Pick<NativeStackNavigationOptions, 'headerLeft' | 'unstable_headerLeftItems'>

function profileHrefForSegments(segments: readonly string[]) {
	if (segments.includes('search'))
		return '/search/profile'
	if (segments[1] === 'home')
		return '/home/profile'
	if (segments[1] === 'watchtower')
		return '/watchtower/profile'
	return '/profile'
}

/**
 * Tab-root profile control.
 * iOS: native bar-button custom item with a strict 44×44 slot (nav bar row height).
 * hidesSharedBackground avoids Liquid Glass stretching the chrome into a wide capsule.
 * Android: plain headerLeft with the same square slot.
 */
export function useAccountAvatarHeaderOptions(): AvatarHeaderOptions {
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
		queryFn: () => gravatarUrlForEmail(trimmed, AVATAR_HEADER_BAR_BUTTON_WIDTH * 2),
		queryKey: ['gravatar', trimmed, AVATAR_HEADER_BAR_BUTTON_WIDTH],
		staleTime: Infinity,
	})

	const onPress = useCallback(() => {
		router.push(profileHref)
	}, [profileHref])

	const uri = gravatarQuery.data

	const avatarButton = useMemo(
		() => (
			<AccountAvatarHeaderButtonSlot
				email={email}
				onPress={onPress}
				uri={uri}
			/>
		),
		[email, onPress, uri],
	)

	if (Platform.OS === 'ios') {
		return {
			unstable_headerLeftItems: () => [{
				element: avatarButton,
				hidesSharedBackground: true,
				type: 'custom',
			}],
		}
	}

	return {
		headerLeft: () => avatarButton,
	}
}
