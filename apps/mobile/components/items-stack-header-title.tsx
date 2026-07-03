import type { ColorValue } from 'react-native'

import type { AppCatalogIcon } from '../lib/app-catalog'

import { View } from 'react-native'

import { CatalogItemIcon } from './catalog-item-icon'
import { StackHeaderTitle } from './stack-header-title'

interface ItemsStackHeaderTitleProps {
	icon: AppCatalogIcon
	tintColor?: ColorValue
	title: string
}

/** Catalog icon + HeaderTitle (Items sub-screens with icons only). */
export function ItemsStackHeaderTitle({ icon, tintColor, title }: ItemsStackHeaderTitleProps) {
	return (
		<View className="max-w-full flex-row items-center gap-2">
			<CatalogItemIcon icon={icon} variant="header" />
			<StackHeaderTitle tintColor={tintColor} title={title} />
		</View>
	)
}
