/** Native UITabBar content height (excludes home-indicator safe area). */
export const TAB_BAR_CONTENT_HEIGHT = 49

/** Extra gap above the tab bar for floating overlays (e.g. Select sheet). */
export const TAB_BAR_CLEARANCE = 12

/** Total native tab bar height including bottom safe area inset. */
export function tabBarOccupiedHeight(safeAreaBottom: number) {
	return TAB_BAR_CONTENT_HEIGHT + safeAreaBottom
}

/** Trailing padding for scroll content inside tab stacks. Native tabs adjust insets automatically. */
export function tabBarScenePaddingBottom(_safeAreaBottom: number) {
	return 16
}

/** Bottom offset for overlays that should sit above the tab bar. */
export function tabBarOverlayBottom(safeAreaBottom: number) {
	return tabBarOccupiedHeight(safeAreaBottom) + TAB_BAR_CLEARANCE
}
