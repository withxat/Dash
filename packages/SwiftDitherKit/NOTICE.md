# SwiftDitherKit

Vendored from [MarkUnthank/SwiftDitherKit](https://github.com/MarkUnthank/SwiftDitherKit) (tag `0.1.0`), MIT License.

Dash patches:
- `DitherTooltip` uses system Liquid Glass (`.glassEffect`) on iOS 26+ / macOS 26+, with the upstream `.regularMaterial` chrome as the fallback.
- Cartesian chart tooltips size to their content, stay above the mark, and may overflow the chart top instead of clamping or flipping below.
