/**
 * Stateless registration challenges and opaque notify bindings.
 *
 * Registration proves possession of an APNs token without storing server-side
 * state: the start route sends a nonce and a short-lived encrypted ticket only
 * through APNs. The complete route verifies both before returning a webhook
 * capability. Notify URLs carry a separate AEAD-sealed binding so Cloudflare's
 * readable webhook metadata never exposes the device token or account id.
 */

import { signPushHMAC, verifyPushHMAC } from './hmac.ts'
import {
	isAccountID,
	isDeviceToken,
	isPushEnvironment,
	isRequestID,
} from './push-validate.ts'

const ENCODER = new TextEncoder()
const SEALED_VERSION = 1
const AES_GCM_IV_BYTES = 12
const CHALLENGE_NONCE_BYTES = 32
const MAX_SEALED_VALUE_LENGTH = 4096
const TICKET_PURPOSE = 'dash.push.registration-ticket.v1'
const NOTIFY_PURPOSE = 'dash.push.notify-binding.v1'
const HKDF_SALT = ENCODER.encode('dash.push.hkdf.v1')

export const REGISTRATION_TICKET_TTL_SECONDS = 5 * 60

export interface RegistrationChallenge {
	nonce: string
	requestID: string
	ticket: string
}

export interface RegistrationStart {
	accountID: string
	environment: string
	requestID: string
	token: string
}

export interface NotifyBinding {
	accountID: string
	environment: string
	issuedAt: number
	token: string
	version: 1
}

interface RegistrationTicket {
	expiresAt: number
	issuedAt: number
	nonceMAC: string
	notifyBinding: string
	requestID: string
	version: 1
}

