# SwiftGlobeKit

SwiftGlobeKit is a native SwiftUI and Metal globe for iOS 17 and later. It
renders a dotted land surface with optional geographic markers and arcs, and
exposes camera, styling, motion, and quality controls as Swift value types.

The package is designed to stay independent of its host app. It does not
perform networking, geocoding, country lookup, analytics loading, or
localization. Callers provide normalized geographic data and their own
semantic colors and accessibility copy.

## Version 1 scope

- A single dotted globe rendered by Metal and hosted in SwiftUI.
- Longitude and latitude camera positioning plus visual scale.
- Optional point markers and great-circle arcs.
- Automatic rotation, direct dragging, inertia, and adaptive quality policy.
- Light- and dark-appearance styling supplied by the caller.
- Explicit lifecycle control so a host can pause rendering when a view is
  covered, off-screen, inactive, or affected by Reduce Motion.

Version 1 is not a map SDK, a geographic data source, a SceneKit or RealityKit
scene, or a drop-in implementation of a web renderer. It does not promise
COBE's approximately 5 KB web bundle size; native binary size, GPU resources,
and platform integration have different constraints.

## Model

`GlobeCoordinate` clamps latitude and wraps longitude at the antimeridian.
`GlobeCamera`, `GlobeStyle`, marker and arc dimensions, and automatic rotation
speed clamp invalid input to documented ranges. Non-finite values fall back to
safe defaults before reaching the renderer.

Markers accept caller-owned identifiers and optional localized accessibility
labels. A marker or arc without a custom color inherits the corresponding
default from `GlobeStyle`.

## Usage

```swift
import SwiftGlobeKit
import SwiftUI

struct TrafficGlobe: View {
  @State private var camera = GlobeCamera(longitude: 103.8, latitude: 1.35)

  private let markers = [
    GlobeMarker(
      id: "singapore",
      coordinate: GlobeCoordinate(latitude: 1.35, longitude: 103.8),
      accessibilityLabel: "Singapore"
    )
  ]

  var body: some View {
    DotGlobeView(
      camera: $camera,
      markers: markers,
      accessibilityLabel: "Traffic locations"
    ) { marker in
      // Route the caller-owned marker to app state.
    }
    .frame(height: 280)
  }
}
```

`DotGlobeView` also has a value-based camera initializer for callers that do
not need to own camera state. Set `isActive` to `false` when the host keeps the
view mounted behind another surface. The renderer also pauses with the app
scene, disables automatic rotation and inertia for Reduce Motion, and lowers
rendering cost in Low Power Mode.

The camera binding is written when direct manipulation ends. Automatic
rotation and inertial settling remain renderer-owned presentation state so
they do not invalidate the surrounding SwiftUI hierarchy every frame.

## Requirements

- Swift 6
- iOS 17 or later
- Xcode with Metal support

The package deliberately declares only iOS 17. It does not add an iPad,
Mac Catalyst, macOS, tvOS, or visionOS product surface.

## Development

From the repository root:

```sh
pnpm globe:test
xcrun swift format lint --strict --recursive packages/SwiftGlobeKit
node packages/SwiftGlobeKit/Scripts/generate-land-mask.mjs --check
```

`pnpm globe:test` runs the model tests, an iOS 17 strict-concurrency
type-check, and a Metal compile/link check without launching a simulator.

The committed land mask is generated deterministically from pinned Natural
Earth data. Its provenance and license are documented in
`THIRD_PARTY_NOTICES.md`.

## Inspiration

The compact dotted-globe visual direction and spherical-Fibonacci sampling
approach are inspired by [COBE](https://github.com/shuding/cobe) by Shu Ding.
SwiftGlobeKit is an independent Swift and Metal implementation: it does not
embed COBE's JavaScript, generated GLSL, or bundled world texture, and does not
claim source or API compatibility.

## License

SwiftGlobeKit is available under the MIT License. See `LICENSE`.
