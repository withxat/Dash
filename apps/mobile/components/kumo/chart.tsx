import type { LayoutChangeEvent } from 'react-native'

import { Chart } from '@expo/ui/swift-ui'
import { frame } from '@expo/ui/swift-ui/modifiers'
import { useMemo, useState } from 'react'
import { Text, View } from 'react-native'

import { colorWithAlpha } from '../../lib/color'
import { isIOS } from '../../lib/is-ios'
import { useTheme } from '../../lib/theme'
import { NativeHost } from '../native-host'

export interface BarChartPoint {
	/** Short label rendered on the x-axis (e.g. a day or hour). */
	label: string
	/** Non-negative magnitude. Bars are scaled relative to the max. */
	value: number
}

/** @deprecated Use `BarChartPoint` */
export type Bar = BarChartPoint

interface BarChartProps {
	/** Bar fill color. Defaults to theme brand. */
	color?: string
	data: BarChartPoint[]
	/** Format the peak value shown above the chart. */
	formatValue?: (value: number) => string
	/** Fixed pixel height of the chart area. */
	height?: number
	/** Bar fill opacity when using the default brand color. */
	opacity?: number
}

function FallbackBarChart({
	barColor,
	data,
	formatValue,
	height,
}: {
	barColor: string
	data: BarChartPoint[]
	formatValue?: (value: number) => string
	height: number
}) {
	const max = Math.max(1, ...data.map(d => d.value))
	const peak = Math.max(0, ...data.map(d => d.value))

	return (
		<View className="gap-1.5">
			{formatValue
				? (
						<Text className="text-[10px] text-placeholder">
							{`peak ${formatValue(peak)}`}
						</Text>
					)
				: null}
			<View className="flex-row items-end gap-1" style={{ height }}>
				{data.map((d, i) => (
					// eslint-disable-next-line react/no-array-index-key -- bars are positional, values/labels can repeat
					<View className="h-full flex-1 flex-col items-center justify-end gap-1" key={i}>
						<View
							style={{
								backgroundColor: barColor,
								height: `${Math.max(3, (d.value / max) * 100)}%`,
							}}
							className="w-full rounded-t-sm"
						/>
						<Text className="max-w-full text-[9px] text-placeholder" numberOfLines={1}>
							{d.label}
						</Text>
					</View>
				))}
			</View>
		</View>
	)
}

/**
 * Kumo Chart (bar) — SwiftUI Charts on iOS; plain View fallback on Android.
 */
export function BarChart({
	color,
	data,
	formatValue,
	height = 140,
	opacity = 1,
}: BarChartProps) {
	const theme = useTheme()
	const barColor = color ?? colorWithAlpha(theme.brand, opacity)
	const peak = Math.max(0, ...data.map(d => d.value))
	const [chartWidth, setChartWidth] = useState(0)

	const chartModifiers = useMemo(
		() => (chartWidth > 0 ? [frame({ height, width: chartWidth })] : []),
		[chartWidth, height],
	)

	const onChartLayout = (event: LayoutChangeEvent) => {
		const nextWidth = event.nativeEvent.layout.width
		setChartWidth((prev) => {
			if (prev === nextWidth)
				return prev
			return nextWidth
		})
	}

	if (data.length === 0) {
		return (
			<View style={{ height }}>
				<View className="h-px w-full bg-hairline" style={{ marginTop: height - 1 }} />
			</View>
		)
	}

	return (
		<View className="w-full gap-1.5">
			{formatValue
				? (
						<Text className="text-[10px] text-placeholder">
							{`peak ${formatValue(peak)}`}
						</Text>
					)
				: null}
			{isIOS
				? (
						<View className="w-full" onLayout={onChartLayout} style={{ height }}>
							{chartModifiers.length > 0
								? (
										<NativeHost>
											<Chart
												data={data.map(point => ({
													color: barColor,
													x: point.label,
													y: point.value,
												}))}
												barStyle={{ cornerRadius: 4 }}
												modifiers={chartModifiers}
												showGrid={false}
												type="bar"
												animate
											/>
										</NativeHost>
									)
								: null}
						</View>
					)
				: (
						<FallbackBarChart
							barColor={barColor}
							data={data}
							formatValue={undefined}
							height={height}
						/>
					)}
		</View>
	)
}

/** Alias for Kumo `Chart` naming. */
export const ChartBar = BarChart
