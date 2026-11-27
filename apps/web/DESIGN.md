# Dash web design system

## 1. Visual theme and atmosphere

`dash.xat.sh` is an understated editorial monograph for a native iPhone instrument. Pure alabaster paper (`#ffffff`), calm gallery-stone pedestals (`#f4f2ee`), two-tone carbon/stone typography, hairline rules, and one bespoke visual signature: a real 4x4 Bayer ordered-dithered sunrise canvas (`DitheredSunriseCanvas`) behind the hero iPhone that echoes Dash's own `SwiftDitherKit` charts and `DashWorkspaceTopWash`.

No floating pill navbars, no eyebrow dot tags, no Bento grids, no boxed architecture diagrams, and no repeated screenshots. Invent nothing: no user counts, ratings, testimonials, awards, or placeholder App Store links.

## 2. Color palette and roles

- `--color-dash-paper` (`#ffffff`): primary editorial canvas
- `--color-dash-gallery` (`#f4f2ee`): quiet stone pedestals behind real iPhone captures
- `--color-dash-ink` (`#0f0f0e`): primary display and body ink, primary CTA fill
- `--color-dash-muted` (`#575550`): body prose (WCAG AA compliant on `#ffffff` and `#f4f2ee`)
- `--color-dash-faint` (`#8c8982`): editorial counterpoint ink, indices, and secondary captions
- `--color-dash-accent` (`#f38020`) / `--color-dash-accent-deep` (`#c45400`): reserved for the dithered sunrise halftone field and keyboard focus rings

The site is light-only, deliberately.

## 3. Typography rules

- Optical `Inter` (falling back to Apple `-apple-system` / `SF Pro Text`) paired with `JetBrains Mono` / `SF Mono` for real hosts (`api.cloudflare.com`, `dash.xat.sh`), schemes (`dash://oauth/callback`), and gallery indices (`01`, `02`, `03`).
- Display headings use `font-medium` (500 weight, never heavy 700), tight tracking (`-0.038em` to `-0.045em`), and a two-tone ink contrast (`#0f0f0e` statement + `#8c8982` counterpoint).
- No em dashes or en dashes in visible copy. Use periods, commas, colons, interpuncts, or plain hyphens.

## 4. Layout and pacing

- **Header**: unboxed 80px architectural bar with the 24px Dash icon + wordmark on the left and quiet text navigation (`Surfaces`, `Architecture`, `Privacy`, `中文` / `EN` locale toggle, `GitHub ↗`) on the right.
- **i18n**: lightweight zero-dependency English and Simplified Chinese (`en` / `zh`) support in `i18n.ts` — auto-detects `navigator.languages`, supports `?lang=zh` / `?lang=en` overrides, persists manual switches in `localStorage`, and updates `<html lang>` and `<title>`. Legal markdown in `@dash/legal` remains English-only with a quiet note on Chinese views.
- **Hero**: asymmetric 7/5 baseline-aligned editorial masthead (including a quiet `By Xat` link to `xat.sh`) above a full-width stone gallery stage (`rounded-[28px]`) housing the procedural Bayer dithered sunrise, one upright uncropped iPhone 16 Pro (`watchtower.webp`), and two desktop hairline callouts.
- **Surfaces**: 3-column museum gallery displaying the remaining three real captures (`zone.webp`, `pages.webp`, `r2.webp`) once each, completely uncropped, with bare numbered editorial copy underneath.
- **Architecture & Privacy**: Swiss hairline specification ledger (`<dl>` with 1px horizontal rules) detailing Direct API, Stateless Relay, Ephemeral Data, and Native iOS Integration.
- **Footer**: matching gallery-stone monolith (`rounded-[28px]`, `bg-dash-gallery`) that bookends the hero stage — quiet brand & `By Xat` attribution on the left, three minimal link columns (`Product`, `Legal`, `Elsewhere`) on the right, and a full-bleed `DitheredWordmarkCanvas` rendering a monumental Bayer-halftone `Dash` wordmark dissolving into a warm bottom sunrise horizon.
- **Legal pages (`/privacy`, `/terms`)**: two-column editorial layout directly on pure alabaster paper, rendered from `@dash/legal`, with per-route `<title>`, `<meta name="description">`, and `<link rel="canonical">` updates.
- **SEO & discoverability**: `index.html` ships JSON-LD `@graph` (`Person`, `WebSite`, `SoftwareApplication`), LCP preload for the hero capture, `twitter:creator`, `<noscript>` fallback, and static `robots.txt`, `sitemap.xml`, and `llms.txt` in `public/`.

## 5. Depth and motion

- Device captures keep `app-shot-shadow` / `app-shot-shadow-soft` on an outer wrapper separate from `app-shot-screen-clip` so Chromium masking never leaks square corners.
- Above-the-fold masthead copy settles via translate-only `Stagger` (`on="load"`). Below-the-fold sections render immediately at `opacity: 1` with no scroll-gated fade traps.
- The Bayer dithered canvas breathes gently at a low 15fps cadence and freezes statically under `prefers-reduced-motion`.
