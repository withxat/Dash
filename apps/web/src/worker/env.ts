/**
 * Bindings for the Dash edge worker (landing + OAuth relay + registration).
 *
 * Deliberately empty: nothing the worker still serves needs a secret. OAuth is
 * a stateless 302 that never touches Cloudflare credentials or the PKCE
 * verifier, and the registration snapshot is unauthenticated RDAP/WHOIS backed
 * by the Cache API.
 */
export interface Env {}
