/** Number/byte/date formatting helpers for Cloudflare API data. */

/** Compact integer formatting: 1234 → "1.2K", 2_500_000 → "2.5M". */
export function formatNumber(n?: number): string {
	if (n == null)
		return '—'
	if (n >= 1e12)
		return `${(n / 1e12).toFixed(1)}T`
	if (n >= 1e9)
		return `${(n / 1e9).toFixed(1)}B`
	if (n >= 1e6)
		return `${(n / 1e6).toFixed(1)}M`
	if (n >= 1e3)
		return `${(n / 1e3).toFixed(1)}K`
	return String(n)
}

/** Byte formatting: 1_500_000 → "1.5 MB". */
export function formatBytes(n?: number): string {
	if (n == null)
		return '—'
	if (n >= 1e12)
		return `${(n / 1e12).toFixed(1)} TB`
	if (n >= 1e9)
		return `${(n / 1e9).toFixed(1)} GB`
	if (n >= 1e6)
		return `${(n / 1e6).toFixed(1)} MB`
	if (n >= 1e3)
		return `${(n / 1e3).toFixed(1)} KB`
	return `${n} B`
}

/** Percentage with one decimal: 0.8234 → "82.3%". */
export function formatPercent(ratio?: number): string {
	if (ratio == null || Number.isNaN(ratio))
		return '—'
	return `${(ratio * 100).toFixed(1)}%`
}

/** Relative time: ISO → "3m ago" / "2h ago" / "5d ago". */
export function timeAgo(iso?: string): string {
	if (!iso)
		return '—'
	const then = new Date(iso).getTime()
	if (Number.isNaN(then))
		return '—'
	const seconds = Math.max(0, Math.floor((Date.now() - then) / 1000))
	if (seconds < 60)
		return `${seconds}s ago`
	const minutes = Math.floor(seconds / 60)
	if (minutes < 60)
		return `${minutes}m ago`
	const hours = Math.floor(minutes / 60)
	if (hours < 24)
		return `${hours}h ago`
	return `${Math.floor(hours / 24)}d ago`
}

/** ISO timestamp for `hours` ago. */
export function isoHoursAgo(hours: number): string {
	return new Date(Date.now() - hours * 3_600_000).toISOString()
}

/** Short date: ISO → locale date string. */
export function formatDate(iso?: string): string {
	if (!iso)
		return '—'
	const d = new Date(iso)
	return Number.isNaN(d.getTime()) ? '—' : d.toLocaleDateString()
}

/** ISO timestamp for `days` ago at the start of the day (UTC). */
export function isoDaysAgo(days: number): string {
	const d = new Date()
	d.setUTCDate(d.getUTCDate() - days)
	d.setUTCHours(0, 0, 0, 0)
	return d.toISOString()
}
