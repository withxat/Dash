import { Text, View } from 'react-native'

import { Button, ButtonText } from './button'
import { cn } from './cn'

interface EmptyProps {
	/** Label for the action button. Defaults to "Retry". */
	actionLabel?: string
	children: string
	className?: string
	/** Optional retry/action handler — renders a small button when provided. */
	onAction?: () => void
}

/** Kumo Empty — centered copy with optional action; no chrome on canvas/list empties. */
export function Empty({ actionLabel = 'Retry', children, className, onAction }: EmptyProps) {
	return (
		<View className={cn('w-full items-center justify-center gap-4 px-6 py-16', className)}>
			<Text className="text-center text-sm text-subtle">{children}</Text>
			{onAction
				? (
						<Button onPress={onAction} size="sm" variant="secondary">
							<ButtonText>{actionLabel}</ButtonText>
						</Button>
					)
				: null}
		</View>
	)
}

/** @deprecated Use `Empty` */
export const EmptyState = Empty
