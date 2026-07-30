# Dash web design system

## 1. Visual theme and atmosphere

Dash uses Cloudflare Kumo as the web design system and the native iPhone app as the visual subject. The page is quiet, direct, and product-led. Real device captures are the primary visual anchor; never reconstruct the iOS interface in HTML for marketing imagery.

The page never talks about itself. No copy about screenshots being unfinished, no notes on what will be published later, no commentary on the page's own construction.

Invent nothing. No metrics, user counts, testimonials, customer logos, awards, or time-saved claims. No pricing copy and no implied paid tier, because none exists. The material that survives a cynical developer's read is the same material every time: things deliberately not built, limits stated plainly, and a demo that lets them check the claims themselves.

## 2. Color palette and roles

Use Kumo semantic tokens for surfaces, text, status, and controls. Black and white alpha values are reserved for shadows and image outlines.

- `kumo-canvas`: long-form page canvas
- `kumo-base`: navigation and primary content surface
- `kumo-recessed`: grouped icon wells and tinted panels
- `kumo-contrast`: the product stage and the relay section
- `kumo-brand`: primary actions and active product emphasis
- `kumo-info`, `kumo-success`, `kumo-warning`, `kumo-danger`: semantic status only
- `kumo-default`, `kumo-strong`, `kumo-subtle`, `kumo-inverse`: text hierarchy

Two contrast traps, both measured on this page:

- `kumo-subtle` clears WCAG AA on `kumo-base` (4.74:1) but **fails on `kumo-recessed`** (4.27:1). Body copy on a recessed surface takes `kumo-default`.
- `kumo-inactive` is the **disabled-control** token, not a text token. As body copy on `kumo-base` it measures **1.48:1**. Never use it for fine print. Fine print is still text and takes `kumo-subtle`.

Re-measure contrast whenever a text token moves onto a new surface. Resolve `oklch()` through a canvas pixel before computing a ratio; parsing the numbers out of the string gives nonsense.

The page is light only, deliberately. Kumo's tokens are `light-dark()` pairs, but the switch is Kumo's own `[data-mode="dark"]` attribute rather than `prefers-color-scheme`, and its `:root { color-scheme: light }` outranks anything set in `@layer base`. Enabling dark mode also inverts every `kumo-contrast` band from near-black to near-white, which recomposes the page rather than recoloring it. Dark mode is a project, not a one-line change.

## 3. Typography rules

- Use Kumo's font stack.
- Body content, buttons, navigation, and data use 14px or 16px.
- Display headings use `font-semibold`, sentence case, and balanced wrapping.
- Use `-0.04em` tracking for the hero and `-0.025em` for headings from 32px upward.
- Use `-0.012em` tracking for 20px to 28px display text.
- Inline emphasis uses `font-medium`; never use `font-bold`.
- Descriptions use pretty wrapping and stay near 65 characters per line.
- Dynamic or aligned numbers use tabular numerals.
- No em dashes or en dashes anywhere in visible copy. Use a period, a comma, a colon, or a plain hyphen.
- Vary heading rhythm. A run of headings built as short declarative fragments is a voice tic, and it is the most recognisable generated cadence there is.

## 4. Component styling

- Use `LinkButton` for primary calls to action and `Link` for lower-emphasis navigation.
- Use `Badge` for compact product metadata. A given badge text appears **once** per page.
- Calls to action use an interruptible `scale(0.96)` press state over 150ms.
- Use the same Solar SVG assets generated for the iOS app. Do not reach for a near-miss glyph to fill a slot; a section with no honest icon gets no icon.
- Use the official Dash App icon for the favicon and every brand lockup.
- `AppScreenshot` owns screenshot geometry. It places the exact 1206x2622 capture below the licensed iPhone 16 Pro bezel in `public/device-frames/`; the capture is clipped to the screen cutout's corner radius before the bezel paints over it. The bezel owns the titanium shell, black screen border, Dynamic Island, and side controls. It never draws or reconstructs the app interface.
- The sticky header brand mark is absent while the landing hero (which already shows the app icon) is on screen, and slides in from the left once the hero has left. Pages without a hero keep the mark visible.
- One call-to-action label per intent across the whole page, navigation included.

