import type { ReactNode } from 'react'

import { Text, View } from 'react-native'

import { cn } from './cn'
import { Label } from './label'

interface FieldProps {
	children: ReactNode
	className?: string
	description?: string
	error?: string
	label?: string
}

/** Kumo Field — groups label, control, description, and error text. */
export function Field({ children, className, description, error, label }: FieldProps) {
	return (
		<View className={cn('gap-1.5', className)}>
			{label ? <Label>{label}</Label> : null}
			{description
				? <Text className="text-xs text-subtle">{description}</Text>
				: null}
			{children}
			{error ? <Text className="text-xs text-danger">{error}</Text> : null}
		</View>
	)
}
