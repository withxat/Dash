import { useSafeAreaInsets } from 'react-native-safe-area-context'

import { tabBarScenePaddingBottom } from './tab-bar'

/** Bottom inset for ScrollView content inside tab stacks. */
export function useTabScrollPadding() {
	const insets = useSafeAreaInsets()
	return tabBarScenePaddingBottom(insets.bottom)
}
