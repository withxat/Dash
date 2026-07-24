/**
 * Map a Cloudflare alert webhook body to an APNs alert payload.
 *
 * Must produce a reasonable notification from just `{"text":"..."}` — that is
 * the shape of Cloudflare's synthetic `/policies/{id}/test` message.
 */

export interface AlertPayload {
	body: string
	collapseID?: string
	/** Deep link the iOS app opens on tap, e.g. `dash://watchtower`. */
	dashRoute?: string
	title: string
}

const MAX_BODY_CHARS = 1000
const MAX_COLLAPSE_BYTES = 64

function prettify(alertType: string): string {
	return alertType.replace(/_/g, ' ')
}

function asString(value: unknown): string | undefined {
	return typeof value === 'string' && value.length > 0 ? value : undefined
}

function truncate(text: string, maxChars: number): string {
	if (text.length <= maxChars)
		return text
	return `${text.slice(0, maxChars - 1)}…`
}

function truncateBytes(text: string, maxBytes: number): string {
	const encoder = new TextEncoder()
	if (encoder.encode(text).byteLength <= maxBytes)
		return text
	let end = text.length
	while (end > 0 && encoder.encode(text.slice(0, end)).byteLength > maxBytes) {
		end--
	}
	return text.slice(0, end)
}

function dashRouteForAlert(obj: Record<string, unknown>, alertType: string | undefined): string {
	const data = obj.data && typeof obj.data === 'object' ? (obj.data as Record<string, unknown>) : {}
	const project
		= asString(data.project_name)
			?? asString(data.projectName)
			?? asString(obj.project_name)
	const deployment
		= asString(data.deployment_id)
			?? asString(data.deploymentId)
			?? asString(obj.deployment_id)
	const zoneID = asString(data.zone_id) ?? asString(data.zoneId) ?? asString(obj.zone_id)
	const worker
		= asString(data.script_name)
			?? asString(data.scriptName)
			?? asString(data.worker_name)
			?? asString(data.workerName)
			?? asString(obj.script_name)

	if (project && deployment) {
		return `dash://pages/${encodeURIComponent(project)}/deployments/${encodeURIComponent(deployment)}`
	}
	if (project && (alertType?.includes('pages') || !zoneID)) {
		return `dash://pages/${encodeURIComponent(project)}`
	}
	if (worker && (alertType?.includes('worker') || alertType?.includes('workers'))) {
		return `dash://worker/${encodeURIComponent(worker)}`
	}
	if (zoneID) {
		// Health / SSL / WAF alerts land on the zone; cache-specific types open purge.
		if (alertType?.includes('cache')) {
			return `dash://zone/${encodeURIComponent(zoneID)}/cache`
		}
		if (alertType?.includes('waf') || alertType?.includes('firewall')) {
			return `dash://zone/${encodeURIComponent(zoneID)}/waf`
		}
		return `dash://zone/${encodeURIComponent(zoneID)}`
	}
	// Zone name without id — open Domains, not a dead Watchtower row.
	if (asString(data.zone_name) ?? asString(data.zoneName)) {
		return 'dash://feature/zones'
	}
	return 'dash://watchtower'
}

export function mapAlert(body: unknown): AlertPayload {
	const obj = body && typeof body === 'object' ? (body as Record<string, unknown>) : {}
	const alertType = asString(obj.alert_type)
	const title
		= asString(obj.policy_name)
			?? asString(obj.name)
			?? (alertType ? prettify(alertType) : undefined)
			?? 'Cloudflare'
	const text = asString(obj.text) ?? 'Alert fired.'
	const correlation = asString(obj.alert_correlation_id)

	return {
		body: truncate(text, MAX_BODY_CHARS),
		collapseID: correlation ? truncateBytes(correlation, MAX_COLLAPSE_BYTES) : undefined,
		dashRoute: dashRouteForAlert(obj, alertType),
		title,
	}
}
