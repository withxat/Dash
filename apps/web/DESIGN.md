# Dash web design system

## 1. Visual theme and atmosphere

Dash uses Cloudflare Kumo as the web design system and the native iPhone app as the visual subject. The page is quiet, direct, and product-led. Real App Store captures are the primary visual anchor; never reconstruct the iOS interface in HTML for marketing imagery.

## 2. Color palette and roles

Use Kumo semantic tokens for surfaces, text, status, and controls. Black and white alpha values are reserved for shadows, image outlines, and dividers on `kumo-contrast`.

- `kumo-canvas`: long-form page canvas
- `kumo-base`: navigation and primary content surface
- `kumo-elevated`: iPhone screenshot frame
- `kumo-recessed`: screenshot placeholder and grouped icon background
- `kumo-contrast`: product stage and security section
- `kumo-brand`: primary actions and active product emphasis
- `kumo-info`, `kumo-success`, `kumo-warning`, `kumo-danger`: semantic status only
- `kumo-default`, `kumo-strong`, `kumo-subtle`, `kumo-inverse`: text hierarchy
- `kumo-hairline`, `kumo-line`, `kumo-focus`: separators, rings, and focus states

## 3. Typography rules

- Use Kumo's font stack.
- Body content, buttons, navigation, and data use 14px or 16px.
- Display headings use `font-semibold`, sentence case, and balanced wrapping.
- Use `-0.04em` tracking for the hero and `-0.025em` for headings from 32px upward.
- Use `-0.012em` tracking for 20px to 28px display text.
- Inline emphasis uses `font-medium`; never use `font-bold`.
- Descriptions use pretty wrapping and stay near 65 characters per line.
- Dynamic or aligned numbers use tabular numerals.

## 4. Component styling

- Use `LinkButton` for primary navigation calls to action and `Link` for lower-emphasis navigation.
- Use `Badge` for compact product metadata.
- Calls to action use an interruptible `scale(0.96)` press state over 150ms.
- Use the same Solar SVG assets generated for the iOS app. Content icons may use filled variants; chrome uses outline variants.
- Use the official Dash App icon for the favicon and every brand lockup.
- `AppScreenshot` owns screenshot geometry. When a capture is unavailable, render its labeled placeholder instead of drawing a fake interface.
- Screenshot frames use a 40px outer radius, 32px inner radius, and 8px padding.

## 5. Layout principles

- Maximum content width is `max-w-7xl`.
- Page gutters are 20px on compact screens and 32px from the small breakpoint.
- Use one 12-column desktop grid for every main section.
- The hero pairs one oversized claim with a single supporting column containing the App icon, copy, and action.
- The screenshot stage is a square-edged, full-width `kumo-contrast` field, not a rounded supporting card.
- Feature capabilities form a numbered index with full-width dividers. Do not wrap capabilities in cards.
- Every section uses the same marker, heading scale, gutters, and 80px to 96px vertical rhythm.
- App gallery captures are equal-width, upright, and aligned to the same baseline.
- Every section has one job: introduce, show, explain, establish trust, or convert.

## 6. Depth and elevation

- Establish depth through `canvas`, `base`, `contrast`, and `elevated` surface steps.
- Use layered transparent shadows for screenshot frames and Kumo's native treatment for controls.
- Use borders only for dividers, section boundaries, and placeholder instructions.
- Real screenshot images receive a 1px inset pure-black outline at 10% opacity.
- Never combine a visible border and a decorative drop shadow on the same surface.

## 7. Do and do not

- Do make the real iPhone screenshots the strongest visual anchor.
- Do use Kumo semantic tokens for every interface color role.
- Do use the Kumo font stack for navigation, labels, chapter markers, body copy, and technical facts.
- Do let product imagery, whitespace, and surface changes provide the visual hierarchy.
- Do preserve visible keyboard focus and 44px touch targets.
- Do keep Solar as the only interface icon family.
- Do respect reduced-motion preferences.
- Do not rebuild or approximate the iOS interface in React.
- Do not introduce decorative gradients, glass effects, or generic feature-card grids.
- Do not rotate, float, or animate static screenshots.
- Do not introduce a second editorial or terminal-style typography system beside Kumo.
- Do not round the primary section containers. The iPhone frame is the only large rounded object.
- Do not use invented metrics, fictional screenshots, or placeholder image services.
- Do not use `transition: all`, bounce, or elastic easing.
- Do not animate static navigation icons.

## 8. Responsive behavior

- The primary text navigation hides below the small breakpoint; the GitHub action remains available.
- The hero becomes a vertical claim, supporting copy, App icon, and action sequence on compact screens.
- Product stage copy and replacement guidance stack around the screenshot on compact screens.
- The capability index remains a single readable list at every width.
- App gallery captures stack on compact screens and align in two equal columns from the small breakpoint.
- Every action keeps a minimum 44px hit area.
- Desktop and 375px are required browser checks for visual changes.

## 9. Agent prompt guide

- "Build a quiet Dash hero with Kumo `bg-kumo-base`, a 12-column desktop grid, a `clamp(56px, 7.5vw, 104px)` semibold headline at `-0.04em`, and one supporting column containing the App icon, copy, and primary action."
- "Add a portrait `AppScreenshot` using a 40px outer radius, 32px inner radius, 8px padding, and a real 1179×2556 capture. Use the labeled placeholder if the file is absent."
- "Create a five-item numbered capability index using Solar filled icons, `border-kumo-hairline` dividers, 40px icon wells, and no individual cards."
- "Create an aligned screenshot gallery with two upright `max-w-80` portrait captures, a 32px desktop gap, and no hover transform."
- "Add a Kumo `LinkButton` with an interruptible 150ms `scale(0.96)` press state and no color transition."
- "Review the page at full width and 375px, checking screenshot geometry, long labels, focus visibility, and horizontal overflow."
