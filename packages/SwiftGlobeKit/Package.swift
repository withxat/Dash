// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "SwiftGlobeKit",
  platforms: [
    .iOS(.v17)
  ],
  products: [
    .library(name: "SwiftGlobeKit", targets: ["SwiftGlobeKit"])
  ],
  targets: [
    .target(
      name: "SwiftGlobeKit",
      resources: [
        .copy("GlobeShaders.metal"),
        .process("Resources"),
      ]
    ),
    .testTarget(name: "SwiftGlobeKitTests", dependencies: ["SwiftGlobeKit"]),
  ]
)
