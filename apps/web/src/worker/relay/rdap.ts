/**
 * Public RDAP lookup via the rdap.org bootstrap. Mirrors the field extraction
 * in packages/cloudflare-api RdapClient.parse so relay + client agree.
 */

import type { RegistrationSnapshot } from './registration-types'

export async function queryRdap(domain: string): Promise<null | RegistrationSnapshot> {
	const encoded = encodeURIComponent(domain)
	const response = await fetch(`https://rdap.org/domain/${encoded}`, {
		headers: {
			accept: 'application/rdap+json, application/json',
		},
		redirect: 'follow',
	})
	if (response.status === 404 || response.status === 204)
		return null
	if (!response.ok) {
		throw new Error(`rdap ${response.status}`)
	}
	const data: unknown = await response.json()
	return parseRdapJson(data, domain)
}

export function parseRdapJson(data: unknown, fallbackDomain: string): null | RegistrationSnapshot {
	if (!data || typeof data !== 'object')
		return null
	const root = data as Record<string, unknown>

	const domain
		= stringField(root.ldhName)
			?? stringField(root.unicodeName)
			?? fallbackDomain

	const status = Array.isArray(root.status)
		? root.status.filter((item): item is string => typeof item === 'string')
		: []

	const events = Array.isArray(root.events) ? root.events : []
	const eventDate = (action: string): null | string => {
		for (const event of events) {
			if (!event || typeof event !== 'object')
				continue
			const row = event as Record<string, unknown>
			const eventAction = stringField(row.eventAction)
			if (!eventAction || eventAction.toLowerCase() !== action.toLowerCase())
				continue
			return stringField(row.eventDate)
		}
		return null
	}

	const nameservers: string[] = []
	if (Array.isArray(root.nameservers)) {
		for (const ns of root.nameservers) {
			if (!ns || typeof ns !== 'object')
				continue
			const row = ns as Record<string, unknown>
			const name = stringField(row.ldhName) ?? stringField(row.unicodeName)
			if (name)
				nameservers.push(name.toLowerCase())
		}
	}

	const registrar = registrarName(
		Array.isArray(root.entities) ? root.entities : [],
	)

	const snapshot: RegistrationSnapshot = {
		domain: domain.toLowerCase(),
		expiresOn: eventDate('expiration'),
		nameservers,
		registeredOn: eventDate('registration'),
		registrar,
		status,
		updatedOn:
			eventDate('last changed')
			?? eventDate('last update of RDAP database'),
	}

	return snapshot
}

function registrarName(entities: unknown[]): null | string {
	for (const entity of entities) {
		if (!entity || typeof entity !== 'object')
			continue
		const row = entity as Record<string, unknown>
		const roles = Array.isArray(row.roles)
			? row.roles.filter((item): item is string => typeof item === 'string')
			: []
		if (!roles.some(role => role.toLowerCase() === 'registrar'))
			continue

		const handle = stringField(row.handle)
		if (handle)
			return handle

		const vcard = row.vcardArray
		if (!Array.isArray(vcard) || vcard.length < 2)
			continue
		const rows = vcard[vcard.length - 1]
		if (!Array.isArray(rows))
			continue
		for (const entry of rows) {
			if (!Array.isArray(entry) || entry[0] !== 'fn')
				continue
			const value = entry[entry.length - 1]
			if (typeof value === 'string' && value.trim())
				return value.trim()
		}
	}
	return null
}

function stringField(value: unknown): null | string {
	return typeof value === 'string' && value.trim() ? value.trim() : null
}
