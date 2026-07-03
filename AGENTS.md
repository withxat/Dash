# AGENTS.md

CloudFX is a mobile Cloudflare client: sign in with a Cloudflare account via
OAuth 2.0 (Authorization Code + PKCE), then manage zones, DNS records (full
CRUD), cache purge, zone quick settings (dev mode / Under Attack / HTTPS /
SSL), firewall security events, Workers (workers.dev start/pause, custom
domains, deployments, per-zone routes, source viewer), Pages projects
(domains, deployment status), R2 buckets + Workers KV
(browse/upload/edit/delete), and account + zone analytics incl. Web Analytics
(RUM). The repo is a pnpm workspace managed with Turborepo.

## Workspace layout

| Workspace | Package name | Purpose |
| --- | --- | --- |
| `apps/mobile` | `@cloudfx/mobile` | The app. Expo SDK 57 + React Native + expo-router + NativeWind. |
| `apps/relay-worker` | `@cloudfx/relay-worker` | Stateless Cloudflare Worker that 302-redirects the `https://` OAuth callback into the `cloudfx://` deep link. Deployed with wrangler. |
| `packages/api` | `@cloudfx/api` | Framework-agnostic, `fetch`-based Cloudflare client: OAuth helpers (exchange / refresh / revoke), `CloudflareClient` with automatic 401 → refresh-retry, typed REST + GraphQL analytics helpers. **Source-exported — no build step.** |
| `packages/ui` | `ui` | shadcn/ui (base-nova) component library for **web** (React DOM + Tailwind v4). Left over from the monorepo template; not consumed by the mobile app. Do not import it from `apps/mobile`. |

Per-app details live in `apps/mobile/README.md` (OAuth flow, env setup, file
layout) and `apps/relay-worker/README.md` (why the relay exists, deploy steps).

## Commands

Requires Node (current LTS) + pnpm 11 via Corepack (`corepack enable`). Always
install from the repo root.

```sh
pnpm install
pnpm dev          # turbo dev (all workspaces with a dev task)
pnpm typecheck    # tsc --noEmit everywhere
pnpm lint         # ESLint everywhere
pnpm lint:fix     # ESLint with --fix (this is also the formatter)
pnpm build        # only packages that define a build task
```

Target a single workspace with `pnpm --filter`:

```sh
pnpm --filter @cloudfx/mobile dev            # Metro / Expo dev server
pnpm --filter @cloudfx/mobile typecheck
pnpm --filter @cloudfx/relay-worker run deploy   # wrangler deploy
```

Before finishing any change, run `pnpm typecheck` and `pnpm lint` (or the
filtered equivalents). Lefthook runs `lint:fix` + `typecheck` on pre-commit,
so unfixed issues will block commits anyway.

## Code style and conventions

- **Formatting is ESLint's job** (`@withxat/eslint-config`, ESLint 10 flat
  config). There is no Prettier. Run `pnpm lint:fix` instead of hand-formatting.
  House style: tabs for indentation, single quotes, no semicolons.
- **TypeScript 6, strict**, via `@withxat/tsconfig`. Keep everything typed; the
  API surface in `packages/api` exports explicit types from `src/index.ts`.
- **Dependency versions come from catalogs** in `pnpm-workspace.yaml`
  (`catalog:devtool`, `catalog:react`, `catalog:mobile`, `catalog:tailwind`).
  When adding a dependency shared across workspaces, add or reuse a catalog
  entry rather than hardcoding a version. Cross-workspace deps use
  `workspace:*`.
- **Commits follow Conventional Commits** (`feat:`, `fix:`, `chore:`, …).
- pnpm supply-chain policy (`trustPolicy: no-downgrade`) may reject new
  packages; exceptions go in `minimumReleaseAgeExclude` / `trustPolicyExclude`
  in `pnpm-workspace.yaml` only after review.

## Mobile app (`apps/mobile`)

- **Routing:** expo-router file-based routes under `app/`. `(auth)` group holds
 the login screen; `(app)/_layout.tsx` is an outer native stack whose **single
 shared header** (`lib/app-shell-header.tsx`) covers native tabs and all pushed
 feature stacks: tab roots show the profile avatar on the left; every other
 screen shows a native back button in the same slot. `(tabs)` uses
 `expo-router/unstable-native-tabs` (home, items, watchtower, search); nested
 stacks under tabs and under `zones` / `workers` / `storage` / `account` /
 `profile` set `headerShown: false` so only the app shell draws a header (form
 sheets keep their own modal header). UI glyphs come from `@solar-icons/react-native` via
 `components/icons.tsx`; catalog/product glyphs are Solar Linear icons mapped
 in `components/catalog-item-icon.tsx`.
