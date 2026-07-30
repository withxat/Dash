# AGENTS.md

Dash for Cloudflare is a native iPhone Cloudflare client. The installed name is `Dash`, the bundle identifier is `sh.xat.dash.app`, and OAuth returns through `dash://oauth/callback` after the stateless HTTPS relay.

## Product scope (UI)

- **iPhone only.** The Xcode target is `TARGETED_DEVICE_FAMILY = 1`. Design, implement, and polish for portrait iPhone. Do not design, implement, polish, or “fix” iPad / iPadOS / Stage Manager / Split View layouts unless the user explicitly asks.
- **One compact canvas per tab.** Navigation is workspace layers on a single phone stack — not `NavigationSplitView`, not sidebar + detail, not dual adaptive layouts. Prefer the compact path for all new work.
- **Do not reintroduce regular-width layout forks.** No `horizontalSizeClass == .regular` chrome, no split selection APIs, no reading-width content columns for “iPad readiness.” Optimize for iPhone; ignore iPad parity.

## Workspace

| Path | Purpose |
| --- | --- |
| `apps/ios` | Swift 6, SwiftUI, Observation, iOS 17+ app and tests |
| `packages/cloudflare-api` | Platform-neutral Swift Package for OAuth and Cloudflare APIs |
| `apps/web` | Vite + React landing page and Hono edge app at `dash.xat.sh` (worker `dash-relay`); hosts OAuth callback and `/push/*` APNs bridge |
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
pnpm lint:l10n      # literal DashL10n / Text keys must exist in Localizable.xcstrings (part of lint)
pnpm ios:icons      # regenerate Solar chrome + Hugeicons file-format assets
pnpm web:dev        # landing + edge worker locally
pnpm web:deploy     # versions upload → deploy dash-relay (landing + OAuth relay)
```

Single tests:

```sh
swift test --package-path packages/cloudflare-api --filter <testFunctionName>
xcodebuild -project apps/ios/Dash.xcodeproj -scheme Dash \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -allowProvisioningUpdates -only-testing:DashTests test
```

All iOS build and test commands use Automatic signing with team `UH4FQTHMG2` (`apps/ios/Config/Signing.xcconfig`). OAuth secrets stay in ignored `Config/Secrets.xcconfig`.

Before finishing a task, run `pnpm lint:fix` and `pnpm lint`. Do NOT run simulator builds or tests (`pnpm ios:build`, `pnpm ios:test`, `pnpm typecheck`) unless explicitly asked — they take too long; the user batch-verifies everything themselves later. `pnpm api:test` is seconds-fast and fine when `packages/cloudflare-api` changed. Commit frequently using Conventional Commits, but note Lefthook's pre-commit hook runs `lint:fix` and `typecheck` on staged changes, so a commit itself triggers a simulator build — ask before committing when that wait matters.

## Architecture

### iOS app

- One `AppModel` (`@Observable @MainActor`, created in `DashApp`, injected via `.environment`) owns the `CloudflareClient`, `KeychainTokenStore`, `FeatureDataCache`, auth state, accounts, and active-account selection. Switching accounts or signing out clears the cache.
- `AppRootView` switches on auth state into `MainTabView` with three primary tabs (Home, Resources, Watchtower), each with its own `NavigationStack` path (`DestinationNavigator` in `DashWorkspace.swift`). Resources stays a browse-only catalog. Every drill-down routes through the `Destination` enum (`Catalog.swift`) via `navigationDestination` into `DestinationRoutedContent`. A new screen means a new `Destination` case plus a branch there — standard push/pop.
- Root header invariant (`dashCatalogScreen` + `MainTabView`): every tab root shows a REAL titleless inline nav bar, propped open by an invisible clear `principal` item — a bar with no title and no items collapses to zero inset. Keeping the bar mounted means a push never changes the bar height (no content shift), and pushed screens' `detailHeader` (icon + title principal) lands on the same metrics. The profile avatar is ONE `HeaderProfileButton` floated by `MainTabView` above the pager (so it neither rides along on tab swipes nor gets squashed by the nav bar's item-height clamp), hand-positioned over the leading slot so the push crossfade reads as the avatar morphing into the back button. Do not seat the avatar as a per-page toolbar item. The warm top wash is shared chrome of the same kind: ONE `DashWorkspaceTopWash`, painted by `MainTabView` behind the pager over the workspace canvas, so Home / Resources / Watchtower all show the same light field and the glow holds still while pages slide across it. That works only because tab roots are transparent — `dashCatalogScreen` paints no background of its own and `DashScrollViewConfigurator(fill: .clear)` punches the UIKit plates above the content controller (hosting wrappers, navigation-controller view, page cell) through in both appearances (`DashCanvasPlateRules`). Never hand a tab root or `DestinationStackHost` an opaque plate again, and never copy the wash into a page — three washes ride their pages on a swipe and read as a seam. Pushed screens stay opaque (`dashDetailCanvasChrome` + full-bleed canvas), which is what hides the wash under a detail. The header frost (`dashHeaderScrim`, installed by both chrome modifiers, so every root and every pushed screen has one) is the exception to all of that: it is the one top layer that must live **inside** the page. UIKit draws the navigation bar above the hosted content, so a band placed in the page passes under the title and the back control and leaves them crisp; float it over the pager next to the avatar and it covers them. To reach the status bar from in there it draws above its own layout box and `DashScreenClipLift` unclips the SwiftUI hosting wrappers up to — never past — the screen's own view controller (unclipping the navigation/page containers lets one screen's chrome spill over an incoming push). The frost imports `VariableBlur` directly through Swift Package Manager and uses its `VariableBlurView` only as the page-local backdrop; do not wrap Dash screens in `ProgressiveBlurHeader.StickyBlurHeader`, because that component owns another `ScrollView` and would break the existing screen/probe architecture. Match the reference look with `maxBlurRadius = 5`, a 64pt tail, and an adaptive white/black tint ramp at 0.7 on top, 0.5 at 90pt, and zero at the bottom. `VariableBlur` reaches the backdrop through an obfuscated private `CAFilter`; the product deliberately accepts that OS/App Store risk and tracks the package's `main` branch, so keep the dependency, resolved revision, Settings credit, and this warning together. Reduce Transparency replaces the effect with a canvas ramp whose full navigation region is opaque. The frost is **not** scrubbed by scroll position: `DashHeaderScrimRules.isScrolled` is a two-threshold flip (arm past `enter`, disarm under `exit`, hysteresis between so a resting finger can't chatter it). Crossing the threshold mounts the band with an interruptible 0.36s opacity + 8pt downward entrance that hides the filter's first composited frame; returning to the top uses the same 0.36s curve while lifting it out by 3pt, and Reduce Motion keeps opacity only. A screen's scroll view is usually not laid out when its chrome mounts, so `DashHeaderScrollProbe` re-resolves across `DashHeaderScrollProbeSchedule` — `layoutSubviews` alone fires too early and may never fire again, which leaves that screen permanently unfrosted. The probe is KVO on the screen's own scroll view writing into a per-screen `@Observable` `DashHeaderScrollState` that only the band reads; a scroll-driven value the screen body reads re-applies the `NavigationStack` path mid-push and UIKit cancels the transition, leaving the pushed screen unmounted for good.
- `FeatureID` (`Catalog.swift`) is the feature registry: title, subtitle, SF Symbol, Solar fill/outline assets, and category per feature. Every feature (zones, registrar, workers, pages, r2, kv, tunnels) is rich, with dedicated views in `FeatureViews.swift`, `RegistrarViews.swift`, `StorageViews.swift`, `R2ObjectViews.swift`, `PagesViews.swift`, and `TunnelViews.swift`; the feature router is an exhaustive switch with no `default:`, so a new `FeatureID` must name its screen or it does not build. `GenericFeatureView` is gone. A new feature also owes `FeatureVisualIdentity.tone(for:)` a tone no sibling uses and `DashAuthorizationScopes.coreFeatures` a membership — tests fail otherwise.
- Registrar is a catalog feature (`.registrar`, "Registered domains", beside Domains under Domains & DNS), not a Profile → Account row: a zone Cloudflare serves DNS for and a name the account owns are different objects, so both browse from Resources. Its capability declares the read scope only — `registrar-domains.admin` stays in `coreWriteOperations` and in `writeScopes(for: .registrarDomain)` because only the per-domain screen mutates, and a feature write scope would hang `FeatureReadOnlyBanner` over an index with no controls (`RegistrarAccess` explains the `.admin` spelling). `RegistrarDomainsView` sets no `detailHeader` of its own; `FeatureRouterContent` owns it, as for every feature-routed list. There is no `Destination.registrarDomains` — the index is `.feature(.registrar)` (`dash://feature/registrar`), while `.registrarDomain` / `dash://registrar/<domain>` still push one registration. Status codes go through `rdapStatusLabel`, which matches `RegistryStatusVocabulary` on a code's **letters alone**: the same EPP status arrives spaced from RDAP, camelCase from the WHOIS backstop, and lowercased-run-together from the Registrar API, and a shape-only splitter cannot break that third form — it shipped `Clienttransferprohibited`, a key no catalog can hold, so the row stayed English on a Chinese screen. Never re-derive a status label from its shape; add the code to the table.
- `FeatureDataCache` is an in-memory, session-scoped cache keyed by `FeatureCacheKey` strings. Views read the cache in `.task` and bypass it from `refreshable` with `force: true`.
- Loading contract (`DashListPhase` via `DashFeatureList`): **Cold** (no cached primary payload) → `DashListSkeleton` only — never an empty shell plus “Updating…”. **Warm** (content already shown) → keep content and the inline “Updating…” strip. **Empty settled** → `DashEmptyState` inside content. Secondary fetches inside a loaded detail (build log, traffic, preview) may use a local ring + short copy (section cold). Do not invent a fifth full-screen spinner.
- Read-only label/value blocks on pushed screens are `DashInfoGroup` + `DashInfoRow` (`DashSurfaces.swift`) — the same two-tone frame as Home's Shortcuts and Recently used, title on the header band, rows in the card below. Do not hand-roll another `DashCard` with a `footnoteSemibold` heading inside it. A group that fetches on its own carries a `DashSectionPhase`: **loading** paints placeholder rows the arriving values land on (a section that pops in later is a layout shift, not a load), **content** shows the rows, **failed** veils the message and a Try again over those same placeholders (`DashSectionFailureVeil` — the section-scale `dashColdFailure`, compact because that one's 72pt mark is sized for a screenful of skeleton). Empty and failed are different answers: a lookup that legitimately returns nothing may drop its section, a lookup that threw never may — conflating them in one optional is how the zone registration card failed silently. Info groups are bounded; like `DashListGroup` they own an eager stack, so never put an unbounded `ForEach` in one.
- Two frames, one rule, so a titled block of section content has exactly one right answer: **a chart or a metric is a `DashGlassCard` with its own `footnoteSemibold` heading inside; read-only label/value fields are a `DashInfoGroup`** on the two-tone band. Charts never move onto the band — Watchtower's reorderable metric cards could not follow, so the analytics screens would end up split across two frames. Pages build outcomes, DNS record types, and the WAF summary + country globe were `DashCard` outliers and are now glass with the rest.
- Switches and setting menus are optimistic: flip the control immediately, disable while the request is in flight, and revert + surface an error on failure. Never replace a `DashSwitch` / menu value with a loading ring — trailing rings stay on submit pills (Connect, Save, Delete, Load more, Purge) and long-running R2 upload cards.
- Workers Builds (`WorkerBuildsSection` + `WorkerBuildActivityController`) live under `/accounts/{id}/builds/…`, not `/workers/…`, and key on the script's immutable **tag** (`external_script_id`), never its name — `WorkerScript.tag` carries it and the detail screen resolves it from the cached workers list. Cloudflare documents no enum for `status`, so `WorkerBuild.phase` reads the lifecycle from the timestamps and treats anything not positively recognised as in-flight as finished: a Live Activity that fails to start is a missing nicety, one pinned to the Lock Screen by an unknown status is a bug only a force-quit clears. A finished build with no `build_outcome` is `.unknown`, never `.success`. The section renders **nothing** when there are no builds or the endpoint 403/404s — most Workers ship via `wrangler deploy` and are not repo-connected, so an empty card would be permanent furniture. The activity carries a `staleDate` rather than a `BGAppRefresh` task (Pages has one; Workers does not), and no push token: Cloudflare publishes build notifications through Queue Event Subscriptions, not notification policies, so the APNs relay cannot carry them and polling is the only signal. There is no "Build now" — the trigger endpoint's response shape is undocumented, so a Worker build activity only ever starts by discovery on visit.
- Worker detail shows the full deployment history from the typed deployments endpoint (active deployment badged; any older deployment can take 100% of traffic via a confirmed cut-over — gradual splits are unsupported on purpose), custom domain attach/detach, plus cached analytics and `workers.dev` controls. R2 uploads are capped at 100 MB (`R2Media.transferSizeLimit`), stay off the main actor while reading, and expose in-view progress, cancellation, and completion feedback.
- The R2 browser (`StorageViews.swift` + `R2ObjectViews.swift`) is a small file manager: image rows show downsampled thumbnails (`R2ThumbnailStore` actor on `AppModel`, session-scoped like the feature cache) while non-image rows show a Hugeicons "02" file-format glyph keyed off the extension (`FileTypeIcons.swift`, generated by `generate-file-icons.mjs`). Tapping an object opens a full-screen preview (`R2ObjectPreview.swift`): the object is downloaded to a temp file and handed to a native `QLPreviewController` inside a `UINavigationController` (system chrome kept — Done + share; Dash only adds ⋯). Objects over the 100 MB transfer ceiling fall back to their glyph. The ⋯ button opens the actions sheet — Copy public URL, Download, and delete. Multi-select batch delete stays on the bucket screen. OAuth REST provides no server-side object copy, so Dash does not offer Rename or Move. The Files mount follows the same boundary: its item capabilities omit rename/reparent/delete, and its extension callbacks reject structural changes while still permitting new uploads and same-key content writes. Bucket settings (`Destination.r2BucketSettings`) manage the r2.dev toggle, custom domains, and empty-bucket delete (Cancel + hold Delete — no type-to-confirm); the resulting `R2DomainsSnapshot` is cached per bucket and decides the copyable URL (serving custom domain beats rate-limited r2.dev). KV namespaces support list / create·edit·delete keys in-app (namespace create stays on the dashboard/Wrangler). Tapping a key pushes `Destination.kvKey` (`KVKeyDetailView`) — view-first `CodeEditor` (JSON) with Copy, then Edit → Format / Save; delete confirms in-page and pops. Create key stays a tray on the namespace screen.
- The DashShare share extension (`apps/ios/DashShare`, bundle `sh.xat.dash.app.share`) uploads shared images to the last-used bucket/prefix and copies the public URL. It reuses `KeychainTokenStore` through the shared keychain access group and reads `R2ShareDestination` records plus the mirrored active-account id from App Group defaults (`group.sh.xat.dash.app`) — `AppModel` keeps that mirror in sync. `UploadToR2Intent` does the same from Shortcuts inside the app process.
- Shared chrome (cards, trays/sheets, pill buttons, catalog toolbar) lives in `DashChrome.swift`; all palette, typography, and spacing tokens in `DashTheme.swift`.
- `Localizable.xcstrings` is a Resources member of **all five** bundles (Dash, DashWidgets, DashShare, DashNotificationService, DashFileProvider). It used to be app-only, so extensions and the Live Activity resolved their `Text` literals against a bundle with no catalog and shipped English no matter the language setting.
- `StatusBadge` takes a `StatusToken` (`DashSurfaces.swift`), never a `String`. Shape, tone, and catalog key all come from exhaustive switches on the token, so a new status cannot compile without naming all three and no string transform can land between the style decision and the localized label. It used to sniff an English word list out of the text and localize `text.capitalized` separately — which is how `"Read-only".capitalized == "Read-Only"` (not a catalog key) kept every read-only badge English on a Chinese screen, and how Cloudflare's `failure` missed `["error", "failed", …]` and drew an info capsule beside a red row icon. Pages outcomes deliberately reuse the build-outcomes legend's keys so badge and chart never disagree. Never re-derive a badge's appearance from its wording.
- Feature-screen spacing is semantic, not page-specific: summary/status cards come before resource rows and settings; bounded groups of independent cards or controls use `DashSurfaceStack` (`itemGap`); conditional feedback beside a control uses `dashItemBoundary`; every following titled group uses `dashSectionBoundary`. Keep `DashFeatureList`'s outer stack at zero spacing so large row `ForEach` collections stay lazy. `DashListGroup` owns an eager `VStack`; never put an unbounded `ForEach` inside it — emit the header and `dashListCardRows` directly into the outer lazy stack. Never compensate with ad-hoc per-page padding.
- Watchtower is Cloudflare's own signal, not Dash's opinion. There is **no Diagnostics section**: Dash used to fold zones, tunnels, Load Balancing pools, registrar, Pages, edge certificates and Health Checks into a client-side ok/warning/critical verdict, but Cloudflare publishes no account-wide diagnostics to base that on — the thresholds (a certificate 20 days from an automatic renewal, a pool the user disabled on purpose) were Dash's invention and raised alarms Cloudflare never did. Do not reintroduce a computed health verdict, and do not add a scope for an endpoint no screen calls. The tab is Charts plus a floated inbox. Charts: the section header carries a Solar mark, the relative fetch time as a `DashMetaBadge` seated after the title, and a pen that opens the layout editor — no freshness card, no freshness line under the title, no Refresh button, and no inline refresh ring, because pull-to-refresh owns reloading and its spinner is the only warm-refresh progress the screen shows (until the first snapshot lands the badge is simply absent, not "Updating…" — the skeleton already says that); a fresh install gets expanded Web Traffic over collapsed CPU Time / Worker Invocations / Cache Rate / Client Request Errors (`WatchtowerAnalyticsCardLayout.defaultLayout`; any saved layout wins, including a pre-editor one), and the cold state paints that saved shape as skeleton cards instead of one spinner panel. `WatchtowerAlertsLoader` fetches one thing — `listNotificationHistory` — and `Destination.watchtowerInbox` splits it into Unread / History / Ignored; Cloudflare exposes no read state, so the first fetched page becomes the local baseline and later deliveries are unread on this iPhone. Ignore is local and reversible (long-press the Watchtower tab, long-press the floating inbox, or tap Ignore all). The tab red dot, the floating badge, the home-screen widget, and local notifications all count exactly one thing: unread Cloudflare deliveries, minus locally ignored ones.
- Home is a launcher: a plain greeting header (`HomeGreetingHeader`) sitting in the shared workspace wash (see the root header invariant above — the glow is no longer Home's, and Home no longer probes its own scroll to translate it), an editable three-slot Quick actions cluster (backed by `dash.home_actions`; fresh-install defaults are Purge Cache / Under Attack / Upload R2, while an existing saved selection is preserved; titleless header with Edit only; Quick-actions edit tray uses `.large` with `DashSheetCard`-matching body insets; Shortcuts edit stays `.content`; both share the selection-list chrome; every choice starts a concrete operation instead of opening a feature catalog), a collapsed-by-default Domains group (deterministic on-device dither avatars from the local `GradientAvatars` package, up to 6 with +N overflow; expanding morphs them into the zone rows with a 6-row viewport that scrolls for the rest; empty unlocked state offers Add domain in-section), an editable Shortcuts group (backed by `dash.home_shortcuts` in `@AppStorage`; defaults are Domains / Workers / Pages / R2; the Edit action opens the `EditShortcutsView` tray listing every catalog feature), and a Recently used group fed by `RecentResources` (JSON in `@AppStorage`, recorded by zone/worker/Pages/R2/KV screens, filtered per account). After current-account R2 use, Home may show one dismissible, account-scoped Share Extension education card; it never appears in Demo. Recently-used rows claim no matched geometry — the Domains expand morph owns the zone identities on Home, and a second source for the same id makes the animations fight. Watchtower stays on its own tab. Zone pinning remains on zone detail.
- Settings lists Siri & Shortcuts discoverability (Purge Cache, Under Attack, Development Mode, Upload to R2, Open Watchtower). Settings → About (`Destination.about`, `AboutView` in `AppRootView.swift`) shows the app icon over the app name, tagline, and version. There is no mascot: Kumo and its RealityKit machinery were removed; sign-in hands off to Home with a plain cross-fade. Zone settings note that removing a domain is not available in Dash.
- Demo: `DemoBackend` serves a read-only world via “Explore the demo” (~60 zones plus bulk workers/Pages/R2/KV for scroll and pagination stress). Demo grants only the initial read scopes, keeps mutation controls locked in the UI, and turns their authorization CTA into **Connect your account**; the backend remains the final write rejection boundary. Watchtower traffic and health paint from session cache on warm tab re-entry; pull-to-refresh still forces a network (or demo) reload.

### Auth flow

- `AppModel.signIn()` builds a PKCE authorize URL and opens `ASWebAuthenticationSession`; Cloudflare redirects to the relay's HTTPS callback, which 302s to `dash://oauth/callback`; the app exchanges the code and stores tokens through `KeychainTokenStore` (an actor implementing the package's `TokenStore` protocol).
- Fresh real-account sign-in requests `DashAuthorizationScopes.core`, the audited union of every permission used by current features, in one consent flow. Existing narrower or unknown grants are upgraded to `core` the next time an access action opens OAuth. `initialReadOnly` remains the Demo profile; lower-layer write checks still enforce mutations.
- Configuration plumbing: `Config/Base.xcconfig` `#include?`s the ignored `Signing.xcconfig` and `Secrets.xcconfig`; `DASH_CLIENT_ID`/`DASH_REDIRECT_URI` flow into Info.plist keys read by `AppConfiguration.current`. Unexpanded `$(...)` values mean unconfigured, which disables sign-in with a hint instead of crashing.

