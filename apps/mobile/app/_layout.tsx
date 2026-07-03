import { QueryClientProvider } from '@tanstack/react-query'
import { Stack } from 'expo-router'
import * as SplashScreen from 'expo-splash-screen'
import { StatusBar } from 'expo-status-bar'
import { GestureHandlerRootView } from 'react-native-gesture-handler'
import { SafeAreaProvider } from 'react-native-safe-area-context'

import { AppErrorBoundary } from '../components/app-error-boundary'
import { ToastProvider } from '../components/toast'
import { queryClient } from '../lib/api'
import { AuthProvider } from '../lib/auth'
import { useTheme } from '../lib/theme'
import { useHideSplashWhenReady } from '../lib/use-hide-splash-when-ready'

import '../global.css'

SplashScreen.preventAutoHideAsync().catch(() => {
	/* splash already hidden */
})

function RootLayoutInner() {
	const theme = useTheme()
	useHideSplashWhenReady()

	return (
		<ToastProvider>
			<StatusBar style="auto" />
			<Stack
				screenOptions={{
					contentStyle: { backgroundColor: theme.canvas },
					headerShown: false,
				}}
			/>
		</ToastProvider>
	)
}

export default function RootLayout() {
	return (
		<GestureHandlerRootView style={{ flex: 1 }}>
			<SafeAreaProvider>
				<QueryClientProvider client={queryClient}>
					<AuthProvider>
						<AppErrorBoundary>
							<RootLayoutInner />
						</AppErrorBoundary>
					</AuthProvider>
				</QueryClientProvider>
			</SafeAreaProvider>
		</GestureHandlerRootView>
	)
}
