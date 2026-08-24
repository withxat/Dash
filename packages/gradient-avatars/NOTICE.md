# GradientAvatars

A hybrid of two MIT-licensed upstreams:

- Seed hashing and HSL harmony palettes follow
  [`@outpacelabs/avatars`](https://avatars.outpacestudios.com) (Outpace Studios).
- Gradient and dither renderers, plus SwiftUI caching and motion, follow
  [medhychabour/hashvatar](https://github.com/medhychabour/hashvatar).

Because the seed and palette are Outpace's, the same string does **not** match
[hashvatar.com](https://www.hashvatar.com). That is deliberate: Dash keeps the
vivid multi-hue palettes and uses hashvatar only for how those colours are
painted.

Other Dash deviations from hashvatar's TypeScript:
- Gradient layer geometry is drawn from a salted second PRNG stream. Upstream
  re-hashes the decimal text of its first four seeds, which depends on
  JavaScript's number formatting.
- The dither cell edge is derived in pixels rather than CSS pixels times the
  device pixel ratio, because the renderer is handed a pixel size.
- Rendering, caching, and animation are Swift: stills are rasterized off the
  main actor into an `NSCache`, and motion is a phase parameter the SwiftUI
  view samples 20 times a second.
