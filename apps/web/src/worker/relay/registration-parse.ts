import type { RegistrationSnapshot } from './registration-types'

const DOMAIN_RE
	= /^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/

export function normalizeDomain(raw: string): null | string {
	const domain = raw.trim().toLowerCase().replace(/\.$/, '')
	if (!DOMAIN_RE.test(domain))
		return null
	return domain
}

export function isUseful(snapshot: RegistrationSnapshot): boolean {
	return Boolean(
		snapshot.registrar
		|| snapshot.expiresOn
		|| snapshot.registeredOn
		|| snapshot.status.length > 0
		|| snapshot.nameservers.length > 0,
	)
}
