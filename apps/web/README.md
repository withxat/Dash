# @dash/web

Landing page and edge app for `https://dash.xat.sh` (Cloudflare Worker name
`dash-relay`).

Stack: Vite 8 + React + Tailwind 4 SPA, Hono Worker for `/health`, `/api/*`,
OAuth callback, and dormant `/push/*`.

```text
GET  /                         Landing SPA (Workers Assets)
GET  /privacy                  Privacy SPA route
GET  /health                   Liveness probe (plain text)
GET  /api/health               JSON health
GET  /oauth/callback           302 → dash://oauth/callback?…
*    /push/*                   Dormant APNs bridge (unchanged behavior)
```

OAuth and push use `assets.run_worker_first` so SPA `not_found_handling`
cannot swallow the Cloudflare OAuth navigation callback.

## Develop

```sh
pnpm install
pnpm web:dev
```

## Deploy

Worker name stays `dash-relay` so the custom domain and APNs secrets remain
bound. Deploy replaces the previous relay-only worker:

```sh
pnpm web:deploy
```

Verify:

```sh
curl -sf https://dash.xat.sh/health
curl -sI 'https://dash.xat.sh/oauth/callback?x=1'   # Location: dash://oauth/callback?x=1
curl -sf https://dash.xat.sh/                        # HTML landing page
```

Secrets (`pnpm --filter @dash/web exec wrangler secret put <NAME>`):

| Name | Notes |
| --- | --- |
| `APNS_KEY_P8` | Entire `.p8` including BEGIN/END lines |
| `APNS_KEY_ID` | 10-character Key ID from Apple |
| `PUSH_HMAC_SECRET` | `openssl rand -base64 32` |

Plain vars live in `wrangler.jsonc` (`APNS_TEAM_ID`, `APNS_TOPIC`).
