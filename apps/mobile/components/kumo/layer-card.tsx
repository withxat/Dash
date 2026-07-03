import type { ReactNode } from 'react'

import { StyleSheet, View } from 'react-native'

import { cardShadowStyle } from '../../lib/shadow'
import { useTheme } from '../../lib/theme'
import { cn } from './cn'
import { ListCardLabel } from './label'

/** Matches `border` / `border-line` — list negative margin uses the same value. */
const CARD_BORDER_WIDTH = StyleSheet.hairlineWidth

interface LayerCardFrameProps {
	bordered?: boolean
	children: ReactNode
	className?: string
	elevated?: boolean
	shadow?: boolean
}

/** Outer shell — one border around header + list. */
export function LayerCardFrame({
	bordered = true,
	children,
	className,
	elevated = false,
	shadow = true,
}: LayerCardFrameProps) {
	const theme = useTheme()

	return (
		<View
			className={cn(
				'overflow-hidden rounded-kumo bg-elevated',
				bordered ? 'border border-line' : 'border-0',
				className,
			)}
			style={shadow ? cardShadowStyle(theme, elevated) : undefined}
		>
			{children}
		</View>
	)
}

interface LayerCardHeaderProps {
	className?: string
	headerAction?: ReactNode
	title: string
}

/** Title band — no border; outer frame provides the outline. */
export function LayerCardHeader({ className, headerAction, title }: LayerCardHeaderProps) {
	return (
		<View className={cn('px-4 py-3', className)}>
			<View className="flex-row items-center justify-between gap-3">
				<ListCardLabel>{title}</ListCardLabel>
				{headerAction ?? null}
			</View>
		</View>
	)
}

interface LayerCardSectionProps {
	bordered?: boolean
	children: ReactNode
	className?: string
}

/**
 * List panel with its own border. Negative margin pulls the list border onto the
 * card border so both share one line; inner content width matches the card's.
 */
export function LayerCardInsetBody({ bordered = true, children, className }: LayerCardSectionProps) {
	if (!bordered) {
		return (
			<View className={cn('overflow-hidden rounded-t-kumo bg-base', className)} style={{ borderCurve: 'continuous' }}>
				{children}
			</View>
		)
	}

	return (
		<View
			style={{
				borderCurve: 'continuous',
				marginBottom: -CARD_BORDER_WIDTH,
				marginHorizontal: -CARD_BORDER_WIDTH,
			}}
			className={cn('overflow-hidden rounded-b-kumo rounded-t-kumo border border-line bg-base', className)}
		>
			{children}
		</View>
	)
}

interface LayerCardProps {
	bordered?: boolean
	children: ReactNode
	className?: string
	elevated?: boolean
	headerAction?: ReactNode
	insetClassName?: string
	shadow?: boolean
	title?: string
}

/** Kumo LayerCard — bordered base surface with soft elevation. */
export function LayerCard({
	bordered = true,
	children,
	className,
	elevated = false,
	headerAction,
	insetClassName,
	shadow = true,
	title,
}: LayerCardProps) {
	const theme = useTheme()
	const hasHeader = Boolean(title)

	if (!hasHeader) {
		return (
			<View
				className={cn(
					'overflow-hidden rounded-kumo bg-base p-4',
					bordered ? 'border border-line' : 'border-0',
					className,
				)}
				style={shadow ? cardShadowStyle(theme, elevated) : undefined}
			>
				{children}
			</View>
		)
	}

	return (
		<LayerCardFrame bordered={bordered} className={className} elevated={elevated} shadow={shadow}>
			<LayerCardHeader headerAction={headerAction} title={title!} />
			<LayerCardInsetBody bordered={bordered} className={insetClassName ?? 'p-4'}>
				{children}
			</LayerCardInsetBody>
		</LayerCardFrame>
	)
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
