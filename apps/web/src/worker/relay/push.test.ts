import assert from 'node:assert/strict'
import { describe, it } from 'node:test'

import { mintNotifyMAC, webhookSecret } from './hmac.ts'
import {
	isDeviceToken,
	isPushEnvironment,
	parseNotifyPath,
} from './push-validate.ts'

const TOKEN = 'b'.repeat(64)
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

	it('parses notify paths case-insensitively', () => {
		const mac = 'c'.repeat(64)
		assert.deepEqual(
			parseNotifyPath(`/push/notify/SandBox.${TOKEN.toUpperCase()}.${mac.toUpperCase()}`),
			{ environment: 'sandbox', mac, token: TOKEN },
		)
		assert.equal(parseNotifyPath('/push/notify/nope'), null)
		assert.equal(parseNotifyPath('/push/register'), null)
	})
})

describe('register URL minting', () => {
	it('composes the signed notify URL the app stores as the webhook destination', async () => {
		const mac = await mintNotifyMAC(HMAC, 'sandbox', TOKEN)
		const secret = await webhookSecret(HMAC, 'sandbox', TOKEN)
		const url = `${ORIGIN}/push/notify/sandbox.${TOKEN}.${mac}`
		assert.match(mac, /^[0-9a-f]{64}$/)
		assert.match(secret, /^[0-9a-f]{64}$/)
		assert.notEqual(secret, mac)
		assert.equal(parseNotifyPath(new URL(url).pathname)?.mac, mac)
	})
})
