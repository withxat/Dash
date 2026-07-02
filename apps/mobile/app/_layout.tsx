import { QueryClientProvider } from '@tanstack/react-query'
import { Stack } from 'expo-router'
import * as SplashScreen from 'expo-splash-screen'
import { StatusBar } from 'expo-status-bar'
import { useEffect } from 'react'
import { SafeAreaProvider } from 'react-native-safe-area-context'

import { queryClient } from '../lib/api'
import { AuthProvider } from '../lib/auth'

import '../global.css'

SplashScreen.preventAutoHideAsync().catch(() => {
	/* splash already hidden */
})

export default function RootLayout() {
	useEffect(() => {
		SplashScreen.hideAsync().catch(() => {
			/* ignore */
		})
	}, [])

	return (
		<SafeAreaProvider>
			<QueryClientProvider client={queryClient}>
				<AuthProvider>
					<StatusBar style="light" />
					<Stack screenOptions={{ headerShown: false }} />
				</AuthProvider>
			</QueryClientProvider>
		</SafeAreaProvider>
	)
}
