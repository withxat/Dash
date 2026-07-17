/**
 * Dash edge worker — landing SPA assets + Hono API + OAuth/push relay.
 *
 * OAuth and push stay worker-first so SPA not_found_handling cannot swallow
 * the Cloudflare OAuth navigation callback.
 */

import type { Env } from './env'

import { Hono } from 'hono'

import { handleOAuth } from './relay/oauth'
import { handlePush } from './relay/push'

const app = new Hono<{ Bindings: Env }>()

app.get('/health', (c) => {
	return c.text('Dash OAuth relay OK\n', 200, {
		'content-type': 'text/plain; charset=utf-8',
	})
})

app.get('/api/health', (c) => {
	return c.json({ ok: true })
})

app.get('/oauth/callback', (c) => {
	return handleOAuth(c.req.raw, new URL(c.req.url))
})

app.all('/push/*', (c) => {
	return handlePush(c.req.raw, new URL(c.req.url), c.env)
})

export default app
