import type { ReactNode } from 'react'

import { Modal, Pressable, Text, View } from 'react-native'

import { overlayShadowStyle } from '../../lib/shadow'
import { useTheme } from '../../lib/theme'
import { cn } from './cn'

export interface DropdownItem {
	destructive?: boolean
	label: string
	onPress: () => void
}

interface DropdownProps {
	items: DropdownItem[]
	onOpenChange: (open: boolean) => void
	open: boolean
	title?: string
	trigger?: ReactNode
}

/** Kumo Dropdown — action sheet style menu on mobile. */
export function Dropdown({ items, onOpenChange, open, title }: DropdownProps) {
	const theme = useTheme()

	return (
		<Modal
			animationType="slide"
			onRequestClose={() => onOpenChange(false)}
			visible={open}
			transparent
		>
			<Pressable className="flex-1 justify-end bg-black/40" onPress={() => onOpenChange(false)}>
				<Pressable onPress={e => e.stopPropagation()}>
					<View
						className="gap-1 rounded-t-kumo border border-line bg-base p-2 pb-8"
						style={[overlayShadowStyle(theme), { borderCurve: 'continuous' }]}
					>
						{title
							? <Text className="px-3 py-2 text-sm font-semibold text-subtle">{title}</Text>
							: null}
						{items.map(item => (
							<Pressable
								className="
									rounded-kumo px-3 py-3
									active:bg-elevated
								"
								onPress={() => {
									onOpenChange(false)
									item.onPress()
								}}
								key={item.label}
							>
								<Text className={cn('text-base', item.destructive ? 'text-danger' : 'text-default')}>
									{item.label}
								</Text>
							</Pressable>
						))}
					</View>
				</Pressable>
			</Pressable>
		</Modal>
	)
}
