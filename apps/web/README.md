# @dash/web

Landing page and edge app for `https://dash.xat.sh` (Cloudflare Worker name
`dash-relay`).

Stack: Vite 8 + React + Tailwind 4 SPA, Hono Worker for `/health`, `/api/*`,
OAuth callback, and `/push/*` APNs bridge.

```text
GET  /                         Landing SPA (Workers Assets)
GET  /privacy                  Privacy SPA route
GET  /terms                    Terms of Use SPA route
GET  /health                   Liveness probe (plain text)
GET  /api/health               JSON health
GET  /api/registration/:domain RDAP → WHOIS registration snapshot
GET  /oauth/callback           302 → dash://oauth/callback?…
POST /push/register/start      Begin APNs possession challenge
POST /push/register/complete   Exchange APNs-delivered proof for capability
POST /push/notify/:binding     Authenticated Cloudflare webhook → APNs
```

`/api/registration/:domain` is anonymous and cacheable (Cache API, 12h).
It tries public RDAP first, then port-43 WHOIS for TLDs without RDAP
(e.g. `.sh`). Response shape matches iOS `RdapRegistration`; 404 when empty.


OAuth and push use `assets.run_worker_first` so SPA `not_found_handling`
cannot swallow the Cloudflare OAuth navigation callback.

Push registration stays stateless without treating an APNs token as
authentication:

1. The app posts a request id, account id, APNs token, and environment to
   `/push/register/start`.
2. The relay returns no capability. It sends a short-lived AEAD ticket and
   random nonce only through a silent APNs registration-challenge payload.
3. The app posts that ticket and nonce to `/push/register/complete`; only then
   does the relay return the Cloudflare webhook URL and `cf-webhook-auth`
   secret.

New webhook URLs contain one opaque AEAD binding, not the APNs token or account
id. Existing tuple-based notify URLs remain accepted during migration, but the
old one-step `/push/register` minting route is intentionally unavailable.
Visible APNs fallback copy is generic. The iOS Notification Service Extension
restores the original Cloudflare copy only after checking the account allowlist,
so notification content stays fail-closed even if iOS skips the extension.

`/push/register/start` is guarded before APNs fan-out by per-location aggregate
and network-actor Workers Rate Limiting bindings. Workers invocation logs are
disabled while migration-era notify URLs remain accepted because those old URLs
contain the APNs token; custom logs contain APNs status codes only.

### Push protocol rollout

This security change intentionally uses a hard cut for registration: deploy the
Worker first, then release the matching app immediately. Existing tuple-based
notify capabilities continue delivering during the transition, but older app
builds receive an error if they try to enable push or rotate their token. The
unsafe one-step mint endpoint must not be restored for compatibility. Once the
supported app population has reconciled its stored webhooks to opaque
capabilities, remove the legacy notify parser and rotate `PUSH_HMAC_SECRET`.

## Develop

```sh
pnpm install
pnpm web:dev
```

## Deploy

Worker name stays `dash-relay` so the custom domain and APNs secrets remain
bound. `pnpm web:deploy` is a two-step rollout — upload a version, then promote
it (`wrangler versions upload` → `wrangler versions deploy --yes`) so a bad
build never skips the versions history:

```sh
pnpm web:deploy
```

`observability.enabled` is on in `wrangler.jsonc` (Workers Logs). A GitHub
Actions cron (`.github/workflows/relay-probe.yml`) dials `/health` and checks
that `/oauth/callback` still 302s to `dash://` every 15 minutes.

Verify:

```sh
curl -sf https://dash.xat.sh/health
curl -sI 'https://dash.xat.sh/oauth/callback?x=1'   # Location: dash://oauth/callback?x=1
curl -sf https://dash.xat.sh/api/registration/xat.sh # RDAP/WHOIS snapshot JSON
curl -sf https://dash.xat.sh/                        # HTML landing page
curl -sf https://dash.xat.sh/privacy                 # Public privacy policy
curl -sf https://dash.xat.sh/terms                   # Public terms of use
```

Relay unit tests (`src/worker/relay/*.test.ts`, `node:test`) run as part of
`pnpm --filter @dash/web typecheck` (and therefore Lefthook's typecheck hook).

Secrets (`pnpm --filter @dash/web exec wrangler secret put <NAME>`):

| Name | Notes |
| --- | --- |
| `APNS_KEY_P8` | Entire `.p8` including BEGIN/END lines |
| `APNS_KEY_ID` | 10-character Key ID from Apple |
| `PUSH_HMAC_SECRET` | `openssl rand -base64 32` |

Plain vars live in `wrangler.jsonc` (`APNS_TEAM_ID`, `APNS_TOPIC`).
