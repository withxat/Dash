import { Redirect, Stack, useSegments } from 'expo-router'
import { ActivityIndicator, View } from 'react-native'

import { AccountProvider } from '../../lib/account-provider'
import { appShellHeaderOptions } from '../../lib/app-shell-header'
import { useTheme } from '../../lib/theme'
import { useAuth } from '../../lib/use-auth'

export default function AppLayout() {
	const { status } = useAuth()
	const theme = useTheme()
	const segments = useSegments()

	if (status === 'loading') {
		return (
			<View className="flex-1 items-center justify-center bg-canvas" style={{ backgroundColor: theme.canvas, flex: 1 }}>
				<ActivityIndicator color={theme.brand} />
			</View>
		)
	}
	if (status !== 'authenticated')
		return <Redirect href="/login" />

	return (
		<AccountProvider>
			<Stack
				screenOptions={{
					...appShellHeaderOptions(segments, theme),
					contentStyle: { backgroundColor: theme.canvas },
				}}
			>
				<Stack.Screen name="(tabs)" />
				<Stack.Screen name="zones" />
				<Stack.Screen name="workers" />
				<Stack.Screen name="storage" />
				<Stack.Screen name="account" />
				<Stack.Screen name="profile" />
			</Stack>
		</AccountProvider>
	)
}
