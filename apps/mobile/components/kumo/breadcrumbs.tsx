import { Pressable, Text, View } from 'react-native'

import { useTheme } from '../../lib/theme'
import { ChevronRightIcon } from '../icons'
import { cn } from './cn'

export interface BreadcrumbItem {
	id?: string
	label: string
	onPress?: () => void
}

interface BreadcrumbsProps {
	className?: string
	items: BreadcrumbItem[]
}

/** Kumo Breadcrumbs — horizontal path with chevron separators. */
export function Breadcrumbs({ className, items }: BreadcrumbsProps) {
	const theme = useTheme()

	return (
		<View className={cn('flex-row flex-wrap items-center gap-1', className)}>
			{items.map((item, index) => (
				<View className="flex-row items-center gap-1" key={item.id ?? item.label}>
					{index > 0
						? <ChevronRightIcon color={theme.placeholder} size={14} />
						: null}
					{item.onPress
						? (
								<Pressable onPress={item.onPress}>
									<Text className="text-sm font-medium text-brand">{item.label}</Text>
								</Pressable>
							)
						: (
								<Text className="text-sm text-subtle">{item.label}</Text>
							)}
				</View>
			))}
		</View>
	)
}
