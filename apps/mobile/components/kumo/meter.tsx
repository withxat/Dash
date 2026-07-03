import { Text, View } from 'react-native'

import { cn } from './cn'

interface MeterProps {
	className?: string
	label?: string
	max?: number
	value: number
}

/** Kumo Meter — horizontal progress bar. */
export function Meter({ className, label, max = 100, value }: MeterProps) {
	const clamped = Math.max(0, Math.min(max, value))
	const percent = max > 0 ? (clamped / max) * 100 : 0

	return (
		<View className={cn('gap-1.5', className)}>
			{label
				? (
						<View className="flex-row items-center justify-between">
							<Text className="text-sm text-default">{label}</Text>
							<Text className="text-xs text-subtle">{`${Math.round(percent)}%`}</Text>
						</View>
					)
				: null}
			<View className="h-2 overflow-hidden rounded-full bg-recessed">
				<View
					className="h-full rounded-full bg-brand"
					style={{ width: `${percent}%` }}
				/>
			</View>
		</View>
	)
}
