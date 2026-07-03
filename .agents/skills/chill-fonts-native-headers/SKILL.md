---
name: chill-fonts-native-headers
description: >-
  Chill Round Gothic static OTF typography for CloudFX mobile — RN Text vs
  UIKit nav-bar rendering, native-stack headerTitleStyle, large-title collapse
  animations, and RCTFont weight pitfalls. Use when header titles look wrong
  weight, SF Pro vs Chill mismatch, font-medium confusion, or tuning tab stack
  headers in apps/mobile.
---

# Chill fonts & native stack headers (CloudFX mobile)

## The three faces (only these exist)

Chill Round Gothic ships as **three static OTFs** embedded via `expo-font` in
`apps/mobile/app.json`. PostScript / asset names:

| Face | File | `chillFonts` key |
| --- | --- | --- |
| Medium | `ChillRoundGothic_Medium.otf` | `medium` |
| Bold | `ChillRoundGothic_Bold.otf` | `bold` |
| Heavy | `ChillRoundGothic_Heavy.otf` | `heavy` |

**Do not** add `Regular` or other weights unless new OTFs are added to the
plugin and `fonts.ts`.

### Tailwind naming trap (`tailwind.config.cjs`)

NativeWind maps **Tailwind class → OTF face**, not English weight names:

| Tailwind | OTF face |
| --- | --- |
| `font-normal` | Medium |
| `font-medium` | **Bold** |
| `font-bold` / `font-semibold` | Heavy |

All use `fontWeight: '400'` in the plugin so RN does not synthesize bold.

---

## Two render paths — never mix rules

| Context | API | Helper | `fontWeight` |
| --- | --- | --- | --- |
| RN `Text`, pushed sub-page titles | JS Text | `chillFaceStyle(face)` | always `'400'` |
| UIKit nav bar (large / collapsed inline) | `headerTitleStyle`, `headerLargeTitleStyle` | `chillNativeHeaderStyle(face)` | see map below |

Source of truth: `apps/mobile/lib/fonts.ts`.

```typescript
// RN Text — PostScript name + 400 only
chillFaceStyle('bold', { fontSize: 17, color })

// UIKit nav bar — PostScript name + UIFontWeight hint for RCTFont
chillNativeHeaderStyle('bold', { fontSize: 17, color })
```

### Why UIKit needs a different `fontWeight`

`react-native-screens` passes styles to **`RCTFont updateFont`**. When
`fontFamily` is a **PostScript name** (not a family name), RCTFont:

1. Loads that face with `+[UIFont fontWithName:size:]`
2. Replaces `familyName` with the typographic family (e.g. "Chill Round Gothic")
3. **Re-selects a sibling face** by matching `fontWeight` inside the family

So `fontWeight: '400'` on `ChillRoundGothic_Heavy` → family matcher picks
**Medium**. The title is still Chill, but looks Medium. This is not SF Pro.

**Native header weight map** (CloudFX-calibrated):

| Face | `fontWeight` string |
| --- | --- |
| `medium` | `'500'` |
| `bold` | `'700'` |
| `heavy` | `'800'` |

Do **not** use `'400'` or `'600'` on native headers for Chill OTFs.

---

## CloudFX header layout (current)

`apps/mobile/lib/navigation.tsx`:

- **Large title** (`headerLargeTitleStyle`): Heavy — `fontFamily: heavy`, `fontWeight: '800'`
- **Native collapsed inline** (`stackHeaderTitleStyle` / `headerTitleStyle`): Bold — `chillNativeHeaderStyle('bold')`
- **Pushed sub-pages** (`stackPushedHeaderTitleStyle`): Bold — `chillFaceStyle('bold')` on plain `Text`

`apps/mobile/lib/tab-stack-header.tsx`:

- **Tab roots** (`index`, `items`): `tabStackScreenOptions` — **no custom `headerTitle`** (keeps iOS large-title → inline collapse animation)
- **Pushed screens**: `tabPushedStackScreenOptions` — custom `StackHeaderTitle` (`Text`, not `HeaderTitle`)
- Route `items` in Items stack: `itemsStackScreenOptions` returns `tabStackScreenOptions` only for that route

