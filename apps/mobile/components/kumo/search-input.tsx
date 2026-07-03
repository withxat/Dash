import type { TextInputProps } from 'react-native'

import { Platform, Pressable, TextInput, View } from 'react-native'

import { useTheme } from '../../lib/theme'
import { SearchIcon, XIcon } from '../icons'
import { cn } from './cn'
import { kumoRadiusStyle } from './radius'

interface SearchInputProps extends Omit<TextInputProps, 'onChangeText' | 'value'> {
	className?: string
	onChangeText: (text: string) => void
	value: string
}

/** Outer height of segmented Tabs (`base`) — inner track + hairline ring. */
const CONTROL_HEIGHT = 38
const FONT_SIZE = 14

/** iOS TextInput misaligns placeholder vs value when lineHeight > fontSize. */
const inputStyle = {
	fontSize: FONT_SIZE,
	paddingVertical: 0,
	...(Platform.OS === 'ios' ? { lineHeight: 0 } : {}),
} as const

/** Kumo search field — control surface with leading search icon and clear action. */
export function SearchInput({
	className,
	onChangeText,
	placeholder = 'Search',
	value,
	...props
}: SearchInputProps) {
	const theme = useTheme()

	return (
		<View
			className={cn(
				'relative flex-row items-center gap-2 border border-line bg-control px-3',
				className,
			)}
			style={{
				...kumoRadiusStyle,
				height: CONTROL_HEIGHT,
			}}
		>
			<SearchIcon color={theme.placeholder} size={16} />
			<TextInput
				className="min-w-0 flex-1 pr-7 text-default"
				clearButtonMode="never"
				onChangeText={onChangeText}
				placeholder={placeholder}
				placeholderTextColor={theme.placeholder}
				returnKeyType="search"
				style={inputStyle}
				value={value}
				{...props}
			/>
			{value.length > 0
				? (
						<Pressable
							className="
								absolute inset-y-0 right-3 w-7 items-center justify-center
								active:opacity-70
							"
							accessibilityLabel="Clear search"
							accessibilityRole="button"
							hitSlop={8}
							onPress={() => onChangeText('')}
						>
							<View
								className="size-5 items-center justify-center rounded-full bg-recessed"
								style={{ borderCurve: 'continuous' }}
							>
								<XIcon color={theme.subtle} size={12} strokeWidth={2.5} />
							</View>
						</Pressable>
					)
				: null}
		</View>
	)
}
