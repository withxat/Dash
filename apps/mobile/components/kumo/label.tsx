import type { ReactNode } from 'react'

import { Text } from 'react-native'

import { chillFaceStyle } from '../../lib/fonts'
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
		<Text
			className={cn('text-subtle', className)}
			style={chillFaceStyle('bold', { fontSize: 16, lineHeight: 22 })}
		>
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
			style={chillFaceStyle('bold', { fontSize: 22, lineHeight: 28 })}
		>
			{children}
		</Text>
	)
}
