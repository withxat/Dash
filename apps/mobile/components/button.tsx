import type { PressableProps } from 'react-native'

import { ActivityIndicator, Pressable, Text } from 'react-native'

/** Minimal className combiner (filters falsy parts and joins with spaces). */
function cx(...parts: Array<false | null | string | undefined>): string {
	return parts.filter((p): p is string => Boolean(p)).join(' ')
}

type Variant = 'ghost' | 'outline' | 'primary'
type Size = 'lg' | 'md'

interface ButtonProps extends Omit<PressableProps, 'children'> {
	children: string
	loading?: boolean
	size?: Size
	variant?: Variant
}

const containerBase
	= 'flex-row items-center justify-center rounded-2xl gap-2 active:opacity-80'

const containerVariants: Record<Variant, string> = {
	ghost: 'bg-transparent',
	outline: 'border border-canvas-muted bg-transparent',
	primary: 'bg-brand',
}

const sizeVariants: Record<Size, string> = {
	lg: 'px-6 py-4',
	md: 'px-4 py-3',
}

const textVariants: Record<Variant, string> = {
	ghost: 'text-white font-semibold',
	outline: 'text-white font-semibold',
	primary: 'text-brand-foreground font-semibold',
}

export function Button({
	children,
	className,
	disabled,
	loading = false,
	size = 'md',
	variant = 'primary',
	...props
}: ButtonProps) {
	return (
		<Pressable
			className={cx(
				containerBase,
				containerVariants[variant],
				sizeVariants[size],
				(disabled || loading) && 'opacity-50',
				className,
			)}
			accessibilityRole="button"
			disabled={disabled || loading}
			{...props}
		>
			{loading
				? (
						<ActivityIndicator color="#fff" />
					)
				: (
						<Text className={textVariants[variant]}>{children}</Text>
					)}
		</Pressable>
	)
}
