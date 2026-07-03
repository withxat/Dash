# CloudFX (mobile)

A mobile Cloudflare client built with Expo / React Native. Sign in with your
Cloudflare account via official OAuth 2.0 (Authorization Code + PKCE), then
manage your zones from your phone:

- **Zones** — browse/search zones per account, zone overview with status and
  nameservers
- **DNS** — full record management: create, edit, and delete records
  (proxied flag, TTL, priority, comments) in a native form sheet
- **Cache** — purge everything or purge a single URL
- **Quick settings** — development mode, Under Attack mode, Always Use HTTPS,
  SSL/TLS mode
- **Security** — firewall events from the last 24 hours with per-action
  summaries
- **Workers & Pages** — script list per account, metadata/bindings, source
  viewer, workers.dev start/pause toggle, custom domains, deployment history,
  per-zone route management (add/delete URL patterns), and Pages projects with
  domains and deployment status
- **Storage** — R2 bucket browser (list/upload/delete objects with prefix
  filtering) and Workers KV browser (namespaces, keys, view/edit/delete values)
- **Analytics** — account-level and zone-level traffic (requests, bandwidth,
  cache rate, threats) with switchable time ranges, plus Web Analytics (RUM)
  page views and visits when a site is configured

The UI follows the system light/dark appearance, uses native tabs and native
large-title headers, and gives haptic feedback on write actions. Visual design
aligns with Cloudflare's [Kumo](https://kumo-ui.com/) design system: semantic
surface hierarchy (`canvas` / `base` / `elevated`), blue primary actions,
orange accent for brand marks, and compact 14px-base typography.

## Architecture

CloudFX is a pnpm workspace. Two packages are involved:

| Package | Purpose |
| --- | --- |
| [`@cloudfx/api`](../../packages/api) | Framework-agnostic, `fetch`-based Cloudflare client: OAuth (PKCE exchange / refresh / revoke), a `CloudflareClient` with automatic 401 → refresh-retry, and typed helpers (`getUser`, `listAccounts`, `listZones`, `listDnsRecords`). Source-exported — no build step. |
| `apps/mobile` | The Expo (SDK 57) + React Native + TypeScript + NativeWind app. Consumes `@cloudfx/api` directly from source via the workspace symlink. |

