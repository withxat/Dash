/**
 * Dash edge worker — landing SPA assets + Hono API + OAuth relay.
 *
 * OAuth stays worker-first so SPA not_found_handling cannot swallow the
 * Cloudflare OAuth navigation callback.
 *
 * There is no push bridge. Dash's only notifications are the Workers and Pages
 * build Live Activities, and those poll from the app while a screen or an
 * activity is consuming them — no APNs token, no push-to-start, nothing for an
 * edge worker to forward. The `/push/*` routes, the APNs client, the HMAC
 * capability, and the alert mapper were removed with that decision.
 */

import type { Env } from './env'

import { Hono } from 'hono'

import { handleOAuth } from './relay/oauth'
import { handleRegistration } from './relay/registration'

const app = new Hono<{ Bindings: Env }>()

app.get('/health', (c) => {
	return c.text('Dash OAuth relay OK\n', 200, {
		'content-type': 'text/plain; charset=utf-8',
	})
})

app.get('/api/health', (c) => {
	return c.json({ ok: true })
})

app.get('/api/registration/:domain', (c) => {
	return handleRegistration(c.req.raw, c.req.param('domain'))
})

app.get('/oauth/callback', (c) => {
	return handleOAuth(c.req.raw, new URL(c.req.url))
})

export default app
