import assert from 'node:assert/strict'
import { describe, it } from 'node:test'

import { mintNotifyMAC, verifyNotifyMAC, webhookSecret } from './hmac.ts'

const SECRET = 'unit-test-hmac-secret'
const TOKEN = 'a'.repeat(64)

describe('notify MAC', () => {
	it('round-trips mint → verify', async () => {
		const mac = await mintNotifyMAC(SECRET, 'production', TOKEN)
		assert.match(mac, /^[0-9a-f]{64}$/)
		assert.equal(await verifyNotifyMAC(SECRET, 'production', TOKEN, mac), true)
	})

	it('rejects a flipped byte and a wrong environment', async () => {
		const mac = await mintNotifyMAC(SECRET, 'production', TOKEN)
		const flipped = `${mac.slice(0, -1)}${mac.endsWith('0') ? '1' : '0'}`
		assert.equal(await verifyNotifyMAC(SECRET, 'production', TOKEN, flipped), false)
		assert.equal(await verifyNotifyMAC(SECRET, 'sandbox', TOKEN, mac), false)
	})

	it('rejects non-hex MAC input without throwing', async () => {
		assert.equal(await verifyNotifyMAC(SECRET, 'production', TOKEN, 'not-hex'), false)
	})
})

describe('webhookSecret', () => {
	it('is stable and distinct from the notify MAC', async () => {
		const mac = await mintNotifyMAC(SECRET, 'sandbox', TOKEN)
		const secret = await webhookSecret(SECRET, 'sandbox', TOKEN)
		const again = await webhookSecret(SECRET, 'sandbox', TOKEN)
		assert.equal(secret, again)
		assert.notEqual(secret, mac)
		assert.match(secret, /^[0-9a-f]{64}$/)
	})
})