function base64url(bytes: Uint8Array): string {
	let binary = ''
	for (const byte of bytes)
		binary += String.fromCharCode(byte)
	return btoa(binary)
		.replace(/\+/g, '-')
		.replace(/\//g, '_')
		.replace(/=+$/, '')
}

function fromBase64url(value: string): null | Uint8Array {
	if (
		value.length === 0
		|| value.length > MAX_SEALED_VALUE_LENGTH
		|| !/^[\w-]+$/.test(value)
	) {
		return null
	}

	const padded = value
		.replace(/-/g, '+')
		.replace(/_/g, '/')
		.padEnd(Math.ceil(value.length / 4) * 4, '=')
	try {
		const binary = atob(padded)
		const bytes = new Uint8Array(binary.length)
		for (let index = 0; index < binary.length; index++)
			bytes[index] = binary.charCodeAt(index)
		return bytes
	}
	catch {
		return null
	}
}

async function deriveAEADKey(secret: string, purpose: string): Promise<CryptoKey> {
	const material = await crypto.subtle.importKey(
		'raw',
		ENCODER.encode(secret),
		'HKDF',
		false,
		['deriveKey'],
	)
	return crypto.subtle.deriveKey(
		{
			hash: 'SHA-256',
			info: ENCODER.encode(purpose),
			name: 'HKDF',
			salt: HKDF_SALT,
		},
		material,
		{ length: 256, name: 'AES-GCM' },
		false,
		['decrypt', 'encrypt'],
	)
}

async function seal(
	secret: string,
	purpose: string,
	value: object,
): Promise<string> {
	const key = await deriveAEADKey(secret, purpose)
	const iv = crypto.getRandomValues(new Uint8Array(AES_GCM_IV_BYTES))
	const plaintext = ENCODER.encode(JSON.stringify(value))
	const ciphertext = new Uint8Array(
		await crypto.subtle.encrypt(
			{
				additionalData: ENCODER.encode(purpose),
				iv,
				name: 'AES-GCM',
				tagLength: 128,
			},
			key,
			plaintext,
		),
	)
	const sealed = new Uint8Array(1 + iv.length + ciphertext.length)
	sealed[0] = SEALED_VERSION
	sealed.set(iv, 1)
	sealed.set(ciphertext, 1 + iv.length)
	return base64url(sealed)
}

async function open(
	secret: string,
	purpose: string,
	sealedValue: string,
): Promise<unknown> {
	const sealed = fromBase64url(sealedValue)
	if (
		!sealed
		|| sealed[0] !== SEALED_VERSION
		|| sealed.length <= 1 + AES_GCM_IV_BYTES + 16
	) {
		return null
	}

	const iv = sealed.slice(1, 1 + AES_GCM_IV_BYTES)
	const ciphertext = sealed.slice(1 + AES_GCM_IV_BYTES)
	try {
		const key = await deriveAEADKey(secret, purpose)
		const plaintext = await crypto.subtle.decrypt(
			{
				additionalData: ENCODER.encode(purpose),
				iv,
				name: 'AES-GCM',
				tagLength: 128,
			},
			key,
			ciphertext,
		)
		return JSON.parse(new TextDecoder().decode(plaintext)) as unknown
	}
	catch {
		return null
	}
}

function isSafeTimestamp(value: unknown): value is number {
	return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0
}

function parseNotifyBinding(value: unknown): NotifyBinding | null {
	if (!value || typeof value !== 'object')
		return null
	const binding = value as Record<string, unknown>
	if (
		binding.version !== 1
		|| typeof binding.accountID !== 'string'
		|| !isAccountID(binding.accountID)
		|| typeof binding.environment !== 'string'
		|| !isPushEnvironment(binding.environment)
		|| !isSafeTimestamp(binding.issuedAt)
		|| typeof binding.token !== 'string'
		|| !isDeviceToken(binding.token)
	) {
		return null
	}
	return {
		accountID: binding.accountID,
		environment: binding.environment,
		issuedAt: binding.issuedAt,
		token: binding.token.toLowerCase(),
		version: 1,
	}
}

function parseRegistrationTicket(value: unknown): null | RegistrationTicket {
	if (!value || typeof value !== 'object')
		return null
	const ticket = value as Record<string, unknown>
	if (
		ticket.version !== 1
		|| !isSafeTimestamp(ticket.expiresAt)
		|| !isSafeTimestamp(ticket.issuedAt)
		|| ticket.expiresAt <= ticket.issuedAt
		|| ticket.expiresAt - ticket.issuedAt > REGISTRATION_TICKET_TTL_SECONDS
		|| typeof ticket.nonceMAC !== 'string'
		|| !/^[0-9a-f]{64}$/i.test(ticket.nonceMAC)
		|| typeof ticket.notifyBinding !== 'string'
		|| fromBase64url(ticket.notifyBinding) === null
		|| typeof ticket.requestID !== 'string'
		|| !isRequestID(ticket.requestID)
	) {
		return null
	}
	return {
		expiresAt: ticket.expiresAt,
		issuedAt: ticket.issuedAt,
		nonceMAC: ticket.nonceMAC.toLowerCase(),
		notifyBinding: ticket.notifyBinding,
		requestID: ticket.requestID,
		version: 1,
	}
}

function nonceMessage(requestID: string, notifyBinding: string, nonce: string): string {
	return `registration-nonce:v1:${requestID}:${notifyBinding}:${nonce}`
}

function isChallengeNonce(nonce: string): boolean {
	return fromBase64url(nonce)?.length === CHALLENGE_NONCE_BYTES
}

export async function createRegistrationChallenge(
	secret: string,
	start: RegistrationStart,
	nowSeconds = Math.floor(Date.now() / 1000),
): Promise<RegistrationChallenge> {
	const notifyBinding = await seal(secret, NOTIFY_PURPOSE, {
		accountID: start.accountID,
		environment: start.environment,
		issuedAt: nowSeconds,
		token: start.token.toLowerCase(),
		version: 1,
	} satisfies NotifyBinding)
	const nonce = base64url(crypto.getRandomValues(new Uint8Array(CHALLENGE_NONCE_BYTES)))
	const nonceMAC = await signPushHMAC(
		secret,
		nonceMessage(start.requestID, notifyBinding, nonce),
	)
	const ticket = await seal(secret, TICKET_PURPOSE, {
		expiresAt: nowSeconds + REGISTRATION_TICKET_TTL_SECONDS,
		issuedAt: nowSeconds,
		nonceMAC,
		notifyBinding,
		requestID: start.requestID,
		version: 1,
	} satisfies RegistrationTicket)

	return { nonce, requestID: start.requestID, ticket }
}

export async function completeRegistrationChallenge(
	secret: string,
	ticketValue: string,
	nonce: string,
	nowSeconds = Math.floor(Date.now() / 1000),
): Promise<null | { binding: NotifyBinding, sealedBinding: string }> {
	if (!isChallengeNonce(nonce))
		return null

	const ticket = parseRegistrationTicket(
		await open(secret, TICKET_PURPOSE, ticketValue),
	)
	if (!ticket || nowSeconds >= ticket.expiresAt || nowSeconds < ticket.issuedAt)
		return null

	const nonceOK = await verifyPushHMAC(
		secret,
		nonceMessage(ticket.requestID, ticket.notifyBinding, nonce),
		ticket.nonceMAC,
	)
	if (!nonceOK)
		return null

	const binding = await openNotifyBinding(secret, ticket.notifyBinding)
	return binding ? { binding, sealedBinding: ticket.notifyBinding } : null
}

export async function openNotifyBinding(
	secret: string,
	sealedBinding: string,
): Promise<NotifyBinding | null> {
	return parseNotifyBinding(await open(secret, NOTIFY_PURPOSE, sealedBinding))
}

function webhookSecretMessage(sealedBinding: string): string {
	return `cf-webhook-auth:opaque:v1:${sealedBinding}`
}

export async function opaqueWebhookSecret(
	secret: string,
	sealedBinding: string,
): Promise<string> {
	return signPushHMAC(secret, webhookSecretMessage(sealedBinding))
}

export async function verifyOpaqueWebhookSecret(
	secret: string,
	sealedBinding: string,
	provided: string,
): Promise<boolean> {
	return verifyPushHMAC(secret, webhookSecretMessage(sealedBinding), provided)
}
