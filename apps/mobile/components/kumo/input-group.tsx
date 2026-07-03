import type { ReactNode } from 'react'

import { View } from 'react-native'

import { cn } from './cn'

interface InputGroupProps {
	children: ReactNode
	className?: string
}

/** Kumo InputGroup — horizontal cluster of inputs or adornments. */
export function InputGroup({ children, className }: InputGroupProps) {
	return (
		<View
			className={cn('flex-row items-stretch overflow-hidden rounded-kumo border border-line', className)}
			style={{ borderCurve: 'continuous' }}
		>
			{children}
		</View>
	)
}

interface InputGroupSlotProps {
	children: ReactNode
	className?: string
}

export function InputGroupPrefix({ children, className }: InputGroupSlotProps) {
	return (
		<View className={cn('items-center justify-center border-r border-hairline bg-elevated px-3', className)}>
			{children}
		</View>
	)
}

export function InputGroupSuffix({ children, className }: InputGroupSlotProps) {
	return (
		<View className={cn('items-center justify-center border-l border-hairline bg-elevated px-3', className)}>
			{children}
		</View>
	)
}
