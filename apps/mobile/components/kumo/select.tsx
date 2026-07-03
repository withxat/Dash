import type { KumoSize } from './types'

import { useEffect, useMemo, useState } from 'react'
import { Modal, Pressable, ScrollView, Text, useWindowDimensions, View } from 'react-native'
import Animated, {
	Easing,
	useAnimatedStyle,
	useSharedValue,
	withTiming,
} from 'react-native-reanimated'
import { useSafeAreaInsets } from 'react-native-safe-area-context'

import { overlayShadowStyle } from '../../lib/shadow'
import { tabBarOverlayBottom } from '../../lib/tab-bar'
import { useTheme } from '../../lib/theme'
import { CaretUpDownIcon, CheckIcon } from '../icons'
import { cn } from './cn'
import { Field } from './field'

export interface SelectOption<T extends number | string = string> {
	label: string
	value: T
}

interface SelectProps<T extends number | string = string> {
	className?: string
	description?: string
	disabled?: boolean
	error?: string
	label?: string
	onChange: (value: T) => void
	options: Array<SelectOption<T>>
	placeholder?: string
	size?: KumoSize
	value: T
}

const TRIGGER_HEIGHT: Record<KumoSize, number> = {
	base: 36,
	lg: 40,
	sm: 26,
	xs: 20,
}

const CARET_SIZE: Record<KumoSize, number> = {
	base: 16,
	lg: 18,
	sm: 14,
	xs: 12,
}

/** Matches Kumo Select option row + floating panel chrome. */
const OPTION_ROW_HEIGHT = 44
const PANEL_VERTICAL_PADDING = 12
const FLOATING_INSET_X = 16

function panelHeight(optionCount: number, windowHeight: number) {
	const contentHeight = optionCount * OPTION_ROW_HEIGHT + PANEL_VERTICAL_PADDING
	const maxHeight = Math.round(windowHeight * 0.55)
	return Math.min(contentHeight, maxHeight)
}

/** Kumo Select — control trigger with floating option panel above the tab bar. */
export function Select<T extends number | string = string>({
	className,
	description,
	disabled = false,
	error,
	label,
	onChange,
	options,
	placeholder = 'Select',
	size = 'base',
	value,
}: SelectProps<T>) {
	const theme = useTheme()
	const insets = useSafeAreaInsets()
	const { height: windowHeight } = useWindowDimensions()
	const [open, setOpen] = useState(false)
	const selected = useMemo(
		() => options.find(option => option.value === value),
		[options, value],
	)
	const listHeight = panelHeight(options.length, windowHeight)
	const floatingBottom = tabBarOverlayBottom(insets.bottom)
	const sheetProgress = useSharedValue(0)

	useEffect(() => {
		if (open) {
			sheetProgress.set(withTiming(1, {
				duration: 320,
				easing: Easing.out(Easing.cubic),
			}))
		}
		else {
			sheetProgress.set(0)
		}
	}, [open, sheetProgress])

	const sheetAnimatedStyle = useAnimatedStyle(() => {
		const progress = sheetProgress.get()
		return {
			opacity: progress,
			transform: [
				{ translateY: (1 - progress) * 36 },
				{ scale: 0.94 + progress * 0.06 },
			],
		}
	})

	const close = () => setOpen(false)

	const trigger = (
		<Pressable
			className={cn(
				'flex-row items-center justify-between gap-2 rounded-kumo border border-line bg-elevated px-3',
				disabled && 'opacity-50',
				className,
			)}
			style={{
				borderCurve: 'continuous',
				height: TRIGGER_HEIGHT[size],
			}}
			accessibilityRole="button"
			accessibilityState={{ disabled }}
			disabled={disabled}
			onPress={() => setOpen(true)}
		>
			<Text
				className={cn(
					'min-w-0 flex-1 text-base font-normal',
					selected ? 'text-default' : 'text-placeholder',
				)}
				numberOfLines={1}
			>
				{selected?.label ?? placeholder}
			</Text>
			<CaretUpDownIcon color={theme.subtle} size={CARET_SIZE[size]} />
		</Pressable>
	)

	const optionList = options.map((option) => {
		const active = option.value === value
		return (
			<Pressable
				className={cn(
					`
						mx-1.5 min-h-11 flex-row items-center justify-between gap-3 rounded-kumo px-2 py-1.5
						active:bg-elevated
					`,
					active && 'bg-tint',
				)}
				onPress={() => {
					onChange(option.value)
					close()
				}}
				accessibilityRole="button"
				accessibilityState={{ selected: active }}
				key={String(option.value)}
				style={{ borderCurve: 'continuous' }}
			>
				<Text className="min-w-0 flex-1 text-base text-default" numberOfLines={2}>
					{option.label}
				</Text>
				{active
					? <CheckIcon color={theme.brand} size={20} />
					: <View className="size-5" />}
			</Pressable>
		)
	})

	const sheet = (
		<Modal
			animationType="fade"
			onRequestClose={close}
			visible={open}
			statusBarTranslucent
			transparent
		>
			<View className="flex-1">
				<Pressable
					accessibilityLabel="Close"
					accessibilityRole="button"
					className="absolute inset-0 bg-black/40"
					onPress={close}
				/>
				<View
					style={{
						paddingBottom: floatingBottom,
						paddingHorizontal: FLOATING_INSET_X,
					}}
					className="flex-1 justify-end"
					pointerEvents="box-none"
				>
					<Animated.View
						style={[
							sheetAnimatedStyle,
							overlayShadowStyle(theme),
							{
								borderCurve: 'continuous',
								height: listHeight,
							},
						]}
						className="w-full overflow-hidden rounded-kumo border border-line bg-base py-1.5"
					>
						<ScrollView
							contentContainerStyle={{ paddingBottom: 8 }}
							keyboardShouldPersistTaps="handled"
							showsVerticalScrollIndicator={options.length > 6}
							style={{ flex: 1 }}
						>
							{optionList}
						</ScrollView>
					</Animated.View>
				</View>
			</View>
		</Modal>
	)

	if (label) {
		return (
			<Field description={description} error={error} label={label}>
				{trigger}
				{sheet}
			</Field>
		)
	}

	return (
		<>
			{trigger}
			{sheet}
		</>
	)
}
