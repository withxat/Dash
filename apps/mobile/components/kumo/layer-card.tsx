import type { ReactNode } from 'react'

import { View } from 'react-native'

import { cardShadowStyle } from '../../lib/shadow'
import { useTheme } from '../../lib/theme'
import { cn } from './cn'

interface LayerCardProps {
	/** Hairline border around the surface. */
	bordered?: boolean
	children: ReactNode
	className?: string
	/** Use a stronger shadow for grouped list surfaces. */
	elevated?: boolean
	/** Drop shadow. List surfaces disable this to avoid a faux edge beside row dividers. */
	shadow?: boolean
}

/** Kumo LayerCard — bordered base surface with soft elevation. */
export function LayerCard({
	bordered = true,
	children,
	className,
	elevated = false,
	shadow = true,
}: LayerCardProps) {
	const theme = useTheme()

	return (
		<View
			className={cn(
				'rounded-kumo bg-base p-4',
				bordered ? 'border border-line' : 'border-0',
				className,
			)}
			style={shadow ? cardShadowStyle(theme, elevated) : undefined}
		>
			{children}
		</View>
	)
}

interface LayerCardSectionProps {
	children: ReactNode
	className?: string
}

/** Secondary header band in a layered card layout. */
export function LayerCardSecondary({ children, className }: LayerCardSectionProps) {
	return (
		<View className={cn('-mx-4 -mt-4 mb-2 border-b border-hairline bg-elevated px-4 py-3', className)}>
			{children}
		</View>
	)
}

/** Primary content band in a layered card layout. */
export function LayerCardPrimary({ children, className }: LayerCardSectionProps) {
	return (
		<View className={cn('gap-2', className)}>
			{children}
		</View>
	)
}

/** @deprecated Use `LayerCard` */
export const Card = LayerCard
/** @deprecated Use `LayerCardSecondary` */
export const CardSecondary = LayerCardSecondary
/** @deprecated Use `LayerCardPrimary` */
export const CardPrimary = LayerCardPrimary
