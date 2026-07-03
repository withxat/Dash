import { Pressable, Text, View } from 'react-native'

import { cn } from './cn'

export interface TocItem {
	id: string
	label: string
	level?: 1 | 2 | 3
	onPress?: () => void
}

interface TableOfContentsProps {
	className?: string
	items: TocItem[]
}

/** Kumo TableOfContents — scrollable anchor list for long screens. */
export function TableOfContents({ className, items }: TableOfContentsProps) {
	return (
		<View className={cn('gap-1', className)}>
			{items.map(item => (
				<Pressable
					className={cn(
						'py-1',
						item.level === 2 && 'pl-3',
						item.level === 3 && 'pl-6',
					)}
					key={item.id}
					onPress={item.onPress}
				>
					<Text className="text-sm text-brand">{item.label}</Text>
				</Pressable>
			))}
		</View>
	)
}
