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

export async function sendAlert(
	env: Env,
	host: APNsHost,
	deviceToken: string,
	alert: AlertPayload,
): Promise<APNsResult> {
	const jwt = await mintJWT(env)
	const aps: Record<string, unknown> = {
		'alert': { body: alert.body, title: alert.title },
		'interruption-level': 'time-sensitive',
		'sound': 'default',
	}
	const payloadObject: Record<string, unknown> = { aps }
	if (alert.dashRoute) {
		payloadObject.dashRoute = alert.dashRoute
	}
	const payload = JSON.stringify(payloadObject)

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
