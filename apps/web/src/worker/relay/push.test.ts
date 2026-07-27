import assert from 'node:assert/strict'
import { describe, it } from 'node:test'

import { mintNotifyMAC, webhookSecret } from './hmac.ts'
import {
	accountBoundDashRoute,
	isAccountID,
	isDeviceToken,
	isPushEnvironment,
	notifyPath,
	parseNotifyPath,
	scopeDashRoute,
} from './push-validate.ts'

const TOKEN = 'b'.repeat(64)
const ACCOUNT_ID = 'a'.repeat(32)
const HMAC = 'unit-test-push-hmac'
const ORIGIN = 'https://dash.xat.sh'

describe('push validators', () => {
	it('accepts hex device tokens of APNs length', () => {
		assert.equal(isDeviceToken(TOKEN), true)
		assert.equal(isDeviceToken('deadbeef'), false)
		assert.equal(isDeviceToken(`${TOKEN}zz`), false)
	})

	it('accepts only sandbox and production', () => {
		assert.equal(isPushEnvironment('sandbox'), true)
		assert.equal(isPushEnvironment('production'), true)
		assert.equal(isPushEnvironment('prod'), false)
	})

	it('accepts bounded opaque account ids', () => {
		assert.equal(isAccountID(ACCOUNT_ID), true)
		assert.equal(isAccountID('account_demo-1'), true)
		assert.equal(isAccountID(''), false)
		assert.equal(isAccountID('account.with.dot'), false)
	})

	it('parses account-scoped and legacy notify paths case-insensitively', () => {
		const mac = 'c'.repeat(64)
		assert.deepEqual(
			parseNotifyPath(
				`/push/notify/SandBox.${TOKEN.toUpperCase()}.${ACCOUNT_ID}.${mac.toUpperCase()}`,
			),
			{ accountID: ACCOUNT_ID, environment: 'sandbox', mac, token: TOKEN },
		)
		assert.deepEqual(
			parseNotifyPath(`/push/notify/SandBox.${TOKEN.toUpperCase()}.${mac.toUpperCase()}`),
			{ environment: 'sandbox', mac, token: TOKEN },
		)
		assert.equal(parseNotifyPath('/push/notify/nope'), null)
		assert.equal(parseNotifyPath('/push/register'), null)
		assert.equal(
			parseNotifyPath(`/push/notify/sandbox.deadbeef.${ACCOUNT_ID}.${mac}`),
			null,
		)
		assert.equal(
			parseNotifyPath(`/push/notify/sandbox.${TOKEN}.${'a'.repeat(129)}.${mac}`),
			null,
		)
	})

	it('adds account context without discarding an existing query', () => {
		assert.equal(
			scopeDashRoute('dash://watchtower', ACCOUNT_ID),
			`dash://watchtower?account=${ACCOUNT_ID}`,
		)
		assert.equal(
			scopeDashRoute('dash://zone/z1?source=push', ACCOUNT_ID),
			`dash://zone/z1?source=push&account=${ACCOUNT_ID}`,
		)
		assert.equal(
			scopeDashRoute('dash://zone/z1?account=stale', ACCOUNT_ID),
			`dash://zone/z1?account=${ACCOUNT_ID}`,
		)
		assert.equal(
			scopeDashRoute('https://example.com/not-dash', ACCOUNT_ID),
			`dash://watchtower?account=${ACCOUNT_ID}`,
		)
		assert.equal(accountBoundDashRoute('dash://watchtower'), undefined)
	})
})

describe('register URL minting', () => {
	it('composes the signed notify URL the app stores as the webhook destination', async () => {
		const mac = await mintNotifyMAC(HMAC, 'sandbox', TOKEN, ACCOUNT_ID)
		const secret = await webhookSecret(HMAC, 'sandbox', TOKEN, ACCOUNT_ID)
		const url = `${ORIGIN}${notifyPath('sandbox', TOKEN, mac, ACCOUNT_ID)}`
		assert.match(mac, /^[0-9a-f]{64}$/)
		assert.match(secret, /^[0-9a-f]{64}$/)
		assert.notEqual(secret, mac)
		assert.deepEqual(parseNotifyPath(new URL(url).pathname), {
			accountID: ACCOUNT_ID,
			environment: 'sandbox',
			mac,
			token: TOKEN,
		})
	})

	it('keeps accountless registration compatible without inventing a scope', async () => {
		const mac = await mintNotifyMAC(HMAC, 'sandbox', TOKEN)
		const secret = await webhookSecret(HMAC, 'sandbox', TOKEN)
		assert.deepEqual(parseNotifyPath(notifyPath('sandbox', TOKEN, mac)), {
			environment: 'sandbox',
			mac,
			token: TOKEN,
		})
		assert.match(secret, /^[0-9a-f]{64}$/)
	})
})
