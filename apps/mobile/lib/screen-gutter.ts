/** Horizontal inset shared by native headers and scroll content. */
export const SCREEN_GUTTER = 16

/** Default vertical gap between grouped lists in tab scroll content. */
export const TAB_SCROLL_GAP = 20

/** Space below the tab-root large title before the first content row. */
export const TAB_ROOT_CONTENT_PADDING_TOP = 16

export function tabScrollContentStyle(options: { gap?: number, paddingBottom: number, paddingTop?: number, tabRoot?: boolean }) {
	const gap = options.gap ?? TAB_SCROLL_GAP
	const paddingTop = options.paddingTop ?? (options.tabRoot ? TAB_ROOT_CONTENT_PADDING_TOP : undefined)

	return {
		gap,
		paddingBottom: options.paddingBottom,
		paddingHorizontal: SCREEN_GUTTER,
		...(paddingTop != null ? { paddingTop } : null),
	}
}
