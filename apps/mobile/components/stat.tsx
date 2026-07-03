import { Text, View } from 'react-native'

import { cx } from '../lib/cx'

interface StatProps {
	className?: string
	/** Optional sub-label shown under the value (e.g. a unit or delta). */
	hint?: string
	label: string
	value: string
}

/** A labeled metric: subtle label + a large value. */
export function Stat({ className, hint, label, value }: StatProps) {
	return (
		<View className={cx('gap-1', className)}>
			<Text className="text-sm text-subtle">{label}</Text>
			<Text className="text-lg font-semibold text-strong">{value}</Text>
			{hint ? <Text className="text-xs text-subtle">{hint}</Text> : null}
		</View>
	)
}
