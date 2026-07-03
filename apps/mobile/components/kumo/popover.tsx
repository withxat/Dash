import type { ReactNode } from 'react'

import { Modal, Pressable, Text, View } from 'react-native'

import { overlayShadowStyle } from '../../lib/shadow'
import { useTheme } from '../../lib/theme'
import { cn } from './cn'

interface PopoverProps {
	children: ReactNode
	onOpenChange: (open: boolean) => void
	open: boolean
}

/** Kumo Popover — small anchored modal sheet. */
export function Popover({ children, onOpenChange, open }: PopoverProps) {
	return (
		<Modal
			animationType="fade"
			onRequestClose={() => onOpenChange(false)}
			visible={open}
			transparent
		>
			<Pressable className="flex-1" onPress={() => onOpenChange(false)}>
				<View className="flex-1 items-center justify-center px-8">
					<Pressable onPress={e => e.stopPropagation()}>
						{children}
					</Pressable>
				</View>
			</Pressable>
		</Modal>
	)
}

export function PopoverContent({ children, className }: { children: ReactNode, className?: string }) {
	const theme = useTheme()
	return (
		<View
			className={cn('min-w-48 gap-2 rounded-kumo border border-line bg-base p-3', className)}
			style={[overlayShadowStyle(theme), { borderCurve: 'continuous' }]}
		>
			{children}
		</View>
	)
}

export function PopoverItem({
	children,
	destructive = false,
	onPress,
}: {
	children: string
	destructive?: boolean
	onPress: () => void
}) {
	return (
		<Pressable
			className="
				rounded-kumo px-2 py-2
				active:bg-elevated
			"
			onPress={onPress}
		>
			<Text className={cn('text-base', destructive ? 'text-danger' : 'text-default')}>{children}</Text>
		</Pressable>
	)
}
