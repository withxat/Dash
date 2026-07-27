/**
 * Push routes: register a device, and forward Cloudflare alert webhooks to APNs.
 *
 * POST /push/register  { token, environment, accountID? } → { url, secret }
 * POST /push/notify/<env>.<token>.<account>.<hmac>  Cloudflare webhook → APNs
 *
 * Accountless registration/notify URLs remain accepted for older app
 * versions, but their notifications carry no resource deep link: the relay
 * cannot safely infer which account owns a legacy capability.
 *
 * Always returns 200 to Cloudflare on the notify path so a dead device token
 * cannot disable the whole webhook destination.
 */

import type { Env } from '../env'
import type { APNsHost } from './apns'

import { mapAlert } from './alert'
import {
	alternateHost,

	clearJWTCache,
	hostForEnvironment,
	sendAlert,
} from './apns'
import { mintNotifyMAC, verifyNotifyMAC, webhookSecret } from './hmac'
import {
	accountBoundDashRoute,
	isAccountID,
	isDeviceToken,
	isPushEnvironment,
	notifyPath,
	parseNotifyPath,
} from './push-validate'

const MAX_BODY_BYTES = 64 * 1024

export async function handlePush(request: Request, url: URL, env: Env): Promise<Response> {
	if (url.pathname === '/push/register') {
		return register(request, url, env)
	}

	const notify = parseNotifyPath(url.pathname)
	if (notify) {
		return notifyDevice(
			request,
			env,
			notify.environment,
			notify.token,
			notify.mac,
			notify.accountID,
		)
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
	if (raw.byteLength === 0 || raw.byteLength > 4096) {
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

	const { accountID, environment, token } = body as Record<string, unknown>
	if (typeof token !== 'string' || !isDeviceToken(token)) {
		return new Response('Bad Request', { status: 400 })
	}
	if (typeof environment !== 'string' || !isPushEnvironment(environment)) {
		return new Response('Bad Request', { status: 400 })
	}
	if (accountID !== undefined && (typeof accountID !== 'string' || !isAccountID(accountID))) {
		return new Response('Bad Request', { status: 400 })
	}
	const scopedAccountID = typeof accountID === 'string' ? accountID : undefined

	const mac = await mintNotifyMAC(env.PUSH_HMAC_SECRET, environment, token, scopedAccountID)
	const secret = await webhookSecret(env.PUSH_HMAC_SECRET, environment, token, scopedAccountID)
	const notifyURL = `${url.origin}${notifyPath(environment, token, mac, scopedAccountID)}`

	return Response.json({ secret, url: notifyURL })
}

async function notifyDevice(
	request: Request,
	env: Env,
	environment: string,
	token: string,
	mac: string,
	accountID?: string,
): Promise<Response> {
	// Always 200 to Cloudflare after auth — a single dead token must not
	// disable the webhook destination.
	const ok = () => new Response('OK', { status: 200 })

	if (request.method !== 'POST') {
		return new Response('Method Not Allowed', { status: 405 })
	}

	if (!env.PUSH_HMAC_SECRET || !env.APNS_KEY_P8 || !env.APNS_KEY_ID) {
		return new Response('Push not configured', { status: 503 })
	}

	if (!(await verifyNotifyMAC(env.PUSH_HMAC_SECRET, environment, token, mac, accountID))) {
		return new Response('Unauthorized', { status: 401 })
	}

	// Optional: set REQUIRE_CF_WEBHOOK_AUTH=0 via a one-line change if CF's
	// destination probe omits the header. Default on — see README.
	const expected = await webhookSecret(env.PUSH_HMAC_SECRET, environment, token, accountID)
	const provided = request.headers.get('cf-webhook-auth')
	if (provided !== expected) {
		return new Response('Unauthorized', { status: 401 })
	}

	const raw = await request.arrayBuffer()
	if (raw.byteLength > MAX_BODY_BYTES) {
		return ok()
	}

	let body: unknown = {}
	if (raw.byteLength > 0) {
		try {
			body = JSON.parse(new TextDecoder().decode(raw))
		}
		catch {
			body = {}
		}
	}

	const alert = mapAlert(body)
	if (alert.dashRoute) {
		const route = accountBoundDashRoute(alert.dashRoute, accountID)
		if (route)
			alert.dashRoute = route
		else
			delete alert.dashRoute
	}
	let host: APNsHost = hostForEnvironment(environment)
	let result = await sendAlert(env, host, token, alert)

	// BadDeviceToken often means we guessed the wrong APNs environment.
	if (result.status === 400) {
		host = alternateHost(host)
		result = await sendAlert(env, host, token, alert)
	}

	// Expired or wrong JWT — clear cache, re-sign once.
	if (result.status === 403) {
		clearJWTCache()
		result = await sendAlert(env, host, token, alert)
	}

	// 410 Unregistered / other failures: drop silently.
	console.warn(`apns ${result.status}${result.reason ? ` ${result.reason}` : ''}`)

	return ok()
}
