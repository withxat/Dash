import assert from 'node:assert/strict'
import { describe, it } from 'node:test'

import { mapAlert } from './alert.ts'

describe('mapAlert', () => {
	it('includes a watchtower deep link by default', () => {
		const alert = mapAlert({
			alert_type: 'http_alert_origin_error',
			name: 'Origin errors',
			text: 'Origin is down',
		})
		assert.equal(alert.title, 'Origin errors')
		assert.equal(alert.body, 'Origin is down')
		assert.equal(alert.dashRoute, 'dash://watchtower')
	})

	it('routes Pages deployments', () => {
		const alert = mapAlert({
			alert_type: 'pages_event',
			data: { deployment_id: 'dep-1', project_name: 'docs' },
			text: 'Deployment failed',
		})
		assert.equal(
			alert.dashRoute,
			'dash://pages/docs/deployments/dep-1',
		)
	})

	it('routes zone-scoped alerts', () => {
		const alert = mapAlert({
			alert_type: 'dos_attack_l7',
			data: { zone_id: 'zone-1' },
			text: 'Attack',
		})
		assert.equal(alert.dashRoute, 'dash://zone/zone-1')
	})

	it('routes Workers alerts by script name', () => {
		const alert = mapAlert({
			alert_type: 'workers_error_rate',
			data: { script_name: 'api' },
			text: 'Errors spiked',
		})
		assert.equal(alert.dashRoute, 'dash://worker/api')
	})

	it('routes cache alerts to zone cache', () => {
		const alert = mapAlert({
			alert_type: 'cache_purge_event',
			data: { zone_id: 'zone-1' },
			text: 'Purged',
		})
		assert.equal(alert.dashRoute, 'dash://zone/zone-1/cache')
	})

	it('routes zone-name-only alerts to Domains', () => {
		const alert = mapAlert({
			alert_type: 'http_alert_origin_error',
			data: { zone_name: 'example.com' },
			text: 'Origin is down',
		})
		assert.equal(alert.dashRoute, 'dash://feature/zones')
	})
})
