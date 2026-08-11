# @dash/web

Landing page and edge app for `https://dash.xat.sh` (Cloudflare Worker name
`dash-relay`).

Stack: Vite 8 + React + Tailwind 4 SPA, Workers Assets, and a Hono Worker for
the liveness probe, OAuth callback, and public registration lookup.

```text
GET /                         Landing SPA and asset navigations
GET /health                   Liveness probe (plain text)
GET /oauth/callback           302 → dash://oauth/callback?…
GET /api/registration/:domain RDAP → WHOIS registration snapshot
```

`/api/registration/:domain` is anonymous and cacheable (Cache API, 12h).
It tries public RDAP first, then port-43 WHOIS for TLDs without RDAP
(e.g. `.sh`). Response shape matches iOS `RdapRegistration`; 404 when empty.

The OAuth callback and registration lookup use `assets.run_worker_first` so SPA
`not_found_handling` cannot swallow either endpoint. The Worker is otherwise
stateless: `Env` is empty, there are no storage bindings or secrets, and the
OAuth flow never receives Cloudflare credentials, tokens, or the PKCE verifier.

## Develop

```sh
pnpm install
pnpm web:dev
```

## Deploy

Worker name stays `dash-relay` so the custom domain remains attached.
`pnpm web:deploy` is a two-step rollout — upload a version, then promote it
(`wrangler versions upload` → `wrangler versions deploy --yes`) so a bad build
never skips the versions history:

```sh
pnpm web:deploy
```

Observability metrics are enabled, but invocation logs stay disabled because
`/oauth/callback` carries the Cloudflare authorization code in its query string.

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
