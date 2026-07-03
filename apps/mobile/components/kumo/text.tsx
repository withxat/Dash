import type { ReactNode } from 'react'

import { Text as RNText } from 'react-native'

import { cn } from './cn'

export type TextVariant = 'body' | 'caption' | 'heading' | 'mono' | 'strong'
export type TextSize = 'base' | 'lg' | 'sm' | 'xs'

interface KumoTextProps {
	children: ReactNode
	className?: string
	muted?: boolean
	size?: TextSize
	variant?: TextVariant
}

const sizeClasses: Record<TextSize, string> = {
	base: 'text-base',
	lg: 'text-lg',
	sm: 'text-sm',
	xs: 'text-xs',
}

const variantClasses: Record<TextVariant, string> = {
	body: 'font-normal text-default',
	caption: 'font-normal text-subtle',
	heading: 'font-semibold text-strong',
	mono: 'font-mono text-default',
	strong: 'font-medium text-strong',
}

/** Kumo Text — typography primitive with semantic variants. */
export function KumoText({
	children,
	className,
	muted = false,
	size = 'base',
	variant = 'body',
}: KumoTextProps) {
	return (
		<RNText
			className={cn(
				sizeClasses[size],
				muted ? 'text-subtle' : variantClasses[variant],
				className,
			)}
		>
			{children}
		</RNText>
	)
}

/** Alias matching Kumo export name. */
export { KumoText as Text }