### Tests

- `DashTests` uses Swift Testing (`@Test`); `DashUITests` uses XCTest. `CloudflareAPITests` uses Swift Testing with a `URLProtocol` mock session — no live network calls.

## Swift conventions

- Use Swift 6 strict concurrency, `async throws`, actors for shared mutable state, and `@Observable @MainActor` for UI state.
- Prefer SwiftUI system navigation, lists, searchable, refreshable, sheets, semantic colors, SF Symbols, and Dynamic Type.
- Phone-first: do not add iPad adaptive layouts, regular-width split navigation, or size-class layout forks (see Product scope above).
- The shared palette is defined in `DashTheme`; do not scatter literal colors through feature views.
- Press feedback: the 0.97 shrink (`DashPressButtonStyle`) is reserved for genuine **button** controls — pills, circular icon buttons, toolbar/back/close actions, small text actions (Cancel, Back, Save, Show more…), and tab labels. Tappable **surfaces** — full-width rows, list items, cards, and tiles — must NOT shrink: give them `DashSurfaceButtonStyle` (no scale, no press animation). `DestinationLink`/`DashListGroupLink` navigation rows already use the surface style. When a tap target reads as a row/card/tile, it is a surface, not a button. Sanctioned exception: the Home Quick-actions tool tiles (`DashToolTile`) are launcher buttons and take `DashPressButtonStyle` — the shrink plus haptic is their press cue, and the tap still opens the action's tray.
- Held gestures: any surface that reads a finger continuously — every chart (`DitherHoldInteraction`) and the globe (`GlobeHoldInteraction`) — arms on a 0.35s hold inside 10pt, announces it with `DashDelight.gestureEngaged()`, and then owns the touch until it lifts: on arming it switches off every ancestor pan/swipe recognizer (list scroll, tab pager, interactive pop) and restores them on release, teardown included. Both packages carry the same two constants and the same claim rule; change one and change the other. Do NOT give such a surface a `DragGesture(minimumDistance: 0)` or an immediately-recognizing pan — that reads the finger before the user has committed and fights all three page gestures at once. A plain tap still lands immediately; only the continuous read waits for the hold.
- App code depends on `CloudflareAPI`, never on JavaScript packages or `packages/ui`.
- Tokens belong in the Keychain. Local OAuth values belong in ignored `Config/Secrets.xcconfig`; never commit credentials.
- Preserve graceful 403 handling. A missing OAuth scope must affect only its feature and should surface an actionable error.
- Use the exact Cloudflare OAuth scope IDs in `CloudflareScopes`. Write scopes usually end in `.write`; Registrar's is `registrar-domains.admin`, and `registrar-domains.write` does not exist. Verify every id against `OAuthScopeCatalog.json` — `sanitized()` drops unknowns silently. Workers permissions remain fine-grained.
- Lists should stay lazy or use `List`; avoid loading unbounded object/key collections into a non-virtualized stack.

