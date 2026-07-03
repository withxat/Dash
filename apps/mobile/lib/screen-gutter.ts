/** Horizontal inset shared by native headers and scroll content. */
export const SCREEN_GUTTER = 16

/** Space below the large title before the first row of tab-root content. */
export const TAB_ROOT_TITLE_GAP = 12

export function tabScrollContentStyle(options: { gap?: number, paddingBottom: number, paddingTop?: number, tabRoot?: boolean }) {
	const paddingTop = options.paddingTop ?? (options.tabRoot ? TAB_ROOT_TITLE_GAP : undefined)

	return {
		gap: options.gap ?? 20,
		paddingBottom: options.paddingBottom,
		paddingHorizontal: SCREEN_GUTTER,
		...(paddingTop != null ? { paddingTop } : null),
	}
}
