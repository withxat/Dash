import { Pressable, Text, View } from 'react-native'

import { cn } from './cn'

interface CheckboxProps {
	checked: boolean
	className?: string
	disabled?: boolean
	label?: string
	onCheckedChange: (checked: boolean) => void
}

/** Kumo Checkbox — custom square control with brand fill when checked. */
export function Checkbox({
	checked,
	className,
	disabled = false,
	label,
	onCheckedChange,
}: CheckboxProps) {
	return (
		<Pressable
			accessibilityRole="checkbox"
			accessibilityState={{ checked, disabled }}
			className={cn('flex-row items-center gap-2', disabled && 'opacity-50', className)}
			disabled={disabled}
			onPress={() => onCheckedChange(!checked)}
		>
			<View
				className={cn(
					'size-4 items-center justify-center rounded border',
					checked ? 'border-brand bg-brand' : 'border-line bg-control',
				)}
				style={{ borderCurve: 'continuous' }}
			>
				{checked
					? (
							<Text className="text-[10px] font-bold text-inverse">✓</Text>
						)
					: null}
			</View>
			{label
				? <Text className="text-base text-default">{label}</Text>
				: null}
		</Pressable>
	)
}
