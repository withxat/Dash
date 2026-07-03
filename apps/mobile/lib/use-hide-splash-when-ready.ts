import { useRootNavigationState } from 'expo-router'
import * as SplashScreen from 'expo-splash-screen'
import { useEffect } from 'react'

import { useAuth } from './use-auth'

/** Keep the native splash up until navigation and auth bootstrap are ready. */
export function useHideSplashWhenReady() {
	const navigationState = useRootNavigationState()
	const { status } = useAuth()

	useEffect(() => {
		if (!navigationState?.key)
			return
		if (status === 'loading')
			return
		SplashScreen.hideAsync().catch(() => {
			/* already hidden */
		})
	}, [navigationState?.key, status])
}
