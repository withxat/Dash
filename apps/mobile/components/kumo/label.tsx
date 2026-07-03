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

/** Section heading above grouped lists (Items categories, Home shortcuts, …). */
export function SectionLabel({ children, className }: LabelProps) {
	// Explicit family + size — tailwind text-* utilities only pick up fontFamily from chillFontPlugin.
	return (
		<Text
			className={cn('text-default', className)}
			style={{ fontFamily: 'ChillRoundGothic_Bold', fontSize: 22, lineHeight: 28 }}
		>
			{children}
		</Text>
	)
}
