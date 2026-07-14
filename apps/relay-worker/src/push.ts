/**
 * Push registration: mint a signed Cloudflare webhook URL for a device token.
 *
 * POST /push/register  { token, environment: "sandbox" | "production" }
 * → { url, secret }
 *
 * The URL is a bearer capability for that one device; the secret is the
 * derived cf-webhook-auth value Cloudflare will send on notify.
 */

import type { Env } from './env'

import { mintNotifyMAC, webhookSecret } from './hmac'

const TOKEN_RE = /^[0-9a-f]{64,200}$/i
const ENVIRONMENTS = new Set(['sandbox', 'production'])
const MAX_BODY_BYTES = 4096

export async function handlePush(request: Request, url: URL, env: Env): Promise<Response> {
	if (url.pathname === '/push/register') {
		return register(request, url, env)
	}
	return new Response('Not Found', { status: 404 })
}

async function register(request: Request, url: URL, env: Env): Promise<Response> {
	if (request.method !== 'POST') {
		return new Response('Method Not Allowed', { status: 405 })
	}

	if (!env.PUSH_HMAC_SECRET) {
		return new Response('Push not configured', { status: 503 })
	}

	const raw = await request.arrayBuffer()
	if (raw.byteLength === 0 || raw.byteLength > MAX_BODY_BYTES) {
		return new Response('Bad Request', { status: 400 })
	}

	let body: unknown
	try {
		body = JSON.parse(new TextDecoder().decode(raw))
	}
	catch {
		return new Response('Bad Request', { status: 400 })
	}

	if (!body || typeof body !== 'object') {
		return new Response('Bad Request', { status: 400 })
	}

	const { environment, token } = body as Record<string, unknown>
	if (typeof token !== 'string' || !TOKEN_RE.test(token)) {
		return new Response('Bad Request', { status: 400 })
	}
	if (typeof environment !== 'string' || !ENVIRONMENTS.has(environment)) {
		return new Response('Bad Request', { status: 400 })
	}

	const mac = await mintNotifyMAC(env.PUSH_HMAC_SECRET, environment, token)
	const secret = await webhookSecret(env.PUSH_HMAC_SECRET, environment, token)
	// Host from the request origin so workers.dev and the custom domain both work.
	const notifyURL = `${url.origin}/push/notify/${environment}.${token}.${mac}`

	return Response.json({ secret, url: notifyURL })
}
