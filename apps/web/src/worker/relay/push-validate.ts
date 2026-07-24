/**
 * Pure push request validators — shared by handlePush and node:test.
 * Keep this module import-free so the test runner can load it without a bundler.
 */

const TOKEN_RE = /^[0-9a-f]{64,200}$/i
const ENVIRONMENTS = new Set(['sandbox', 'production'])
const NOTIFY_PATH = /^\/push\/notify\/(sandbox|production)\.([0-9a-f]+)\.([0-9a-f]+)$/i

export function isDeviceToken(token: string): boolean {
	return TOKEN_RE.test(token)
}

export function isPushEnvironment(environment: string): boolean {
	return ENVIRONMENTS.has(environment)
}

export function parseNotifyPath(pathname: string): null | {
	environment: string
	mac: string
	token: string
} {
	const match = pathname.match(NOTIFY_PATH)
	if (!match)
		return null
	return {
		environment: match[1].toLowerCase(),
		mac: match[3].toLowerCase(),
		token: match[2].toLowerCase(),
	}
}
