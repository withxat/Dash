import type { PressableProps } from 'react-native'

import { Pressable, Text } from 'react-native'

import { cn } from './cn'

interface LinkProps extends Omit<PressableProps, 'children'> {
	children: string
	className?: string
	muted?: boolean
}

/** Kumo Link — tappable text styled as a hyperlink. */
export function Link({ children, className, muted = false, ...props }: LinkProps) {
	return (
		<Pressable accessibilityRole="link" {...props}>
			<Text
				className={cn(
					'text-base font-medium underline',
					muted ? 'text-subtle' : 'text-brand',
					className,
				)}
			>
				{children}
			</Text>
		</Pressable>
	)
}
