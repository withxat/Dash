/**
 * Public domain registration lookup for the iOS zone detail card.
 *
 * GET /api/registration/:domain
 *   → RDAP (IANA bootstrap → registry, rdap.org as redirector fallback)
 *   → port-43 WHOIS fallback (IANA referral → registry → optional registrar)
 *   → flat JSON matching iOS RdapRegistration
 *
 * Cache API only (12h hit / 1h miss). No KV/DO. No contact fields.
 */

import type { RegistrationSnapshot } from './registration-types'

import { parseRdapJson, queryRdap } from './rdap'
import { isUseful, normalizeDomain } from './registration-parse'
import { lookupWhois } from './whois'
import { parseWhoisText } from './whois-parse'

export { isUseful, normalizeDomain } from './registration-parse'
export type { RegistrationSnapshot } from './registration-types'
/** Exported for unit tests — same empty-payload rule as iOS RdapClient.parse. */
export { parseRdapJson, parseWhoisText }

const CACHE_TTL_HIT = 12 * 60 * 60
const CACHE_TTL_MISS = 60 * 60
const RATE_LIMIT_PER_HOUR = 40

export async function handleRegistration(
	request: Request,
	domainParam: string,
): Promise<Response> {
	if (request.method !== 'GET') {
		return new Response('Method Not Allowed', { status: 405 })
	}

	const domain = normalizeDomain(domainParam)
	if (!domain) {
		return new Response('Bad Request', { status: 400 })
	}

	const cache = caches.default
	const cacheKey = registrationCacheKey(domain)
	const cached = await cache.match(cacheKey)
	if (cached) {
		return cached
	}

	const ip = request.headers.get('cf-connecting-ip') ?? 'unknown'
	if (!(await allowLookup(cache, ip))) {
		return new Response('Too Many Requests', {
			headers: { 'retry-after': '3600' },
			status: 429,
		})
	}

	const snapshot = await resolveRegistration(domain)
	const response = snapshot
		? jsonResponse(snapshot, CACHE_TTL_HIT)
		: new Response(null, {
				headers: { 'cache-control': `public, max-age=${CACHE_TTL_MISS}` },
				status: 404,
			})

	try {
		await cache.put(cacheKey, response.clone())
	}
	catch {
		// Cache put can fail under quota; still serve the live response.
	}

	return response
}

async function resolveRegistration(domain: string): Promise<null | RegistrationSnapshot> {
	try {
		const rdap = await queryRdap(domain)
		if (rdap && isUseful(rdap))
			return rdap
	}
	catch {
		// Fall through to WHOIS.
	}

	try {
		const whois = await lookupWhois(domain)
		if (whois && isUseful(whois))
			return whois
	}
	catch {
		// Unsupported / timed out — hide the card.
	}

	return null
}

function registrationCacheKey(domain: string): Request {
	return new Request(`https://registration.dash.internal/v1/${domain}`)
}

async function allowLookup(cache: Cache, ip: string): Promise<boolean> {
	const hour = Math.floor(Date.now() / 3_600_000)
	const key = new Request(`https://registration-rl.dash.internal/${hour}/${encodeURIComponent(ip)}`)
	const existing = await cache.match(key)
	const count = existing ? Number.parseInt(await existing.text(), 10) || 0 : 0
	if (count >= RATE_LIMIT_PER_HOUR)
		return false
	try {
		await cache.put(
			key,
			new Response(String(count + 1), {
				headers: { 'cache-control': 'max-age=3600' },
			}),
		)
	}
	catch {
		// If rate-limit bookkeeping fails, allow the lookup.
	}
	return true
}

function jsonResponse(body: RegistrationSnapshot, maxAge: number): Response {
	return Response.json(body, {
		headers: {
			'cache-control': `public, max-age=${maxAge}`,
		},
	})
}
