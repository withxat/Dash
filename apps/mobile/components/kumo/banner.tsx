import type { ReactNode } from 'react'

import { Text, View } from 'react-native'

import { cn } from './cn'

export type BannerVariant = 'danger' | 'info' | 'success' | 'warning'

interface BannerProps {
	children: ReactNode
	className?: string
	title?: string
	variant?: BannerVariant
}

const variantClasses: Record<BannerVariant, string> = {
	danger: 'border-danger/30 bg-danger-tint/50',
	info: 'border-info/30 bg-info-tint/50',
	success: 'border-success/30 bg-success-tint/50',
	warning: 'border-warning/30 bg-warning-tint/50',
}

const titleClasses: Record<BannerVariant, string> = {
	danger: 'text-danger',
	info: 'text-info',
	success: 'text-success',
	warning: 'text-warning',
}

/** Kumo Banner — inline alert surface with semantic tint. */
export function Banner({ children, className, title, variant = 'info' }: BannerProps) {
	return (
		<View
			className={cn('gap-1 rounded-kumo border px-4 py-3', variantClasses[variant], className)}
			style={{ borderCurve: 'continuous' }}
		>
			{title
				? <Text className={cn('text-sm font-semibold', titleClasses[variant])}>{title}</Text>
				: null}
			<Text className="text-sm text-default">{children}</Text>
		</View>
	)
}
