// swift-tools-version: 6.0
// Vendored from https://github.com/Lakr233/BlossomColorPicker (1.0.0)
// BlossomColorPickerCore is exposed so Dash can embed ExpandedBlossomView.

import PackageDescription

let package = Package(
  name: "BlossomColorPicker",
  platforms: [
    .macOS(.v14),
    .iOS(.v17),
  ],
  products: [
    .library(name: "BlossomColorPicker", targets: ["BlossomColorPicker"]),
    .library(name: "BlossomColorPickerCore", targets: ["BlossomColorPickerCore"]),
  ],
  targets: [
    .target(
      name: "BlossomColorPickerCore",
      resources: [.process("Resources")]
    ),
    .target(
      name: "BlossomColorPicker",
      dependencies: ["BlossomColorPickerCore"]
    ),
    .testTarget(
      name: "BlossomColorPickerCoreTests",
      dependencies: ["BlossomColorPickerCore"]
    ),
  ]
)
