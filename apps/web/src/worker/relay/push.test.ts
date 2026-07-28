import type { Env } from '../env.ts'
import type { RegistrationChallengePayload } from './apns.ts'
import type { PushDependencies } from './push.ts'

import assert from 'node:assert/strict'
import { describe, it } from 'node:test'

import { registrationChallengePayloadJSON } from './apns.ts'
import { mintNotifyMAC, webhookSecret } from './hmac.ts'
import {
	openNotifyBinding,
	REGISTRATION_TICKET_TTL_SECONDS,
} from './push-crypto.ts'
import {
	accountBoundDashRoute,
	isAccountID,
	isDeviceToken,
	isPushEnvironment,
	isRequestID,
	notifyPath,
	parseNotifyPath,
	scopeDashRoute,
} from './push-validate.ts'
import { handlePush } from './push.ts'

const TOKEN = 'b'.repeat(64)
const ACCOUNT_ID = 'a'.repeat(32)
const REQUEST_ID = 'request_1234-5678'
const HMAC = 'unit-test-push-hmac'
const ORIGIN = 'https://dash.xat.sh'
const STARTED_AT = 1_720_000_000
const ALLOWING_RATE_LIMITER: RateLimit = {
	limit: async () => ({ success: true }),
}
const ENV: Env = {
	APNS_KEY_ID: 'KEY',
	APNS_KEY_P8: 'PRIVATE KEY',
	APNS_TEAM_ID: 'TEAM',
	APNS_TOPIC: 'sh.xat.dash.app',
	PUSH_HMAC_SECRET: HMAC,
	PUSH_REGISTRATION_ACTOR_LIMITER: ALLOWING_RATE_LIMITER,
	PUSH_REGISTRATION_GLOBAL_LIMITER: ALLOWING_RATE_LIMITER,
}

function post(path: string, body: unknown, headers?: HeadersInit): Request {
	return new Request(`${ORIGIN}${path}`, {
		body: JSON.stringify(body),
		headers: { 'content-type': 'application/json', ...headers },
		method: 'POST',
	})
}

async function startChallenge(
	nowSeconds = STARTED_AT,
): Promise<{ challenge: RegistrationChallengePayload, response: Response }> {
	let challenge: RegistrationChallengePayload | undefined
	const request = post('/push/register/start', {
		accountID: ACCOUNT_ID,
		environment: 'sandbox',
		requestID: REQUEST_ID,
		token: TOKEN,
	})
	const response = await handlePush(
		request,
		new URL(request.url),
		ENV,
		undefined,
		{
			nowSeconds: () => nowSeconds,
			sendRegistrationChallenge: async (_env, host, token, value) => {
				assert.equal(host, 'api.sandbox.push.apple.com')
				assert.equal(token, TOKEN)
				challenge = value
				return { status: 200 }
			},
		},
	)
	assert.ok(challenge)
	return { challenge, response }
}

async function completeChallenge(
	challenge: RegistrationChallengePayload,
	nowSeconds = STARTED_AT,
): Promise<Response> {
	const request = post('/push/register/complete', {
		nonce: challenge.nonce,
		ticket: challenge.ticket,
	})
	return handlePush(
		request,
		new URL(request.url),
		ENV,
		undefined,
		{ nowSeconds: () => nowSeconds },
	)
}

