import type { ReactNode } from 'react'

import { View } from 'react-native'

import { cn } from './cn'

interface ToolbarProps {
	children: ReactNode
	className?: string
}

/** Kumo Toolbar — horizontal control surface for actions. */
export function Toolbar({ children, className }: ToolbarProps) {
	return (
		<View
			className={cn(
				'flex-row flex-wrap items-center gap-2 rounded-kumo border border-line bg-control p-2',
				className,
			)}
			style={{ borderCurve: 'continuous' }}
		>
			{children}
		</View>
	)
}

export function ToolbarGroup({ children, className }: ToolbarProps) {
	return (
		<View className={cn('flex-row items-center gap-1', className)}>
			{children}
		</View>
	)
}

export function ToolbarSeparator({ className }: { className?: string }) {
	return <View className={cn('h-6 w-px bg-hairline', className)} />
}
