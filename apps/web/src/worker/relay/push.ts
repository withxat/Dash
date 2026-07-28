/**
 * Push routes: prove APNs-token possession, then forward Cloudflare alerts.
 *
 * POST /push/register/start
 *   { requestID, token, environment, accountID } → 202 with an empty body.
 *   The nonce and encrypted ticket are delivered only to that APNs token.
 * POST /push/register/complete
 *   { ticket, nonce } → { url, secret } after the short-lived proof verifies.
 * POST /push/notify/<opaque-binding>
 *   Cloudflare webhook → APNs alert and account-scoped silent refresh.
 *
 * Tuple-based notify URLs remain accepted for installed older app versions,
 * but the old unauthenticated one-step registration endpoint is gone.
 *
 * Notify returns 200 after webhook authentication so a dead device token
 * cannot disable the entire Cloudflare webhook destination.
 */

import type { Env } from '../env.ts'
import type { APNsHost, APNsResult } from './apns.ts'

import { mapAlert } from './alert.ts'
import {
	alternateHost,
	clearJWTCache,
	hostForEnvironment,
	sendAlert as sendAPNsAlert,
	sendBackgroundRefresh as sendAPNsBackgroundRefresh,
	sendRegistrationChallenge as sendAPNsRegistrationChallenge,
} from './apns.ts'
import { verifyNotifyMAC, verifyWebhookSecret } from './hmac.ts'
import {
	completeRegistrationChallenge,
	createRegistrationChallenge,
	opaqueWebhookSecret,
	openNotifyBinding,
	verifyOpaqueWebhookSecret,
} from './push-crypto.ts'
import {
	accountBoundDashRoute,
	isAccountID,
	isDeviceToken,
	isPushEnvironment,
	isRequestID,
	opaqueNotifyPath,
	parseNotifyPath,
} from './push-validate.ts'

const MAX_ALERT_BODY_BYTES = 64 * 1024
const MAX_REGISTRATION_BODY_BYTES = 4096
const REGISTRATION_RATE_LIMIT_SECONDS = 60

/** Defers work past the response; falls back to awaiting when absent. */
export type WaitUntil = (promise: Promise<unknown>) => void

export interface PushDependencies {
	nowSeconds?: () => number
	sendAlert?: typeof sendAPNsAlert
	sendBackgroundRefresh?: typeof sendAPNsBackgroundRefresh
	sendRegistrationChallenge?: typeof sendAPNsRegistrationChallenge
}

type JSONResult
	= | { ok: false }
		| { ok: true, value: unknown }

export async function handlePush(
	request: Request,
	url: URL,
	env: Env,
	waitUntil?: WaitUntil,
	dependencies: PushDependencies = {},
): Promise<Response> {
	if (url.pathname === '/push/register/start') {
		return startRegistration(request, env, dependencies)
	}
	if (url.pathname === '/push/register/complete') {
		return completeRegistration(request, url, env, dependencies)
	}

	const notify = parseNotifyPath(url.pathname)
	if (!notify)
		return new Response('Not Found', { status: 404 })

	if (notify.kind === 'opaque') {
		return notifyOpaqueDevice(
			request,
			env,
			notify.sealedBinding,
			waitUntil,
			dependencies,
		)
	}

	return notifyLegacyDevice(
		request,
		env,
		notify.environment,
		notify.token,
		notify.mac,
		notify.accountID,
		waitUntil,
		dependencies,
	)
}

async function readBoundedBody(
	request: Request,
	maxBytes: number,
): Promise<null | Uint8Array> {
	const declaredLength = request.headers.get('content-length')
	if (declaredLength !== null) {
		const length = Number(declaredLength)
		if (!Number.isSafeInteger(length) || length < 0 || length > maxBytes)
			return null
	}

	if (!request.body)
		return new Uint8Array()

	const reader = request.body.getReader()
	const chunks: Uint8Array[] = []
	let total = 0
	try {
		while (true) {
			const { done, value } = await reader.read()
			if (done)
				break
			total += value.byteLength
			if (total > maxBytes) {
				try {
					await reader.cancel()
				}
				catch {
					// The size decision is already final.
				}
				return null
			}
			chunks.push(value)
		}
	}
	finally {
		reader.releaseLock()
	}

	const body = new Uint8Array(total)
	let offset = 0
	for (const chunk of chunks) {
		body.set(chunk, offset)
		offset += chunk.byteLength
	}
	return body
}

