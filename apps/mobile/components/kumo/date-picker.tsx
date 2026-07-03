import { DatePicker as SwiftDatePicker } from '@expo/ui/swift-ui'
import { Platform, Text, View } from 'react-native'

import { isIOS } from '../../lib/is-ios'
import { NativeHost } from '../native-host'

interface DatePickerProps {
	className?: string
	displayedComponents?: Array<'date' | 'hourAndMinute'>
	onChange: (date: Date) => void
	value: Date
}

/** Kumo DatePicker — SwiftUI date picker on iOS; placeholder on Android. */
export function DatePicker({ className, displayedComponents = ['date'], onChange, value }: DatePickerProps) {
	if (isIOS) {
		return (
			<View className={className}>
				<NativeHost>
					<SwiftDatePicker
						displayedComponents={displayedComponents}
						onDateChange={onChange}
						selection={value}
					/>
				</NativeHost>
			</View>
		)
	}

	return (
		<View className={className}>
			<Text className="text-sm text-subtle">
				{`DatePicker — use a platform picker on ${Platform.OS}.`}
			</Text>
		</View>
	)
}
