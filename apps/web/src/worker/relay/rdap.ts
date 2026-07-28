/**
 * Public RDAP lookup. Field extraction lives in rdap-parse, so this module
 * stays network-only and the parser stays unit-testable off-runtime.
 *
 * The registry base URL comes from IANA's own bootstrap file, so the common
 * path talks to the authoritative server directly. rdap.org stays as the
 * fallback for the TLDs IANA does not bootstrap (.sh, .io, .de …) and for a
 * registry that will not answer — it is a redirector we do not control, so it
 * must never be the only way through. A miss here is not the last word either:
 * the caller still has port-43 WHOIS behind us.
 */

import type { RegistrationSnapshot } from './registration-types'

import { rdapBaseForDomain, rdapDomainUrl, RELAY_USER_AGENT } from './rdap-bootstrap'
import { parseRdapJson } from './rdap-parse'

export { parseRdapJson } from './rdap-parse'

const RDAP_TIMEOUT_MS = 6_000

/**
 * `answer` is what the server said, including a definitive "no such domain".
 * `unavailable` means the server never spoke — the only case worth retrying
 * somewhere else.
 */
type RdapOutcome
	= | { kind: 'answer', snapshot: null | RegistrationSnapshot }
		| { kind: 'unavailable' }

export async function queryRdap(domain: string): Promise<null | RegistrationSnapshot> {
	const base = await rdapBaseForDomain(domain)
	if (base) {
		const registry = await fetchRdap(rdapDomainUrl(base, domain), domain)
		if (registry.kind === 'answer')
			return registry.snapshot
	}

	const encoded = encodeURIComponent(domain)
	const redirector = await fetchRdap(`https://rdap.org/domain/${encoded}`, domain)
	if (redirector.kind === 'answer')
		return redirector.snapshot

	throw new Error('rdap unavailable')
}

async function fetchRdap(url: string, domain: string): Promise<RdapOutcome> {
	let response: Response
	try {
		response = await fetch(url, {
			headers: {
				'accept': 'application/rdap+json, application/json',
				'user-agent': RELAY_USER_AGENT,
			},
			redirect: 'follow',
			signal: AbortSignal.timeout(RDAP_TIMEOUT_MS),
		})
	}
	catch {
		return { kind: 'unavailable' }
	}

	if (response.status === 404 || response.status === 204)
		return { kind: 'answer', snapshot: null }
	if (!response.ok)
		return { kind: 'unavailable' }

	try {
		const data: unknown = await response.json()
		return { kind: 'answer', snapshot: parseRdapJson(data, domain) }
	}
	catch {
		return { kind: 'unavailable' }
	}
}