async function readJSON(
	request: Request,
	maxBytes: number,
): Promise<JSONResult> {
	const raw = await readBoundedBody(request, maxBytes)
	if (!raw || raw.byteLength === 0)
		return { ok: false }
	try {
		return {
			ok: true,
			value: JSON.parse(new TextDecoder().decode(raw)) as unknown,
		}
	}
	catch {
		return { ok: false }
	}
}

function isPushConfigured(env: Env): boolean {
	return Boolean(
		env.PUSH_HMAC_SECRET
		&& env.APNS_KEY_P8
		&& env.APNS_KEY_ID
		&& env.APNS_TEAM_ID
		&& env.APNS_TOPIC,
	)
}

function currentTime(dependencies: PushDependencies): number {
	return dependencies.nowSeconds?.() ?? Math.floor(Date.now() / 1000)
}

async function startRegistration(
	request: Request,
	env: Env,
	dependencies: PushDependencies,
): Promise<Response> {
	if (request.method !== 'POST')
		return new Response('Method Not Allowed', { status: 405 })
	if (!isPushConfigured(env))
		return new Response('Push not configured', { status: 503 })
	if (!(await allowsRegistrationAttempt(request, env))) {
		return new Response('Too Many Requests', {
			headers: { 'retry-after': String(REGISTRATION_RATE_LIMIT_SECONDS) },
			status: 429,
		})
	}

	const parsed = await readJSON(request, MAX_REGISTRATION_BODY_BYTES)
	if (!parsed.ok || !parsed.value || typeof parsed.value !== 'object')
		return new Response('Bad Request', { status: 400 })

	const { accountID, environment, requestID, token }
		= parsed.value as Record<string, unknown>
	if (
		typeof requestID !== 'string'
		|| !isRequestID(requestID)
		|| typeof accountID !== 'string'
		|| !isAccountID(accountID)
		|| typeof environment !== 'string'
		|| !isPushEnvironment(environment)
		|| typeof token !== 'string'
		|| !isDeviceToken(token)
	) {
		return new Response('Bad Request', { status: 400 })
	}

	const challenge = await createRegistrationChallenge(
		env.PUSH_HMAC_SECRET,
		{
			accountID,
			environment,
			requestID,
			token: token.toLowerCase(),
		},
		currentTime(dependencies),
	)
	const sendChallenge
		= dependencies.sendRegistrationChallenge ?? sendAPNsRegistrationChallenge
	const host = hostForEnvironment(environment)
	let result = await sendChallenge(env, host, token, challenge)

	if (result.status === 403) {
		clearJWTCache()
		result = await sendChallenge(env, host, token, challenge)
	}
	if (result.status !== 200) {
		console.warn(`apns registration ${result.status}`)
		return new Response('Push challenge failed', { status: 502 })
	}

	return new Response(null, {
		headers: { 'cache-control': 'no-store' },
		status: 202,
	})
}

async function allowsRegistrationAttempt(
	request: Request,
	env: Env,
): Promise<boolean> {
	// Registration is a rare user action. Cap both aggregate APNs fan-out and
	// one network actor before parsing a caller-controlled token. The native
	// rate-limit counters are per Cloudflare location and intentionally
	// permissive, so these are guardrails rather than accounting.
	const actor = request.headers.get('cf-connecting-ip') ?? 'unknown'
	const [global, perActor] = await Promise.all([
		env.PUSH_REGISTRATION_GLOBAL_LIMITER.limit({
			key: 'push-registration-start',
		}),
		env.PUSH_REGISTRATION_ACTOR_LIMITER.limit({
			key: `push-registration-start:${actor}`,
		}),
	])
	return global.success && perActor.success
}

async function completeRegistration(
	request: Request,
	url: URL,
	env: Env,
	dependencies: PushDependencies,
): Promise<Response> {
	if (request.method !== 'POST')
		return new Response('Method Not Allowed', { status: 405 })
	if (!env.PUSH_HMAC_SECRET)
		return new Response('Push not configured', { status: 503 })

	const parsed = await readJSON(request, MAX_REGISTRATION_BODY_BYTES)
	if (!parsed.ok || !parsed.value || typeof parsed.value !== 'object')
		return new Response('Bad Request', { status: 400 })

	const { nonce, ticket } = parsed.value as Record<string, unknown>
	if (
		typeof nonce !== 'string'
		|| nonce.length > 128
		|| typeof ticket !== 'string'
		|| ticket.length > MAX_REGISTRATION_BODY_BYTES
	) {
		return new Response('Bad Request', { status: 400 })
	}

	const completed = await completeRegistrationChallenge(
		env.PUSH_HMAC_SECRET,
		ticket,
		nonce,
		currentTime(dependencies),
	)
	if (!completed)
		return new Response('Unauthorized', { status: 401 })

	const secret = await opaqueWebhookSecret(
		env.PUSH_HMAC_SECRET,
		completed.sealedBinding,
	)
	const notifyURL = `${url.origin}${opaqueNotifyPath(completed.sealedBinding)}`
	return Response.json(
		{ secret, url: notifyURL },
		{ headers: { 'cache-control': 'no-store' } },
	)
}

