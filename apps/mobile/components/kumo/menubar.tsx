import type { ReactNode } from 'react'

import { View } from 'react-native'

import { cn } from './cn'

interface MenubarProps {
	children: ReactNode
	className?: string
}

/** Simplified Kumo Menubar — horizontal toolbar strip (not a native menubar). */
export function Menubar({ children, className }: MenubarProps) {
	return (
		<View className={cn('flex-row items-center gap-1 rounded-kumo border border-line bg-control p-1', className)}>
			{children}
		</View>
	)
}

export function MenubarItem({ children, className }: { children: ReactNode, className?: string }) {
	return (
		<View className={cn('rounded-kumo px-3 py-1.5', className)}>
			{children}
		</View>
	)
}
