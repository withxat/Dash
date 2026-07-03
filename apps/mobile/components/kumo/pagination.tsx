import { Pressable, Text, View } from 'react-native'

import { Button, ButtonText } from './button'
import { cn } from './cn'

interface PaginationProps {
	className?: string
	onPageChange: (page: number) => void
	page: number
	totalPages: number
}

/** Kumo Pagination — previous / next controls with page indicator. */
export function Pagination({ className, onPageChange, page, totalPages }: PaginationProps) {
	const canPrev = page > 1
	const canNext = page < totalPages

	return (
		<View className={cn('flex-row items-center justify-between gap-3', className)}>
			<Button
				disabled={!canPrev}
				onPress={() => onPageChange(page - 1)}
				size="sm"
				variant="secondary"
			>
				<ButtonText>Previous</ButtonText>
			</Button>
			<Text className="text-sm text-subtle">{`${page} / ${totalPages}`}</Text>
			<Button
				disabled={!canNext}
				onPress={() => onPageChange(page + 1)}
				size="sm"
				variant="secondary"
			>
				<ButtonText>Next</ButtonText>
			</Button>
		</View>
	)
}

/** Individual page button for custom layouts. */
export function PaginationItem({
	active = false,
	children,
	onPress,
}: {
	active?: boolean
	children: string
	onPress: () => void
}) {
	return (
		<Pressable
			className={cn(
				'min-w-8 items-center rounded-kumo px-2 py-1',
				active ? 'bg-brand' : 'bg-control',
			)}
			onPress={onPress}
			style={{ borderCurve: 'continuous' }}
		>
			<Text className={cn('text-sm font-medium', active ? 'text-inverse' : 'text-default')}>
				{children}
			</Text>
		</Pressable>
	)
}
