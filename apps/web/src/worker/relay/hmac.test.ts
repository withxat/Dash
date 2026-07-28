import assert from 'node:assert/strict'
import { describe, it } from 'node:test'

import {
	mintNotifyMAC,
	verifyNotifyMAC,
	verifyWebhookSecret,
	webhookSecret,
} from './hmac.ts'

const SECRET = 'unit-test-hmac-secret'
const TOKEN = 'a'.repeat(64)
const ACCOUNT_ID = 'b'.repeat(32)

describe('notify MAC', () => {
	it('round-trips mint → verify', async () => {
		const mac = await mintNotifyMAC(SECRET, 'production', TOKEN, ACCOUNT_ID)
		assert.match(mac, /^[0-9a-f]{64}$/)
		assert.equal(
			await verifyNotifyMAC(SECRET, 'production', TOKEN, mac, ACCOUNT_ID),
			true,
		)
	})

	it('rejects a flipped byte, wrong environment, and wrong account', async () => {
		const mac = await mintNotifyMAC(SECRET, 'production', TOKEN, ACCOUNT_ID)
		const flipped = `${mac.slice(0, -1)}${mac.endsWith('0') ? '1' : '0'}`
		assert.equal(
			await verifyNotifyMAC(SECRET, 'production', TOKEN, flipped, ACCOUNT_ID),
			false,
		)
		assert.equal(
			await verifyNotifyMAC(SECRET, 'sandbox', TOKEN, mac, ACCOUNT_ID),
			false,
		)
		assert.equal(
			await verifyNotifyMAC(SECRET, 'production', TOKEN, mac, 'other-account'),
			false,
		)
	})

	it('rejects non-hex MAC input without throwing', async () => {
		assert.equal(
			await verifyNotifyMAC(SECRET, 'production', TOKEN, 'not-hex', ACCOUNT_ID),
			false,
		)
	})

	it('continues to verify legacy accountless URLs', async () => {
		const mac = await mintNotifyMAC(SECRET, 'production', TOKEN)
		assert.equal(await verifyNotifyMAC(SECRET, 'production', TOKEN, mac), true)
	})
})

describe('webhookSecret', () => {
	it('is stable and distinct from the notify MAC', async () => {
		const mac = await mintNotifyMAC(SECRET, 'sandbox', TOKEN, ACCOUNT_ID)
		const secret = await webhookSecret(SECRET, 'sandbox', TOKEN, ACCOUNT_ID)
		const again = await webhookSecret(SECRET, 'sandbox', TOKEN, ACCOUNT_ID)
		assert.equal(secret, again)
		assert.notEqual(secret, mac)
		assert.notEqual(
			secret,
			await webhookSecret(SECRET, 'sandbox', TOKEN, 'other-account'),
		)
		assert.match(secret, /^[0-9a-f]{64}$/)
		assert.equal(
			await verifyWebhookSecret(
				SECRET,
				'sandbox',
				TOKEN,
				secret,
				ACCOUNT_ID,
			),
			true,
		)
		assert.equal(
			await verifyWebhookSecret(
				SECRET,
				'sandbox',
				TOKEN,
				`${secret.slice(0, -1)}${secret.endsWith('0') ? '1' : '0'}`,
				ACCOUNT_ID,
			),
			false,
		)
	})
})
