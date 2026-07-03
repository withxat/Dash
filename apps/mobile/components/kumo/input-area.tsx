import type { TextInputProps } from 'react-native'

import { TextInput } from 'react-native'

import { useTheme } from '../../lib/theme'
import { cn } from './cn'

type InputAreaVariant = 'default' | 'error'

interface InputAreaProps extends TextInputProps {
	mono?: boolean
	variant?: InputAreaVariant
}

/** Kumo InputArea — multiline control surface. */
export function InputArea({ className, mono = false, variant = 'default', ...props }: InputAreaProps) {
	const theme = useTheme()
	return (
		<TextInput
			className={cn(
				'min-h-24 rounded-kumo border bg-control px-3 py-2 text-base text-default',
				variant === 'error' ? 'border-danger' : 'border-line',
				mono && 'font-mono',
				className,
			)}
			placeholderTextColor={theme.placeholder}
			style={{ borderCurve: 'continuous', textAlignVertical: 'top' }}
			multiline
			{...props}
		/>
	)
}