## 5. Layout principles

- Maximum content width is `max-w-7xl`.
- Page gutters are 20px on compact screens and 32px from the small breakpoint.
- The hero carries at most four text elements: one badge, the headline, one paragraph, and the action row. No trailing micro-copy under the buttons.
- The product stage is a square-edged, full-width `kumo-contrast` field, not a rounded supporting card.
- **Every section uses a different layout family.** As shipped: asymmetric hero split, centered full-bleed stage, sticky product tour, offset label-and-text list, dark item grid, and the closing two-column action band.
- **No section numbering.** No `01 / Capabilities` markers, no numbered capability index, no numbered principles. A section's position on the page is its label.
- Keep eyebrows to at most one per three sections. As shipped the page has exactly one, the hero badge.
- Do not put a large headline on the left and a small explanatory paragraph on the right as a section header. Stack them, or give the second column real content.
- Every section has one job: act, verify, undo, reach, trust, or convert.

## 6. Depth and elevation

- Establish depth through `canvas`, `base`, `contrast`, and `elevated` surface steps.
- Use a silhouette-aware drop shadow on the device composite and Kumo's native treatment for controls.
- Use borders only for dividers and section boundaries.
- Never combine a visible border and a decorative drop shadow on the same surface.
- Hairlines inside a `kumo-contrast` band use the `rule-on-contrast` utility, which rides `currentColor`. `kumo-inverse` exists only as a text color, so a border token cannot be used there, and a hardcoded white alpha would be wrong if the band is ever repainted.

## 7. Motion

Motion lives in `motion-primitives.tsx` and uses Motion (`motion/react`). One easing curve, `cubic-bezier(0.16, 1, 0.3, 1)`, and one duration, 0.62s, for the whole site.

- `Stagger` / `StaggerItem` sequence a group so it reads in the order it should be understood. `on="load"` above the fold, `on="view"` below it.
- Above-the-fold entrances are **translate only, never opacity**. An `opacity: 0` hero headline is not painted, so fading it in pushes out Largest Contentful Paint by the length of its own entrance.
- `Reveal` is the single-block version for content with nothing to sequence.
- `Parallax` applies a scroll-linked vertical offset.
- `StickyTour` holds one device still while the surfaces inside it change. The pin is the argument: the product is a single compact app, not a pile of separate screens. It is built on CSS `position: sticky` rather than a scroll-hijacking pin, so it cannot desynchronise from the scrollbar or strand a reader mid-section, and below `lg` it degrades to a plain stacked list with each capture inline.
- The header brand icon is a discrete enter/exit driven by an `IntersectionObserver` on the hero — not a scroll-linked motion value. The icon is out of flow (absolute) so its entrance is x + blur + opacity only; the wordmark is pushed by the same transition on `paddingLeft`, so icon and text move together rather than the text jumping after the icon settles. Never a width stretch of the mark itself.
- Every animation must answer "what does this communicate?" with hierarchy, sequence, or feedback. Decoration is not an answer.
- Scroll values stay on Motion values (`useScroll`, `useTransform`). Never drive continuous scroll or pointer values through React state, and never attach a `scroll` listener.
- Everything degrades through `useReducedMotion()` to a static, fully visible page, backed by the CSS `prefers-reduced-motion` block.

Screenshots get **one** scroll-linked entrance and nothing else. No perpetual float, no rotation, no 3D tilt, no hover transform.

**`useTransform` input ranges must stay inside `[0,1]` and never decrease.** Motion binds the value to a WAAPI animation at mount, and an out-of-range or non-monotonic offset throws `Offsets must be monotonically non-decreasing` during render, which takes down the entire page with an empty `#root` and no error overlay. For a crossfade, give the first and last stops open-ended bands rather than letting them start below 0 or end above 1, and check that the opacities across all layers sum to 1 at every progress value so there is never a blank or double-exposed frame.

## 8. Do and do not

