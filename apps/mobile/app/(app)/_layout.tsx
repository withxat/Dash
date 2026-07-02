import { Redirect, Stack } from 'expo-router'

import { AccountProvider } from '../../lib/account-provider'
import { useAuth } from '../../lib/use-auth'

export default function AppLayout() {
	const { status } = useAuth()

	if (status === 'loading')
		return null
	if (status !== 'authenticated')
		return <Redirect href="/login" />

	return (
		<AccountProvider>
			<Stack
				screenOptions={{
					contentStyle: { backgroundColor: '#0b0b0f' },
					headerShown: true,
					headerStyle: { backgroundColor: '#0b0b0f' },
					headerTintColor: '#ffffff',
					headerTitleStyle: { fontWeight: '600' },
				}}
			>
				<Stack.Screen name="home" options={{ title: 'CloudFX' }} />
			</Stack>
		</AccountProvider>
	)
}
