import type { ReactNode } from 'react'

import { Text, View } from 'react-native'

import { cn } from './cn'

interface TooltipProps {
	children: ReactNode
	className?: string
	/** On mobile, surfaced via accessibility hint on the child wrapper. */
	label: string
}

/**
 * Kumo Tooltip — mobile stub. Pass `accessibilityHint` through the child or
 * use a `Banner` for persistent helper text.
 */
export function Tooltip({ children, className, label }: TooltipProps) {
	return (
		<View accessibilityHint={label} className={className}>
			{children}
		</View>
	)
}

export function TooltipContent({ children, className }: { children: ReactNode, className?: string }) {
	return (
		<View className={cn('rounded-kumo border border-line bg-elevated px-2 py-1', className)}>
			<Text className="text-xs text-default">{children}</Text>
		</View>
	)
}
