import type { NativeStackNavigationOptions } from 'expo-router/build/react-navigation/native-stack/types'

import { useQuery } from '@tanstack/react-query'
import { router, useSegments } from 'expo-router'
import { useCallback, useMemo } from 'react'
import { Platform } from 'react-native'

import { AccountAvatarHeaderButton } from '../components/account-avatar-header-button'
import { cloudflareClient } from './api'
import { AVATAR_HEADER_BAR_BUTTON_WIDTH } from './avatar-header'
import { gravatarUrlForEmail } from './gravatar'

type AvatarHeaderOptions = Pick<NativeStackNavigationOptions, 'headerLeft' | 'unstable_headerLeftItems'>

function profileHrefForSegments(segments: readonly string[]) {
	if (segments[1] === 'home')
		return '/home/profile'
	if (segments[1] === 'watchtower')
		return '/watchtower/profile'
	if (segments[1] === 'search')
		return '/search/profile'
	return '/profile'
}

/**
 * Tab-root profile control.
 * iOS: native header item (`type: 'custom'`) — RN Screens iOS 26 wrapper keeps a square
 * intrinsic size so the avatar stays round; plain `headerLeft` gets stretched by Liquid Glass.
 * Android: `headerLeft` custom view with the same fixed square slot.
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
		() => <AccountAvatarHeaderButton email={email} onPress={onPress} uri={uri} />,
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
