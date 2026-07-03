import { Pressable, Text, View } from 'react-native'

import { cn } from './cn'

interface RadioOption<T extends string> {
	label: string
	value: T
}

interface RadioGroupProps<T extends string> {
	className?: string
	disabled?: boolean
	onChange: (value: T) => void
	options: Array<RadioOption<T>>
	value: T
}

/** Kumo RadioGroup — custom circular radio controls. */
export function RadioGroup<T extends string>({
	className,
	disabled = false,
	onChange,
	options,
	value,
}: RadioGroupProps<T>) {
	return (
		<View className={cn('gap-3', className)}>
			{options.map(option => (
				<Pressable
					accessibilityRole="radio"
					accessibilityState={{ checked: value === option.value, disabled }}
					className={cn('flex-row items-center gap-2', disabled && 'opacity-50')}
					disabled={disabled}
					key={option.value}
					onPress={() => onChange(option.value)}
				>
					<View
						className={cn(
							'size-4 items-center justify-center rounded-full border',
							value === option.value ? 'border-brand' : 'border-line',
						)}
					>
						{value === option.value
							? <View className="size-2 rounded-full bg-brand" />
							: null}
					</View>
					<Text className="text-base text-default">{option.label}</Text>
				</Pressable>
			))}
		</View>
	)
}

/** Single radio item for compound usage. */
export function RadioItem({
	checked,
	disabled = false,
	label,
	onPress,
}: {
	checked: boolean
	disabled?: boolean
	label: string
	onPress: () => void
}) {
	return (
		<Pressable
			accessibilityRole="radio"
			accessibilityState={{ checked, disabled }}
			className={cn('flex-row items-center gap-2', disabled && 'opacity-50')}
			disabled={disabled}
			onPress={onPress}
		>
			<View
				className={cn(
					'size-4 items-center justify-center rounded-full border',
					checked ? 'border-brand' : 'border-line',
				)}
			>
				{checked ? <View className="size-2 rounded-full bg-brand" /> : null}
			</View>
			<Text className="text-base text-default">{label}</Text>
		</Pressable>
	)
}
