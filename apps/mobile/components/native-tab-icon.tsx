import homeFill from '../assets/tab-icons/home-fill.png'
import homeLine from '../assets/tab-icons/home-line.png'
import itemsFill from '../assets/tab-icons/items-fill.png'
import itemsLine from '../assets/tab-icons/items-line.png'
import searchFill from '../assets/tab-icons/search-fill.png'
import searchLine from '../assets/tab-icons/search-line.png'
import watchtowerFill from '../assets/tab-icons/watchtower-fill.png'
import watchtowerLine from '../assets/tab-icons/watchtower-line.png'

export type TabIconName = 'home' | 'items' | 'search' | 'watchtower'

/** Solar line/fill PNGs for native tabs (template tint on iOS). */
const TAB_ICONS: Record<TabIconName, { default: number, selected: number }> = {
	home: { default: homeLine, selected: homeFill },
	items: { default: itemsLine, selected: itemsFill },
	search: { default: searchLine, selected: searchFill },
	watchtower: { default: watchtowerLine, selected: watchtowerFill },
}

export function nativeTabIconProps(name: TabIconName) {
	const icons = TAB_ICONS[name]
	return {
		renderingMode: 'template' as const,
		src: { default: icons.default, selected: icons.selected },
	}
}
