import { useEffect } from 'react'
import Animated, {
	useAnimatedStyle,
	useSharedValue,
	withRepeat,
	withTiming,
} from 'react-native-reanimated'

import { cn } from './cn'

interface SkeletonLineProps {
	/** Tailwind classes controlling the shape, e.g. "h-4 w-24 rounded-sm". */
	className?: string
}

/** Kumo SkeletonLine — pulsing placeholder block for loading states. */
export function SkeletonLine({ className }: SkeletonLineProps) {
	const pulse = useSharedValue(0)

	useEffect(() => {
		pulse.set(withRepeat(withTiming(1, { duration: 800 }), -1, true))
	}, [pulse])

	const style = useAnimatedStyle(() => ({
		opacity: 0.5 + pulse.get() * 0.5,
	}))

	return (
		<Animated.View
			className={cn('rounded-sm bg-recessed', className)}
			style={style}
		/>
	)
}

/** @deprecated Use `SkeletonLine` */
export const Skeleton = SkeletonLine
