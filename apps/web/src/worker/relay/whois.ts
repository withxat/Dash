/**
 * Port-43 WHOIS via cloudflare:sockets.
 *
 * Flow: whois.iana.org referral → registry → optional registrar WHOIS when
 * the registry answer is thin (common for .com/.net).
 */

import type { RegistrationSnapshot } from './registration-types'

import { connect } from 'cloudflare:sockets'

import {
	extractReferralHost,
	extractRegistrarWhoisHost,
	isThickEnough,
	mergeSnapshots,
	parseWhoisText,
	tldGuessHost,
} from './whois-parse'

const WHOIS_TIMEOUT_MS = 8_000
const IANA_WHOIS = 'whois.iana.org'

export async function lookupWhois(domain: string): Promise<null | RegistrationSnapshot> {
	const ianaText = await whoisQuery(IANA_WHOIS, domain)
	const referral = extractReferralHost(ianaText) ?? tldGuessHost(domain)
	if (!referral)
		return parseWhoisText(ianaText, domain)

	const registryText = await whoisQuery(referral, domain)
	const snapshot = parseWhoisText(registryText, domain)
	if (snapshot && isThickEnough(snapshot))
		return snapshot

	const registrarHost = extractRegistrarWhoisHost(registryText)
	if (!registrarHost || registrarHost === referral)
		return snapshot

	const registrarText = await whoisQuery(registrarHost, domain)
	const registrarSnapshot = parseWhoisText(registrarText, domain)
	return mergeSnapshots(snapshot, registrarSnapshot)
}

export { parseWhoisText } from './whois-parse'

async function whoisQuery(hostname: string, query: string): Promise<string> {
	return await withTimeout((async () => {
		const socket = connect({ hostname, port: 43 })
		try {
			await socket.opened
			const writer = socket.writable.getWriter()
			await writer.write(new TextEncoder().encode(`${query}\r\n`))
			await writer.close()

			const reader = socket.readable.getReader()
			const chunks: Uint8Array[] = []
			while (true) {
				const result = await reader.read()
				if (result.done)
					break
				if (result.value)
					chunks.push(result.value)
			}
			return new TextDecoder().decode(concat(chunks))
		}
		finally {
			try {
				await socket.close()
			}
			catch {
				// already closed
			}
		}
	})(), WHOIS_TIMEOUT_MS)
}

function concat(chunks: Uint8Array[]): Uint8Array {
	let length = 0
	for (const chunk of chunks) length += chunk.byteLength
	const out = new Uint8Array(length)
	let offset = 0
	for (const chunk of chunks) {
		out.set(chunk, offset)
		offset += chunk.byteLength
	}
	return out
}

async function withTimeout<T>(promise: Promise<T>, ms: number): Promise<T> {
	let handle: ReturnType<typeof setTimeout> | undefined
	try {
		return await Promise.race([
			promise,
			new Promise<T>((_, reject) => {
				handle = setTimeout(() => reject(new Error('whois timeout')), ms)
			}),
		])
	}
	finally {
		if (handle !== undefined)
			clearTimeout(handle)
	}
}
