import type { ReactNode } from 'react'

import { View } from 'react-native'

import { cn } from './cn'

interface GridProps {
	children: ReactNode
	className?: string
	columns?: 1 | 2 | 3 | 4
	gap?: 2 | 3 | 4
}

const columnClasses = {
	1: 'w-full',
	2: 'w-1/2',
	3: 'w-1/3',
	4: 'w-1/4',
} as const

const gapClasses = {
	2: 'gap-2',
	3: 'gap-3',
	4: 'gap-4',
} as const

/** Kumo Grid — flex-wrap grid layout. */
export function Grid({ children, className, columns = 2, gap = 3 }: GridProps) {
	return (
		<View className={cn('flex-row flex-wrap', gapClasses[gap], className)}>
			{Array.isArray(children)
				? children.map((child, index) => (
					// eslint-disable-next-line react/no-array-index-key -- grid slots are positional
						<View className={columnClasses[columns]} key={index}>
							{child}
						</View>
					))
				: (
						<View className={columnClasses[columns]}>{children}</View>
					)}
		</View>
	)
}

export function GridItem({ children, className, span = 1 }: { children: ReactNode, className?: string, span?: 1 | 2 }) {
	return (
		<View className={cn(span === 2 ? 'w-full' : 'w-1/2', className)}>
			{children}
		</View>
	)
}
