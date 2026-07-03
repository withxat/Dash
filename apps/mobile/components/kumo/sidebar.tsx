import type { ReactNode } from 'react'

import { View } from 'react-native'

import { cn } from './cn'

interface SidebarProps {
	children: ReactNode
	className?: string
}

/**
 * Kumo Sidebar — vertical nav column for tablet layouts.
 * On phone widths, prefer native tabs or a drawer screen.
 */
export function Sidebar({ children, className }: SidebarProps) {
	return (
		<View className={cn('w-56 gap-1 border-r border-hairline bg-elevated p-2', className)}>
			{children}
		</View>
	)
}

export function SidebarItem({ active = false, children, className }: { active?: boolean, children: ReactNode, className?: string }) {
	return (
		<View className={cn('rounded-kumo px-3 py-2', active && 'bg-tint/30', className)}>
			{children}
		</View>
	)
}
