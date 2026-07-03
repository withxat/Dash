import type { TextInputProps } from 'react-native'

import { useState } from 'react'
import { Pressable, Text, TextInput, View } from 'react-native'

import { useTheme } from '../../lib/theme'
import { cn } from './cn'

type SensitiveInputVariant = 'default' | 'error'

interface SensitiveInputProps extends Omit<TextInputProps, 'secureTextEntry'> {
	label?: string
	variant?: SensitiveInputVariant
}

/** Kumo SensitiveInput — password / secret field with reveal toggle. */
export function SensitiveInput({ className, label, variant = 'default', ...props }: SensitiveInputProps) {
	const theme = useTheme()
	const [visible, setVisible] = useState(false)

	return (
		<View className="gap-1.5">
			{label
				? <Text className="text-sm font-medium text-default">{label}</Text>
				: null}
			<View className="relative">
				<TextInput
					className={cn(
						'h-9 rounded-kumo border bg-control px-3 pr-16 text-base text-default',
						variant === 'error' ? 'border-danger' : 'border-line',
						className,
					)}
					placeholderTextColor={theme.placeholder}
					secureTextEntry={!visible}
					style={{ borderCurve: 'continuous' }}
					{...props}
				/>
				<Pressable
					className="absolute inset-y-0 right-0 justify-center px-3"
					onPress={() => setVisible(v => !v)}
				>
					<Text className="text-xs font-medium text-brand">
						{visible ? 'Hide' : 'Show'}
					</Text>
				</Pressable>
			</View>
		</View>
	)
}
