# Dash for Cloudflare

[English](README.md) | [简体中文](README.zh-CN.md)

Dash is a native iPhone Cloudflare client built with SwiftUI. It signs in with OAuth 2.0 Authorization Code + PKCE and focuses on the day-to-day resources people manage from a phone.

The installed app is named **Dash**. Its bundle identifier is `sh.xat.dash.app`, its callback is `dash://oauth/callback`, and its App Store name is **Dash for Cloudflare**.

## MVP features

Five resource surfaces, plus the shell that makes them usable:

| Feature | What you can do |
| --- | --- |
| **Domains** | Zones, DNS, cache purge, domain settings, zone analytics |
| **Workers** | View scripts, deployment history and cut-over, custom domains, `workers.dev`, analytics |
| **Pages** | View projects, deployments and logs, retry/rollback, custom domains, build Live Activities |
| **R2** | Buckets, browse/upload/preview, rename/move, public URLs, share extension and Shortcuts |
| **KV** | Namespaces, key list, read / create·edit·delete keys |

Shell around those features: Home launcher, Resources catalog, Watchtower traffic charts and Cloudflare notification history, Settings (push alerts, About), multi-account OAuth, and iPhone-only single-stack navigation.

Out of MVP scope: D1, Queues, Vectorize, Secrets Store, Images, Stream, Access, and iPad / split layouts.

## Workspace

| Path | Purpose |
| --- | --- |
| `apps/ios` | iOS 17+ SwiftUI app, Xcode project, unit tests, and UI tests |
| `packages/cloudflare-api` | Dependency-free Swift Package for OAuth and Cloudflare REST/GraphQL APIs |
| `packages/SwiftGlobeKit` | Native SwiftUI + Metal dotted-globe package |
| `apps/web` | Landing page + Hono edge app (`dash-relay`) at `https://dash.xat.sh` |
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

Real-account sign-in requests the audited union of read and write permissions used by Dash's current features in one authorization. The Demo remains read-only. Existing narrower or unknown grants are upgraded to that current set the next time an access action opens OAuth.

Changing scopes requires enabling the same exact scope IDs on the OAuth client and authorizing the updated request again.

## Develop

```sh
open apps/ios/Dash.xcodeproj
pnpm ios:build
pnpm ios:test
pnpm api:test
pnpm globe:test
pnpm lint
pnpm lint:fix
pnpm typecheck
```

The API client stores tokens through a `TokenStore` abstraction. Dash implements it with a device-only Keychain service. The client serializes refreshes, retries one request after a 401, and clears credentials on sign-out.

## Landing + OAuth relay (`apps/web`)

`apps/web` deploys as worker `dash-relay` on `https://dash.xat.sh`. It serves the
marketing landing page, redirects OAuth to `dash://oauth/callback`, and keeps
the `/push/*` APNs bridge for Settings → Push alerts. The relay path is
intentionally stateless: it never logs callback parameters and never receives
the PKCE verifier.

```sh
pnpm install
pnpm --filter @dash/web exec wrangler login
pnpm web:deploy   # versions upload → versions deploy
```

After deploy, verify:

```sh
curl -sf https://dash.xat.sh/health
curl -sI 'https://dash.xat.sh/oauth/callback?x=1'
curl -sf https://dash.xat.sh/
```

Register `https://dash.xat.sh/oauth/callback` on the Cloudflare OAuth client and
in `DASH_REDIRECT_URI`.

## Verification

`pnpm typecheck` runs JavaScript type checking, Swift Package tests, and a signed simulator build. `pnpm ios:test` runs Dash unit and UI tests on an iPhone 17 Pro simulator. Lefthook formats and verifies staged Swift and TypeScript changes before commit.

## License

[MIT](LICENSE)
