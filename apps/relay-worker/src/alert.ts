/**
 * Map a Cloudflare alert webhook body to an APNs alert payload.
 *
 * Must produce a reasonable notification from just `{"text":"..."}` — that is
 * the shape of Cloudflare's synthetic `/policies/{id}/test` message.
 */

export interface AlertPayload {
	body: string
	collapseID?: string
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
		title,
	}
}