- Do make real iPhone captures the strongest visual anchor.
- Do use Kumo semantic tokens for every interface color role.
- Do let product imagery, whitespace, and surface changes provide the visual hierarchy.
- Do preserve visible keyboard focus and 44px touch targets.
- Do state limits plainly. The 100 MB ceiling, iPhone only, no server-side copy, unread tracked per device, and background refresh being best effort are all trust-building, not weaknesses to hide.
- Do not rebuild or approximate the iOS interface in React.
- Do not introduce decorative gradients, glass effects, or generic feature-card grids.
- Do not introduce a second editorial or terminal-style typography system beside Kumo.
- Do not round the primary section containers. The iPhone frame is the only large rounded object.
- Do not use `transition: all`, bounce, or elastic easing.

## 9. Capturing screenshots

The published captures are 1206x2622, the native iPhone 16 Pro display resolution. They are saved to `public/screens/` and referenced with a `?v=` suffix that is bumped on replacement.

Store them as WebP, not PNG. A raw simulator capture is about 1.7 MB, which is unacceptable for a hero image; `sharp(src).webp({ quality: 85, effort: 6 })` brings it to roughly 40 to 150 KB with the dithered chart fills still crisp. `sharp` is already a workspace dependency.

The device bezel is a separate, transparent SVG so one cached asset serves every capture and the Sticky Tour can keep swapping only real app pixels. Its attribution and CC BY-SA 4.0 terms are recorded in `THIRD_PARTY_NOTICES.md`. Do not flatten the frame into every WebP or replace it with an unlicensed mockup.

**Demo mode is usable, but only below the feature roots.** Demo grants read scopes only, so every feature *root* screen (Resources, Domains, Workers, Pages, R2, KV) carries a pinned `Read-only` warning and a `Connect your account` button. Published as marketing those say the app cannot write, so those screens are unusable. **Drill-down screens carry no such chrome**: a zone detail, an R2 bucket browser, a Pages project, and a KV key editor are all clean. Watchtower is clean at its root because it has no write controls.

Also avoid demo screens whose sample data is bulk filler (`site-01` through `site-08`, `bulk:item-001`) or joke corporations (Initech, Umbrella Corp, Cyberdyne, Tyrell). `example.com` and its siblings are ideal: neutral, reserved, and instantly legible.

The four captures the page ships are the zone detail, Watchtower charts, the Pages project with its build-outcome chart, and an R2 bucket browser.

## 10. Shared-link preview

`public/og.png` is generated, not hand-made: `node apps/web/scripts/generate-og-image.mjs` composites the real zone capture against the hero claim at 1200x630, the size both Open Graph and Twitter `summary_large_image` expect. Regenerate it whenever the hero claim or that capture changes, and bump the `?v=` on the meta tags in `index.html`.

## 11. Responsive behavior

- The primary text navigation hides below the small breakpoint; the GitHub action remains available.
- The hero becomes a vertical claim, supporting copy, App icon, and action sequence on compact screens.
- The sticky tour collapses to a stacked list with each capture inline below its copy.
- Every action keeps a minimum 44px hit area.
- Desktop and 375px are required browser checks for visual changes; confirm `documentElement.scrollWidth` never exceeds `clientWidth`.

## 12. Agent prompt guide

- "Build a quiet Dash hero with Kumo `bg-kumo-base`, a 12-column desktop grid, a `clamp(56px, 7.5vw, 104px)` semibold headline at `-0.04em`, and one supporting column holding the App icon, one paragraph, and the action row."
- "Add a portrait `AppScreenshot` using the licensed iPhone 16 Pro bezel overlay and a real 1206x2622 WebP capture aligned to its exact screen aperture."
- "Add a stop to `StickyTour` with a headline, two short paragraphs, and one capture, and state in one sentence what holding the device still communicates at that stop."
- "Wrap a section in `Stagger` and its children in `StaggerItem` so they enter in reading order."
- "Review the page at full width and 375px, checking screenshot geometry, long labels, focus visibility, horizontal overflow, and text contrast on every surface the token touches."
