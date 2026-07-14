# @dash/relay-worker

Stateless Cloudflare Worker at `https://dash.xat.sh` (worker name `dash-relay`).
It does two jobs:

1. **OAuth callback** — Cloudflare requires an HTTPS redirect URI; the worker
   302s to `dash://oauth/callback` so Dash can capture the code.
2. **Push bridge** — `POST /push/register` mints an HMAC-signed webhook URL;
   Cloudflare alert webhooks hit `/push/notify/…` and the worker forwards an
   APNs alert.

```text
OAuth:
  Dash → dash.cloudflare.com
  Cloudflare → https://dash.xat.sh/oauth/callback?code=…&state=…
  relay → dash://oauth/callback?code=…&state=…
  Dash → token endpoint with the code and private PKCE verifier

Push:
  Dash → POST https://dash.xat.sh/push/register {token, environment}
  relay → {url, secret}  (url embeds env.token.hmac)
  Dash → creates Cloudflare webhook destination with that url + secret
  Cloudflare alert → POST url (cf-webhook-auth: secret)
  relay → verifies HMAC + secret → APNs alert
```

The worker stores nothing. It never sees Cloudflare API tokens or the PKCE
verifier. It logs only APNs HTTP status codes (never device tokens, payloads,
or notify URLs).

## Deploy

```sh
pnpm install
pnpm --filter @dash/relay-worker exec wrangler login
pnpm --filter @dash/relay-worker run deploy
```

Verify:

```sh
curl https://dash.xat.sh/                    # Dash OAuth relay OK
curl -D - https://dash.xat.sh/oauth/callback?x=1 -o /dev/null
# → 302 Location: dash://oauth/callback?x=1
```

Register `https://dash.xat.sh/oauth/callback` on the Cloudflare OAuth client and
in `DASH_REDIRECT_URI`. The custom domain is bound in the Cloudflare dashboard,
not in `wrangler.jsonc`.

## Secrets and vars

Plain vars in `wrangler.jsonc` (non-secret):

| Name | Value |
| --- | --- |
| `APNS_TEAM_ID` | `J4CCPX9K6H` |
| `APNS_TOPIC` | `sh.xat.dash` |

Secrets (`pnpm --filter @dash/relay-worker exec wrangler secret put <NAME>`):

| Name | Notes |
| --- | --- |
| `APNS_KEY_P8` | Entire `.p8` including BEGIN/END lines |
| `APNS_KEY_ID` | 10-character Key ID from Apple |
| `PUSH_HMAC_SECRET` | `openssl rand -base64 32` |

## Push notes

- `wrangler dev` cannot talk to APNs ([workerd#4841](https://github.com/cloudflare/workerd/issues/4841)).
  Deploy and test with Cloudflare's policy test endpoint.
- If Cloudflare's webhook destination probe omits `cf-webhook-auth` and
  registration appears to fail with 401, temporarily skip that header check in
  `src/push.ts` (one-line change), redeploy, and re-test.
- JWT signing is cached ~50 minutes per isolate; cross-isolate bursts are
  throttled upstream by Cloudflare `alert_interval`.
