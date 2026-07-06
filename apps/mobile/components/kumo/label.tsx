import type { ReactNode } from 'react'

import { Text } from 'react-native'

import { cn } from './cn'

interface LabelProps {
	children: ReactNode
	className?: string
	htmlFor?: string
}

/** Kumo Label — field label above controls. */
export function Label({ children, className }: LabelProps) {
	return (
		<Text className={cn('text-sm font-medium text-default', className)}>
			{children}
		</Text>
	)
}

/** In-card section title for grouped lists (LayerCard header band). */
export function ListCardLabel({ children, className }: LabelProps) {
	return (
		<Text className={cn('text-base font-medium text-subtle', className)}>
			{children}
		</Text>
	)
}

/** Section heading above grouped lists (Items categories, Home shortcuts, …). */
export function SectionLabel({ children, className }: LabelProps) {
	return (
		<Text className={cn('text-2xl font-semibold text-default', className)}>
			{children}
		</Text>
	)
}
