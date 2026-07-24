/**
 * Pure WHOIS text parsing — no sockets. Shared by the Worker lookup path and
 * node:test unit coverage.
 */

import type { RegistrationSnapshot } from './registration-types'

export function parseWhoisText(text: string, domain: string): null | RegistrationSnapshot {
	const fields = collectFields(text)
	if (fields.size === 0)
		return null

	const status = multi(fields, ['domain status', 'status'])
		.map(stripStatusUrl)
		.filter(Boolean)

	const nameservers = multi(fields, [
		'name server',
		'nameserver',
		'nserver',
	]).map(value => value.toLowerCase().replace(/\.$/, ''))

	return {
		domain: domain.toLowerCase(),
		expiresOn: first(fields, [
			'registry expiry date',
			'registrar registration expiration date',
			'expiry date',
			'expiration date',
			'expires',
			'paid-till',
		]),
		nameservers: unique(nameservers),
		registeredOn: first(fields, [
			'creation date',
			'created',
			'created on',
			'registered on',
			'registration time',
		]),
		registrar: first(fields, ['registrar', 'sponsoring registrar']),
		status: unique(status),
		updatedOn: first(fields, [
			'updated date',
			'last updated',
			'last modified',
			'changed',
		]),
	}
}

export function extractReferralHost(text: string): null | string {
	const fields = collectFields(text)
	return hostFromValue(
		first(fields, ['whois', 'refer', 'referralserver']),
	)
}

export function extractRegistrarWhoisHost(text: string): null | string {
	const fields = collectFields(text)
	return hostFromValue(
		first(fields, [
			'registrar whois server',
			'whois server',
			'referral url',
		]),
	)
}

export function tldGuessHost(domain: string): null | string {
	const tld = domain.split('.').pop()
	if (!tld)
		return null
	// Last-resort guesses when IANA omits a whois: line.
	if (tld === 'sh' || tld === 'io' || tld === 'ac')
		return `whois.nic.${tld}`
	return null
}

export function isThickEnough(snapshot: RegistrationSnapshot): boolean {
	return Boolean(snapshot.registrar && (snapshot.expiresOn || snapshot.registeredOn))
}

export function mergeSnapshots(
	primary: null | RegistrationSnapshot,
	secondary: null | RegistrationSnapshot,
): null | RegistrationSnapshot {
	if (!primary)
		return secondary
	if (!secondary)
		return primary
	return {
		domain: primary.domain,
		expiresOn: primary.expiresOn ?? secondary.expiresOn,
		nameservers: unique([...primary.nameservers, ...secondary.nameservers]),
		registeredOn: primary.registeredOn ?? secondary.registeredOn,
		registrar: primary.registrar ?? secondary.registrar,
		status: unique([...primary.status, ...secondary.status]),
		updatedOn: primary.updatedOn ?? secondary.updatedOn,
	}
}

function collectFields(text: string): Map<string, string[]> {
	const fields = new Map<string, string[]>()
	for (const line of text.split(/\r?\n/)) {
		const trimmed = line.trim()
		if (!trimmed || trimmed.startsWith('%') || trimmed.startsWith('#'))
			continue
		const idx = trimmed.indexOf(':')
		if (idx <= 0)
			continue
		const key = trimmed.slice(0, idx).trim().toLowerCase()
		const value = trimmed.slice(idx + 1).trim()
		if (!key || !value)
			continue
		// Skip marker lines like ">>> Last update…"
		if (key.startsWith('>>>'))
			continue
		const list = fields.get(key) ?? []
		list.push(value)
		fields.set(key, list)
	}
	return fields
}

function first(fields: Map<string, string[]>, keys: string[]): null | string {
	for (const key of keys) {
		const values = fields.get(key)
		if (values?.[0])
			return normalizeDateish(values[0])
	}
	return null
}

function multi(fields: Map<string, string[]>, keys: string[]): string[] {
	const out: string[] = []
	for (const key of keys) {
		const values = fields.get(key)
		if (!values)
			continue
		for (const value of values) out.push(value)
	}
	return out
}

function normalizeDateish(value: string): string {
	// Keep ISO-ish timestamps; strip trailing timezone labels we don't need.
	return value.replace(/\s+\(.*\)$/, '').trim()
}

function stripStatusUrl(value: string): string {
	const urlIdx = value.search(/\s+https?:\/\//i)
	const status = (urlIdx >= 0 ? value.slice(0, urlIdx) : value).trim()
	return status.replace(/_/g, ' ')
}

function hostFromValue(value: null | string): null | string {
	if (!value)
		return null
	let host = value.trim()
	host = host.replace(/^whois:\/\//i, '')
	try {
		if (host.includes('://')) {
			host = new URL(host).hostname
		}
	}
	catch {
		// keep raw
	}
	host = host.replace(/\/.*$/, '').replace(/:\d+$/, '').toLowerCase()
	if (!host || host.includes(' ') || !host.includes('.'))
		return null
	return host
}

function unique(values: string[]): string[] {
	return [...new Set(values.map(value => value.trim()).filter(Boolean))]
}
