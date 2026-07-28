import assert from 'node:assert/strict'
import { describe, it } from 'node:test'

import {
	baseForDomain,
	parseBootstrap,
	rdapDomainUrl,
	readCachedBootstrap,
} from './rdap-bootstrap.ts'
import { parseRdapJson } from './rdap-parse.ts'
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

	it('strips the root dot from fully-qualified nameservers', () => {
		// bbc.co.uk answers RDAP with trailing dots; the WHOIS leg returns them
		// bare. Both legs feed the same zone card, so they have to agree.
		const snapshot = parseRdapJson({
			ldhName: 'bbc.co.uk',
			nameservers: [
				{ ldhName: 'DDNS0.BBC.CO.UK.' },
				{ ldhName: 'dns0.bbc.com.' },
			],
		}, 'bbc.co.uk')
		assert.ok(snapshot)
		assert.deepEqual(snapshot.nameservers, ['ddns0.bbc.co.uk', 'dns0.bbc.com'])
	})

	it('prefers the registrar name over its IANA handle', () => {
		// Verisign answers .com with both; the handle is the bare id "1910".
		const snapshot = parseRdapJson({
			entities: [{
				handle: '1910',
				publicIds: [{ identifier: '1910', type: 'IANA Registrar ID' }],
				roles: ['registrar'],
				vcardArray: ['vcard', [
					['version', {}, 'text', '4.0'],
					['fn', {}, 'text', 'Cloudflare, Inc.'],
				]],
			}],
			ldhName: 'cloudflare.com',
		}, 'cloudflare.com')
		assert.ok(snapshot)
		assert.equal(snapshot.registrar, 'Cloudflare, Inc.')
	})

	it('falls back to the handle when the entity carries no vCard name', () => {
		const snapshot = parseRdapJson({
			entities: [{ handle: 'Registry Operator', roles: ['registrar'] }],
			ldhName: 'example.test',
		}, 'example.test')
		assert.ok(snapshot)
		assert.equal(snapshot.registrar, 'Registry Operator')
	})
})

describe('parseBootstrap', () => {
	const document = {
		publication: '2026-07-23T02:00:03Z',
		services: [
			[['com'], ['https://rdap.verisign.com/com/v1/']],
			[['app', 'DEV'], ['https://pubapi.registry.google/rdap']],
			[['kg'], ['http://rdap.cctld.kg/']],
			[['legacy'], ['http://old.example', 'https://new.example/rdap/']],
			[['broken'], ['not a url']],
			[['nourls'], []],
			[['short']],
		],
	}

	it('maps every tld in a service entry and normalizes the base url', () => {
		const bootstrap = parseBootstrap(document)
		assert.ok(bootstrap)
		assert.equal(bootstrap.publication, '2026-07-23T02:00:03Z')
		assert.equal(bootstrap.tlds.com, 'https://rdap.verisign.com/com/v1/')
		assert.equal(bootstrap.tlds.app, 'https://pubapi.registry.google/rdap/')
		assert.equal(bootstrap.tlds.dev, 'https://pubapi.registry.google/rdap/')
	})

	it('prefers https and keeps http only when it is all a registry publishes', () => {
		const bootstrap = parseBootstrap(document)
		assert.ok(bootstrap)
		assert.equal(bootstrap.tlds.legacy, 'https://new.example/rdap/')
		assert.equal(bootstrap.tlds.kg, 'http://rdap.cctld.kg/')
	})

	it('drops unusable entries instead of failing the whole file', () => {
		const bootstrap = parseBootstrap(document)
		assert.ok(bootstrap)
		assert.equal(bootstrap.tlds.broken, undefined)
		assert.equal(bootstrap.tlds.nourls, undefined)
		assert.equal(bootstrap.tlds.short, undefined)
	})

	it('rejects a body that is not a bootstrap file', () => {
		assert.equal(parseBootstrap(null), null)
		assert.equal(parseBootstrap({ services: 'nope' }), null)
		assert.equal(parseBootstrap({ services: [] }), null)
	})
})

describe('readCachedBootstrap', () => {
	it('round-trips what loadBootstrap writes to the Cache API', () => {
		const parsed = parseBootstrap({
			publication: '2026-07-23T02:00:03Z',
			services: [[['com'], ['https://rdap.verisign.com/com/v1/']]],
		})
		assert.ok(parsed)
		// Response.json → cached.json() is a JSON round-trip and nothing more.
		const restored = readCachedBootstrap(JSON.parse(JSON.stringify(parsed)))
		assert.deepEqual(restored, parsed)
	})

	it('rejects an entry written under an older shape', () => {
		assert.equal(readCachedBootstrap({ tlds: {} }), null)
		assert.equal(readCachedBootstrap({ com: 'https://rdap.verisign.com/' }), null)
		assert.equal(readCachedBootstrap(null), null)
	})
})

describe('baseForDomain', () => {
	const tlds = {
		'com': 'https://rdap.verisign.com/com/v1/',
		'com.br': 'https://rdap.registro.br/',
	}

	it('resolves a tld regardless of case or trailing dot', () => {
		assert.equal(baseForDomain(tlds, 'Example.COM.'), tlds.com)
	})

	it('prefers the longest matching suffix', () => {
		assert.equal(baseForDomain(tlds, 'nic.com.br'), tlds['com.br'])
	})

	it('returns null for a tld iana does not bootstrap', () => {
		// .sh, .io and .de are genuinely absent — these fall through to rdap.org.
		assert.equal(baseForDomain(tlds, 'xat.sh'), null)
	})
})

describe('rdapDomainUrl', () => {
	it('joins the registry base with the domain path', () => {
		assert.equal(
			rdapDomainUrl('https://rdap.verisign.com/com/v1/', 'example.com'),
			'https://rdap.verisign.com/com/v1/domain/example.com',
		)
	})

	it('tolerates a base url without a trailing slash', () => {
		assert.equal(
			rdapDomainUrl('https://rdap.example/rdap', 'example.com'),
			'https://rdap.example/rdap/domain/example.com',
		)
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
