import { useEffect } from 'react'
import { Pressable } from 'react-native'
import Animated, {
	interpolateColor,
	useAnimatedStyle,
	useSharedValue,
	withTiming,
} from 'react-native-reanimated'

import { thumbShadowStyle } from '../../lib/shadow'
import { useTheme } from '../../lib/theme'

export type SwitchSize = 'base' | 'lg' | 'sm'
export type SwitchVariant = 'default' | 'neutral'

interface SwitchProps {
	checked: boolean
	disabled?: boolean
	onCheckedChange: (checked: boolean) => void
	size?: SwitchSize
	variant?: SwitchVariant
}

/** Kumo stratus sizes — thumb is square (side = track height), slides width − height. */
const SIZE = {
	base: { height: 18, radius: 5, width: 36 },
	lg: { height: 20, radius: 5, width: 40 },
	sm: { height: 16, radius: 5, width: 32 },
} as const

const RING = 1

/** Kumo squircle switch — rounded-rect track + thumb, not an iOS pill/circle. */
export function Switch({
	checked,
	disabled = false,
	onCheckedChange,
	size = 'base',
	variant = 'default',
}: SwitchProps) {
	const theme = useTheme()
	const dimensions = SIZE[size]
	const travel = dimensions.width - dimensions.height
	const progress = useSharedValue(checked ? 1 : 0)

	useEffect(() => {
		progress.set(withTiming(checked ? 1 : 0, { duration: 150 }))
	}, [checked, progress])

	const ringStyle = useAnimatedStyle(() => ({
		backgroundColor: interpolateColor(
			progress.get(),
			[0, 1],
			variant === 'neutral'
				? [theme.switchTrackOffRing, theme.switchTrackNeutralOnRing]
				: [theme.switchTrackOffRing, theme.switchTrackOnRing],
		),
	}))

	const trackStyle = useAnimatedStyle(() => ({
		backgroundColor: interpolateColor(
			progress.get(),
			[0, 1],
			variant === 'neutral'
				? [theme.switchTrackOff, theme.switchTrackNeutralOn]
				: [theme.switchTrackOff, theme.switchTrackOn],
		),
	}))

	const thumbStyle = useAnimatedStyle(() => ({
		transform: [{ translateX: progress.get() * travel }],
	}))

	return (
		<Pressable
			accessibilityRole="switch"
			accessibilityState={{ checked, disabled }}
			disabled={disabled}
			onPress={() => onCheckedChange(!checked)}
		>
			<Animated.View
				style={[
					{
						alignSelf: 'flex-start',
						borderCurve: 'continuous',
						borderRadius: dimensions.radius + RING,
						opacity: disabled ? 0.5 : 1,
						padding: RING,
					},
					ringStyle,
				]}
			>
				<Animated.View
					style={[
						{
							borderCurve: 'continuous',
							borderRadius: dimensions.radius,
							height: dimensions.height,
							overflow: 'hidden',
							width: dimensions.width,
						},
						trackStyle,
					]}
				>
					<Animated.View
						style={[
							{
								backgroundColor: theme.base,
								borderCurve: 'continuous',
								borderRadius: dimensions.radius,
								height: dimensions.height,
								left: 0,
								position: 'absolute',
								top: 0,
								width: dimensions.height,
							},
							thumbShadowStyle(theme),
							thumbStyle,
						]}
					/>
				</Animated.View>
			</Animated.View>
		</Pressable>
	)
}
