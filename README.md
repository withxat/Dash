<p align="center">
  <img src="docs/dash-icon.png" alt="Dash" width="120" height="120">
</p>

# Dash for Cloudflare

English | [简体中文](README.zh-CN.md)

Dash is a native iPhone Cloudflare client built with SwiftUI. It signs in with OAuth 2.0 Authorization Code + PKCE and focuses on the day-to-day resources people manage from a phone.

The installed app is named **Dash**. Its bundle identifier is `sh.xat.dash.app`, its callback is `dash://oauth/callback`, and its App Store name is **Dash for Cloudflare**.

## Features

Resource surfaces in the catalog, plus the shell that makes them usable:

| Feature | What you can do |
| --- | --- |
| **Domains** | Zones, DNS, cache settings, domain settings, traffic / WAF / Web Analytics |
| **Registrations** | Registrar domains you own, status and expiry |
| **Email Routing** | Per-domain routes, settings, destination addresses |
| **Workers** | Scripts, deployment history and cut-over, custom domains, `workers.dev`, analytics, Workers Builds |
| **Pages** | Projects, deployments and logs, retry/rollback, custom domains, build Live Activities |
| **R2** | Buckets, browse/upload/preview, public URLs, Files integration, share extension and Shortcuts |
| **KV** | Namespaces, key list, read / create·edit·delete keys |
| **Tunnels** | Experimental; opt in under Settings → Experimental |

Shell around those features: Home launcher, Resources catalog, Watchtower traffic charts and Cloudflare notification history, an app-icon unread badge, Account / Domain Metrics widgets, multi-account OAuth, and iPhone-only single-stack navigation.

Out of scope for now: D1, Queues, Vectorize, Secrets Store, Images, Stream, Access, and iPad / split layouts.

## Repository layout

```text
apps/
  ios/                   Native iPhone app (SwiftUI, iOS 17+)
    Dash/                Main app target
    DashShare/           Share extension (upload to R2)
    DashWidgets/         Account / Domain Metrics widgets
    DashFileProvider/    Files app R2 mount
    DashTests/           Unit tests
    DashUITests/         UI tests
  web/                   Landing + Hono edge app (`dash-relay` at dash.xat.sh)
packages/
  cloudflare-api/        OAuth + Cloudflare REST/GraphQL client (no third-party deps)
  gradient-avatars/      Deterministic on-device avatars (Outpace palettes, hashvatar paint)
  SwiftDitherKit/        Dithered SwiftUI charts and hold-to-scrub interaction
  SwiftGlobeKit/         SwiftUI + Metal dotted globe for analytics
  BlossomColorPicker/    Vendored SwiftUI color picker
  legal/                 Privacy Policy and Terms of Use (shared with the site)
  ui/                    Unused web component library from the original workspace
docs/                    App icon and other public doc assets
```

The iOS app links the local `cloudflare-api`, `gradient-avatars`, `SwiftDitherKit`, and `SwiftGlobeKit` packages. `BlossomColorPicker` remains a separately tested vendored package; `legal` is the single source for in-app and `dash.xat.sh` legal pages.

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

Real-account sign-in requests the audited union of read and write permissions used by Dash's current features in one authorization. The Demo remains read-only. Any later OAuth reauthorization also requests that full set.

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

## Landing + edge relay (`apps/web`)

`apps/web` deploys as worker `dash-relay` on `https://dash.xat.sh`. It serves the
landing SPA through Workers Assets and owns four public route families:

```text
GET /                         Landing SPA and asset navigations
GET /health                   Liveness probe
GET /oauth/callback           302 → dash://oauth/callback?…
GET /api/registration/:domain RDAP → WHOIS registration snapshot
```

The OAuth callback and registration lookup run worker-first so SPA fallback
routing cannot swallow them. The registration snapshot is anonymous and
cacheable; it tries public RDAP before its port-43 WHOIS fallback. The relay has
no storage or secrets, never receives the PKCE verifier, and keeps invocation
logs disabled because callback URLs contain the Cloudflare authorization code.

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
