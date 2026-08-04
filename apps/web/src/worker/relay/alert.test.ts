import assert from 'node:assert/strict'
import { describe, it } from 'node:test'

import { mapAlert } from './alert.ts'
import {
	alertPayloadJSON,
	backgroundRefreshPayloadJSON,
	registrationChallengePayloadJSON,
} from './apns.ts'

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

describe('alert tiering', () => {
	it('reserves time-sensitive for alerts that mean something is broken', () => {
		for (const type of [
			'http_alert_origin_error',
			'dos_attack_l7',
			'advanced_ddos_attack_l7_alert',
			'load_balancing_health_alert',
			'tunnel_health_event',
			'secondary_dns_all_primaries_failing',
		]) {
			assert.equal(
				mapAlert({ alert_type: type, text: 'x' }).interruptionLevel,
				'time-sensitive',
				type,
			)
		}
	})

	it('keeps digests quiet and everything else merely active', () => {
		assert.equal(
			mapAlert({ alert_type: 'weekly_account_overview', text: 'x' }).interruptionLevel,
			'passive',
		)
		assert.equal(
			mapAlert({ alert_type: 'billing_usage_alert', text: 'x' }).interruptionLevel,
			'passive',
		)
		assert.equal(
			mapAlert({ alert_type: 'universal_ssl_event_type', text: 'x' }).interruptionLevel,
			'active',
		)
		assert.equal(mapAlert({ text: 'x' }).interruptionLevel, 'active')
	})

	it('never reads severity out of the alert wording', () => {
		// Cloudflare rewrites `text` freely; only alert_type may drive the tier.
		const alarming = mapAlert({
			alert_type: 'weekly_account_overview',
			text: 'CRITICAL: everything failed and the origin is down',
		})
		assert.equal(alarming.interruptionLevel, 'passive')
	})

	it('groups a stack per resource', () => {
		assert.equal(
			mapAlert({ alert_type: 'dos_attack_l7', data: { zone_id: 'z1' }, text: 'x' }).threadID,
			'zone:z1',
		)
		assert.equal(
			mapAlert({ alert_type: 'pages_event', data: { project_name: 'docs' }, text: 'x' })
				.threadID,
			'pages:docs',
		)
		assert.equal(mapAlert({ alert_type: 'future_alert', text: 'x' }).threadID, 'type:future_alert')
	})

	it('only offers zone actions when a zone id can target them', () => {
		assert.equal(
			mapAlert({ alert_type: 'dos_attack_l7', data: { zone_id: 'z1' }, text: 'x' }).category,
			'dash.alert.zone.attack',
		)
		assert.equal(
			mapAlert({ alert_type: 'http_alert_origin_error', data: { zone_id: 'z1' }, text: 'x' })
				.category,
			'dash.alert.zone.origin',
		)
		assert.equal(
			mapAlert({ alert_type: 'universal_ssl_event_type', data: { zone_id: 'z1' }, text: 'x' })
				.category,
			'dash.alert.zone.certificate',
		)
		// Zone name only: Purge / Under Attack have nothing to act on.
		assert.equal(
			mapAlert({ alert_type: 'dos_attack_l7', data: { zone_name: 'a.com' }, text: 'x' })
				.category,
			undefined,
		)
		assert.equal(mapAlert({ text: 'x' }).category, undefined)
	})

	it('forwards the raw alert type so the extension can localize', () => {
		const alert = mapAlert({
			alert_type: 'http_alert_origin_error',
			data: { zone_id: 'z1', zone_name: 'example.com' },
			text: 'Origin is down',
		})
		assert.equal(alert.alertType, 'http_alert_origin_error')
		assert.equal(alert.subject, 'example.com')
	})
})

describe('alertPayloadJSON', () => {
	it('emits the aps keys the app depends on', () => {
		const payload = JSON.parse(
			alertPayloadJSON(
				mapAlert({
					alert_type: 'dos_attack_l7',
					data: { zone_id: 'z1', zone_name: 'example.com' },
					name: 'L7 DDoS',
					text: 'Attack detected',
				}),
			),
		)
		assert.deepEqual(payload.aps.alert, {
			body: 'Open Dash to sync your Cloudflare alerts.',
			title: 'Dash',
		})
		assert.equal(payload.dashOriginalTitle, 'L7 DDoS')
		assert.equal(payload.dashOriginalBody, 'Attack detected')
		assert.equal(payload.aps['interruption-level'], 'time-sensitive')
		assert.equal(payload.aps['mutable-content'], 1)
		assert.equal(payload.aps['thread-id'], 'zone:z1')
		assert.equal(payload.aps.category, 'dash.alert.zone.attack')
		assert.equal(payload.aps['relevance-score'], 1)
		assert.equal(payload.dashRoute, 'dash://zone/z1')
		assert.equal(payload.dashAlertType, 'dos_attack_l7')
		assert.equal(payload.dashSubject, 'example.com')
	})

	it('omits category and thread-id rather than sending empty ones', () => {
		const payload = JSON.parse(alertPayloadJSON(mapAlert({ text: 'Alert fired.' })))
		assert.equal('category' in payload.aps, false)
		assert.equal(payload.aps['thread-id'], undefined)
		assert.equal(payload.aps['interruption-level'], 'active')
	})

	it('carries account identity at the top level when the binding is scoped', () => {
		const payload = JSON.parse(
			alertPayloadJSON(mapAlert({ text: 'Alert fired.' }), 'account-1'),
		)
		assert.equal(payload.dashAccountID, 'account-1')
		assert.equal(
			JSON.parse(backgroundRefreshPayloadJSON('account-1')).dashAccountID,
			'account-1',
		)
		assert.equal(
			'dashAccountID' in JSON.parse(backgroundRefreshPayloadJSON()),
			false,
		)
	})

	it('keeps registration proof material in the silent challenge payload', () => {
		const payload = JSON.parse(registrationChallengePayloadJSON({
			nonce: 'nonce',
			requestID: 'request-1',
			ticket: 'ticket',
		}))
		assert.deepEqual(payload, {
			aps: { 'content-available': 1 },
			dashKind: 'registration-challenge',
			nonce: 'nonce',
			requestID: 'request-1',
			ticket: 'ticket',
		})
	})
})