describe('push validators', () => {
	it('accepts only bounded request ids, account ids, tokens, and environments', () => {
		assert.equal(isDeviceToken(TOKEN), true)
		assert.equal(isDeviceToken('deadbeef'), false)
		assert.equal(isDeviceToken(`${TOKEN}zz`), false)
		assert.equal(isPushEnvironment('sandbox'), true)
		assert.equal(isPushEnvironment('production'), true)
		assert.equal(isPushEnvironment('prod'), false)
		assert.equal(isAccountID(ACCOUNT_ID), true)
		assert.equal(isAccountID('account_demo-1'), true)
		assert.equal(isAccountID(''), false)
		assert.equal(isAccountID('account.with.dot'), false)
		assert.equal(isRequestID(REQUEST_ID), true)
		assert.equal(isRequestID(''), false)
		assert.equal(isRequestID('x'.repeat(129)), false)
	})

	it('parses opaque and migration-era notify paths', () => {
		const opaque = 'z'.repeat(80)
		const mac = 'c'.repeat(64)
		assert.deepEqual(parseNotifyPath(`/push/notify/${opaque}`), {
			kind: 'opaque',
			sealedBinding: opaque,
		})
		assert.deepEqual(
			parseNotifyPath(
				`/push/notify/SandBox.${TOKEN.toUpperCase()}.${ACCOUNT_ID}.${mac.toUpperCase()}`,
			),
			{
				accountID: ACCOUNT_ID,
				environment: 'sandbox',
				kind: 'legacy',
				mac,
				token: TOKEN,
			},
		)
		assert.deepEqual(
			parseNotifyPath(`/push/notify/SandBox.${TOKEN.toUpperCase()}.${mac.toUpperCase()}`),
			{ environment: 'sandbox', kind: 'legacy', mac, token: TOKEN },
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

describe('APNs possession registration', () => {
	it('exposes no capability at start and sends proof material only via APNs', async () => {
		const { challenge, response } = await startChallenge()
		assert.equal(response.status, 202)
		assert.equal(response.headers.get('cache-control'), 'no-store')
		assert.equal(await response.text(), '')

		const payload = JSON.parse(registrationChallengePayloadJSON(challenge))
		assert.deepEqual(Object.keys(payload).sort(), [
			'aps',
			'dashKind',
			'nonce',
			'requestID',
			'ticket',
		])
		assert.deepEqual(payload.aps, { 'content-available': 1 })
		assert.equal(payload.dashKind, 'registration-challenge')
		assert.equal(payload.requestID, REQUEST_ID)
		assert.equal(typeof payload.ticket, 'string')
		assert.equal(typeof payload.nonce, 'string')
		assert.equal('url' in payload, false)
		assert.equal('secret' in payload, false)
	})

	it('returns an opaque usable capability only after completion', async () => {
		const { challenge } = await startChallenge()
		const response = await completeChallenge(challenge)
		assert.equal(response.status, 200)
		assert.equal(response.headers.get('cache-control'), 'no-store')
		const capability = await response.json() as { secret: string, url: string }
		assert.match(capability.secret, /^[0-9a-f]{64}$/)

		const notifyURL = new URL(capability.url)
		assert.equal(notifyURL.origin, ORIGIN)
		assert.equal(notifyURL.pathname.includes(TOKEN), false)
		assert.equal(notifyURL.pathname.includes(ACCOUNT_ID), false)
		assert.equal(notifyURL.pathname.includes('sandbox'), false)
		const parsed = parseNotifyPath(notifyURL.pathname)
		assert.equal(parsed?.kind, 'opaque')
		assert.ok(parsed && parsed.kind === 'opaque')

		const binding = await openNotifyBinding(HMAC, parsed.sealedBinding)
		assert.deepEqual(binding, {
			accountID: ACCOUNT_ID,
			environment: 'sandbox',
			issuedAt: STARTED_AT,
			token: TOKEN,
			version: 1,
		})

		let deliveredAccount: string | undefined
		let backgroundAccount: string | undefined
		const dependencies = {
			sendAlert: async (_env, _host, token, alert, accountID) => {
				assert.equal(token, TOKEN)
				assert.equal(alert.dashRoute, `dash://watchtower?account=${ACCOUNT_ID}`)
				deliveredAccount = accountID
				return { status: 200 }
			},
			sendBackgroundRefresh: async (_env, _host, token, accountID) => {
				assert.equal(token, TOKEN)
				backgroundAccount = accountID
				return { status: 200 }
			},
		} satisfies PushDependencies
		const notifyRequest = new Request(capability.url, {
			body: JSON.stringify({ text: 'Account alert' }),
			headers: { 'cf-webhook-auth': capability.secret },
			method: 'POST',
		})
		const notifyResponse = await handlePush(
			notifyRequest,
			notifyURL,
			ENV,
			undefined,
			dependencies,
		)
		assert.equal(notifyResponse.status, 200)
		assert.equal(deliveredAccount, ACCOUNT_ID)
		assert.equal(backgroundAccount, ACCOUNT_ID)
	})

	it('documents deterministic, idempotent replay within the ticket lifetime', async () => {
		const { challenge } = await startChallenge()
		const first = await completeChallenge(challenge)
		const second = await completeChallenge(challenge)
		assert.equal(first.status, 200)
		assert.equal(second.status, 200)
		assert.deepEqual(await second.json(), await first.json())
	})

	it('rejects a wrong nonce, a tampered ticket, and an expired ticket identically', async () => {
		const { challenge } = await startChallenge()
		const wrongNonce = `${challenge.nonce.startsWith('A') ? 'B' : 'A'}${challenge.nonce.slice(1)}`
		const wrongNonceRequest = post('/push/register/complete', {
			nonce: wrongNonce,
			ticket: challenge.ticket,
		})
		const wrongNonceResponse = await handlePush(
			wrongNonceRequest,
			new URL(wrongNonceRequest.url),
			ENV,
			undefined,
			{ nowSeconds: () => STARTED_AT },
		)

		const tamperedTicket = `${challenge.ticket.startsWith('A') ? 'B' : 'A'}${challenge.ticket.slice(1)}`
		const tamperedRequest = post('/push/register/complete', {
			nonce: challenge.nonce,
			ticket: tamperedTicket,
		})
		const tamperedResponse = await handlePush(
			tamperedRequest,
			new URL(tamperedRequest.url),
			ENV,
			undefined,
			{ nowSeconds: () => STARTED_AT },
		)

		const expiredResponse = await completeChallenge(
			challenge,
			STARTED_AT + REGISTRATION_TICKET_TTL_SECONDS,
		)
		for (const response of [wrongNonceResponse, tamperedResponse, expiredResponse]) {
			assert.equal(response.status, 401)
			assert.equal(await response.text(), 'Unauthorized')
		}
	})

	it('keeps ticket and notify-binding AEAD contexts non-interchangeable', async () => {
		const { challenge } = await startChallenge()
		const completed = await completeChallenge(challenge)
		const capability = await completed.json() as { secret: string, url: string }
		const parsed = parseNotifyPath(new URL(capability.url).pathname)
		assert.ok(parsed && parsed.kind === 'opaque')

		const request = post('/push/register/complete', {
			nonce: challenge.nonce,
			ticket: parsed.sealedBinding,
		})
		const response = await handlePush(
			request,
			new URL(request.url),
			ENV,
			undefined,
			{ nowSeconds: () => STARTED_AT },
		)
		assert.equal(response.status, 401)
		assert.equal(await response.text(), 'Unauthorized')
	})

	it('rejects an altered opaque binding or webhook secret before APNs delivery', async () => {
		const { challenge } = await startChallenge()
		const completed = await completeChallenge(challenge)
		const capability = await completed.json() as { secret: string, url: string }
		let delivered = false
		const dependencies = {
			sendAlert: async () => {
				delivered = true
				return { status: 200 }
			},
		} satisfies PushDependencies

		const wrongSecret = `${capability.secret.slice(0, -1)}${
			capability.secret.endsWith('0') ? '1' : '0'
		}`
		const wrongSecretRequest = new Request(capability.url, {
			body: '{}',
			headers: { 'cf-webhook-auth': wrongSecret },
			method: 'POST',
		})
		const wrongSecretResponse = await handlePush(
			wrongSecretRequest,
			new URL(wrongSecretRequest.url),
			ENV,
			undefined,
			dependencies,
		)

		const url = new URL(capability.url)
		const component = url.pathname.slice('/push/notify/'.length)
		const tampered = `${component.startsWith('A') ? 'B' : 'A'}${component.slice(1)}`
		const tamperedURL = `${url.origin}/push/notify/${tampered}`
		const tamperedRequest = new Request(tamperedURL, {
			body: '{}',
			headers: { 'cf-webhook-auth': capability.secret },
			method: 'POST',
		})
		const tamperedResponse = await handlePush(
			tamperedRequest,
			new URL(tamperedURL),
			ENV,
			undefined,
			dependencies,
		)

		assert.equal(wrongSecretResponse.status, 401)
		assert.equal(tamperedResponse.status, 401)
		assert.equal(delivered, false)
	})

	it('rejects incomplete, accountless, and oversized registration bodies', async () => {
		const incomplete = post('/push/register/complete', { nonce: 'missing-ticket' })
		assert.equal(
			(await handlePush(incomplete, new URL(incomplete.url), ENV)).status,
			400,
		)

		const accountless = post('/push/register/start', {
			environment: 'sandbox',
			requestID: REQUEST_ID,
			token: TOKEN,
		})
		assert.equal(
			(await handlePush(accountless, new URL(accountless.url), ENV)).status,
			400,
		)

		const oversized = post('/push/register/start', { padding: 'x'.repeat(5000) })
		assert.equal(
			(await handlePush(oversized, new URL(oversized.url), ENV)).status,
			400,
		)
	})

	it('rejects an oversized alert body even when content-length understates it', async () => {
		const { challenge } = await startChallenge()
		const completed = await completeChallenge(challenge)
		const capability = await completed.json() as { secret: string, url: string }
		let delivered = false
		const request = new Request(capability.url, {
			body: 'x'.repeat(64 * 1024 + 1),
			headers: {
				'cf-webhook-auth': capability.secret,
				'content-length': '1',
			},
			method: 'POST',
		})
		const response = await handlePush(
			request,
			new URL(capability.url),
			ENV,
			undefined,
			{
				sendAlert: async () => {
					delivered = true
					return { status: 200 }
				},
			},
		)
		// Authenticated webhooks always receive 200 so Cloudflare does not
		// disable the destination; the oversized payload is simply not sent.
		assert.equal(response.status, 200)
		assert.equal(delivered, false)
	})

	it('returns no challenge material when APNs rejects the start delivery', async () => {
		const request = post('/push/register/start', {
			accountID: ACCOUNT_ID,
			environment: 'sandbox',
			requestID: REQUEST_ID,
			token: TOKEN,
		})
		const response = await handlePush(
			request,
			new URL(request.url),
			ENV,
			undefined,
			{
				sendRegistrationChallenge: async () => ({ status: 410 }),
			},
		)
		assert.equal(response.status, 502)
		assert.equal((await response.text()).includes('ticket'), false)
		assert.equal(response.headers.get('cache-control'), null)
	})

	it('does not let legacy URL fields re-mint a capability', async () => {
		const legacyMAC = await mintNotifyMAC(HMAC, 'sandbox', TOKEN, ACCOUNT_ID)
		const legacyPath = notifyPath('sandbox', TOKEN, legacyMAC, ACCOUNT_ID)
		const oldRegister = post('/push/register', {
			accountID: ACCOUNT_ID,
			environment: 'sandbox',
			token: TOKEN,
		})
		const oldResponse = await handlePush(oldRegister, new URL(oldRegister.url), ENV)
		assert.equal(oldResponse.status, 404)

		const { challenge, response } = await startChallenge()
		assert.equal(response.status, 202)
		assert.equal(await response.text(), '')
		const forgedComplete = post('/push/register/complete', {
			nonce: challenge.nonce,
			ticket: legacyPath,
		})
		const forgedResponse = await handlePush(
			forgedComplete,
			new URL(forgedComplete.url),
			ENV,
			undefined,
			{ nowSeconds: () => STARTED_AT },
		)
		assert.equal(forgedResponse.status, 401)
	})

	it('rate limits registration before sending anything to APNs', async () => {
		let challengeCalls = 0
		const denyingLimiter: RateLimit = {
			limit: async () => ({ success: false }),
		}
		const request = post('/push/register/start', {
			accountID: ACCOUNT_ID,
			environment: 'sandbox',
			requestID: REQUEST_ID,
			token: TOKEN,
		})
		const response = await handlePush(
			request,
			new URL(request.url),
			{
				...ENV,
				PUSH_REGISTRATION_ACTOR_LIMITER: denyingLimiter,
			},
			undefined,
			{
				sendRegistrationChallenge: async () => {
					challengeCalls++
					return { status: 200 }
				},
			},
		)
		assert.equal(response.status, 429)
		assert.equal(response.headers.get('retry-after'), '60')
		assert.equal(challengeCalls, 0)
	})

	it('keeps migration-era notify capabilities valid without exposing a mint route', async () => {
		const mac = await mintNotifyMAC(HMAC, 'sandbox', TOKEN, ACCOUNT_ID)
		const secret = await webhookSecret(HMAC, 'sandbox', TOKEN, ACCOUNT_ID)
		let delivered = false
		const path = notifyPath('sandbox', TOKEN, mac, ACCOUNT_ID)
		const request = new Request(`${ORIGIN}${path}`, {
			body: JSON.stringify({ text: 'Legacy delivery' }),
			headers: { 'cf-webhook-auth': secret },
			method: 'POST',
		})
		const response = await handlePush(
			request,
			new URL(request.url),
			ENV,
			undefined,
			{
				sendAlert: async () => {
					delivered = true
					return { status: 204 }
				},
			},
		)
		assert.equal(response.status, 200)
		assert.equal(delivered, true)
	})
})
