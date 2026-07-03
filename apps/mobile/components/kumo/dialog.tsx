import type { ReactNode } from 'react'

import { Modal, Pressable, Text, View } from 'react-native'

import { overlayShadowStyle } from '../../lib/shadow'
import { useTheme } from '../../lib/theme'
import { cn } from './cn'

interface DialogProps {
	children: ReactNode
	onOpenChange: (open: boolean) => void
	open: boolean
}

/** Kumo Dialog root — RN Modal wrapper. */
export function Dialog({ children, onOpenChange, open }: DialogProps) {
	return (
		<Modal
			animationType="fade"
			onRequestClose={() => onOpenChange(false)}
			visible={open}
			transparent
		>
			<Pressable
				className="flex-1 items-center justify-center bg-black/40 px-6"
				onPress={() => onOpenChange(false)}
			>
				<Pressable onPress={e => e.stopPropagation()}>
					{children}
				</Pressable>
			</Pressable>
		</Modal>
	)
}

interface DialogContentProps {
	children: ReactNode
	className?: string
}

export function DialogContent({ children, className }: DialogContentProps) {
	const theme = useTheme()
	return (
		<View
			className={cn('w-full max-w-sm gap-4 rounded-kumo border border-line bg-base p-5', className)}
			style={[overlayShadowStyle(theme), { borderCurve: 'continuous' }]}
		>
			{children}
		</View>
	)
}

export function DialogHeader({ description, title }: { description?: string, title: string }) {
	return (
		<View className="gap-1">
			<Text className="text-lg font-semibold text-strong">{title}</Text>
			{description
				? <Text className="text-sm text-subtle">{description}</Text>
				: null}
		</View>
	)
}

export function DialogFooter({ children, className }: { children: ReactNode, className?: string }) {
	return (
		<View className={cn('flex-row justify-end gap-2', className)}>
			{children}
		</View>
	)
}
