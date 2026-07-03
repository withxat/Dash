import { NativeTabs } from 'expo-router/unstable-native-tabs'

import { nativeTabIconProps } from '../../../components/native-tab-icon'
import { useTheme } from '../../../lib/theme'
import { useSyncAppShellHeader } from '../../../lib/use-sync-app-shell-header'

export default function TabsLayout() {
	const theme = useTheme()
	useSyncAppShellHeader()

	return (
		<NativeTabs
			iconColor={{ default: theme.subtle, selected: theme.brand }}
			tintColor={theme.brand}
		>
			<NativeTabs.Trigger name="home">
				<NativeTabs.Trigger.Label hidden />
				<NativeTabs.Trigger.Icon {...nativeTabIconProps('home')} />
			</NativeTabs.Trigger>
			<NativeTabs.Trigger name="items">
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
	)
}
