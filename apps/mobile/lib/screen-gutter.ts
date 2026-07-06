/** Horizontal inset shared by native headers and scroll content. */
export const SCREEN_GUTTER = 16

/** Space below the tab-root in-screen header before scroll content. */
export const TAB_ROOT_TITLE_GAP = 12

export function tabScrollContentStyle(options: { gap?: number, paddingBottom: number, paddingTop?: number }) {
	return {
		gap: options.gap ?? 20,
		paddingBottom: options.paddingBottom,
		paddingHorizontal: SCREEN_GUTTER,
		...(options.paddingTop != null ? { paddingTop: options.paddingTop } : null),
	}
}
