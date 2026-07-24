# ``SwiftDitherKit``

Draw SwiftUI charts with ordered-dither textures.

## Overview

SwiftDitherKit is a dependency-free chart library based on Dither Kit. It has
area, line, bar, pie, donut, radar, and sparkline views. Area, line, and
sparkline charts include the idle sparkles used by the original charts.

Choose a chart, provide `DitherDatum`, `DitherSeries`, or `DitherSlice` values,
and give the view a height. The library renders and caches the dithered image
away from the main actor.

```swift
struct TrafficChart: View {
  @State private var selection: String?

  var body: some View {
    DitherAreaChart(
      data: traffic,
      series: channels,
      options: DitherCartesianOptions(
        stacking: .stacked,
        valueFormat: .compact,
        accessibility: DitherAccessibility(title: "Monthly traffic")
      ),
      selection: $selection
    )
    .frame(height: 260)
  }
}
```

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:InteractionAndAccessibility>

### Cartesian charts

- ``DitherAreaChart``
- ``DitherLineChart``
- ``DitherBarChart``
- ``DitherSparkline``
- ``DitherCartesianOptions``
- ``DitherStacking``

### Polar charts

- ``DitherPieChart``
- ``DitherRadarChart``
- ``DitherPolarOptions``

### Data and appearance

- ``DitherDatum``
- ``DitherSeries``
- ``DitherSlice``
- ``DitherColor``
- ``DitherVariant``
- ``DitherBloom``
- ``DitherMargins``
- ``DitherValueFormat``
- ``DitherAccessibility``
- ``DitherRenderingMode``
