/**
 * IANA RDAP bootstrap (RFC 7484).
 *
 * https://data.iana.org/rdap/dns.json maps each TLD to its authoritative
 * registry RDAP base URL, so a lookup can address the registry directly
 * instead of routing through the third-party rdap.org redirector — one hop
 * fewer, and no dependency on a service that fronts its own bot management.
 *
 * IANA republishes roughly weekly (`publication` carries the timestamp), so a
 * day-long Cache API entry is never meaningfully behind. A per-isolate memo
 * sits on top of that, because a cache hit still costs a parse.
 *
 * Not every TLD is bootstrapped — .sh, .io and .de publish no RDAP base here —
 * so a miss is normal and callers fall back rather than fail.
 */

const BOOTSTRAP_URL = 'https://data.iana.org/rdap/dns.json'
const BOOTSTRAP_CACHE_KEY = 'https://rdap-bootstrap.dash.internal/v1/dns.json'
const BOOTSTRAP_TTL = 24 * 60 * 60
const BOOTSTRAP_TIMEOUT_MS = 5_000
const MEMO_TTL_MS = BOOTSTRAP_TTL * 1_000

/** rdap.org answered header-less subrequests with a bot challenge; identify us. */
export const RELAY_USER_AGENT = 'Dash-Relay/1.0 (+https://dash.xat.sh)'

export interface RdapBootstrap {
	/** IANA's own publication timestamp — identifies the cached snapshot. */
	publication: null | string
	/** TLD (no leading dot, lowercased) → RDAP base URL with a trailing slash. */
	tlds: Record<string, string>
}

let memo: null | { expiresAt: number, value: RdapBootstrap } = null

/** Authoritative RDAP base URL for a domain, or null when IANA has none. */
export async function rdapBaseForDomain(domain: string): Promise<null | string> {
	const bootstrap = await loadBootstrap()
	if (!bootstrap)
		return null
	return baseForDomain(bootstrap.tlds, domain)
}

/** Longest-suffix match, per RFC 7484 §4. */
export function baseForDomain(
	tlds: Record<string, string>,
	domain: string,
): null | string {
	const labels = domain.trim().toLowerCase().replace(/\.$/, '').split('.')
	for (let index = 0; index < labels.length; index++) {
		const suffix = labels.slice(index).join('.')
		if (!suffix)
			continue
		const base = tlds[suffix]
		if (base)
			return base
	}
	return null
}

export function rdapDomainUrl(base: string, domain: string): string {
	const root = base.endsWith('/') ? base : `${base}/`
	return `${root}domain/${encodeURIComponent(domain)}`
}

export function parseBootstrap(data: unknown): null | RdapBootstrap {
	if (!data || typeof data !== 'object')
		return null
	const root = data as Record<string, unknown>
	if (!Array.isArray(root.services))
		return null

	const tlds: Record<string, string> = {}
	for (const service of root.services) {
		if (!Array.isArray(service) || service.length < 2)
			continue
		const [names, urls] = service
		if (!Array.isArray(names) || !Array.isArray(urls))
			continue
		const base = preferredBase(urls)
		if (!base)
			continue
		for (const name of names) {
			if (typeof name !== 'string')
				continue
			const key = name.trim().toLowerCase().replace(/^\.|\.$/g, '')
			if (key)
				tlds[key] = base
		}
	}

	if (Object.keys(tlds).length === 0)
		return null
	return { publication: stringField(root.publication), tlds }
}

async function loadBootstrap(): Promise<null | RdapBootstrap> {
	const now = Date.now()
	if (memo && memo.expiresAt > now)
		return memo.value

	const cache = caches.default
	const cacheKey = new Request(BOOTSTRAP_CACHE_KEY)

	try {
		const cached = await cache.match(cacheKey)
		if (cached) {
			const value = readCachedBootstrap(await cached.json())
			if (value)
				return remember(value, now)
		}
	}
	catch {
		// Unreadable cache entry — refetch.
	}

	try {
		const response = await fetch(BOOTSTRAP_URL, {
			headers: {
				'accept': 'application/json',
				'user-agent': RELAY_USER_AGENT,
			},
			signal: AbortSignal.timeout(BOOTSTRAP_TIMEOUT_MS),
		})
		if (response.ok) {
			const value = parseBootstrap(await response.json())
			if (value) {
				try {
					await cache.put(
						cacheKey,
						Response.json(value, {
							headers: { 'cache-control': `public, max-age=${BOOTSTRAP_TTL}` },
						}),
					)
				}
				catch {
					// Cache put can fail under quota; the memo still holds.
				}
				return remember(value, now)
			}
		}
	}
	catch {
		// IANA unreachable or slow.
	}

	// Better a stale map than a forced trip through the redirector.
	return memo?.value ?? null
}

function remember(value: RdapBootstrap, now: number): RdapBootstrap {
	memo = { expiresAt: now + MEMO_TTL_MS, value }
	return value
}

/**
 * Our own compacted cache body — still validated, since an entry written before
 * a shape change outlives the deploy that changed it. Exported for the
 * round-trip test: if this and the `cache.put` above ever disagree, nothing
 * breaks loudly, every cold isolate just silently refetches IANA.
 */
export function readCachedBootstrap(data: unknown): null | RdapBootstrap {
	if (!data || typeof data !== 'object')
		return null
	const root = data as Record<string, unknown>
	if (!root.tlds || typeof root.tlds !== 'object')
		return null

	const tlds: Record<string, string> = {}
	for (const [key, value] of Object.entries(root.tlds as Record<string, unknown>)) {
		if (typeof value === 'string' && value)
			tlds[key] = value
	}

	if (Object.keys(tlds).length === 0)
		return null
	return { publication: stringField(root.publication), tlds }
}

function preferredBase(urls: unknown[]): null | string {
	let insecure: null | string = null
	for (const raw of urls) {
		if (typeof raw !== 'string')
			continue
		let url: URL
		try {
			url = new URL(raw.trim())
		}
		catch {
			continue
		}
		const normalized = url.href.endsWith('/') ? url.href : `${url.href}/`
		if (url.protocol === 'https:')
			return normalized
		if (url.protocol === 'http:' && !insecure)
			insecure = normalized
	}
	return insecure
}

function stringField(value: unknown): null | string {
	return typeof value === 'string' && value.trim() ? value.trim() : null
}
