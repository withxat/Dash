# AGENTS.md

Dash for Cloudflare is a native iPhone Cloudflare client. The installed name is `Dash`, the bundle identifier is `sh.xat.dash`, and OAuth returns through `dash://oauth/callback` after the stateless HTTPS relay.

## Product scope (UI)

- **iPhone only.** The Xcode target is `TARGETED_DEVICE_FAMILY = 1`. Design, implement, and polish for portrait iPhone. Do not design, implement, polish, or “fix” iPad / iPadOS / Stage Manager / Split View layouts unless the user explicitly asks.
- **One compact canvas per tab.** Navigation is workspace layers on a single phone stack — not `NavigationSplitView`, not sidebar + detail, not dual adaptive layouts. Prefer the compact path for all new work.
- **Do not reintroduce regular-width layout forks.** No `horizontalSizeClass == .regular` chrome, no split selection APIs, no reading-width content columns for “iPad readiness.” Optimize for iPhone; ignore iPad parity.

## Workspace

| Path | Purpose |
| --- | --- |
| `apps/ios` | Swift 6, SwiftUI, Observation, iOS 17+ app and tests |
| `packages/cloudflare-api` | Platform-neutral Swift Package for OAuth and Cloudflare APIs |
| `apps/web` | Vite + React landing page and Hono edge app at `dash.xat.sh` (worker `dash-relay`); hosts OAuth callback and dormant `/push/*` |
| `packages/ui` | Web-only component library; do not import it into Dash |

## Commands

```sh
pnpm install
pnpm ios:build      # signed simulator build
pnpm ios:device     # signed device build
pnpm ios:test       # unit + UI tests on an iPhone 17 Pro simulator (Xcode 26+)
pnpm api:test       # Swift Package tests, no simulator needed
pnpm typecheck      # turbo typecheck + api:test + full simulator build (slow)
pnpm lint
pnpm lint:fix
pnpm ios:icons      # regenerate Solar icon assets
pnpm web:dev        # landing + edge worker locally
pnpm web:deploy     # deploy dash-relay (landing + OAuth relay)
```

Single tests:

```sh
swift test --package-path packages/cloudflare-api --filter <testFunctionName>
xcodebuild -project apps/ios/Dash.xcodeproj -scheme Dash \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -allowProvisioningUpdates -only-testing:DashTests test
```

All iOS build and test commands use Automatic signing with team `J4CCPX9K6H` (`apps/ios/Config/Signing.xcconfig`). OAuth secrets stay in ignored `Config/Secrets.xcconfig`.

Before finishing a task, run `pnpm lint:fix`, `pnpm lint`, `pnpm typecheck`, and `pnpm ios:test`. Fix failures before committing. Commit frequently using Conventional Commits. Lefthook's pre-commit hook runs `lint:fix` and `typecheck` on staged changes, so commits trigger a simulator build.

## Architecture

### iOS app

- One `AppModel` (`@Observable @MainActor`, created in `DashApp`, injected via `.environment`) owns the `CloudflareClient`, `KeychainTokenStore`, `FeatureDataCache`, auth state, accounts, and active-account selection. Switching accounts or signing out clears the cache.
- `AppRootView` switches on auth state into `MainTabView` with three primary tabs (Home, Resources, Watchtower), each with its own `WorkspaceHost` canvas. Resources stays a browse-only catalog. Every drill-down routes through the `Destination` enum (`Catalog.swift`) opened on the tab's `WorkspaceController` and rendered by `DestinationRoutedContent` (`DashWorkspace.swift`). A new screen means a new `Destination` case plus a branch there — layers morph in place instead of using `NavigationPath` push.
- `FeatureID` (`Catalog.swift`) is the feature registry: title, subtitle, SF Symbol, Solar asset, and category per feature. Rich features (zones, workers, R2, KV, D1, account) have dedicated views in `FeatureViews.swift`, `StorageViews.swift`, and `AccountFeatureViews.swift`; the rest fall through to `GenericFeatureView`, which maps the `FeatureID` to a REST path and lists `GenericResource` rows. A simple list feature needs only a `FeatureID` case and a path there — no new view.
- `FeatureDataCache` is an in-memory, session-scoped cache keyed by `FeatureCacheKey` strings. Views read the cache in `.task` and bypass it from `refreshable` with `force: true`.
- Worker detail shows the latest actively serving deployment from the typed deployments endpoint, plus cached analytics and `workers.dev` controls. R2 uploads are capped at 100 MB, stay off the main actor while reading, and expose in-view progress, cancellation, and completion feedback.
- Shared chrome (cards, trays/sheets, pill buttons, catalog toolbar) lives in `DashChrome.swift`; all palette, typography, and spacing tokens in `DashTheme.swift`.
- Watchtower (`WatchtowerModel.swift`) fans out account-health requests concurrently (zones, tunnels, LB pools, registrar, Pages, alerts, plus per-zone certificates and healthchecks capped at 10 zones) and folds them into status signals. Snapshot freshness is shared with the widget: fresh through 2 hours, aging through 24 hours, then stale. Signals without an in-app destination open a detail tray instead of becoming dead rows.
- Home is a launcher: the animated Kumo cloud mascot (`CloudMascotBody`/`CloudMascotEyes` template assets, deterministic sway/blink in `HomeMascotMotion`) over a greeting, three preset quick-action tiles (Add domain opens a tray backed by `createZone`; Workers and R2 open their features), a collapsed-by-default Domains group (deterministic on-device dither avatars from the local `GradientAvatars` package; expanding morphs them into the zone rows plus View all), a static Shortcuts group of all four features, and a Recently used group fed by `RecentResources` (JSON in `@AppStorage`, recorded by zone/worker/R2/KV screens, filtered per account). Watchtower stays on its own tab. Zone pinning remains on zone detail. The legacy `dash.home_shortcuts` value remains decodable for rollback, but it is no longer rendered.

