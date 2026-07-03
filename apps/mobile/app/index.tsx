import { Redirect } from 'expo-router'
import { ActivityIndicator, View } from 'react-native'

import { useTheme } from '../lib/theme'
import { useAuth } from '../lib/use-auth'

export default function Index() {
	const { status } = useAuth()
	const theme = useTheme()

	if (status === 'loading') {
		return (
			<View className="flex-1 items-center justify-center bg-canvas" style={{ backgroundColor: theme.canvas, flex: 1 }}>
				<ActivityIndicator color={theme.brand} />
			</View>
		)
	}
	return status === 'authenticated' ? <Redirect href="/home" /> : <Redirect href="/login" />
}
