# Getting Started

Build a chart from stable data and series identifiers.

## Add data

Each datum represents a category. Its `values` keys match the IDs of the series
you want to render.

```swift
let traffic = [
  DitherDatum(
    id: "jan",
    label: "Jan",
    values: ["desktop": 186, "mobile": 80]
  ),
  DitherDatum(
    id: "feb",
    label: "Feb",
    values: ["desktop": 240, "mobile": 122]
  ),
]

let channels = [
  DitherSeries(id: "desktop", label: "Desktop", color: .blue),
  DitherSeries(
    id: "mobile",
    label: "Mobile",
    color: .purple,
    variant: .hatched
  ),
]
```

IDs must be unique and stable while a chart is displayed. Missing, infinite,
and NaN values are treated as zero.

## Choose a chart and size

```swift
DitherBarChart(
  data: traffic,
  series: channels,
  options: DitherCartesianOptions(stacking: .stacked)
)
.frame(height: 260)
```

SwiftUI proposes the width. Supply a useful height because the raster follows
the proposed chart size. ``DitherStacking/percent`` normalizes positive and
negative values independently.

For pie and donut charts, provide slices directly. Set `innerRadiusRatio` above
zero to open the center:

```swift
DitherPieChart(
  slices: [
    DitherSlice(id: "direct", value: 34, color: .blue),
    DitherSlice(id: "search", value: 28, color: .purple),
  ],
  innerRadiusRatio: 0.5
)
.frame(height: 280)
```

## Customize values and colours

Use one of the seven built-in colours or create an application colour:

```swift
let brand = DitherColor(hex: 0x36C98F)
```

Set ``DitherValueFormat`` in the chart options to keep axes, tooltips, and
VoiceOver values consistent and locale-aware.

## Render an offscreen snapshot

Live charts render asynchronously. `ImageRenderer` and some snapshot tools do
not run SwiftUI tasks, so opt their subtree into immediate rendering:

```swift
let renderer = ImageRenderer(
  content: TrafficChart()
    .ditherRenderingMode(.immediate)
)
```

Immediate mode renders during view evaluation. Use it for static offscreen
images, not live scrolling interfaces.
