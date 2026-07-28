/**
 * Stateless HMAC helpers for push capabilities.
 *
 * The tuple-based helpers at the bottom preserve existing notify URLs during
 * migration. New registrations use the generic domain-separated helpers from
 * this module with an opaque AEAD binding instead.
 */

function toHex(bytes: ArrayBuffer): string {
	return [...new Uint8Array(bytes)].map(b => b.toString(16).padStart(2, '0')).join('')
}

function fromHex(hex: string): null | Uint8Array {
	if (hex.length % 2 !== 0 || !/^[0-9a-f]+$/i.test(hex))
		return null
	const out = new Uint8Array(hex.length / 2)
	for (let i = 0; i < out.length; i++) {
		out[i] = Number.parseInt(hex.slice(i * 2, i * 2 + 2), 16)
	}
	return out
}

async function importKey(secret: string): Promise<CryptoKey> {
	return crypto.subtle.importKey(
		'raw',
		new TextEncoder().encode(secret),
		{ hash: 'SHA-256', name: 'HMAC' },
		false,
		['sign', 'verify'],
	)
}

export async function signPushHMAC(secret: string, message: string): Promise<string> {
	const key = await importKey(secret)
	const mac = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(message))
	return toHex(mac)
}

/** Verifies a hex HMAC without comparing secret material in JavaScript. */
export async function verifyPushHMAC(
	secret: string,
	message: string,
	macHex: string,
): Promise<boolean> {
	const mac = fromHex(macHex)
	if (!mac)
		return false
	const key = await importKey(secret)
	return crypto.subtle.verify(
		'HMAC',
		key,
		mac,
		new TextEncoder().encode(message),
	)
}

function notifyBinding(environment: string, token: string, accountID?: string): string {
	return accountID
		? `${environment}.${token}.${accountID}`
		: `${environment}.${token}`
}

/** Mint the hex HMAC that seals the notify URL's device/account binding. */
export async function mintNotifyMAC(
	secret: string,
	environment: string,
	token: string,
	accountID?: string,
): Promise<string> {
	return signPushHMAC(secret, notifyBinding(environment, token, accountID))
}

/** Constant-time verify of a notify-URL MAC via WebCrypto. */
export async function verifyNotifyMAC(
	secret: string,
	environment: string,
	token: string,
	macHex: string,
	accountID?: string,
): Promise<boolean> {
	return verifyPushHMAC(secret, notifyBinding(environment, token, accountID), macHex)
}

/**
 * Derive the `cf-webhook-auth` secret for a device. Cloudflare echoes the
 * webhook URL on GET but never the secret, so this keeps
 * `notifications.read` from becoming a usable push capability.
 */
export async function webhookSecret(
	secret: string,
	environment: string,
	token: string,
	accountID?: string,
): Promise<string> {
	return signPushHMAC(
		secret,
		`cf-webhook-auth:${notifyBinding(environment, token, accountID)}`,
	)
}

/** Constant-time verification for legacy `cf-webhook-auth` values. */
export async function verifyWebhookSecret(
	secret: string,
	environment: string,
	token: string,
	provided: string,
	accountID?: string,
): Promise<boolean> {
	return verifyPushHMAC(
		secret,
		`cf-webhook-auth:${notifyBinding(environment, token, accountID)}`,
		provided,
	)
}
