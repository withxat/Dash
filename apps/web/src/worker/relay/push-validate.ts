/**
 * Pure push request validators — shared by handlePush and node:test.
 * Keep this module import-free so the test runner can load it without a bundler.
 */

const TOKEN_RE = /^[0-9a-f]{64,200}$/i
const ACCOUNT_ID_RE = /^[\w-]{1,128}$/
const ENVIRONMENTS = new Set(['sandbox', 'production'])
const SCOPED_NOTIFY_PATH
	= /^\/push\/notify\/(sandbox|production)\.([0-9a-f]{64,200})\.([\w-]{1,128})\.([0-9a-f]{64})$/i
const LEGACY_NOTIFY_PATH
	= /^\/push\/notify\/(sandbox|production)\.([0-9a-f]{64,200})\.([0-9a-f]{64})$/i

export function isAccountID(accountID: string): boolean {
	return ACCOUNT_ID_RE.test(accountID)
}

export function isDeviceToken(token: string): boolean {
	return TOKEN_RE.test(token)
}

export function isPushEnvironment(environment: string): boolean {
	return ENVIRONMENTS.has(environment)
}

export function notifyPath(
	environment: string,
	token: string,
	mac: string,
	accountID?: string,
): string {
	const binding = accountID ? `${token}.${accountID}` : token
	return `/push/notify/${environment}.${binding}.${mac}`
}

export function scopeDashRoute(route: string, accountID: string): string {
	try {
		const url = new URL(route)
		if (url.protocol !== 'dash:')
			throw new TypeError('Not a Dash route')
		url.searchParams.set('account', accountID)
		return url.toString()
	}
	catch {
		return `dash://watchtower?account=${encodeURIComponent(accountID)}`
	}
}

/** Legacy capabilities have no trustworthy account, so their tap is app-only. */
export function accountBoundDashRoute(
	route: string,
	accountID?: string,
): string | undefined {
	return accountID ? scopeDashRoute(route, accountID) : undefined
}

export function parseNotifyPath(pathname: string): null | {
	accountID?: string
	environment: string
	mac: string
	token: string
} {
	const scoped = pathname.match(SCOPED_NOTIFY_PATH)
	if (scoped) {
		return {
			accountID: scoped[3],
			environment: scoped[1].toLowerCase(),
			mac: scoped[4].toLowerCase(),
			token: scoped[2].toLowerCase(),
		}
	}
	const match = pathname.match(LEGACY_NOTIFY_PATH)
	if (!match)
		return null
	return {
		environment: match[1].toLowerCase(),
		mac: match[3].toLowerCase(),
		token: match[2].toLowerCase(),
	}
}
