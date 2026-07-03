import { useQuery } from '@tanstack/react-query'
import { router } from 'expo-router'
import { Pressable } from 'react-native'

import { cloudflareClient } from '../lib/api'
import { AVATAR_HEADER_SIZE } from '../lib/avatar-header'
import { UserAvatar } from './user-avatar'

export function AccountAvatarHeaderButton() {
	const userQuery = useQuery({
		queryFn: () => cloudflareClient.getUser(),
		queryKey: ['cf', 'user'],
	})

	const email = userQuery.data?.email ?? ''

	return (
		<Pressable
			accessibilityLabel="Open profile"
			accessibilityRole="button"
			className="active:opacity-80"
			hitSlop={8}
			onPress={() => router.push('/profile')}
		>
			<UserAvatar email={email} size={AVATAR_HEADER_SIZE} />
		</Pressable>
	)
}
