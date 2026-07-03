import { router } from 'expo-router'
import { Pressable } from 'react-native'

import { useTheme } from '../lib/theme'
import { ChevronLeftIcon } from './icons'

/**
 * Manual back button for the root screen of pushed group stacks (zones,
 * account, …). That screen has no native back button — the back state lives
 * in the outer (hidden-header) stack — so we pop it ourselves.
 */
export function HeaderBackButton() {
	const theme = useTheme()

	return (
		<Pressable
			accessibilityLabel="Go back"
			accessibilityRole="button"
			className="active:opacity-70"
			hitSlop={12}
			onPress={() => router.back()}
		>
			<ChevronLeftIcon color={theme.default} size={26} />
		</Pressable>
	)
}
