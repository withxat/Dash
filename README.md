# Dash for Cloudflare

[English](README.md) | [简体中文](README.zh-CN.md)

Dash is a native iOS and iPadOS Cloudflare client built with SwiftUI. It signs in with OAuth 2.0 Authorization Code + PKCE and manages zones, DNS, cache, security settings, Workers, Pages, R2, KV, D1, Queues, Vectorize, Secrets Store, account services, and analytics.

The installed app is named **Dash**. Its bundle identifier is `sh.xat.dash`, its callback is `dash://oauth/callback`, and its App Store name is **Dash for Cloudflare**.

## Workspace

| Path | Purpose |
| --- | --- |
| `apps/ios` | iOS 17+ SwiftUI app, Xcode project, unit tests, and UI tests |
| `packages/cloudflare-api` | Dependency-free Swift Package for OAuth and Cloudflare REST/GraphQL APIs |
| `apps/relay-worker` | Stateless Worker that redirects the registered HTTPS callback to `dash://` |
| `packages/ui` | Unused web component library retained from the original workspace |

## Requirements

- Xcode 26 or newer with an iOS Simulator
- Swift 6
- Node.js current LTS and pnpm 11 for the relay Worker and web package

## Configure OAuth

Copy the sample configuration:

```sh
cp apps/ios/Config/Secrets.xcconfig.example apps/ios/Config/Secrets.xcconfig
```

Set `DASH_CLIENT_ID` to the public Cloudflare OAuth client ID and `DASH_REDIRECT_URI` to the deployed relay's HTTPS `/oauth/callback` URL. The HTTPS redirect must be registered on the Cloudflare OAuth client. Do not register the custom scheme with Cloudflare; the relay converts the final callback to `dash://oauth/callback`.

Changing scopes requires enabling the same exact scope IDs on the OAuth client and signing in again.

## Develop

```sh
open apps/ios/Dash.xcodeproj
pnpm ios:build
pnpm ios:test
pnpm api:test
pnpm lint
pnpm lint:fix
pnpm typecheck
```

The API client stores tokens through a `TokenStore` abstraction. Dash implements it with a device-only Keychain service. The client serializes refreshes, retries one request after a 401, and clears credentials on sign-out.

## OAuth relay

The relay is intentionally stateless. It never logs callback parameters and never receives the PKCE verifier.

```sh
pnpm install
pnpm --filter @dash/relay-worker exec wrangler login
pnpm --filter @dash/relay-worker run deploy
```

Redeploy the Worker before using Dash so its callback target is `dash://oauth/callback`. After deploy, update the Cloudflare OAuth client and `DASH_REDIRECT_URI` to `https://dash-relay.<subdomain>.workers.dev/oauth/callback`.

## Verification

`pnpm typecheck` runs JavaScript type checking, Swift Package tests, and a signed simulator build. `pnpm ios:test` runs Dash unit and UI tests on an iPhone 17 Pro simulator. Lefthook formats and verifies staged Swift and TypeScript changes before commit.

## License

[MIT](LICENSE)
