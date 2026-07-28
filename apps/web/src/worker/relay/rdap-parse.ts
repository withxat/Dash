/**
 * RDAP response field extraction. Mirrors packages/cloudflare-api
 * RdapClient.parse so relay + client agree.
 */

import type { RegistrationSnapshot } from './registration-types'

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
			// Some RDAP servers return the fully-qualified form (`ns1.example.com.`).
			// parseWhoisText strips the root dot, so strip it here too — otherwise the
			// zone card renders the field differently depending on which leg answered.
			if (name)
				nameservers.push(name.toLowerCase().replace(/\.$/, ''))
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

		// The vCard `fn` carries the registrar's actual name. `handle` is usually
		// just its IANA registrar id — "376", "1910" — which the zone card would
		// render as a bare number, so the name wins and the id is a last resort.
		const vcard = row.vcardArray
		if (Array.isArray(vcard) && vcard.length >= 2) {
			const rows = vcard[vcard.length - 1]
			if (Array.isArray(rows)) {
				for (const entry of rows) {
					if (!Array.isArray(entry) || entry[0] !== 'fn')
						continue
					const value = entry[entry.length - 1]
					if (typeof value === 'string' && value.trim())
						return value.trim()
				}
			}
		}

		const handle = stringField(row.handle)
		if (handle)
			return handle
	}
	return null
}

function stringField(value: unknown): null | string {
	return typeof value === 'string' && value.trim() ? value.trim() : null
}
