import { useQuery } from '@tanstack/react-query'
import { useState } from 'react'
import { Image, Text, View } from 'react-native'

import { cx } from '../lib/cx'
import { emailInitial, gravatarUrlForEmail } from '../lib/gravatar'

interface UserAvatarImageProps {
	className?: string
	email: string
	frame: ReturnType<typeof squareFrame>
	size: number
	uri: string
}

function squareFrame(size: number) {
	return {
		borderCurve: 'continuous' as const,
		borderRadius: size / 2,
		height: size,
		overflow: 'hidden' as const,
		width: size,
	}
}

function UserAvatarImage({ className, email, frame, size, uri }: UserAvatarImageProps) {
	const [failed, setFailed] = useState(false)

	if (failed) {
		return (
			<View
				className={cx('items-center justify-center bg-accent', className)}
				style={frame}
			>
				<Text className="font-semibold text-inverse" style={{ fontSize: size * 0.4 }}>
					{emailInitial(email)}
				</Text>
			</View>
		)
	}

	return (
		<View className={cx('bg-base', className)} style={frame}>
			<Image
				onError={() => setFailed(true)}
				resizeMode="cover"
				source={{ uri }}
				style={{ height: size, width: size }}
			/>
		</View>
	)
}

interface UserAvatarProps {
	className?: string
	email: string
	size?: number
	uri?: string
}

export function UserAvatar({ className, email, size = 40, uri: uriProp }: UserAvatarProps) {
	const trimmed = email.trim()
	const gravatarQuery = useQuery({
		enabled: !uriProp && trimmed.length > 0,
		queryFn: () => gravatarUrlForEmail(trimmed, size * 2),
		queryKey: ['gravatar', trimmed, size],
		staleTime: Infinity,
	})

	const frame = squareFrame(size)
	const uri = uriProp ?? gravatarQuery.data

	if (uri) {
		return (
			<UserAvatarImage
				className={className}
				email={trimmed}
				frame={frame}
				key={uri}
				size={size}
				uri={uri}
			/>
		)
	}

	return (
		<View
			className={cx('items-center justify-center bg-accent', className)}
			style={frame}
		>
			<Text className="font-semibold text-inverse" style={{ fontSize: size * 0.4 }}>
				{emailInitial(email)}
			</Text>
		</View>
	)
}
