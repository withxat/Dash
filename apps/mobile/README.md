# CloudFX (mobile)

A mobile Cloudflare client built with Expo / React Native. Sign in with your
Cloudflare account via official OAuth 2.0 (Authorization Code + PKCE), then
browse your accounts, zones, and DNS records.

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
6. Select the scopes the app will request: `user-details.read`,
   `account-settings.read`, `zone.read`, `dns.read`, `analytics.read`, and
   `account-analytics.read`. The `offline_access` protocol scope is used for
   refresh tokens.
7. Save and copy the **Client ID**.

> The Client ID is **not secret** for a PKCE public client and is safe to bundle
> in the app. There is no client secret.

## 2. Register the redirect URI

`expo-auth-session`'s `makeRedirectUri` resolves the redirect URI for the
current runtime. In a development build or standalone build with the
`cloudfx` scheme (see [`app.json`](./app.json)), it resolves to:

```text
cloudfx://oauth/callback
```

Register exactly this value in your Cloudflare OAuth client's allowed redirect
URIs. (In Expo Go the URI is `exp://<host>:<port>/--/oauth/callback`, but Go is
not supported for this flow — use a dev build.)

## 3. Configure the Client ID

The app reads the Client ID from the `EXPO_PUBLIC_CLOUDFLARE_CLIENT_ID` env var
at build time (see [`lib/config.ts`](./lib/config.ts)). Copy the example env
file and fill it in:

```sh
cp .env.example .env
# .env
EXPO_PUBLIC_CLOUDFLARE_CLIENT_ID=<your-client-id>
```

`EXPO_PUBLIC_*` variables are inlined into the bundle by Expo/Metro, so they
are available in `lib/config.ts` as `process.env.EXPO_PUBLIC_CLOUDFLARE_CLIENT_ID`.
If the value is empty, the login screen shows a "not configured" state instead
of starting the flow.

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

1. **Authorize.** `lib/auth.tsx` builds an auth request with
   `expo-auth-session`'s `useAuthRequest` (`response_type=code`, PKCE with
   S256, scopes from `lib/config.ts`) and opens the Cloudflare authorize page
   (`https://dash.cloudflare.com/oauth2/authorize`) in an in-app browser.
2. **Redirect.** After consent, Cloudflare redirects to
   `cloudfx://oauth/callback?code=...`. The in-app browser closes and
   `promptAsync()` resolves with the result.
3. **Exchange.** The app calls `@cloudfx/api`'s `exchangeAuthorizationCode`
   against `https://dash.cloudflare.com/oauth2/token`, sending the `code`,
   `code_verifier`, `client_id`, and `redirect_uri`. The response is a
   `TokenSet` (`access_token`, optional `refresh_token`, `expires_in`).
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
[`packages/api/src/scopes.ts`](../../packages/api/src/scopes.ts) and is
`user-details.read`, `account-settings.read`, `zone.read`, `dns.read`,
`analytics.read`, `account-analytics.read`, and `offline_access`.

## Project layout

```text
apps/mobile/
├── app/                 # expo-router (file-based) routes
│   ├── _layout.tsx      # Root: SafeArea + QueryClient + AuthProvider
│   ├── index.tsx        # Auth gate → redirect to /login or /home
│   ├── (auth)/
│   │   ├── _layout.tsx
│   │   └── login.tsx    # Sign-in screen (shows redirect URI when unconfigured)
│   └── (app)/
│       ├── _layout.tsx  # Authenticated guard
│       └── home.tsx     # Verify token + list accounts/zones
├── components/
│   └── button.tsx       # Shared button
├── lib/
│   ├── api.ts           # Singleton CloudflareClient + React Query
│   ├── auth-context.ts  # Auth context + types
│   ├── auth.tsx         # AuthProvider (OAuth + PKCE + token storage)
│   ├── use-auth.ts      # useAuth() hook
│   ├── config.ts        # Client id, redirect URI, scopes, discovery
│   └── storage.ts       # SecureStore-backed token store
├── app.json             # Expo config (scheme: cloudfx, plugins)
├── babel.config.cjs     # NativeWind + reanimated Babel plugins
├── metro.config.cjs     # Monorepo + NativeWind + tsconfig paths
├── tailwind.config.cjs
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
