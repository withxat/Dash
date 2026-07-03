/** Minimal className combiner — filters falsy parts and joins with spaces. */
export function cx(...parts: Array<false | null | string | undefined>): string {
	return parts.filter((p): p is string => Boolean(p)).join(' ')
}
