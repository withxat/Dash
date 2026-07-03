/** Apply an alpha channel to a `#rrggbb` hex color. */
export function colorWithAlpha(hex: string, alpha: number): string {
	const normalized = hex.replace('#', '')
	const r = Number.parseInt(normalized.slice(0, 2), 16)
	const g = Number.parseInt(normalized.slice(2, 4), 16)
	const b = Number.parseInt(normalized.slice(4, 6), 16)
	return `rgba(${r}, ${g}, ${b}, ${alpha})`
}