### Auth flow

- `AppModel.signIn()` builds a PKCE authorize URL and opens `ASWebAuthenticationSession`; Cloudflare redirects to the relay's HTTPS callback, which 302s to `dash://oauth/callback`; the app exchanges the code and stores tokens through `KeychainTokenStore` (an actor implementing the package's `TokenStore` protocol).
- Fresh sign-in requests `DashAuthorizationScopes.core` (66 scopes), not every published Cloudflare permission. Workers AI, Browser Rendering, Images, and Stream are hidden behind the experimental-features setting and add their eight scopes incrementally.
- Configuration plumbing: `Config/Base.xcconfig` `#include?`s the ignored `Signing.xcconfig` and `Secrets.xcconfig`; `DASH_CLIENT_ID`/`DASH_REDIRECT_URI` flow into Info.plist keys read by `AppConfiguration.current`. Unexpanded `$(...)` values mean unconfigured, which disables sign-in with a hint instead of crashing.

### Tests

- `DashTests` uses Swift Testing (`@Test`); `DashUITests` uses XCTest. `CloudflareAPITests` uses Swift Testing with a `URLProtocol` mock session — no live network calls.

## Swift conventions

- Use Swift 6 strict concurrency, `async throws`, actors for shared mutable state, and `@Observable @MainActor` for UI state.
- Prefer SwiftUI system navigation, lists, searchable, refreshable, sheets, semantic colors, SF Symbols, and Dynamic Type.
- Phone-first: do not add iPad adaptive layouts, regular-width split navigation, or size-class layout forks (see Product scope above).
- The Kumo-aligned palette is defined in `DashTheme`; do not scatter literal colors through feature views.
- App code depends on `CloudflareAPI`, never on JavaScript packages or `packages/ui`.
- Tokens belong in the Keychain. Local OAuth values belong in ignored `Config/Secrets.xcconfig`; never commit credentials.
- Preserve graceful 403 handling. A missing OAuth scope must affect only its feature and should surface an actionable error.
- Use the exact Cloudflare OAuth scope IDs in `CloudflareScopes`. Write scopes end in `.write`; Workers permissions remain fine-grained.
- Lists should stay lazy or use `List`; avoid loading unbounded object/key collections into a non-virtualized stack.

## Cloudflare API package

- Keep `packages/cloudflare-api` dependency-free and Foundation-based.
- New endpoints go through `CloudflareClient` so they inherit Bearer auth, single-flight refresh, and one retry after 401.
- Public response types are `Codable` and `Sendable`; public operations use `async throws`.
- Binary endpoints use `Data` or file URLs. Do not decode unbounded bodies as text unless the endpoint is known to be bounded.

## Edge app (landing + OAuth + dormant push)

Cloudflare accepts only HTTP(S) redirect URIs. The registered HTTPS callback is
served by worker `dash-relay` at `https://dash.xat.sh` (`apps/web`): a Vite React
landing SPA plus a Hono Worker that redirects OAuth to `dash://oauth/callback`
and bridges Cloudflare alert webhooks to APNs under `/push/*`.

Route ownership:

- `GET /` and SPA navigations → Workers Assets (landing)
- `GET /health` → liveness probe
- `GET /oauth/callback` → 302 to `dash://oauth/callback` (worker-first)
- `/push/*` → dormant APNs bridge (worker-first)

The iOS app does not register for remote notifications or expose the APNs
workflow. Keep `/push/*` dormant for rollback and cleanup compatibility; do not
ship it as a user-facing capability until the entitlement and device flow are
explicitly restored and verified.

Invariants that still hold:

- Zero storage (no KV, DO, or D1). Push state lives in the user's own Cloudflare
  account as a webhook destination plus notification policies.
- Never touches Cloudflare credentials, OAuth tokens, or the PKCE verifier.
- Never logs query parameters, device tokens, alert payloads, or notify URLs
  (the URL is a bearer capability). Logs only APNs status codes via
  `wrangler tail`.

The worker still holds the APNs `.p8` signing key and can process APNs device
tokens for dormant `/push/*` routes. `wrangler dev` cannot reach APNs (HTTP/2).
