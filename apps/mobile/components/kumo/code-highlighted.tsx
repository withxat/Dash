import type { ReactNode } from 'react'

import { ScrollView, Text, View } from 'react-native'

import { cn } from './cn'

interface CodeHighlightedProps {
	children: string
	className?: string
	mono?: boolean
}

/** Kumo CodeHighlighted — monospace recessed code block. */
export function CodeHighlighted({ children, className, mono = true }: CodeHighlightedProps) {
	return (
		<ScrollView showsHorizontalScrollIndicator={false} horizontal>
			<View
				className={cn('rounded-kumo border border-hairline bg-recessed px-3 py-2', className)}
				style={{ borderCurve: 'continuous' }}
			>
				<Text className={cn('text-sm text-default', mono && 'font-mono')}>{children}</Text>
			</View>
		</ScrollView>
	)
}

/** Inline code span. */
export function CodeInline({ children, className }: { children: ReactNode, className?: string }) {
	return (
		<Text className={cn('rounded bg-recessed px-1 font-mono text-sm text-default', className)}>
			{children}
		</Text>
	)
}