### Do not use `HeaderTitle` from `expo-router/react-navigation` for Chill

`HeaderTitle` merges styles in order:

1. `{ fontFamily: 'System', fontWeight: '600' }` (RN theme `fonts.bold`)
2. `fontSize: 17`
3. Your style

Even when overridden, this path diverges from UIKit native titles. Use plain
`Text` + `chillFaceStyle` in `StackHeaderTitle`.

### Custom `headerTitle` breaks collapse animation

React Navigation docs: custom `headerTitle` disables native title transition
when large title collapses. Only tab **roots** must stay on native title;
pushed screens may use custom `Text`.

---

## React Navigation theme merge

`useHeaderConfigProps` (expo-router native-stack fork) flattens:

```javascript
StyleSheet.flatten([
  Platform.select({ ios: fonts.bold /* or heavy for large */ }),
  headerTitleStyle,
])
```

`fonts.bold` = `{ fontFamily: 'System', fontWeight: '600' }`. Your
`headerTitleStyle` must **override both** `fontFamily` (PostScript) and
`fontWeight` (native map above). Setting only `fontFamily` leaves `'600'` and
RCTFont picks the wrong sibling.

---

## Checklist when titles look wrong

1. **Confirm face, not SF Pro** — wrong weight often means RCTFont family
   re-match, not system font fallback.
2. **Native vs Text** — Is this route using `headerTitleStyle` (UIKit) or
   pushed `StackHeaderTitle` (Text)? Apply the correct helper.
3. **`fontWeight: '400'` on native** — almost always renders Medium.
4. **Tailwind `font-medium`** — means Bold OTF, not Medium.
5. **Tab root has custom `headerTitle`?** — remove for collapse animation;
   use `tabStackScreenOptions` without `headerTitle` on `index` / `items`.
6. **Font file changes** — `expo-font` config plugin embeds at build time;
   OTF updates require **dev build rebuild**, not Metro reload alone.
7. **Only three files** in `app.json` plugin + `chillFontAssets`; delete stray
   copies (e.g. Regular) from `assets/fonts/`.

---

## Reference files

| File | Role |
| --- | --- |
| `apps/mobile/lib/fonts.ts` | `chillFonts`, `chillFaceStyle`, `chillNativeHeaderStyle` |
| `apps/mobile/lib/navigation.tsx` | `stackScreenOptions`, header title styles |
| `apps/mobile/lib/tab-stack-header.tsx` | Tab root vs pushed stack options |
| `apps/mobile/components/stack-header-title.tsx` | Pushed title (`Text`) |
| `apps/mobile/components/items-stack-header-title.tsx` | Icon + `StackHeaderTitle` |
| `apps/mobile/tailwind.config.cjs` | NativeWind face mapping |

---

## Anti-patterns

```typescript
// ❌ Native header — 400 always → Medium in family matcher
headerTitleStyle: { fontFamily: chillFonts.heavy, fontWeight: '400' }

// ❌ Native header — 600 often → Medium, not Bold
headerTitleStyle: { fontFamily: chillFonts.bold, fontWeight: '600' }

// ❌ RN Text — synthetic bold on static OTF
chillFaceStyle('bold', { fontWeight: '700' })

// ❌ Pushed title — HeaderTitle merges System+600
import { HeaderTitle } from 'expo-router/react-navigation'

// ❌ Tab root — custom headerTitle kills collapse animation
tabRootScreenOptions: { headerTitle: () => <Text>...</Text> }
```

```typescript
// ✅ Native large title
headerLargeTitleStyle: { fontFamily: chillFonts.heavy, fontWeight: '800', color }

// ✅ Native collapsed inline (one step below large)
headerTitleStyle: chillNativeHeaderStyle('bold', { fontSize: 17, color })

// ✅ Pushed sub-page
<Text style={chillFaceStyle('bold', { fontSize: 17, color })}>{title}</Text>
```
