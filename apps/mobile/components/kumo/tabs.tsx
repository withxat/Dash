import type { LayoutChangeEvent } from 'react-native'

import type { KumoSize } from './types'

import { useEffect, useState } from 'react'
import { Pressable, Text, View } from 'react-native'
import Animated, {
	useAnimatedStyle,
	useSharedValue,
	withTiming,
} from 'react-native-reanimated'

import { thumbShadowStyle } from '../../lib/shadow'
import { useTheme } from '../../lib/theme'
import { cn } from './cn'

export interface TabOption<T extends string> {
	label: string
	value: T
}

interface TabsProps<T extends string> {
	className?: string
	onChange: (value: T) => void
	options: Array<TabOption<T>>
	size?: KumoSize
	value: T
	variant?: 'segmented' | 'underline'
}

/** Kumo segmented tabs — stratus sizing aligned with web Kumo Tabs. */
const SIZE = {
	base: {
		fontSize: 'text-base' as const,
		height: 36,
		innerRadius: 8,
		insetY: 2,
		outerRadius: 9,
		paddingX: 2,
		tabRadius: 6,
	},
	lg: {
		fontSize: 'text-base' as const,
		height: 36,
		innerRadius: 8,
		insetY: 2,
		outerRadius: 9,
		paddingX: 2,
		tabRadius: 6,
	},
	sm: {
		fontSize: 'text-xs' as const,
		height: 26,
		innerRadius: 6,
		insetY: 2,
		outerRadius: 7,
		paddingX: 2,
		tabRadius: 4,
	},
	xs: {
		fontSize: 'text-xs' as const,
		height: 26,
		innerRadius: 6,
		insetY: 2,
		outerRadius: 7,
		paddingX: 2,
		tabRadius: 4,
	},
} as const

const RING = 1

function SegmentedTabs<T extends string>({
	className,
	onChange,
	options,
	size = 'base',
	value,
}: Omit<TabsProps<T>, 'variant'>) {
	const theme = useTheme()
	const dims = SIZE[size]
	const selectedIndex = Math.max(0, options.findIndex(option => option.value === value))
	const [rowWidth, setRowWidth] = useState(0)
	const segmentWidth = rowWidth > 0 ? rowWidth / options.length : 0
	const progress = useSharedValue(selectedIndex)

	useEffect(() => {
		progress.set(withTiming(selectedIndex, { duration: 150 }))
	}, [progress, selectedIndex])

	const onRowLayout = (event: LayoutChangeEvent) => {
		setRowWidth(event.nativeEvent.layout.width)
	}

	const indicatorStyle = useAnimatedStyle(() => ({
		transform: [{ translateX: progress.get() * segmentWidth }],
		width: segmentWidth,
	}))

	return (
		<View className={className} style={{ alignSelf: 'stretch' }}>
			<View
				style={{
					backgroundColor: theme.hairline,
					borderCurve: 'continuous',
					borderRadius: dims.outerRadius,
					padding: RING,
				}}
			>
				<View
					style={{
						backgroundColor: theme.recessed,
						borderCurve: 'continuous',
						borderRadius: dims.innerRadius,
						height: dims.height,
						overflow: 'hidden',
						paddingHorizontal: dims.paddingX,
					}}
				>
					<View
						style={{
							flex: 1,
							flexDirection: 'row',
							marginVertical: dims.insetY,
							position: 'relative',
						}}
						onLayout={onRowLayout}
					>
						{segmentWidth > 0
							? (
									<Animated.View
										style={[
											{
												backgroundColor: theme.base,
												borderCurve: 'continuous',
												borderRadius: dims.tabRadius,
												bottom: 0,
												left: 0,
												position: 'absolute',
												top: 0,
											},
											thumbShadowStyle(theme),
											indicatorStyle,
										]}
										pointerEvents="none"
									/>
								)
							: null}
						{options.map(option => (
							<Pressable
								accessibilityRole="button"
								accessibilityState={{ selected: value === option.value }}
								className="z-10 min-w-0 flex-1 items-center justify-center px-2"
								key={option.value}
								onPress={() => onChange(option.value)}
							>
								<Text
									className={cn(
										'font-medium',
										dims.fontSize,
										value === option.value ? 'text-default' : 'text-subtle',
									)}
									numberOfLines={1}
								>
									{option.label}
								</Text>
							</Pressable>
						))}
					</View>
				</View>
			</View>
		</View>
	)
}

/** Kumo Tabs — recessed segmented control or underline tab strip (no native UISegmentedControl). */
export function Tabs<T extends string>({
	className,
	onChange,
	options,
	size = 'base',
	value,
	variant = 'segmented',
}: TabsProps<T>) {
	const dims = SIZE[size]

	if (variant === 'underline') {
		return (
			<View className={cn('flex-row border-b border-hairline', className)}>
				{options.map(option => (
					<Pressable
						className={cn(
							'border-b-2 px-4 py-2',
							value === option.value ? 'border-brand' : 'border-transparent',
						)}
						key={option.value}
						onPress={() => onChange(option.value)}
					>
						<Text
							className={cn(
								'font-medium',
								dims.fontSize,
								value === option.value ? 'text-brand' : 'text-subtle',
							)}
						>
							{option.label}
						</Text>
					</Pressable>
				))}
			</View>
		)
	}

	return (
		<SegmentedTabs
			className={className}
			onChange={onChange}
			options={options}
			size={size}
			value={value}
		/>
	)
}
