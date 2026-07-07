# @dash/relay-worker

Dash OAuth relay bridges Cloudflare's required HTTPS redirect URI to the native app's `dash://oauth/callback` URL.

It forwards the callback query string with a 302 response, stores no state, logs no query parameters, and cannot exchange the authorization code because the PKCE verifier remains inside Dash.

```text
Dash → dash.cloudflare.com
Cloudflare → https://dash-relay.<subdomain>.workers.dev/oauth/callback?code=…&state=…
relay → dash://oauth/callback?code=…&state=…
Dash → token endpoint with the code and private PKCE verifier
```

Deploy from the repository root:

```sh
pnpm install
pnpm --filter @dash/relay-worker exec wrangler login
pnpm --filter @dash/relay-worker run deploy
```

Verify `GET /` returns `Dash OAuth relay OK`. Register the deployed `https://dash-relay.<subdomain>.workers.dev/oauth/callback` URL on the Cloudflare OAuth client and in `DASH_REDIRECT_URI`.
