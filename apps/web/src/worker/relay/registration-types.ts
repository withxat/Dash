/** Flat registration payload shared by RDAP + WHOIS parsers and iOS. */
export interface RegistrationSnapshot {
	domain: string
	expiresOn: null | string
	nameservers: string[]
	registeredOn: null | string
	registrar: null | string
	status: string[]
	updatedOn: null | string
}
