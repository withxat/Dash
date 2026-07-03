import type { KumoSize } from './types'

import { ActivityIndicator, View } from 'react-native'

import { useTheme } from '../../lib/theme'
import { cn } from './cn'

interface LoaderProps {
	className?: string
	size?: KumoSize
}

const sizeMap: Record<KumoSize, 'large' | 'small'> = {
	base: 'small',
	lg: 'large',
	sm: 'small',
	xs: 'small',
}

/** Kumo Loader — centered activity indicator. */
export function Loader({ className, size = 'base' }: LoaderProps) {
	const theme = useTheme()
	return (
		<View className={cn('items-center justify-center py-4', className)}>
			<ActivityIndicator color={theme.brand} size={sizeMap[size]} />
		</View>
	)
}
