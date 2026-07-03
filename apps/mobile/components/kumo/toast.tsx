import type { ReactNode } from 'react'

import type { ToastTone } from '../../lib/toast-context'

import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { Text } from 'react-native'
import Animated from 'react-native-reanimated'
import { useSafeAreaInsets } from 'react-native-safe-area-context'

import { fadeInUp, fadeOutUp } from '../../lib/motion'
import { overlayShadowStyle } from '../../lib/shadow'
import { useTheme } from '../../lib/theme'
import { ToastContext } from '../../lib/toast-context'
import { cn } from './cn'

interface ToastState {
	id: number
	message: string
	tone: ToastTone
}

const toneClasses: Record<ToastTone, string> = {
	error: 'border border-line bg-danger-tint/60',
	neutral: 'border border-line bg-elevated',
	success: 'border border-line bg-success-tint/70',
}

const toneTextClasses: Record<ToastTone, string> = {
	error: 'text-danger',
	neutral: 'text-default',
	success: 'text-success',
}

/** App-level toast provider — fire-and-forget feedback below the status bar. */
export function ToastProvider({ children }: { children: ReactNode }) {
	const [toast, setToast] = useState<null | ToastState>(null)
	const timerRef = useRef<null | ReturnType<typeof setTimeout>>(null)
	const insets = useSafeAreaInsets()
	const theme = useTheme()

	const show = useCallback((message: string, tone: ToastTone = 'neutral') => {
		if (timerRef.current)
			clearTimeout(timerRef.current)
		setToast({ id: Date.now(), message, tone })
		timerRef.current = setTimeout(setToast, 2600, null)
	}, [])

	useEffect(() => () => {
		if (timerRef.current)
			clearTimeout(timerRef.current)
	}, [])

	const value = useMemo(() => ({ show }), [show])

	return (
		<ToastContext value={value}>
			{children}
			{toast
				? (
						<Animated.View
							style={{
								borderCurve: 'continuous',
								top: insets.top + 8,
								...overlayShadowStyle(theme),
							}}
							className={cn('absolute inset-x-4 rounded-kumo px-4 py-3', toneClasses[toast.tone])}
							entering={fadeInUp}
							exiting={fadeOutUp}
							key={toast.id}
							pointerEvents="none"
						>
							<Text className={cn('text-center text-sm font-medium', toneTextClasses[toast.tone])}>
								{toast.message}
							</Text>
						</Animated.View>
					)
				: null}
		</ToastContext>
	)
}

/** Presentational inline toast surface (Kumo Toasty-style). */
export function ToastBanner({ message, tone = 'neutral' }: { message: string, tone?: ToastTone }) {
	return (
		<Text className={cn('rounded-kumo px-4 py-3 text-center text-sm font-medium', toneClasses[tone], toneTextClasses[tone])}>
			{message}
		</Text>
	)
}
