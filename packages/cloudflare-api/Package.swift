// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "CloudflareAPI",
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
  ],
  products: [
    .library(name: "CloudflareAPI", targets: ["CloudflareAPI"])
  ],
  targets: [
    .target(
      name: "CloudflareAPI",
      resources: [.process("Resources")]
    ),
    .testTarget(name: "CloudflareAPITests", dependencies: ["CloudflareAPI"]),
  ]
)
