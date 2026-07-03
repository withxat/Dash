import { useCallback, useState } from 'react'
import { Text, View } from 'react-native'

import { Button, ButtonText } from './button'
import { cn } from './cn'

interface ClipboardTextProps {
	className?: string
	label?: string
	/** Called when the user taps Copy. Wire to your clipboard helper. */
	onCopy?: (value: string) => Promise<void> | void
	value: string
}

/** Kumo ClipboardText — read-only value with copy action (provide `onCopy`). */
export function ClipboardText({ className, label, onCopy, value }: ClipboardTextProps) {
	const [copied, setCopied] = useState(false)

	const copy = useCallback(async () => {
		await onCopy?.(value)
		setCopied(true)
		setTimeout(setCopied, 1500, false)
	}, [onCopy, value])

	return (
		<View className={cn('gap-2', className)}>
			{label ? <Text className="text-sm font-medium text-default">{label}</Text> : null}
			<View className="flex-row items-center gap-2 rounded-kumo border border-line bg-control px-3 py-2">
				<Text className="flex-1 font-mono text-sm text-default" selectable>
					{value}
				</Text>
				{onCopy
					? (
							<Button onPress={copy} size="sm" variant="secondary">
								<ButtonText>{copied ? 'Copied' : 'Copy'}</ButtonText>
							</Button>
						)
					: null}
			</View>
		</View>
	)
}