## Cloudflare API package

- Keep `packages/cloudflare-api` dependency-free and Foundation-based.
- New endpoints go through `CloudflareClient` so they inherit Bearer auth, single-flight refresh, and one retry after 401.
- Public response types are `Codable` and `Sendable`; public operations use `async throws`.
- Binary endpoints use `Data` or file URLs. Do not decode unbounded bodies as text unless the endpoint is known to be bounded.

## Edge app (landing + OAuth + push)

Cloudflare accepts only HTTP(S) redirect URIs. The registered HTTPS callback is
served by worker `dash-relay` at `https://dash.xat.sh` (`apps/web`): a Vite React
landing SPA plus a Hono Worker that redirects OAuth to `dash://oauth/callback`
and bridges Cloudflare alert webhooks to APNs under `/push/*`.

Route ownership:

- `GET /` and SPA navigations → Workers Assets (landing)
- `GET /health` → liveness probe
- `GET /oauth/callback` → 302 to `dash://oauth/callback` (worker-first)
- `GET /api/registration/:domain` → RDAP then port-43 WHOIS snapshot for the
  iOS zone registration card (Cache API only; worker-first)
- `/push/*` → APNs bridge (worker-first): registration proves possession of the
  APNs token through a silent-push challenge before returning an opaque notify
  capability; notify forwards mapped alerts (including `dashRoute` deep links)
  to APNs

