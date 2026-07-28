/**
 * Map a Cloudflare alert webhook body to an APNs alert payload.
 *
 * Must produce a reasonable notification from just `{"text":"..."}` — that is
 * the shape of Cloudflare's synthetic `/policies/{id}/test` message.
 *
 * Severity, grouping, and category are derived from `alert_type` and the
 * structured `data` object only — never from the wording of `text`. Cloudflare
 * writes that string in English and rephrases it without notice; a payload that
 * sniffed it for "failed" would silently change tier on a copy edit, and the
 * Notification Service Extension could not localize what the relay had already
 * branched on.
 */

export type AlertInterruptionLevel = 'active' | 'passive' | 'time-sensitive'

/**
 * Notification category, which selects the action buttons iOS shows on a long
 * press. The app registers one `UNNotificationCategory` per value, so this list
 * is a contract: adding a value here without adding it there yields a
 * notification with no actions.
 */
export type AlertCategory
	= | 'dash.alert.generic'
		| 'dash.alert.pages'
		| 'dash.alert.worker'
		| 'dash.alert.zone.attack'
		| 'dash.alert.zone.certificate'
		| 'dash.alert.zone.origin'

export interface AlertPayload {
	/**
	 * Raw Cloudflare `alert_type`, forwarded verbatim. The Notification Service
	 * Extension keys its on-device localization off this, which is the only way
	 * a Chinese user sees a Chinese notification — Cloudflare's `text` is always
	 * English and the relay must not translate it (no catalog, no user locale).
	 */
	alertType?: string
	body: string
	/** Selects the long-press actions; omitted when no action applies. */
	category?: AlertCategory
	collapseID?: string
	/** Deep link the iOS app opens on tap, e.g. `dash://watchtower`. */
	dashRoute?: string
	interruptionLevel: AlertInterruptionLevel
	relevanceScore: number
	/** Resource this alert is about, for the extension's localized body. */
	subject?: string
	/** Groups notifications about one resource into a single stack. */
	threadID?: string
	title: string
}

const MAX_BODY_CHARS = 1000
const MAX_COLLAPSE_BYTES = 64
const MAX_THREAD_CHARS = 128

/**
 * Alert types that mean something is broken right now. Everything else stays
 * `active` so the genuinely urgent ones keep their weight — a relay that marks
 * every alert time-sensitive trains people to turn the whole thing off.
 */
const URGENT_MARKERS = [
	'billing_anomaly',
	'ddos',
	'dos_attack',
	'health_check',
	'incident',
	'load_balancing_health',
	'origin_error',
	'origin_monitoring',
	'primaries_failing',
	'tunnel_health',
] as const

/** Digest-shaped alerts that should never interrupt. */
const QUIET_MARKERS = [
	'maintenance',
	'overview',
	'usage_alert',
	'weekly',
] as const

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

interface AlertSubject {
	deployment?: string
	project?: string
	worker?: string
	zoneID?: string
	zoneName?: string
}

/** Pulls the resource identifiers Cloudflare spells a dozen different ways. */
function subjectOf(obj: Record<string, unknown>): AlertSubject {
	const data = obj.data && typeof obj.data === 'object' ? (obj.data as Record<string, unknown>) : {}
	return {
		deployment:
			asString(data.deployment_id)
			?? asString(data.deploymentId)
			?? asString(obj.deployment_id),
		project:
			asString(data.project_name)
			?? asString(data.projectName)
			?? asString(obj.project_name),
		worker:
			asString(data.script_name)
			?? asString(data.scriptName)
			?? asString(data.worker_name)
			?? asString(data.workerName)
			?? asString(obj.script_name),
		zoneID: asString(data.zone_id) ?? asString(data.zoneId) ?? asString(obj.zone_id),
		zoneName: asString(data.zone_name) ?? asString(data.zoneName),
	}
}

/** Human-readable name of what the alert is about, if the payload named one. */
function subjectNameOf(subject: AlertSubject): string | undefined {
	const name = subject.zoneName ?? subject.project ?? subject.worker
	return name ? truncate(name, MAX_THREAD_CHARS) : undefined
}

function dashRouteForAlert(subject: AlertSubject, alertType: string | undefined): string {
	const { deployment, project, worker, zoneID, zoneName } = subject

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
	if (zoneName) {
		return 'dash://feature/zones'
	}
	return 'dash://watchtower'
}

export function interruptionLevelForAlert(alertType: string | undefined): AlertInterruptionLevel {
	if (!alertType)
		return 'active'
	const type = alertType.toLowerCase()
	if (QUIET_MARKERS.some(marker => type.includes(marker)))
		return 'passive'
	if (URGENT_MARKERS.some(marker => type.includes(marker)))
		return 'time-sensitive'
	return 'active'
}

function relevanceForLevel(level: AlertInterruptionLevel): number {
	switch (level) {
		case 'passive':
			return 0.2
		case 'time-sensitive':
			return 1
		default:
			return 0.6
	}
}

/**
 * Category is only emitted when its actions can actually run: the zone
 * categories carry Purge cache / Under Attack, which need a zone id. A category
 * whose action has no target would render a button that fails on tap.
 */
function categoryForAlert(
	subject: AlertSubject,
	alertType: string | undefined,
): AlertCategory | undefined {
	const type = alertType?.toLowerCase() ?? ''

	if (subject.project) {
		return 'dash.alert.pages'
	}
	if (subject.worker && type.includes('worker')) {
		return 'dash.alert.worker'
	}
	if (!subject.zoneID) {
		return undefined
	}
	if (type.includes('ssl') || type.includes('certificate')) {
		return 'dash.alert.zone.certificate'
	}
	if (
		type.includes('dos_attack')
		|| type.includes('ddos')
		|| type.includes('waf')
		|| type.includes('firewall')
	) {
		return 'dash.alert.zone.attack'
	}
	if (type.includes('origin') || type.includes('edge_error') || type.includes('health')) {
		return 'dash.alert.zone.origin'
	}
	return 'dash.alert.generic'
}

/**
 * Groups a stack per resource so one flapping origin does not bury every other
 * domain. Falls back to the alert type, which still beats one undifferentiated
 * pile.
 */
function threadIDForAlert(
	subject: AlertSubject,
	alertType: string | undefined,
): string | undefined {
	const { project, worker, zoneID, zoneName } = subject
	const raw
		= project
			? `pages:${project}`
			: worker
				? `worker:${worker}`
				: zoneID
					? `zone:${zoneID}`
					: zoneName
						? `zone:${zoneName}`
						: alertType
							? `type:${alertType}`
							: undefined
	return raw ? truncate(raw, MAX_THREAD_CHARS) : undefined
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
	const subject = subjectOf(obj)
	const interruptionLevel = interruptionLevelForAlert(alertType)

	return {
		alertType,
		body: truncate(text, MAX_BODY_CHARS),
		category: categoryForAlert(subject, alertType),
		collapseID: correlation ? truncateBytes(correlation, MAX_COLLAPSE_BYTES) : undefined,
		dashRoute: dashRouteForAlert(subject, alertType),
		interruptionLevel,
		relevanceScore: relevanceForLevel(interruptionLevel),
		subject: subjectNameOf(subject),
		threadID: threadIDForAlert(subject, alertType),
		title,
	}
}
