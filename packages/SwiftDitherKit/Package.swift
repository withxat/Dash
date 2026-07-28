// swift-tools-version: 6.0
// Vendored from https://github.com/MarkUnthank/SwiftDitherKit (0.1.0)
// Patch: chart tooltips use Liquid Glass on iOS 26+ / macOS 26+.
// Patch: cartesian tooltips size to content and stay above the mark (may overflow).
// Patch: every plot shares one hold-to-engage gesture (`DitherHoldInteraction`)
// that claims the enclosing scroll/pager/pop recognizers until the finger lifts.

import PackageDescription

let package = Package(
  name: "SwiftDitherKit",
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
    .tvOS(.v17),
    .visionOS(.v1),
  ],
  products: [
    .library(name: "SwiftDitherKit", targets: ["SwiftDitherKit"])
  ],
  targets: [
    .target(name: "SwiftDitherKit"),
    .testTarget(name: "SwiftDitherKitTests", dependencies: ["SwiftDitherKit"]),
  ]
)
