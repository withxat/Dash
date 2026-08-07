/**
 * Bindings for the Dash edge worker (landing + OAuth relay + registration).
 *
 * Deliberately empty: nothing the worker still serves needs a secret. OAuth is
 * a stateless 302 that never touches Cloudflare credentials or the PKCE
 * verifier, and the registration snapshot is unauthenticated RDAP/WHOIS backed
 * by the Cache API.
 *
 * The APNs signing key, `PUSH_HMAC_SECRET`, and the two push rate limiters left
 * with the push bridge. Once this deploys, remove the secrets from the account
 * as well — `wrangler secret delete APNS_KEY_P8 APNS_KEY_ID PUSH_HMAC_SECRET`
 * — and drop `APNS_TEAM_ID` / `APNS_TOPIC` and the limiter bindings from
 * `wrangler.jsonc`.
 */
export interface Env {}
