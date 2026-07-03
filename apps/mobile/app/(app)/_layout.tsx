import { Redirect, Stack } from 'expo-router'
import { ActivityIndicator, View } from 'react-native'

import { AccountProvider } from '../../lib/account-provider'
import { appShellHeaderOptions } from '../../lib/app-shell-header'
import { stackScreenOptions } from '../../lib/navigation'
import { useTheme } from '../../lib/theme'
import { useAuth } from '../../lib/use-auth'

export default function AppLayout() {
	const { status } = useAuth()
	const theme = useTheme()

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
			<Stack screenOptions={stackScreenOptions(theme)}>
				<Stack.Screen name="(tabs)" options={appShellHeaderOptions(['(app)', '(tabs)', 'home'], theme)} />
				<Stack.Screen name="zones" options={appShellHeaderOptions(['(app)', 'zones', 'index'], theme)} />
				<Stack.Screen name="workers" options={appShellHeaderOptions(['(app)', 'workers', 'index'], theme)} />
				<Stack.Screen name="storage" options={appShellHeaderOptions(['(app)', 'storage', 'index'], theme)} />
				<Stack.Screen name="account" options={appShellHeaderOptions(['(app)', 'account', 'index'], theme)} />
				<Stack.Screen name="profile" options={appShellHeaderOptions(['(app)', 'profile', 'index'], theme)} />
			</Stack>
		</AccountProvider>
	)
}
