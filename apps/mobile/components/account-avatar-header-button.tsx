import type { Href } from 'expo-router'

import { useQuery } from '@tanstack/react-query'
import { router, useSegments } from 'expo-router'
import { Pressable } from 'react-native'

import { cloudflareClient } from '../lib/api'
import { AVATAR_HEADER_SIZE } from '../lib/avatar-header'
import { UserAvatar } from './user-avatar'

export function AccountAvatarHeaderButton() {
	const segments = useSegments() as readonly string[]
	const userQuery = useQuery({
		queryFn: () => cloudflareClient.getUser(),
		queryKey: ['cf', 'user'],
	})

	const email = userQuery.data?.email ?? ''
	let profileHref: Href = '/profile'
	if (segments[1] === 'home')
		profileHref = '/home/profile'
	else if (segments[1] === 'watchtower')
		profileHref = '/watchtower/profile'
	else if (segments[1] === 'search')
		profileHref = '/search/profile'

	return (
		<Pressable
			accessibilityLabel="Open profile"
			accessibilityRole="button"
			className="active:opacity-80"
			hitSlop={8}
			onPress={() => router.push(profileHref)}
		>
			<UserAvatar email={email} size={AVATAR_HEADER_SIZE} />
		</Pressable>
	)
}
