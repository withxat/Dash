import type { ReactNode } from 'react'

import { useEffect, useState } from 'react'
import { Pressable, Text } from 'react-native'
import Animated, {
	useAnimatedStyle,
	useSharedValue,
	withTiming,
} from 'react-native-reanimated'

import { collapseIn, collapseOut, layoutTransition } from '../../lib/motion'
import { useTheme } from '../../lib/theme'
import { ChevronRightIcon } from '../icons'
import { cn } from './cn'

interface CollapsibleProps {
	children: ReactNode
	className?: string
	defaultOpen?: boolean
	title: string
}

/** Kumo Collapsible — expandable section with chevron indicator. */
export function Collapsible({ children, className, defaultOpen = false, title }: CollapsibleProps) {
	const theme = useTheme()
	const [open, setOpen] = useState(defaultOpen)
	const rotation = useSharedValue(defaultOpen ? 90 : 0)

	useEffect(() => {
		rotation.set(withTiming(open ? 90 : 0, { duration: 200 }))
	}, [open, rotation])

	const chevronStyle = useAnimatedStyle(() => ({
		transform: [{ rotate: `${rotation.get()}deg` }],
	}))

	return (
		<Animated.View
			className={cn('overflow-hidden rounded-kumo border border-line bg-base', className)}
			layout={layoutTransition}
		>
			<Pressable
				className="flex-row items-center justify-between px-4 py-3"
				onPress={() => setOpen(v => !v)}
			>
				<Text className="text-base font-medium text-default">{title}</Text>
				<Animated.View style={chevronStyle}>
					<ChevronRightIcon color={theme.subtle} size={18} />
				</Animated.View>
			</Pressable>
			{open
				? (
						<Animated.View
							className="border-t border-hairline px-4 py-3"
							entering={collapseIn}
							exiting={collapseOut}
							layout={layoutTransition}
						>
							{children}
						</Animated.View>
					)
				: null}
		</Animated.View>
	)
}