Settings → Push alerts enables the client path: APNs entitlement, device token
registration, Cloudflare webhook + policies, and optional test alert. Pages
build Live Activities poll every 10s in the foreground and continue via
best-effort `BGAppRefresh` (`sh.xat.dash.app.pages-build-refresh`) while a
build is in progress; they still request an ActivityKit push token, but the
relay does not send Live Activity pushes (zero-storage invariant). A Live
Activity is raised two ways and only two: the deployment screen's initial
refresh finds a build already running (the only way to catch one started on the
web), or `retry()` hands the returned deployment straight to
`PagesBuildActivityController.adopt` so a build started *in* Dash does not wait
to be rediscovered. Push-to-start is deliberately not used.

`mapAlert` derives severity, grouping, and actions from `alert_type` and the
structured `data` only — **never** from the wording of `text`. Cloudflare
rewrites that string without notice, and the extension could not localize what
the relay had already branched on (same rule as `StatusBadge`). It emits
`interruption-level` (time-sensitive only for outage-shaped types, `passive` for
digests), `relevance-score`, a per-resource `thread-id`, and an `aps.category` —
but a category only when its actions have a target, since the zone actions need
a zone id. Category raw values are a wire contract with
`DashNotificationCategory`; every action is `.foreground` and retargets the
notification's own route (`dash://zone/<id>` → `…/cache`), so a Lock Screen
button can never perform an unconfirmed write and the `?account=` scope always
survives. After a successful alert the relay fires one silent
`content-available` push (via `waitUntil`, so Cloudflare's webhook delivery is
not held open); the app answers it with `performPushTriggeredRefresh`, which
forces a Watchtower reload with `notifiesLocally: false` — the baseline still
advances, but the local diff stays quiet or every alert arrives twice.

