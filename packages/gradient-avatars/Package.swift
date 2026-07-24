// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "GradientAvatars",
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
  ],
  products: [
    .library(name: "GradientAvatars", targets: ["GradientAvatars"])
  ],
  targets: [
    .target(name: "GradientAvatars"),
    .testTarget(name: "GradientAvatarsTests", dependencies: ["GradientAvatars"]),
  ]
)
