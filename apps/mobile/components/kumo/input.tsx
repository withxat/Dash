import type { TextInputProps } from 'react-native'

import { Text, TextInput, View } from 'react-native'

import { cx } from '../../lib/cx'
import { useTheme } from '../../lib/theme'

type InputVariant = 'default' | 'error'

interface InputProps extends TextInputProps {
	/** Optional label rendered above the field. */
	label?: string
	/** Use a monospace font (e.g. record content, IPs). */
	mono?: boolean
	variant?: InputVariant
}

/** Kumo Input — control surface with hairline ring and focus emphasis. */
export function Input({ className, label, mono = false, variant = 'default', ...props }: InputProps) {
	const theme = useTheme()
	return (
		<View className="gap-1.5">
			{label
				? <Text className="text-sm font-medium text-default">{label}</Text>
				: null}
			<TextInput
				className={cx(
					'h-9 rounded-kumo border bg-control px-3 text-base text-default',
					variant === 'error' ? 'border-danger' : 'border-line',
					mono && 'font-mono',
					className,
				)}
				placeholderTextColor={theme.placeholder}
				style={{ borderCurve: 'continuous' }}
				{...props}
			/>
		</View>
	)
}
