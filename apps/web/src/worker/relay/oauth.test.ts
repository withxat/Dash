import assert from 'node:assert/strict'
import { describe, it } from 'node:test'

import { handleOAuth } from './oauth.ts'

describe('handleOAuth', () => {
	it('302s the full query string to dash://oauth/callback', () => {
		const url = new URL('https://dash.xat.sh/oauth/callback?code=abc&state=xyz')
		const response = handleOAuth(new Request(url), url)
		assert.equal(response.status, 302)
		assert.equal(response.headers.get('location'), 'dash://oauth/callback?code=abc&state=xyz')
		assert.equal(response.headers.get('cache-control'), 'no-store')
	})

	it('rejects non-GET methods', () => {
		const url = new URL('https://dash.xat.sh/oauth/callback')
		const response = handleOAuth(new Request(url, { method: 'POST' }), url)
		assert.equal(response.status, 405)
	})
})
