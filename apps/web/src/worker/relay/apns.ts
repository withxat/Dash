/**
 * APNs HTTP/2 client using a .p8 AuthKey (ES256 JWT).
 *
 * WebCrypto's ECDSA sign output is raw r‖s (64 bytes) — exactly what JWS ES256
 * wants. Do not DER-decode; that is the classic pitfall when porting from
 * Node's crypto.createSign.
 *
 * JWT is cached at module scope for 50 minutes (Apple allows 20–60). Across
 * isolates the worker may mint a few extras; Cloudflare's alert_interval
 * upstream keeps APNs from being hammered.
 */

import type { Env } from '../env'
import type { AlertPayload } from './alert'

const JWT_TTL_SECONDS = 50 * 60

interface CachedJWT {
	expiresAt: number
	token: string
}

let cachedJWT: CachedJWT | null = null

function base64url(data: ArrayBuffer | string | Uint8Array): string {
	const bytes
		= typeof data === 'string'
			? new TextEncoder().encode(data)
			: data instanceof Uint8Array
				? data
				: new Uint8Array(data)
	let binary = ''
	for (const b of bytes) binary += String.fromCharCode(b)
	return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

function pemToArrayBuffer(pem: string): ArrayBuffer {
	const b64 = pem
		.replace(/-----BEGIN PRIVATE KEY-----/, '')
		.replace(/-----END PRIVATE KEY-----/, '')
		.replace(/\s+/g, '')
	const binary = atob(b64)
	const bytes = new Uint8Array(binary.length)
	for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i)
	return bytes.buffer
}

async function importAPNsKey(pem: string): Promise<CryptoKey> {
	return crypto.subtle.importKey(
		'pkcs8',
		pemToArrayBuffer(pem),
		{ name: 'ECDSA', namedCurve: 'P-256' },
		false,
		['sign'],
	)
}

async function mintJWT(env: Env): Promise<string> {
	const now = Math.floor(Date.now() / 1000)
	if (cachedJWT && cachedJWT.expiresAt > now + 60) {
		return cachedJWT.token
	}

	const header = base64url(JSON.stringify({ alg: 'ES256', kid: env.APNS_KEY_ID }))
	const claims = base64url(JSON.stringify({ iat: now, iss: env.APNS_TEAM_ID }))
	const signingInput = `${header}.${claims}`
	const key = await importAPNsKey(env.APNS_KEY_P8)
	const signature = await crypto.subtle.sign(
		{ hash: 'SHA-256', name: 'ECDSA' },
		key,
		new TextEncoder().encode(signingInput),
	)
	const token = `${signingInput}.${base64url(signature)}`
	cachedJWT = { expiresAt: now + JWT_TTL_SECONDS, token }
	return token
}

export function clearJWTCache(): void {
	cachedJWT = null
}

export type APNsHost = 'api.push.apple.com' | 'api.sandbox.push.apple.com'

export function hostForEnvironment(environment: string): APNsHost {
	return environment === 'sandbox' ? 'api.sandbox.push.apple.com' : 'api.push.apple.com'
}

export function alternateHost(host: APNsHost): APNsHost {
	return host === 'api.push.apple.com'
		? 'api.sandbox.push.apple.com'
		: 'api.push.apple.com'
}

export interface APNsResult {
	reason?: string
	status: number
}

/**
 * Builds the APNs JSON body. Exported for tests: the payload shape is a
 * contract with the app's Notification Service Extension and its registered
 * categories, and it is cheaper to assert here than to read it off a device.
 */
export function alertPayloadJSON(alert: AlertPayload, accountID?: string): string {
	const aps: Record<string, unknown> = {
		// Failure-safe Lock Screen copy. The Notification Service Extension
		// restores/localizes the Cloudflare copy only after its account allowlist
		// check. If iOS skips the extension, stale-account resource names still
		// never appear in the visible notification.
		'alert': {
			body: 'Open Dash to sync your Cloudflare alerts.',
			title: 'Dash',
		},
		'interruption-level': alert.interruptionLevel,
		// Lets the extension rewrite the English body into the user's language
		// and stamp the badge before iOS displays anything.
		'mutable-content': 1,
		'relevance-score': alert.relevanceScore,
		'sound': 'default',
	}
	if (alert.category) {
		aps.category = alert.category
	}
	if (alert.threadID) {
		aps['thread-id'] = alert.threadID
	}

	const payloadObject: Record<string, unknown> = { aps }
	payloadObject.dashOriginalTitle = alert.title
	payloadObject.dashOriginalBody = alert.body
	if (alert.dashRoute) {
		payloadObject.dashRoute = alert.dashRoute
	}
	if (alert.alertType) {
		payloadObject.dashAlertType = alert.alertType
	}
	if (alert.subject) {
		payloadObject.dashSubject = alert.subject
	}
	if (accountID) {
		payloadObject.dashAccountID = accountID
	}
	return JSON.stringify(payloadObject)
}

