/**
 * Stateless HMAC helpers for signed push URLs and cf-webhook-auth secrets.
 *
 * The device token is never stored; the notify URL embeds env + token + an
 * HMAC over that pair so anyone who presents a valid URL can push only to
 * that device. The Cloudflare webhook secret is derived the same way so the
 * worker can recompute it from the URL with zero storage.
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

async function sign(secret: string, message: string): Promise<string> {
	const key = await importKey(secret)
	const mac = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(message))
	return toHex(mac)
}

/** Mint the hex HMAC that seals `environment.token` into a notify URL. */
export async function mintNotifyMAC(
	secret: string,
	environment: string,
	token: string,
): Promise<string> {
	return sign(secret, `${environment}.${token}`)
}

/** Constant-time verify of a notify-URL MAC via WebCrypto. */
export async function verifyNotifyMAC(
	secret: string,
	environment: string,
	token: string,
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
		new TextEncoder().encode(`${environment}.${token}`),
	)
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
): Promise<string> {
	return sign(secret, `cf-webhook-auth:${environment}.${token}`)
}
