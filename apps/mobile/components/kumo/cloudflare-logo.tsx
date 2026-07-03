import { Text, View } from 'react-native'

import { cn } from './cn'

interface CloudflareLogoProps {
	className?: string
	size?: 'lg' | 'md' | 'sm'
}

const sizeClasses = {
	lg: 'text-2xl',
	md: 'text-lg',
	sm: 'text-sm',
} as const

/** Kumo CloudflareLogo — text mark for mobile (no SVG asset yet). */
export function CloudflareLogo({ className, size = 'md' }: CloudflareLogoProps) {
	return (
		<View className={cn('flex-row items-center gap-1', className)}>
			<Text className={cn('font-semibold text-brand', sizeClasses[size])}>cloudflare</Text>
		</View>
	)
}