- **Styling:** NativeWind `className` strings (Tailwind v3 syntax) over
 Kumo-aligned semantic color tokens (`bg-canvas`, `bg-base`, `bg-elevated`,
 `text-default`, `text-subtle`, `border-line`, `bg-brand`, `text-accent`, …)
 defined as CSS variables in `global.css` with light/dark values (system
 appearance via `darkMode: 'media'`). Primary actions use Cloudflare blue
 (`brand`); the orange accent (`accent`) is reserved for brand marks and
 emphasis. The Kumo-aligned design system lives in `components/kumo/` (barrel
 `components/kumo/index.ts`); legacy paths under `components/*.tsx` re-export
 from there for backward compatibility. Non-native primitives mirror Kumo
 patterns (`Badge` variants/appearances, squircle `Switch`, `LayerCard`, etc.).
 Never hardcode hex colors in components; for JS-side colors (navigator chrome,
 spinners, animated controls) use `useTheme()` from `lib/theme.ts`. Combine
 conditional classes with the local `cx` helper from `lib/cx.ts` — not
 `clsx`/`cn` from elsewhere. App-specific helpers (Stat, Row, SettingRow,
 Segmented, icons, …) stay in `components/`; prefer importing Kumo primitives
 from `components/kumo` for new UI. Long lists use `LegendList` from
 `@legendapp/list/react-native`.
- **Data:** TanStack React Query on top of a singleton `CloudflareClient`
  (`lib/api.ts`). Tokens live in SecureStore (`lib/storage.ts`); auth state
  comes from `useAuth()` (`lib/use-auth.ts`), active account from
  `useActiveAccount()`.
- **Config:** `EXPO_PUBLIC_CLOUDFLARE_CLIENT_ID` and
  `EXPO_PUBLIC_CLOUDFLARE_REDIRECT_URI` are read at bundle time in
  `lib/config.ts`. They are inlined by Metro — after changing `.env`, Metro
  must be restarted. If unset, the login screen shows a "not configured" state.
- **Expo Go is not supported.** The OAuth flow needs the custom `cloudfx://`
  scheme, so a development build is required (`eas build --profile development`
  or `expo prebuild`). Adding/changing native dependencies requires a new dev
  build; JS-only changes do not.
- Always follow the React Native performance rules in
  `.agents/skills/vercel-react-native-skills/` (they are workspace rules):
  no bare strings outside `<Text>`, no `&&` rendering with falsy values,
  virtualize lists, native navigators, `Pressable` over Touchables, etc.

## OAuth architecture (why the relay Worker exists)

Cloudflare OAuth clients only accept `http(s)://` redirect URIs, but the app
can only reliably capture callbacks via the `cloudfx://` custom scheme. So:

```
app → authorize on dash.cloudflare.com (redirect_uri = https://<worker>/oauth/callback)
dash → 302 https://<worker>/oauth/callback?code=…&state=…
worker → 302 cloudfx://oauth/callback?code=…&state=…   (captured by the app)
app → exchanges code + PKCE code_verifier for tokens
```

The Worker (`apps/relay-worker/src/index.ts`) is stateless, logs nothing, and
cannot exchange the code (it never holds the PKCE verifier). Keep it that way:
do not add state, logging of query params, or token handling to it.

Scopes are exact Cloudflare scope IDs (e.g. `zone.read`, `dns.write`) defined
in `packages/api/src/scopes.ts` — colon-delimited scopes are rejected by
Cloudflare, write scopes end in `.write` (never `.edit`), and Workers
permissions are fine-grained (`workers-scripts.*`, `workers-routes.*`,
`workers-kv-storage.*`, `workers-r2.*` / `workers-r2-bucket-item.*`) — there
is no blanket `workers.read`/`workers.edit`. Requesting a scope also requires
enabling it on the OAuth client in the Cloudflare dashboard, and existing
sessions must sign out/in to pick up newly added scopes. The app degrades
gracefully on 403s from missing scopes (hides or explains the affected
section). Discover valid scope IDs via `GET /client/v4/oauth/scopes`.

## packages/api rules

- Keep it dependency-free and platform-agnostic: plain `fetch`, no React, no
  Expo imports. It is consumed from source by the mobile app via the workspace
  symlink.
- New Cloudflare endpoints go through `CloudflareClient` (so they inherit the
  401 → refresh-retry behavior) with response types in `src/types.ts`, and get
  re-exported from `src/index.ts`.
