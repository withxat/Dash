import type { ReactNode } from 'react'

import Animated from 'react-native-reanimated'

import { fadeIn, fadeOut, layoutTransition } from '../lib/motion'

interface LayoutItemProps {
	children: ReactNode
}

/** Animated wrapper for a list row — enter/exit fade plus layout reflow. */
export function LayoutItem({ children }: LayoutItemProps) {
	return (
		<Animated.View entering={fadeIn} exiting={fadeOut} layout={layoutTransition}>
			{children}
		</Animated.View>
	)
}

interface LayoutGroupProps {
	children: ReactNode
}

/** Animated wrapper for a section that mounts/unmounts (e.g. conditional ListGroup). */
export function LayoutGroup({ children }: LayoutGroupProps) {
	return (
		<Animated.View entering={fadeIn} exiting={fadeOut} layout={layoutTransition}>
			{children}
		</Animated.View>
	)
}
