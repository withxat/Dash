# Dash web design system

## 1. Visual theme and atmosphere

Dash uses Cloudflare Kumo as the web design system and the native iPhone app as the visual subject. The landing page is a single quiet stage: short claim, one call to action, and one multi-device composition of real captures. It is not a scroll-through feature brochure.

The page never talks about itself. No copy about screenshots being unfinished, no notes on what will be published later, no commentary on the page's own construction.

Invent nothing. No metrics, user counts, testimonials, customer logos, awards, or time-saved claims. No pricing copy and no implied paid tier, because none exists.

## 2. Color palette and roles

Use Kumo semantic tokens for surfaces, text, status, and controls. Black and white alpha values are reserved for shadows and image outlines.

- `kumo-canvas`: page canvas (legal pages, footer surround)
- `kumo-base`: navigation and the landing field
- `kumo-brand`: primary actions
- `kumo-default`, `kumo-strong`, `kumo-subtle`, `kumo-inverse`: text hierarchy

Two contrast traps:

- `kumo-subtle` clears WCAG AA on `kumo-base` (4.74:1) but **fails on `kumo-recessed`** (4.27:1). Body copy on a recessed surface takes `kumo-default`.
- `kumo-inactive` is the **disabled-control** token, not a text token. Never use it for fine print.

The page is light only, deliberately. Dark mode is a project, not a one-line change.

## 3. Typography rules

- Use Kumo's font stack.
- Body content, buttons, and data use 14px or 16px.
- Display headings use `font-semibold`, sentence case, and balanced wrapping.
- Use `-0.04em` tracking for the hero.
- Descriptions use pretty wrapping and stay near 65 characters per line.
- No em dashes or en dashes anywhere in visible copy. Use a period, a comma, a colon, or a plain hyphen.

## 4. Component styling

- Use `LinkButton` for the primary call to action and `Link` for footer navigation.
- Use `Badge` once for compact product metadata.
- Calls to action use an interruptible `scale(0.96)` press state over 150ms.
- Use the official Dash App icon for the favicon and the header lockup.
- `AppScreenshot` owns screenshot geometry: real 1206x2622 WebP under the licensed iPhone 16 Pro bezel in `public/device-frames/`. The capture is masked to the screen cutout corner radius. Never reconstruct the app UI in HTML.
- `DeviceCluster` is the only product visual on the landing page: three framed captures. Behind their lower half sits one rounded rectangle running a slow umbrella gradient. Compact: upright row with horizontal scroll. `sm+`: fanned angles. One composition, not a gallery of separate sections.
- One call-to-action label per intent across the whole site.

## 5. Layout principles

- Maximum content width is `max-w-7xl`.
- Page gutters are 20px on compact screens and 32px from the small breakpoint.
- **The landing page is one section.** Badge, headline, one paragraph, one CTA, then the device cluster. No Features / Security / OS surfaces / relay grids / second CTA band.
- Header is brand + GitHub only. No in-page section nav.
- The hero carries at most four text elements: one badge, the headline, one paragraph, and the action row.
- The landing field is flat `kumo-base`. Color lives only inside the rounded stage behind the phones, not as a full-bleed band.
- **No section numbering**, no capability cards, no sticky product tour.

## 6. Depth and elevation

- Depth comes from the device drop shadows, phone stacking order (center in front), and the rounded gradient stage behind the lower half of the cluster.
- The stage gradient is slow and ambient. Respect `prefers-reduced-motion` by freezing it.
- Drop shadow lives on `app-shot-shadow`, never on the same box as the screen clip (filter breaks overflow clipping in Chromium).
- Use borders only for header and footer hairlines.

## 7. Motion

Motion lives in `motion-primitives.tsx` and uses Motion (`motion/react`). One easing curve, `cubic-bezier(0.16, 1, 0.3, 1)`, and one duration, 0.62s.

- The landing hero uses `Stagger` / `StaggerItem` with `on="load"` for the claim only.
- Above-the-fold entrances are **translate only, never opacity**, so LCP is not delayed by a transparent headline.
- The phones are static. No perpetual float, no 3D tilt, no hover transform. Angles are fixed CSS rotates. Motion is reserved for the umbrella gradient inside the stage.
- Everything degrades through `useReducedMotion()` and the CSS `prefers-reduced-motion` block.

`Reveal`, `Parallax`, and `StickyTour` remain available in `motion-primitives.tsx` for other surfaces, but the landing page does not use them.

## 8. Do and do not

- Do make real iPhone captures the strongest visual anchor.
- Do keep the page short enough that the product is understood without scrolling through copy.
- Do use Kumo semantic tokens for every interface color role.
- Do preserve visible keyboard focus and 44px touch targets.
- Do not rebuild or approximate the iOS interface in React.
- Do not reintroduce multi-section marketing tours, sticky scroll pin demos, or feature card grids.
- Do not introduce decorative glass, bounce easing, or a second type system. The umbrella gradient is allowed only inside the device-cluster stage, never as a page wash.
- Do not round the primary section containers. The iPhone frame is the only large rounded object.

## 9. Capturing screenshots

The published captures are 1206x2622 WebP in `public/screens/`, referenced with a `?v=` suffix. Use `sharp(src).webp({ quality: 85, effort: 6 })`.

The device bezel is a separate transparent SVG (CC BY-SA 4.0; see `THIRD_PARTY_NOTICES.md`). Do not flatten the frame into every WebP.

Landing ships three captures in the cluster: zone detail, Watchtower, and Pages. R2 remains available as a spare capture for swaps.

**Demo mode note for new captures:** prefer drill-down screens without the root `Read-only` chrome. Avoid bulk filler names and joke corporations.

## 10. Shared-link preview

`public/og.png` is generated by `node apps/web/scripts/generate-og-image.mjs`. Regenerate when the hero claim or the zone capture changes, and bump the `?v=` on the meta tags in `index.html`.

## 11. Responsive behavior

- Header keeps brand + GitHub at every width.
- The claim stacks above the cluster on all widths.
- Below `sm`, the cluster is three upright phones in a horizontal scroll track (no fan). From `sm` up, the fanned composition returns.
- Every action keeps a minimum 44px hit area.
- Desktop and 375px are required browser checks; confirm `documentElement.scrollWidth` never exceeds `clientWidth`.

## 12. Agent prompt guide

- "Rebuild the landing page as one section: badge, headline, one paragraph, one GitHub CTA, and a three-phone device cluster on a contrast stage."
- "Add or swap an `AppScreenshot` in `DeviceCluster` using the licensed bezel and a real 1206x2622 WebP."
- "Do not add new landing sections without an explicit request to expand beyond the single-stage page."
- "Review at full width and 375px: screenshot geometry, clip radius, focus, horizontal overflow, contrast."
