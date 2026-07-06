import { Image, Pressable, StyleSheet, Text, View } from 'react-native'

import {
	AVATAR_HEADER_SIZE,
	avatarHeaderPressableStyle,
	avatarHeaderSlotStyle,
	isIosLiquidGlassHeader,
} from '../lib/avatar-header'
import { emailInitial } from '../lib/gravatar'
import { useTheme } from '../lib/theme'

interface AccountAvatarHeaderButtonProps {
	email: string
	onPress: () => void
	uri?: string
}

function circularContentStyle(size: number, borderColor?: string) {
	return {
		borderCurve: 'continuous' as const,
		borderRadius: size / 2,
		height: size,
		width: size,
		...(borderColor
			? {
					borderColor,
					borderWidth: StyleSheet.hairlineWidth,
				}
			: null),
	}
}

/**
 * Tab-root profile avatar — fixed 44×44 slot for UIKit bar-button intrinsic size.
 * Wrapped in avatarHeaderSlotStyle at the call site on iOS.
 */
export function AccountAvatarHeaderButton({ email, onPress, uri }: AccountAvatarHeaderButtonProps) {
	const theme = useTheme()
	const size = AVATAR_HEADER_SIZE
	const borderColor = isIosLiquidGlassHeader() ? undefined : theme.line

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
						<Image
							resizeMode="cover"
							source={{ uri }}
							style={circularContentStyle(size, borderColor)}
						/>
					)
				: (
						<View
							className="items-center justify-center bg-accent"
							style={circularContentStyle(size, borderColor)}
						>
							<Text
								style={{
									color: theme.inverse,
									fontSize: size * 0.4,
									fontWeight: '600',
								}}
							>
								{emailInitial(email)}
							</Text>
						</View>
					)}
		</Pressable>
	)
}

/** Outermost wrapper — drives RN Screens / UIKit bar-button intrinsic content size. */
export function AccountAvatarHeaderButtonSlot(props: AccountAvatarHeaderButtonProps) {
	return (
		<View style={avatarHeaderSlotStyle()}>
			<AccountAvatarHeaderButton {...props} />
		</View>
	)
}
