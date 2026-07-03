import { Text, View } from 'react-native'

import { cx } from '../../lib/cx'

const BASE = 'flex-row items-center self-start rounded-full px-2 py-0.5'

export type BadgeAppearance = 'dot' | 'filled'

export type BadgeVariant
	= | 'beta'
		| 'blue'
		| 'error'
		| 'green'
		| 'info'
		| 'neutral'
		| 'orange'
		| 'outline'
		| 'primary'
		| 'purple'
		| 'red'
		| 'secondary'
		| 'success'
		| 'teal'
		| 'teal-subtle'
		| 'warning'

interface BadgeProps {
	appearance?: BadgeAppearance
	children: string
	className?: string
	/** Use a monospace font (e.g. DNS record types). */
	mono?: boolean
	variant?: BadgeVariant
}

const filledVariants: Record<BadgeVariant, { container: string, text: string }> = {
	'beta': {
		container: 'border border-dashed border-brand bg-transparent',
		text: 'text-brand',
	},
	'blue': {
		container: 'bg-badge-blue',
		text: 'text-inverse',
	},
	'error': {
		container: 'bg-danger-tint/60',
		text: 'text-danger',
	},
	'green': {
		container: 'bg-badge-green',
		text: 'text-inverse',
	},
	'info': {
		container: 'bg-info-tint/70',
		text: 'text-info',
	},
	'neutral': {
		container: 'bg-badge-neutral',
		text: 'text-inverse',
	},
	'orange': {
		container: 'bg-badge-orange',
		text: 'text-strong',
	},
	'outline': {
		container: 'border border-fill bg-transparent',
		text: 'text-default',
	},
	'primary': {
		container: 'bg-badge-inverted',
		text: 'text-badge-inverted-fg',
	},
	'purple': {
		container: 'bg-badge-purple',
		text: 'text-inverse',
	},
	'red': {
		container: 'bg-badge-red',
		text: 'text-inverse',
	},
	'secondary': {
		container: 'bg-fill',
		text: 'text-subtle',
	},
	'success': {
		container: 'bg-success-tint/70',
		text: 'text-success',
	},
	'teal': {
		container: 'bg-badge-teal',
		text: 'text-inverse',
	},
	'teal-subtle': {
		container: 'bg-badge-teal-subtle',
		text: 'text-badge-teal-subtle-fg',
	},
	'warning': {
		container: 'bg-warning-tint/70',
		text: 'text-warning',
	},
}

const dotColors: Partial<Record<BadgeVariant, string>> = {
	error: 'bg-badge-red',
	neutral: 'bg-badge-neutral',
	success: 'bg-success',
	warning: 'bg-badge-orange',
}

/** Small status label aligned with Kumo Badge variants. */
export function Badge({
	appearance = 'filled',
	children,
	className,
	mono = false,
	variant = 'primary',
}: BadgeProps) {
	const filled = filledVariants[variant]
	const dotClass = appearance === 'dot' ? dotColors[variant] : undefined

	return (
		<View
			className={cx(
				BASE,
				appearance === 'dot'
					? 'gap-1.5 border border-hairline bg-transparent'
					: filled.container,
				className,
			)}
			style={{ borderCurve: 'continuous' }}
		>
			{dotClass
				? <View className={cx('size-1.5 rounded-full', dotClass)} />
				: null}
			<Text
				className={cx(
					'text-xs font-medium',
					mono && 'font-mono',
					appearance === 'dot' ? 'text-default' : filled.text,
				)}
			>
				{children}
			</Text>
		</View>
	)
}

/** @deprecated Use `BadgeVariant` */
export type BadgeTone = BadgeVariant
