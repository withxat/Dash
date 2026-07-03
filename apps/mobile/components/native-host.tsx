import type { ReactNode } from 'react'
import type { StyleProp, ViewStyle } from 'react-native'

import { Host } from '@expo/ui'
import { View } from 'react-native'

import { isIOS } from '../lib/is-ios'

interface NativeHostProps {
	children: ReactNode
	/** When true, the host sizes to its SwiftUI content instead of expanding. */
	matchContents?: boolean
	style?: StyleProp<ViewStyle>
}

/** Bridges a subtree to SwiftUI on iOS; renders children directly on other platforms. */
export function NativeHost({ children, matchContents = true, style }: NativeHostProps) {
	if (!isIOS)
		return <View style={[{ width: '100%' }, style]}>{children}</View>

	return (
		<Host
			style={[
				matchContents ? { width: '100%' } : { alignSelf: 'stretch', width: '100%' },
				style,
			]}
			matchContents={matchContents}
		>
			{children}
		</Host>
	)
}
