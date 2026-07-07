# AGENTS.md

Dash for Cloudflare is a native iOS/iPadOS Cloudflare client. The installed name is `Dash`, the bundle identifier is `sh.xat.dash`, and OAuth returns through `dash://oauth/callback` after the stateless HTTPS relay.

## Workspace

| Path | Purpose |
| --- | --- |
| `apps/ios` | Swift 6, SwiftUI, Observation, iOS 17+ app and tests |
| `packages/cloudflare-api` | Platform-neutral Swift Package for OAuth and Cloudflare APIs |
| `apps/relay-worker` | Stateless TypeScript Cloudflare Worker OAuth relay |
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
pnpm --filter @dash/relay-worker run deploy
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
- `AppRootView` switches on auth state into `MainTabView` — three tabs (Home, Items, Watchtower), each its own `NavigationStack`. Every push routes through the `Destination` enum (`Catalog.swift`) resolved in `destinationRouting()` (`AppRootView.swift`). A new screen means a new `Destination` case plus a branch there.
- `FeatureID` (`Catalog.swift`) is the feature registry: title, subtitle, SF Symbol, Solar asset, and category per feature. Rich features (zones, workers, R2, KV, D1, account) have dedicated views in `FeatureViews.swift`, `StorageViews.swift`, and `AccountFeatureViews.swift`; the rest fall through to `GenericFeatureView`, which maps the `FeatureID` to a REST path and lists `GenericResource` rows. A simple list feature needs only a `FeatureID` case and a path there — no new view.
- `FeatureDataCache` is an in-memory, session-scoped cache keyed by `FeatureCacheKey` strings. Views read the cache in `.task` and bypass it from `refreshable` with `force: true`.
- Shared chrome (cards, trays/sheets, pill buttons, catalog toolbar) lives in `DashChrome.swift`; all palette, typography, and spacing tokens in `DashTheme.swift`.
- Watchtower (`WatchtowerModel.swift`) fans out account-health requests concurrently (zones, tunnels, LB pools, registrar, Pages, alerts, plus per-zone certificates and healthchecks capped at 10 zones) and folds them into status signals.
- Home shortcuts and recents persist in `AppStorage` as comma-separated `FeatureID` raw values.

### Auth flow

- `AppModel.signIn()` builds a PKCE authorize URL and opens `ASWebAuthenticationSession`; Cloudflare redirects to the relay's HTTPS callback, which 302s to `dash://oauth/callback`; the app exchanges the code and stores tokens through `KeychainTokenStore` (an actor implementing the package's `TokenStore` protocol).
- Configuration plumbing: `Config/Base.xcconfig` `#include?`s the ignored `Signing.xcconfig` and `Secrets.xcconfig`; `DASH_CLIENT_ID`/`DASH_REDIRECT_URI` flow into Info.plist keys read by `AppConfiguration.current`. Unexpanded `$(...)` values mean unconfigured, which disables sign-in with a hint instead of crashing.

### Tests

- `DashTests` uses Swift Testing (`@Test`); `DashUITests` uses XCTest. `CloudflareAPITests` uses Swift Testing with a `URLProtocol` mock session — no live network calls.

## Swift conventions

- Use Swift 6 strict concurrency, `async throws`, actors for shared mutable state, and `@Observable @MainActor` for UI state.
- Prefer SwiftUI system navigation, lists, searchable, refreshable, sheets, semantic colors, SF Symbols, and Dynamic Type.
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

## OAuth relay

Cloudflare accepts only HTTP(S) redirect URIs. The registered HTTPS callback is deployed as `dash-relay` on Workers, which redirects to `dash://oauth/callback`.

The Worker must remain stateless: do not log query parameters, persist authorization state, handle tokens, or receive the PKCE verifier. Redeploy it before releasing a Dash build that expects the new scheme.
