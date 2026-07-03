# @cloudfx/relay-worker

A tiny Cloudflare Worker that bridges Cloudflare OAuth and the CloudFX mobile app.

## Why this exists

Cloudflare OAuth clients **only allow `http(s)://` redirect URIs** (enforced in
the dashboard and at the token endpoint). The CloudFX mobile app, however,
captures its OAuth callback via the `cloudfx://` custom scheme — the only
redirect mechanism that works reliably inside the in-app browser on a dev
build (Universal Links need a real domain + AASA and are flaky in the
simulator).

This worker is deployed at the registered `https://` redirect URI and simply
**302-redirects the callback into `cloudfx://`**, forwarding the full query
string (`code`, `state`, …). The app's in-app browser captures the
`cloudfx://` navigation and finishes the flow.

> The mobile app still uses [`expo-auth-session`](https://docs.expo.dev/versions/latest/sdk/auth-session/)
> for PKCE, state, and authorize-URL construction. The only customization is
> telling `WebBrowser.openAuthSessionAsync` to watch the `cloudfx://` capture
> URI while the authorize request sends the worker's `https://` URI as
> `redirect_uri`. No PKCE or OAuth plumbing is hand-rolled.

### Security

The authorization code is one-time, short-lived, and bound to the PKCE
`code_verifier`, which only the app ever holds. Neither this relay nor anyone
observing the redirect can exchange the code. The worker is stateless and logs
nothing.

## Deploy

```sh
# from the repo root
pnpm install

# one-time: authenticate wrangler (opens a browser)
pnpm --filter @cloudfx/relay-worker exec wrangler login

# deploy
pnpm --filter @cloudfx/relay-worker run deploy
```

The deploy prints the worker URL, e.g.
`https://cloudfx-relay.<your-subdomain>.workers.dev`.

Verify it is live:

```sh
curl -i https://cloudfx-relay.<your-subdomain>.workers.dev/
# HTTP/2 200
# CloudFX OAuth relay OK
```

## Register the redirect URI

In your Cloudflare OAuth client, add the worker's `/oauth/callback` path as an
allowed redirect URI:

```text
https://cloudfx-relay.<your-subdomain>.workers.dev/oauth/callback
```

Then set the same value in the mobile app's `.env`:

```sh
# apps/mobile/.env
EXPO_PUBLIC_CLOUDFLARE_REDIRECT_URI=https://cloudfx-relay.<your-subdomain>.workers.dev/oauth/callback
```

Rebuild/restart the app and sign in.

## How it works

```
app  -- authorize (redirect_uri=https://worker/oauth/callback) -->  dash.cloudflare.com
dash.cloudflare.com  -- 302 https://worker/oauth/callback?code=..&state=.. -->  this worker
this worker  -- 302 cloudfx://oauth/callback?code=..&state=.. -->  app (captured)
app  -- exchange(code, code_verifier, redirect_uri=https://worker/oauth/callback) -->  token endpoint
```

## Files

```text
apps/relay-worker/
├── src/index.ts     # GET handler: health check + 302 to cloudfx://
├── wrangler.jsonc   # name=cloudfx-relay, main=src/index.ts
├── tsconfig.json    # @cloudflare/workers-types, strict
└── package.json     # deploy / typecheck scripts
```
