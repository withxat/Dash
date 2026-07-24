# Interaction and Accessibility

Coordinate active chart state with SwiftUI and supply localized chart meaning.

## Own the active selection

Every selectable chart accepts an optional `Binding<String?>`. The value is a
series ID for cartesian and radar charts, and a slice ID for pie charts.

```swift
@State private var activeSeries: String?

DitherLineChart(
  data: traffic,
  series: channels,
  selection: $activeSeries
)
```

Tapping the active item clears it. If new data removes the selected ID, the
chart also clears the binding. Omit the binding and use
`defaultSelectedSeriesID` or `defaultSelectedSliceID` when the chart should
manage its own state.

Area and line charts use the visible series polygon as their tap target. Bars
use exact grouped or stacked rectangles; pie charts use their wedge geometry.
Radar series are selected through the legend.

## Describe the data

SwiftDitherKit exposes its data through Apple's chart accessibility descriptor
APIs. Assistive technologies receive categories, numeric values, series, axis
labels, and selection status even though the pixels themselves are decorative.

```swift
let options = DitherCartesianOptions(
  valueFormat: .currency(code: "EUR"),
  accessibility: DitherAccessibility(
    title: "Quarterly revenue",
    summary: "Revenue by product and quarter",
    categoryAxisLabel: "Quarter",
    valueAxisLabel: "Revenue"
  )
)
```

Localize these strings in the host application. The chart reads SwiftUI's
current locale when formatting visible and accessible numbers.

## Respect motion settings

Entrances and data changes animate by default. Increment `replayToken` to replay
an entrance, or set `animate` to `false`. Area, line, and sparkline charts show
occasional sparkles while idle. With Reduce Motion enabled, the sparkles stop
blinking and chart changes use an opacity fade. Scrubbing updates immediately.
