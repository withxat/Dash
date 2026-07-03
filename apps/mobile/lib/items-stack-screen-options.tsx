import type { ColorValue } from 'react-native'

import type { ThemePalette } from './theme'

import { ItemsStackHeaderTitle } from '../components/items-stack-header-title'
import { itemsStackIcon, itemsStackTitle } from './items-stack-title'
import { tabPushedStackScreenOptions, tabStackScreenOptions } from './tab-stack-header'

export function itemsStackScreenOptions(theme: ThemePalette, routeName: string) {
	if (routeName === 'items')
		return tabStackScreenOptions(theme)

	const icon = itemsStackIcon(routeName)

	return {
		...tabPushedStackScreenOptions(theme),
		title: itemsStackTitle(routeName),
		...(icon
			? {
					headerTitle: ({ children, tintColor }: { children: string, tintColor?: ColorValue }) => (
						<ItemsStackHeaderTitle icon={icon} tintColor={tintColor} title={String(children)} />
					),
				}
			: null),
	}
}