export async function sendAlert(
	env: Env,
	host: APNsHost,
	deviceToken: string,
	alert: AlertPayload,
	accountID?: string,
): Promise<APNsResult> {
	const jwt = await mintJWT(env)
	const headers: Record<string, string> = {
		'apns-priority': '10',
		'apns-push-type': 'alert',
		'apns-topic': env.APNS_TOPIC,
		'authorization': `bearer ${jwt}`,
		'content-type': 'application/json',
	}
	if (alert.collapseID) {
		headers['apns-collapse-id'] = alert.collapseID
	}

	return post(host, deviceToken, headers, alertPayloadJSON(alert, accountID))
}

export interface RegistrationChallengePayload {
	nonce: string
	requestID: string
	ticket: string
}

export function registrationChallengePayloadJSON(
	challenge: RegistrationChallengePayload,
): string {
	return JSON.stringify({
		aps: { 'content-available': 1 },
		dashKind: 'registration-challenge',
		nonce: challenge.nonce,
		requestID: challenge.requestID,
		ticket: challenge.ticket,
	})
}

/**
 * Delivers the proof material only to the APNs token being registered.
 *
 * A fixed collapse id means repeated start requests for one device replace
 * each other in APNs rather than queueing background wakes. Expiration zero
 * prevents a stale challenge from being stored for later delivery.
 */
export async function sendRegistrationChallenge(
	env: Env,
	host: APNsHost,
	deviceToken: string,
	challenge: RegistrationChallengePayload,
): Promise<APNsResult> {
	const jwt = await mintJWT(env)
	const headers: Record<string, string> = {
		'apns-collapse-id': 'dash-registration',
		'apns-expiration': '0',
		'apns-priority': '5',
		'apns-push-type': 'background',
		'apns-topic': env.APNS_TOPIC,
		'authorization': `bearer ${jwt}`,
		'content-type': 'application/json',
	}
	return post(
		host,
		deviceToken,
		headers,
		registrationChallengePayloadJSON(challenge),
	)
}

/**
 * Silent companion push that wakes the app to refresh the Watchtower snapshot
 * and reload the widget, so the Lock Screen unread count is right without the
 * user opening Dash. Best-effort by design: iOS budgets background pushes, and
 * the alert above is what the user actually sees.
 *
 * Sent as its own request rather than folded into the alert — a payload with
 * both `alert` and `content-available` is delivered as an alert and the
 * background handler only runs if the user taps it, which is exactly the case
 * this is meant to cover.
 */
export async function sendBackgroundRefresh(
	env: Env,
	host: APNsHost,
	deviceToken: string,
	accountID?: string,
): Promise<APNsResult> {
	const jwt = await mintJWT(env)
	const headers: Record<string, string> = {
		'apns-priority': '5',
		'apns-push-type': 'background',
		'apns-topic': env.APNS_TOPIC,
		'authorization': `bearer ${jwt}`,
		'content-type': 'application/json',
	}
	return post(
		host,
		deviceToken,
		headers,
		backgroundRefreshPayloadJSON(accountID),
	)
}

export function backgroundRefreshPayloadJSON(accountID?: string): string {
	const payload: Record<string, unknown> = {
		aps: { 'content-available': 1 },
	}
	if (accountID) {
		payload.dashAccountID = accountID
	}
	return JSON.stringify(payload)
}

async function post(
	host: APNsHost,
	deviceToken: string,
	headers: Record<string, string>,
	payload: string,
): Promise<APNsResult> {
	const response = await fetch(`https://${host}/3/device/${deviceToken}`, {
		body: payload,
		headers,
		method: 'POST',
	})

	let reason: string | undefined
	if (!response.ok) {
		try {
			const err = (await response.json()) as { reason?: string }
			reason = err.reason
		}
		catch {
			// ignore parse failures
		}
	}
	return { reason, status: response.status }
}
