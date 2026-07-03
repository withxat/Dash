import { ActivityIndicator, Text, View } from 'react-native'

import { useTheme } from '../lib/theme'
import { Switch } from './switch'

interface SettingRowProps {
	disabled?: boolean
	/** Show a spinner instead of the switch while a mutation is in flight. */
	loading?: boolean
	onValueChange: (value: boolean) => void
	subtitle?: string
	title: string
	value: boolean
}

/** A titled row with a trailing Kumo-style switch. */
export function SettingRow({
	disabled = false,
	loading = false,
	onValueChange,
	subtitle,
	title,
	value,
}: SettingRowProps) {
	const theme = useTheme()

	return (
		<View className="flex-row items-center justify-between gap-3 py-3">
			<View className="min-w-0 flex-1 gap-0.5">
				<Text className="font-medium text-default">{title}</Text>
				{subtitle
					? <Text className="text-xs text-subtle">{subtitle}</Text>
					: null}
			</View>
			{loading
				? <ActivityIndicator color={theme.brand} />
				: (
						<Switch
							checked={value}
							disabled={disabled}
							onCheckedChange={onValueChange}
						/>
					)}
		</View>
	)
}
