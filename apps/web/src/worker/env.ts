/**
 * Bindings for the Dash edge worker (landing + OAuth relay + push + registration).
 *
 * Secrets (wrangler secret put): APNS_KEY_P8, APNS_KEY_ID, PUSH_HMAC_SECRET.
 * Plain vars (wrangler.jsonc): APNS_TEAM_ID, APNS_TOPIC.
 */
export interface Env {
	APNS_KEY_ID: string
	APNS_KEY_P8: string
	APNS_TEAM_ID: string
	APNS_TOPIC: string
	PUSH_HMAC_SECRET: string
	PUSH_REGISTRATION_ACTOR_LIMITER: RateLimit
	PUSH_REGISTRATION_GLOBAL_LIMITER: RateLimit
}
