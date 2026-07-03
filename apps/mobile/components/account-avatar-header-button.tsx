import { Image, Pressable, StyleSheet, Text, View } from 'react-native'

import { AVATAR_HEADER_SIZE, avatarHeaderPressableStyle } from '../lib/avatar-header'
import { chillFaceStyle } from '../lib/fonts'
import { emailInitial } from '../lib/gravatar'
import { useTheme } from '../lib/theme'

interface AccountAvatarHeaderButtonProps {
	email: string
	onPress: () => void
	uri?: string
}

function squareAvatarFrame(size: number) {
	const radius = size / 2

	return {
		borderCurve: 'continuous' as const,
		borderRadius: radius,
		height: size,
		maxHeight: size,
		maxWidth: size,
		minHeight: size,
		minWidth: size,
		overflow: 'hidden' as const,
		width: size,
	}
}

/** Tab-root profile avatar — fixed square slot so UIKit cannot stretch it into a capsule. */
export function AccountAvatarHeaderButton({ email, onPress, uri }: AccountAvatarHeaderButtonProps) {
	const theme = useTheme()
	const size = AVATAR_HEADER_SIZE
	const frame = {
		...squareAvatarFrame(size),
		borderColor: theme.line,
		borderWidth: StyleSheet.hairlineWidth,
	}

	return (
		<Pressable
			accessibilityLabel="Open profile"
			accessibilityRole="button"
			className="active:opacity-80"
			onPress={onPress}
			style={avatarHeaderPressableStyle(size)}
		>
			{uri
				? (
						<View style={frame}>
							<Image
								resizeMode="cover"
								source={{ uri }}
								style={{ height: size, width: size }}
							/>
						</View>
					)
				: (
						<View className="items-center justify-center bg-accent" style={frame}>
							<Text
								style={chillFaceStyle('heavy', {
									color: theme.inverse,
									fontSize: size * 0.4,
								})}
							>
								{emailInitial(email)}
							</Text>
						</View>
					)}
		</Pressable>
	)
}
