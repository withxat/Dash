import type { ReactNode } from 'react'

import { View } from 'react-native'

import { cn } from './cn'

interface FlowProps {
	children: ReactNode
	className?: string
	direction?: 'column' | 'row'
	gap?: 1 | 2 | 3 | 4 | 6 | 8
}

const gapClasses = {
	1: 'gap-1',
	2: 'gap-2',
	3: 'gap-3',
	4: 'gap-4',
	6: 'gap-6',
	8: 'gap-8',
} as const

/** Kumo Flow — flex container with consistent gap spacing. */
export function Flow({ children, className, direction = 'column', gap = 4 }: FlowProps) {
	return (
		<View
			className={cn(
				direction === 'row' ? 'flex-row flex-wrap items-center' : 'flex-col',
				gapClasses[gap],
				className,
			)}
		>
			{children}
		</View>
	)
}
