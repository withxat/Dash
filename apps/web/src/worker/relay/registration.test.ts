import assert from 'node:assert/strict'
import { describe, it } from 'node:test'

import { parseRdapJson } from './rdap.ts'
import { isUseful, normalizeDomain } from './registration-parse.ts'
import {
	extractReferralHost,
	extractRegistrarWhoisHost,
	parseWhoisText,
} from './whois-parse.ts'

describe('normalizeDomain', () => {
	it('accepts dotted lowercase hostnames', () => {
		assert.equal(normalizeDomain('Xat.SH.'), 'xat.sh')
	})

	it('rejects path-like and empty values', () => {
		assert.equal(normalizeDomain(''), null)
		assert.equal(normalizeDomain('localhost'), null)
		assert.equal(normalizeDomain('evil.com/foo'), null)
	})
})

describe('parseWhoisText', () => {
	it('extracts registrar expiry and nameservers from nic.sh style text', () => {
		const text = `
Domain Name: xat.sh
Registrar: Cloudflare, Inc
Creation Date: 2024-10-23T06:49:51Z
Registry Expiry Date: 2027-10-23T06:49:51Z
Updated Date: 2026-05-05T02:33:29Z
Domain Status: clientTransferProhibited https://icann.org/epp#clientTransferProhibited
Name Server: jason.ns.cloudflare.com
Name Server: nola.ns.cloudflare.com
`
		const snapshot = parseWhoisText(text, 'xat.sh')
		assert.ok(snapshot)
		assert.equal(snapshot.registrar, 'Cloudflare, Inc')
		assert.equal(snapshot.registeredOn, '2024-10-23T06:49:51Z')
		assert.equal(snapshot.expiresOn, '2027-10-23T06:49:51Z')
		assert.equal(snapshot.status[0], 'clientTransferProhibited')
		assert.deepEqual(snapshot.nameservers, [
			'jason.ns.cloudflare.com',
			'nola.ns.cloudflare.com',
		])
		assert.equal(isUseful(snapshot), true)
	})
})

describe('parseRdapJson', () => {
	it('mirrors iOS RdapClient field extraction', () => {
		const snapshot = parseRdapJson({
			entities: [{
				roles: ['registrar'],
				vcardArray: ['vcard', [
					['version', {}, 'text', '4.0'],
					['fn', {}, 'text', 'RESERVED'],
				]],
			}],
			events: [
				{ eventAction: 'registration', eventDate: '1995-08-14T04:00:00Z' },
				{ eventAction: 'expiration', eventDate: '2027-08-13T04:00:00Z' },
			],
			ldhName: 'example.com',
			nameservers: [{ ldhName: 'a.iana-servers.net' }],
			status: ['client transfer prohibited'],
		}, 'example.com')
		assert.ok(snapshot)
		assert.equal(snapshot.registrar, 'RESERVED')
		assert.equal(snapshot.expiresOn, '2027-08-13T04:00:00Z')
		assert.deepEqual(snapshot.nameservers, ['a.iana-servers.net'])
	})
})

describe('whois referrals', () => {
	it('reads IANA whois: referrals', () => {
		assert.equal(
			extractReferralHost('% IANA\nwhois:        whois.nic.sh\n'),
			'whois.nic.sh',
		)
	})

	it('reads registrar whois hosts from thin registry answers', () => {
		assert.equal(
			extractRegistrarWhoisHost(
				'Registrar WHOIS Server: whois.cloudflare.com\n',
			),
			'whois.cloudflare.com',
		)
	})
})
