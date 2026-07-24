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
*    /push/*                   APNs bridge (register + notify)
```

`/api/registration/:domain` is anonymous and cacheable (Cache API, 12h).
It tries public RDAP first, then port-43 WHOIS for TLDs without RDAP
(e.g. `.sh`). Response shape matches iOS `RdapRegistration`; 404 when empty.


OAuth and push use `assets.run_worker_first` so SPA `not_found_handling`
cannot swallow the Cloudflare OAuth navigation callback.

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
