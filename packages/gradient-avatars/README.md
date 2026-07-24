# GradientAvatars

A dependency-free Swift port of
[`@outpacelabs/avatars`](https://avatars.outpacestudios.com). It creates stable
mesh-gradient or ordered-dither avatars from a string or numeric seed, entirely
on-device with no stored images and no network requests.

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
```

The default shape is a circle. Pass `cornerRadius: 0` for a square.

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

String hashing and palette generation match the upstream JavaScript engine's
v0.2.1 golden values. Rendering uses native Core Graphics and Core Image, so
minor rasterization differences from browser Canvas are expected.

## License

MIT. The original implementation and design are copyright Outpace Studios; see
`LICENSE`.
