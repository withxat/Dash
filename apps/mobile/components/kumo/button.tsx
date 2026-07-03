import type { ReactNode } from 'react'
import type { PressableProps } from 'react-native'

import { createContext, use } from 'react'
import { ActivityIndicator, Pressable, Text, View } from 'react-native'

import { cx } from '../../lib/cx'
import { useTheme } from '../../lib/theme'

type Variant = 'destructive' | 'ghost' | 'outline' | 'primary' | 'secondary' | 'secondary-destructive'
type Size = 'lg' | 'md' | 'sm'

interface ButtonProps extends Omit<PressableProps, 'children'> {
	children: ReactNode
	loading?: boolean
	size?: Size
	variant?: Variant
}

const containerBase
	= 'flex-row items-center justify-center gap-1.5 rounded-kumo active:opacity-80'

const containerVariants: Record<Variant, string> = {
	'destructive': 'border border-danger bg-danger',
	'ghost': 'bg-transparent',
	'outline': 'border border-line bg-transparent',
	'primary': 'border border-brand bg-brand',
	'secondary': 'border border-line bg-base',
	'secondary-destructive': 'border border-line bg-base',
}

const sizeVariants: Record<Size, string> = {
	lg: 'h-10 px-4',
	md: 'h-9 px-3',
	sm: 'h-6.5 px-2',
}

const textVariants: Record<Variant, string> = {
	'destructive': 'font-medium text-inverse',
	'ghost': 'font-medium text-default',
	'outline': 'font-medium text-default',
	'primary': 'font-medium text-inverse',
	'secondary': 'font-medium text-default',
	'secondary-destructive': 'font-medium text-danger',
}

const ButtonVariantContext = createContext<Variant>('secondary')

/**
 * Compound button: compose with `ButtonText` / `ButtonIcon` children.
 *
 * ```tsx
 * <Button onPress={save}><ButtonText>Save</ButtonText></Button>
 * ```
 */
export function Button({
	children,
	className,
	disabled,
	loading = false,
	size = 'md',
	variant = 'secondary',
	...props
}: ButtonProps) {
	const theme = useTheme()
	const spinnerColor = variant === 'primary' || variant === 'destructive'
		? theme.inverse
		: theme.default

	return (
		<ButtonVariantContext value={variant}>
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
				style={{ borderCurve: 'continuous' }}
				{...props}
			>
				{loading ? <ActivityIndicator color={spinnerColor} /> : children}
			</Pressable>
		</ButtonVariantContext>
	)
}

export function ButtonText({ children, className }: { children: ReactNode, className?: string }) {
	const variant = use(ButtonVariantContext)
	return <Text className={cx(textVariants[variant], 'text-base', className)}>{children}</Text>
}

export function ButtonIcon({ children }: { children: ReactNode }) {
	return <View>{children}</View>
}