`DashNotificationService` (bundle `sh.xat.dash.app.notification-service`) is the
only place that can localize an alert: the relay has no catalog and no idea what
language the phone is set to, and Cloudflare's `text` is always English. It maps
`dashAlertType` → localized copy through `AlertLocalization`, leaves unknown
types untouched, and does not write the SpringBoard badge. `DashApp` wires
`PushDelegate.inbox` during app construction, before any scene appears, because
a silent background launch may never mount a root view. The visible APNs fallback is
generic; original Cloudflare copy is restored only after the extension confirms
that `dashAccountID` is still authorized on this device, so a skipped extension
cannot leak a signed-out account's resource name. Because an extension's
`UserDefaults.standard` is its own suite, `DashApp` mirrors the in-app language
choice into App Group defaults — without that mirror the extension only ever
sees the system language. `Localizable.xcstrings` is a Resources member here
too, for the same reason it is in DashWidgets and DashShare.

The app is the sole owner of the SpringBoard badge. Every Watchtower refresh,
read, ignore, account switch, and sign-out funnels through the app-owned unread
count and `setBadgeCount`; the Notification Service Extension must not infer
`snapshot + 1`, because visible and silent pushes may arrive in either order or
belong to different accounts.

Per-domain alert subscriptions (`ZoneAlertsSection`, on zone settings) are
notification policy **filters**, not one policy per domain: Dash keeps one policy
per alert type and moves zone ids in and out of `filters["zones"]`, because the
policy list is shared with the Cloudflare dashboard and has no folders. A managed
policy is one matched by name *and* still bound to this device's webhook. A
policy with no `zones` filter means "every zone" to Cloudflare, so it renders as
read-only `.allDomains` — a per-domain switch there would either silently widen
an account-wide alert or have to invent a list of every other zone.

Domain-expiry reminders (`ExpiryReminders`) are local `UNCalendarNotification`s
at 30/7/1 days, scheduled off the RDAP lookup the zone screen already performs —
no relay call, no stored state, cleared on sign-out. Certificate expiry is
deliberately absent: Cloudflare renews Universal SSL itself and publishes
`universal_ssl_event_type` when that fails, so a local countdown would be the
same invented alarm this app removed from Watchtower.

Invariants that still hold:

- Zero storage (no KV, DO, or D1). Push state lives in the user's own Cloudflare
  account as a webhook destination plus notification policies.
- Never touches Cloudflare credentials, OAuth tokens, or the PKCE verifier.
- Never logs query parameters, device tokens, alert payloads, or notify URLs
  (the URL is a bearer capability). Logs only APNs status codes via
  `wrangler tail`.

The worker holds the APNs `.p8` signing key. `wrangler dev` cannot reach APNs
(HTTP/2).
