# GradientAvatars

A dependency-free Swift package that paints stable gradient or ordered-dither
avatars from a string or numeric seed, entirely on-device with no stored images
and no network requests. Seeds and palettes follow
[`@outpacelabs/avatars`](https://avatars.outpacestudios.com); the gradient and
dither renderers follow [hashvatar](https://github.com/medhychabour/hashvatar).

The package lives under `packages/gradient-avatars` and is linked to the Dash
app as a local Swift package.

## Requirements

- Swift 6
- iOS 17 or newer
- macOS 14 or newer

## SwiftUI

Add `GradientAvatars` as a local package dependency, then:

```swift
import GradientAvatars

GradientAvatar(seed: user.id, size: 48)
GradientAvatar(seed: user.email, size: 96, cornerRadius: 18)
GradientAvatar(seed: user.id, size: 48, pattern: .dither)
GradientAvatar(seed: user.id, size: 48, pattern: .dither, animated: true)
```

The default shape is a circle. Pass `cornerRadius: 0` for a square.

A palette picks an HSL colour harmony (analogous, triadic, and friends) so an
avatar reads as a vivid multi-hue set rather than one muted family.
`.gradient` blurs six polygons over a bright base; `.dither` resolves a
two-tone sweep through an 8×8 Bayer matrix.

## Motion

`animated: true` swirls the pattern instead of drawing one still. Three limits
apply, and all three are deliberate:

- Only `.dither` moves. A gradient frame costs six Gaussian blurs, which is
  affordable once into a cache and not twenty times a second.
- Only avatars up to `AvatarMotion.animatablePixelSize` move, because every
  frame is a fresh CPU raster. Motion is for the handful of large avatars it
  reads on, not for list rows.
- Reduce Motion falls back to the still, byte-identically.

Stills go through an `NSCache` filled off the main actor; animated frames
deliberately bypass it. A seat that changes size asks for a raster nobody has
drawn yet, so the cache also keeps the last size drawn of each face and lends it
out until the exact one lands — a sharpness away from correct, where a miss
would be a hole.

## Images and palettes

```swift
let image = AvatarRenderer.image(
  seed: "jane@example.com",
  size: 512
)

let png = AvatarRenderer.pngData(
  seed: "jane@example.com",
  size: 512,
  pattern: .dither
)

let palette = AvatarGenerator.palette(for: "jane@example.com")
print(palette.colors.map(\.hex))
```

Seeds and palettes match `@outpacelabs/avatars` v0.2.1 golden values. They do
not match [hashvatar.com](https://www.hashvatar.com) — Dash keeps Outpace's
brighter harmonies on purpose. Rendering uses native Core Graphics and Core
Image, so minor rasterization differences from browser Canvas are expected.
`NOTICE.md` lists every deviation.

## License

MIT. See `LICENSE` and `NOTICE.md`.
