import { Redirect, useSegments } from 'expo-router'
import { NativeTabs } from 'expo-router/unstable-native-tabs'
import { ActivityIndicator, View } from 'react-native'

import { nativeTabIconProps } from '../../components/native-tab-icon'
import { AccountProvider } from '../../lib/account-provider'
import { useTheme } from '../../lib/theme'
import { useAuth } from '../../lib/use-auth'

function isTabRoot(segments: readonly string[]) {
	return ['home', 'items', 'watchtower', 'search'].includes(segments.at(-1) ?? '')
}

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
			<NativeTabs
				hidden={!isTabRoot(segments)}
				iconColor={{ default: theme.subtle, selected: theme.brand }}
				tintColor={theme.brand}
			>
				<NativeTabs.Trigger name="home">
					<NativeTabs.Trigger.Label hidden />
					<NativeTabs.Trigger.Icon {...nativeTabIconProps('home')} />
				</NativeTabs.Trigger>
				<NativeTabs.Trigger name="(items)">
					<NativeTabs.Trigger.Label hidden />
					<NativeTabs.Trigger.Icon {...nativeTabIconProps('items')} />
				</NativeTabs.Trigger>
				<NativeTabs.Trigger name="watchtower">
					<NativeTabs.Trigger.Label hidden />
					<NativeTabs.Trigger.Icon {...nativeTabIconProps('watchtower')} />
				</NativeTabs.Trigger>
				<NativeTabs.Trigger name="search" role="search">
					<NativeTabs.Trigger.Label hidden />
					<NativeTabs.Trigger.Icon {...nativeTabIconProps('search')} />
				</NativeTabs.Trigger>
			</NativeTabs>
		</AccountProvider>
	)
}
