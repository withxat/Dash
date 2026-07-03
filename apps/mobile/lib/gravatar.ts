import * as Crypto from 'expo-crypto'

/** Gravatar avatar URL for an email (MD5 hash, lowercase trimmed). */
export async function gravatarUrlForEmail(email: string, size = 96): Promise<string> {
	const normalized = email.trim().toLowerCase()
	const hash = await Crypto.digestStringAsync(Crypto.CryptoDigestAlgorithm.MD5, normalized)
	// d=404: no default image — we show a centered letter fallback when the user has no Gravatar.
	// d=mp (mystery person) artwork is off-center and makes the avatar look oval/misaligned.
	return `https://www.gravatar.com/avatar/${hash}?s=${size}&d=404`
}

/** First character shown when Gravatar has no image for this email. */
export function emailInitial(email: string): string {
	const trimmed = email.trim()
	return trimmed ? trimmed[0]!.toUpperCase() : '?'
}