The app stores tokens with [`expo-secure-store`](https://docs.expo.dev/versions/latest/sdk/secure-store/)
and drives the OAuth flow with [`expo-auth-session`](https://docs.expo.dev/versions/latest/sdk/auth-session/)
+ [`expo-web-browser`](https://docs.expo.dev/versions/latest/sdk/web-browser/).

## Prerequisites

- Node.js (current LTS) and pnpm 11 (enable with `corepack enable`)
- An [Expo development build](https://docs.expo.dev/develop/development-builds/introduction/)
  toolchain (EAS Build or a local `expo prebuild` workflow)
- A Cloudflare account

> **Expo Go is not supported.** The OAuth flow uses a custom URL scheme
> (`cloudfx://`) to capture the redirect, and Expo Go does not allow custom
> schemes for auth redirects. You need a development build or standalone build.

## 1. Create a Cloudflare OAuth client

Cloudflare third-party OAuth clients are PKCE public clients. Create one in the
dashboard:

1. Sign in to <https://dash.cloudflare.com>.
2. Open **My Profile → API Tokens → Create OAuth Client** (or via the IAM OAuth
   Clients API).
3. Set a **name** (e.g. `CloudFX`).
4. Add the **redirect URI** (see below).
5. Enable the **Authorization Code (+ PKCE)** grant. Enable
   **Refresh tokens** if you want silent session restore.
6. Select the scopes the app will request (the full list lives in
   [`packages/api/src/scopes.ts`](../../packages/api/src/scopes.ts)):
   `user-details.read`, `account-settings.read`, `zone.read`, `dns.read`,
   `dns.write`, `cache.purge`, `zone-settings.read`, `zone-settings.write`,
   `workers-scripts.read`, `workers-scripts.write`, `workers-routes.read`,
   `workers-routes.write`, `workers-kv-storage.read`,
   `workers-kv-storage.write`, `workers-r2.read`,
   `workers-r2-bucket-item.read`, `workers-r2-bucket-item.write`, `page.read`,
   `analytics.read`, and `account-analytics.read`. Note there is no blanket
   "Workers" scope — permissions are fine-grained per product (Scripts,
   Routes, KV Storage, R2 Storage). The `offline_access` protocol scope is
   used for refresh tokens.
7. Save and copy the **Client ID**.

> **Adding scopes later?** Every scope in `DEFAULT_CLOUDFLARE_SCOPES` must be
> enabled on the OAuth client, and existing sessions keep their old grants —
> users must sign out and back in to pick up newly added scopes.

> The Client ID is **not secret** for a PKCE public client and is safe to bundle
> in the app. There is no client secret.

## 2. Deploy the relay Worker & register the redirect URI

Cloudflare OAuth clients **only accept `http(s)://` redirect URIs** — a custom
scheme like `cloudfx://` is rejected. The app captures its callback via
`cloudfx://` (the only redirect mechanism that works reliably in a dev build's
in-app browser), so a tiny relay Worker bridges the two:

1. Deploy the worker (see [`apps/relay-worker/README.md`](../relay-worker/README.md)):

   ```sh
   pnpm --filter @cloudfx/relay-worker exec wrangler login   # one-time
   pnpm --filter @cloudfx/relay-worker run deploy
   ```

   Note the printed URL, e.g. `https://cloudfx-relay.<subdomain>.workers.dev`,
   and verify it with `curl -i <url>/` (expect `200 CloudFX OAuth relay OK`).

2. Register the worker's `/oauth/callback` path as an allowed redirect URI in
   your Cloudflare OAuth client:

   ```text
   https://cloudfx-relay.<subdomain>.workers.dev/oauth/callback
   ```

The worker is stateless and only 302-redirects `https://.../oauth/callback?…`
into `cloudfx://oauth/callback?…`. The authorization code is one-time and
PKCE-bound, so the relay cannot exchange it.

## 3. Configure env vars

The app reads the Client ID and redirect URI from `EXPO_PUBLIC_*` env vars at
build time (see [`lib/config.ts`](./lib/config.ts)). Copy the example env file
and fill in both:

```sh
cp .env.example .env
# .env
EXPO_PUBLIC_CLOUDFLARE_CLIENT_ID=<your-client-id>
EXPO_PUBLIC_CLOUDFLARE_REDIRECT_URI=https://cloudfx-relay.<subdomain>.workers.dev/oauth/callback
```

`EXPO_PUBLIC_*` variables are inlined into the bundle by Expo/Metro, so they
are available in `lib/config.ts` as `process.env.EXPO_PUBLIC_*`. If either is
empty, the login screen shows a "not configured" state instead of starting the
flow. After changing `.env`, restart Metro so the new values are bundled.

## 4. Run the app

Install dependencies from the repository root, then start the dev server:

```sh
pnpm install
pnpm --filter @cloudfx/mobile dev
```

Create a development build (one-time, and whenever native deps change):

```sh
cd apps/mobile
eas build --profile development --platform ios   # or android
# or, for a local prebuild:
# npx expo prebuild
```

If you use EAS Build, run `eas init` once to populate `extra.eas.projectId` in
[`app.json`](./app.json). Install the resulting build on a device/simulator,
then open it — it will connect to the running Metro bundler.

## How the OAuth flow works

1. **Authorize.** `lib/auth.tsx` uses `expo-auth-session`'s `useAuthRequest`
   (`response_type=code`, PKCE with S256, scopes from `lib/config.ts`) to build
   the authorize URL — `redirect_uri` is the relay Worker's https URL. It opens
   the Cloudflare authorize page (`https://dash.cloudflare.com/oauth2/authorize`)
   in an in-app browser via `WebBrowser.openAuthSessionAsync`, watching for the
   `cloudfx://` capture URI.
2. **Redirect.** After consent, Cloudflare redirects to the Worker's
   `https://.../oauth/callback?code=...&state=...`; the Worker 302s into
   `cloudfx://oauth/callback?...`, the in-app browser captures it and resolves.
3. **Exchange.** The app validates `state`, then calls `@cloudfx/api`'s
   `exchangeAuthorizationCode` against `https://dash.cloudflare.com/oauth2/token`,
   sending the `code`, `code_verifier`, `client_id`, and `redirect_uri`. The
   response is a `TokenSet` (`access_token`, optional `refresh_token`,
   `expires_in`).
4. **Store.** Tokens are written to the iOS Keychain / Android Keystore via
   `expo-secure-store` (see [`lib/storage.ts`](./lib/storage.ts)).
5. **Use.** `lib/api.ts` exports a singleton `CloudflareClient` that sends the
   access token as a `Bearer` header to the Cloudflare REST API v4. On a `401`,
   it transparently refreshes (if a `refresh_token` exists) and retries once.
6. **Sign out.** `signOut()` revokes the token
   (`https://dash.cloudflare.com/oauth2/revoke`) and clears local storage.

### Scopes

Cloudflare third-party OAuth uses the exact scope IDs assigned to the OAuth
client. Colon-delimited scopes are rejected. The default set lives in
[`packages/api/src/scopes.ts`](../../packages/api/src/scopes.ts) and covers
user/account/zone reads, DNS read/write, cache purge, zone settings
read/write, Workers scripts/routes read/write, Workers KV read/write, R2
bucket + object read/write, Pages read, zone + account analytics, and
`offline_access`. Note that Workers permissions are fine-grained — there is no
blanket `workers.read`/`workers.edit` scope. The full list of scope IDs your
client can request is available from
`GET https://api.cloudflare.com/client/v4/oauth/scopes`.

## Project layout

```text
apps/mobile/
├── app/                     # expo-router (file-based) routes
│   ├── _layout.tsx          # Root: SafeArea + QueryClient + Auth + Toast
│   ├── index.tsx            # Auth gate → redirect to /login or /home
│   ├── (auth)/
│   │   ├── _layout.tsx
│   │   └── login.tsx        # Sign-in screen (shows redirect URI when unconfigured)
│   └── (app)/
│       ├── _layout.tsx      # Authenticated guard + native tabs
│       ├── home/            # Account overview + sign out
│       ├── zones/
│       │   ├── index.tsx    # Zone list (native search, infinite scroll)
│       │   └── [id]/
│       │       ├── index.tsx    # Overview, quick settings, cache, traffic
│       │       ├── dns.tsx      # DNS record list (virtualized)
│       │       ├── record.tsx   # Create/edit/delete record (form sheet)
│       │       ├── security.tsx # Firewall events, last 24h
│       │       └── routes.tsx   # Workers routes (add/delete)
│       ├── analytics/       # Account analytics + Web Analytics (RUM)
│       ├── workers/         # Workers + Pages lists, [name].tsx detail
│       │                    # (subdomain toggle, domains, deployments,
│       │                    # source), pages/[project].tsx deployments
│       └── storage/
│           ├── index.tsx        # Storage menu (R2, KV, D1, Queues, …)
│           ├── r2/index.tsx     # R2 bucket list + create
│           ├── r2/[bucket].tsx  # Object browser (upload/delete, prefix)
│           ├── kv/index.tsx     # KV namespace list + create
│           ├── kv/[namespace].tsx # Key browser (prefix, pagination)
│           └── kv-entry.tsx     # View/edit/delete a value (form sheet)
├── components/              # Shared primitives (Button, Card, Row, Badge,
│                            # Input, Segmented, SettingRow, Skeleton, Toast,
│                            # BarChart, EmptyState, icons, AccountSwitcher)
├── lib/
│   ├── api.ts               # Singleton CloudflareClient + React Query
│   ├── auth.tsx             # AuthProvider (OAuth + PKCE + token storage)
│   ├── theme.ts             # Light/dark palettes + useTheme()
│   ├── navigation.ts        # Themed native-stack screen options
│   ├── haptics.ts           # Haptic feedback helpers
│   ├── format.ts            # Number/byte/date/percent formatting
│   ├── config.ts            # Client id, redirect URI, scopes, discovery
│   └── storage.ts           # SecureStore-backed token store
├── app.json                 # Expo config (scheme: cloudfx, plugins)
├── babel.config.cjs         # NativeWind + reanimated Babel plugins
├── metro.config.cjs         # Monorepo + NativeWind + tsconfig paths
├── tailwind.config.cjs      # Kumo semantic color tokens (CSS variables)
└── tsconfig.json
```

## Scripts

Run from the repository root with `pnpm --filter @cloudfx/mobile <script>`:

| Script | Description |
| --- | --- |
| `dev` | Start Metro / Expo dev server |
| `typecheck` | `tsc --noEmit` |
| `lint` | ESLint |

Or use the Turbo tasks from the root: `pnpm typecheck`, `pnpm lint`.
