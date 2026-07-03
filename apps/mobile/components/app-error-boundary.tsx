import type { ErrorInfo, ReactNode } from 'react'

import { Component } from 'react'
import { Pressable, ScrollView, Text, View } from 'react-native'

import { lightPalette } from '../lib/theme'

interface AppErrorBoundaryProps {
	children: ReactNode
}

interface AppErrorBoundaryState {
	error: Error | null
}

/** Surfaces startup/render crashes instead of a blank screen. */
export class AppErrorBoundary extends Component<AppErrorBoundaryProps, AppErrorBoundaryState> {
	state: AppErrorBoundaryState = { error: null }

	static getDerivedStateFromError(error: Error): AppErrorBoundaryState {
		return { error }
	}

	componentDidCatch(error: Error, info: ErrorInfo) {
		console.error('CloudFX render error:', error, info.componentStack)
	}

	private onRetry = () => {
		this.setState({ error: null })
	}

	render() {
		const { error } = this.state
		if (!error)
			return this.props.children

		const palette = lightPalette
		return (
			<View style={{ backgroundColor: palette.canvas, flex: 1, padding: 24 }}>
				<ScrollView contentContainerStyle={{ flexGrow: 1, gap: 16, justifyContent: 'center' }}>
					<Text style={{ color: palette.strong, fontSize: 20, fontWeight: '600' }}>
						CloudFX failed to start
					</Text>
					<Text style={{ color: palette.subtle, fontSize: 14, lineHeight: 20 }}>
						A JavaScript error stopped the app from rendering. If you just installed from Xcode,
						make sure Metro is running on your Mac (`pnpm --filter @cloudfx/mobile dev`) and the
						phone is on the same Wi‑Fi.
					</Text>
					<Text
						style={{
							color: palette.danger,
							fontFamily: 'Menlo',
							fontSize: 12,
							lineHeight: 18,
						}}
						selectable
					>
						{error.message}
					</Text>
					<Pressable
						style={{
							alignSelf: 'flex-start',
							backgroundColor: palette.brand,
							borderCurve: 'continuous',
							borderRadius: 12,
							paddingHorizontal: 16,
							paddingVertical: 10,
						}}
						onPress={this.onRetry}
					>
						<Text style={{ color: palette.inverse, fontSize: 14, fontWeight: '600' }}>Retry</Text>
					</Pressable>
				</ScrollView>
			</View>
		)
	}
}