async function notifyOpaqueDevice(
	request: Request,
	env: Env,
	sealedBinding: string,
	waitUntil: undefined | WaitUntil,
	dependencies: PushDependencies,
): Promise<Response> {
	if (request.method !== 'POST')
		return new Response('Method Not Allowed', { status: 405 })
	if (!isPushConfigured(env))
		return new Response('Push not configured', { status: 503 })

	const binding = await openNotifyBinding(env.PUSH_HMAC_SECRET, sealedBinding)
	if (!binding)
		return new Response('Unauthorized', { status: 401 })

	const provided = request.headers.get('cf-webhook-auth')
	if (
		!provided
		|| !(await verifyOpaqueWebhookSecret(
			env.PUSH_HMAC_SECRET,
			sealedBinding,
			provided,
		))
	) {
		return new Response('Unauthorized', { status: 401 })
	}

	return deliverNotification(
		request,
		env,
		binding.environment,
		binding.token,
		binding.accountID,
		waitUntil,
		dependencies,
	)
}

async function notifyLegacyDevice(
	request: Request,
	env: Env,
	environment: string,
	token: string,
	mac: string,
	accountID: string | undefined,
	waitUntil: undefined | WaitUntil,
	dependencies: PushDependencies,
): Promise<Response> {
	if (request.method !== 'POST')
		return new Response('Method Not Allowed', { status: 405 })
	if (!isPushConfigured(env))
		return new Response('Push not configured', { status: 503 })
	if (!(await verifyNotifyMAC(env.PUSH_HMAC_SECRET, environment, token, mac, accountID)))
		return new Response('Unauthorized', { status: 401 })

	const provided = request.headers.get('cf-webhook-auth')
	if (
		!provided
		|| !(await verifyWebhookSecret(
			env.PUSH_HMAC_SECRET,
			environment,
			token,
			provided,
			accountID,
		))
	) {
		return new Response('Unauthorized', { status: 401 })
	}

	return deliverNotification(
		request,
		env,
		environment,
		token,
		accountID,
		waitUntil,
		dependencies,
	)
}

async function deliverNotification(
	request: Request,
	env: Env,
	environment: string,
	token: string,
	accountID: string | undefined,
	waitUntil: undefined | WaitUntil,
	dependencies: PushDependencies,
): Promise<Response> {
	const ok = () => new Response('OK', { status: 200 })
	const raw = await readBoundedBody(request, MAX_ALERT_BODY_BYTES)
	if (!raw)
		return ok()

	let body: unknown = {}
	if (raw.byteLength > 0) {
		try {
			body = JSON.parse(new TextDecoder().decode(raw)) as unknown
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

	const sendAlert = dependencies.sendAlert ?? sendAPNsAlert
	let host: APNsHost = hostForEnvironment(environment)
	let result: APNsResult = await sendAlert(env, host, token, alert, accountID)
	if (result.status === 400) {
		host = alternateHost(host)
		result = await sendAlert(env, host, token, alert, accountID)
	}
	if (result.status === 403) {
		clearJWTCache()
		result = await sendAlert(env, host, token, alert, accountID)
	}

	// 410 Unregistered / other failures are intentionally non-fatal to the
	// Cloudflare destination. Do not log payload, token, account, or URL.
	console.warn(`apns ${result.status}`)

	if (result.status === 200) {
		const sendBackgroundRefresh
			= dependencies.sendBackgroundRefresh ?? sendAPNsBackgroundRefresh
		const refresh = sendBackgroundRefresh(env, host, token, accountID).then((background) => {
			if (background.status !== 200)
				console.warn(`apns background ${background.status}`)
		})
		if (waitUntil)
			waitUntil(refresh)
		else
			await refresh
	}

	return ok()
}
