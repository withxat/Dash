# GradientAvatars

Swift port of [medhychabour/hashvatar](https://github.com/medhychabour/hashvatar), MIT License.

The palette and both renderers follow the upstream TypeScript, down to the
JavaScript arithmetic that decides a seed, so the same string produces the same
avatar here and on [hashvatar.com](https://www.hashvatar.com).

Dash deviations:
- Gradient layer geometry is drawn from a salted second PRNG stream. Upstream
  re-hashes the decimal text of its first four seeds, which depends on
  JavaScript's number formatting.
- The dither cell edge is derived in pixels rather than CSS pixels times the
  device pixel ratio, because the renderer is handed a pixel size.
- Rendering, caching, and animation are Swift: stills are rasterized off the
  main actor into an `NSCache`, and motion is a phase parameter the SwiftUI
  view samples 20 times a second.

An earlier version of this package ported
[`@outpacelabs/avatars`](https://avatars.outpacestudios.com) instead. None of
its palette or rendering remains.
