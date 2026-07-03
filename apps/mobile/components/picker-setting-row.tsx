import { ActivityIndicator, View } from 'react-native'

import { useTheme } from '../lib/theme'
import { Select } from './kumo/select'

export interface PickerOption<T extends number | string> {
	label: string
	value: T
}

interface PickerSettingRowProps<T extends number | string> {
	disabled?: boolean
	loading?: boolean
	onChange: (value: T) => void
	options: Array<PickerOption<T>>
	subtitle?: string
	title: string
	value: T
}

/** Enum setting — Kumo Select dropdown. */
export function PickerSettingRow<T extends number | string>({
	disabled = false,
	loading = false,
	onChange,
	options,
	subtitle,
	title,
	value,
}: PickerSettingRowProps<T>) {
	const theme = useTheme()

	return (
		<View className="py-3">
			{loading
				? <ActivityIndicator color={theme.brand} />
				: (
						<Select
							description={subtitle}
							disabled={disabled}
							label={title}
							onChange={onChange}
							options={options}
							value={value}
						/>
					)}
		</View>
	)
}
