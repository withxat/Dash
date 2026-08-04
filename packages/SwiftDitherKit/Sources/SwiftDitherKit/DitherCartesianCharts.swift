import SwiftUI

/// Shared presentation and interaction options for area, line, and bar charts.
public struct DitherCartesianOptions: Hashable, Sendable {
  /// How multiple series share the value axis.
  public var stacking: DitherStacking
  /// Space reserved for chart chrome around the raster.
  public var margins: DitherMargins
  /// Optional glow made from the rendered raster.
  public var bloom: DitherBloom
  /// Whether chart entrances and data changes animate.
  public var animate: Bool
  /// Duration of the entrance animation.
  public var animationDuration: TimeInterval
  /// Increment this value to replay the entrance animation.
  public var replayToken: Int
  /// Whether the plot accepts scrubbing and direct mark taps.
  public var interactive: Bool
  /// Whether value grid lines and category labels are visible.
  public var showsAxes: Bool
  /// Whether the selectable series legend is visible.
  public var showsLegend: Bool
  /// Whether scrubbing presents a value tooltip.
  public var showsTooltip: Bool
  /// Locale-aware formatting shared by axes, tooltips, and accessibility values.
  public var valueFormat: DitherValueFormat
  /// Semantic labels exposed with the chart accessibility descriptor.
  public var accessibility: DitherAccessibility
  /// Optional lower bound for the value-axis maximum. Use when a flat series
  /// (for example an all-zero sparkline lifted off the floor) should not expand
  /// to fill the full plot height.
  public var valueCeiling: Double?

  public init(
    stacking: DitherStacking = .overlaid,
    margins: DitherMargins = .cartesian,
    bloom: DitherBloom = .off,
    animate: Bool = true,
    animationDuration: TimeInterval = 0.28,
    replayToken: Int = 0,
    interactive: Bool = true,
    showsAxes: Bool = true,
    showsLegend: Bool = true,
    showsTooltip: Bool = true,
    valueFormat: DitherValueFormat = .automatic,
    accessibility: DitherAccessibility = DitherAccessibility(),
    valueCeiling: Double? = nil
  ) {
    self.stacking = stacking
    self.margins = margins
    self.bloom = bloom
    self.animate = animate
    self.animationDuration = animationDuration
    self.replayToken = replayToken
    self.interactive = interactive
    self.showsAxes = showsAxes
    self.showsLegend = showsLegend
    self.showsTooltip = showsTooltip
    self.valueFormat = valueFormat
    self.accessibility = accessibility
    self.valueCeiling = valueCeiling
  }
}

/// An area chart rendered with an ordered-dither fill.
public struct DitherAreaChart: View {
  let data: [DitherDatum]
  let series: [DitherSeries]
  let options: DitherCartesianOptions
  let markerIndex: Int?
  let highlighted: Bool
  let selection: Binding<String?>?
  let defaultSelectedSeriesID: String?
  let onHoverChange: ((Int?) -> Void)?
  let onSelectionChange: ((String?) -> Void)?
  let onTap: (() -> Void)?

  /// Creates an area chart.
  ///
  /// - Parameters:
  ///   - data: Categories and values to draw.
  ///   - series: Visual configuration for each value series.
  ///   - options: Layout, formatting, motion, and interaction options.
  ///   - markerIndex: A datum index at which to show the vertical marker.
  ///   - highlighted: Whether to render the chart at its emphasized intensity.
  ///   - selection: A binding to the selected series ID.
  ///   - defaultSelectedSeriesID: The initial selection when `selection` is omitted.
  ///   - onHoverChange: Called with the datum index under the pointer, or `nil`.
  ///   - onSelectionChange: Called when the selected series ID changes.
  ///   - onTap: Replaces direct plot-series selection for a plain tap. The
  ///     legend remains selectable and hold-to-scrub is unchanged.
  public init(
    data: [DitherDatum],
    series: [DitherSeries],
    options: DitherCartesianOptions = DitherCartesianOptions(),
    markerIndex: Int? = nil,
    highlighted: Bool = false,
    selection: Binding<String?>? = nil,
    defaultSelectedSeriesID: String? = nil,
    onHoverChange: ((Int?) -> Void)? = nil,
    onSelectionChange: ((String?) -> Void)? = nil,
    onTap: (() -> Void)? = nil
  ) {
    self.data = data
    self.series = series
    self.options = options
    self.markerIndex = markerIndex
    self.highlighted = highlighted
    self.selection = selection
    self.defaultSelectedSeriesID = defaultSelectedSeriesID
    self.onHoverChange = onHoverChange
    self.onSelectionChange = onSelectionChange
    self.onTap = onTap
  }

  public var body: some View {
    DitherCartesianChart(
      kind: .area,
      data: data,
      series: series,
      options: options,
      markerIndex: markerIndex,
      highlighted: highlighted,
      selection: selection,
      defaultSelectedSeriesID: defaultSelectedSeriesID,
      onHoverChange: onHoverChange,
      onSelectionChange: onSelectionChange,
      onTap: onTap
    )
  }
}

/// A line chart whose stroke is a thin ordered-dither glow band.
public struct DitherLineChart: View {
  let data: [DitherDatum]
  let series: [DitherSeries]
  let options: DitherCartesianOptions
  let markerIndex: Int?
  let highlighted: Bool
  let selection: Binding<String?>?
  let defaultSelectedSeriesID: String?
  let onHoverChange: ((Int?) -> Void)?
  let onSelectionChange: ((String?) -> Void)?
  let onTap: (() -> Void)?

  /// Creates a line chart.
  ///
  /// - Parameters:
  ///   - data: Categories and values to draw.
  ///   - series: Visual configuration for each value series.
  ///   - options: Layout, formatting, motion, and interaction options.
  ///   - markerIndex: A datum index at which to show the vertical marker.
  ///   - highlighted: Whether to render the chart at its emphasized intensity.
  ///   - selection: A binding to the selected series ID.
  ///   - defaultSelectedSeriesID: The initial selection when `selection` is omitted.
  ///   - onHoverChange: Called with the datum index under the pointer, or `nil`.
  ///   - onSelectionChange: Called when the selected series ID changes.
  ///   - onTap: Replaces direct plot-series selection for a plain tap. The
  ///     legend remains selectable and hold-to-scrub is unchanged.
  public init(
    data: [DitherDatum],
    series: [DitherSeries],
    options: DitherCartesianOptions = DitherCartesianOptions(),
    markerIndex: Int? = nil,
    highlighted: Bool = false,
    selection: Binding<String?>? = nil,
    defaultSelectedSeriesID: String? = nil,
    onHoverChange: ((Int?) -> Void)? = nil,
    onSelectionChange: ((String?) -> Void)? = nil,
    onTap: (() -> Void)? = nil
  ) {
    self.data = data
    self.series = series
    self.options = options
    self.markerIndex = markerIndex
    self.highlighted = highlighted
    self.selection = selection
    self.defaultSelectedSeriesID = defaultSelectedSeriesID
    self.onHoverChange = onHoverChange
    self.onSelectionChange = onSelectionChange
    self.onTap = onTap
  }

  public var body: some View {
    DitherCartesianChart(
      kind: .line,
      data: data,
      series: series,
      options: options,
      markerIndex: markerIndex,
      highlighted: highlighted,
      selection: selection,
      defaultSelectedSeriesID: defaultSelectedSeriesID,
      onHoverChange: onHoverChange,
      onSelectionChange: onSelectionChange,
      onTap: onTap
    )
  }
}

/// A grouped, stacked, or percent-stacked dithered bar chart.
public struct DitherBarChart: View {
  let data: [DitherDatum]
  let series: [DitherSeries]
  let options: DitherCartesianOptions
  let highlighted: Bool
  let selection: Binding<String?>?
  let defaultSelectedSeriesID: String?
  let onHoverChange: ((Int?) -> Void)?
  let onSelectionChange: ((String?) -> Void)?
  let onTap: (() -> Void)?

  /// Creates a bar chart.
  ///
  /// - Parameters:
  ///   - data: Categories and values to draw.
  ///   - series: Visual configuration for each value series.
  ///   - options: Layout, formatting, motion, and interaction options.
  ///   - highlighted: Whether to render the chart at its emphasized intensity.
  ///   - selection: A binding to the selected series ID.
  ///   - defaultSelectedSeriesID: The initial selection when `selection` is omitted.
  ///   - onHoverChange: Called with the datum index under the pointer, or `nil`.
  ///   - onSelectionChange: Called when the selected series ID changes.
  ///   - onTap: Replaces direct plot-series selection for a plain tap. The
  ///     legend remains selectable and hold-to-scrub is unchanged.
  public init(
    data: [DitherDatum],
    series: [DitherSeries],
    options: DitherCartesianOptions = DitherCartesianOptions(),
    highlighted: Bool = false,
    selection: Binding<String?>? = nil,
    defaultSelectedSeriesID: String? = nil,
    onHoverChange: ((Int?) -> Void)? = nil,
    onSelectionChange: ((String?) -> Void)? = nil,
    onTap: (() -> Void)? = nil
  ) {
    self.data = data
    self.series = series
    self.options = options
    self.highlighted = highlighted
    self.selection = selection
    self.defaultSelectedSeriesID = defaultSelectedSeriesID
    self.onHoverChange = onHoverChange
    self.onSelectionChange = onSelectionChange
    self.onTap = onTap
  }

  public var body: some View {
    DitherCartesianChart(
      kind: .bar,
      data: data,
      series: series,
      options: options,
      markerIndex: nil,
      highlighted: highlighted,
      selection: selection,
      defaultSelectedSeriesID: defaultSelectedSeriesID,
      onHoverChange: onHoverChange,
      onSelectionChange: onSelectionChange,
      onTap: onTap
    )
  }
}

/// A compact single-series area chart without axes or a legend.
public struct DitherSparkline: View {
  let values: [Double]
  let color: DitherColor
  let variant: DitherVariant
  let markerIndex: Int?
  let highlighted: Bool
  let bloom: DitherBloom
  let animate: Bool

  /// Creates a sparkline.
  ///
  /// - Parameters:
  ///   - values: Values to draw. Infinite and NaN values are treated as zero.
  ///   - color: The colour of the dithered area.
  ///   - variant: The dither fill pattern.
  ///   - markerIndex: A value index at which to show the vertical marker.
  ///   - highlighted: Whether to render the sparkline at its emphasized intensity.
  ///   - bloom: The glow applied behind the raster.
  ///   - animate: Whether the sparkline animates its entrance and data changes.
  public init(
    values: [Double],
    color: DitherColor,
    variant: DitherVariant = .gradient,
    markerIndex: Int? = nil,
    highlighted: Bool = false,
    bloom: DitherBloom = .off,
    animate: Bool = false
  ) {
    self.values = values
    self.color = color
    self.variant = variant
    self.markerIndex = markerIndex
    self.highlighted = highlighted
    self.bloom = bloom
    self.animate = animate
  }

  public var body: some View {
    let data = values.enumerated().map { index, value in
      DitherDatum(id: "sample-\(index)", label: "\(index + 1)", values: ["value": value])
    }
    let options = DitherCartesianOptions(
      margins: .sparkline,
      bloom: bloom,
      animate: animate,
      interactive: false,
      showsAxes: false,
      showsLegend: false,
      showsTooltip: false
    )
    DitherCartesianChart(
      kind: .area,
      data: data,
      series: [DitherSeries(id: "value", color: color, variant: variant)],
      options: options,
      markerIndex: markerIndex,
      highlighted: highlighted,
      selection: nil,
      defaultSelectedSeriesID: nil,
      onHoverChange: nil,
      onSelectionChange: nil,
      onTap: nil
    )
  }
}

private struct DitherCartesianChart: View {
  @Environment(\.locale) private var locale
  @State private var hoverIndex: Int?
  @State private var selectedSeriesID: String?

  let kind: DitherChartKind
  let data: [DitherDatum]
  let series: [DitherSeries]
  let options: DitherCartesianOptions
  let markerIndex: Int?
  let highlighted: Bool
  let selection: Binding<String?>?
  let onHoverChange: ((Int?) -> Void)?
  let onSelectionChange: ((String?) -> Void)?
  let onTap: (() -> Void)?

  init(
    kind: DitherChartKind,
    data: [DitherDatum],
    series: [DitherSeries],
    options: DitherCartesianOptions,
    markerIndex: Int?,
    highlighted: Bool,
    selection: Binding<String?>?,
    defaultSelectedSeriesID: String?,
    onHoverChange: ((Int?) -> Void)?,
    onSelectionChange: ((String?) -> Void)?,
    onTap: (() -> Void)?
  ) {
    self.kind = kind
    self.data = data
    self.series = series
    self.options = options
    self.markerIndex = markerIndex
    self.highlighted = highlighted
    self.selection = selection
    self.onHoverChange = onHoverChange
    self.onSelectionChange = onSelectionChange
    self.onTap = onTap
    _hoverIndex = State(initialValue: nil)
    _selectedSeriesID = State(
      initialValue: selection == nil ? defaultSelectedSeriesID : selection?.wrappedValue
    )
  }

  var body: some View {
    VStack(spacing: 6) {
      DitherCartesianPlot(
        kind: kind,
        data: data,
        series: series,
        options: options,
        markerIndex: markerIndex,
        externallyHighlighted: highlighted,
        selectedSeriesID: effectiveSelection,
        hoverIndex: $hoverIndex,
        onHoverChange: onHoverChange,
        onSelectSeries: selectSeries(id:),
        onTap: onTap
      )
      if options.showsLegend, !series.isEmpty {
        DitherLegend(
          entries: series.map {
            DitherLegendEntry(id: $0.id, label: $0.label, color: $0.color)
          },
          selectedID: effectiveSelection
        ) { id in selectSeries(id: id) }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text(verbatim: accessibilityLabel))
    .accessibilityChartDescriptor(
      DitherCartesianChartDescriptor(
        kind: kind,
        data: data,
        series: series,
        stacking: options.stacking,
        selectedSeriesID: effectiveSelection,
        valueFormat: options.valueFormat,
        accessibility: options.accessibility,
        locale: locale
      )
    )
    .onChange(of: requestedSelection, initial: true) { _, selectedID in
      validateSelection(selectedID, validIDs: series.map(\.id))
    }
    .onChange(of: series.map(\.id)) { _, validIDs in
      validateSelection(requestedSelection, validIDs: validIDs)
    }
  }

  private var accessibilityLabel: String {
    if let title = options.accessibility.title { return title }
    let type: String
    switch kind {
    case .area: type = "Area"
    case .line: type = "Line"
    case .bar: type = "Bar"
    }
    return "\(type) chart with \(data.count) data points and \(series.count) series"
  }

  private func selectSeries(id: String) {
    let next = effectiveSelection == id ? nil : id
    setSelection(next)
  }

  private var requestedSelection: String? {
    if let selection { return selection.wrappedValue }
    return selectedSeriesID
  }

  private var effectiveSelection: String? {
    DitherSelection.normalized(requestedSelection, validIDs: series.map(\.id))
  }

  private func validateSelection(_ selectedID: String?, validIDs: [String]) {
    guard selectedID != DitherSelection.normalized(selectedID, validIDs: validIDs) else { return }
    setSelection(nil)
  }

  private func setSelection(_ next: String?) {
    if let selection {
      selection.wrappedValue = next
    } else {
      selectedSeriesID = next
    }
    onSelectionChange?(next)
  }
}

private struct DitherCartesianPlot: View {
  @Environment(\.locale) private var locale
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let kind: DitherChartKind
  let data: [DitherDatum]
  let series: [DitherSeries]
  let options: DitherCartesianOptions
  let markerIndex: Int?
  let externallyHighlighted: Bool
  let selectedSeriesID: String?
  @Binding var hoverIndex: Int?
  let onHoverChange: ((Int?) -> Void)?
  let onSelectSeries: (String) -> Void
  let onTap: (() -> Void)?

  /// Measured bubble size; positioning falls back to a short single-series guess
  /// until the first preference pass lands.
  @State private var tooltipSize: CGSize = CGSize(width: 160, height: 52)

  var body: some View {
    GeometryReader { proxy in
      let plotRect = makePlotRect(in: proxy.size)
      let bands = DitherGeometry.computeBands(
        data: data,
        series: series,
        stacking: options.stacking
      )
      let scale = DitherLinearScale(
        minimum: bands.minimum,
        maximum: max(bands.maximum, options.valueCeiling ?? 0),
        height: plotRect.height
      )
      let effectiveMarker = validatedMarker(hoverIndex ?? markerIndex)
      let renderInput = DitherCartesianRenderInput(
        kind: kind,
        data: data,
        series: series,
        stacking: options.stacking,
        size: plotRect.size,
        selectedSeriesID: selectedSeriesID,
        hoverIndex: effectiveMarker,
        highlighted: externallyHighlighted || hoverIndex != nil,
        valueCeiling: options.valueCeiling
      )
      ZStack(alignment: .topLeading) {
        if options.showsAxes {
          DitherCartesianChrome(
            data: data,
            kind: kind,
            scale: scale,
            plotRect: plotRect,
            valueFormat: options.valueFormat,
            locale: locale
          )
        }
        DitherAsyncRaster(
          request: .cartesian(renderInput),
          size: plotRect.size,
          bloom: options.bloom,
          revealStyle: .leading,
          animate: options.animate,
          animationDuration: options.animationDuration,
          transitionKey: DitherTransitionKey.cartesian(
            kind: kind,
            data: data,
            series: series,
            stacking: options.stacking,
            selectedSeriesID: selectedSeriesID,
            highlighted: externallyHighlighted
          ),
          replayToken: options.replayToken
        )
        .position(x: plotRect.midX, y: plotRect.midY)

        if options.interactive, !data.isEmpty {
          DitherCartesianInteractionLayer(
            kind: kind,
            data: data,
            series: series,
            stacking: options.stacking,
            plotSize: plotRect.size,
            hoverIndex: $hoverIndex,
            onHoverChange: onHoverChange,
            onSelectSeries: onSelectSeries,
            onTap: onTap
          )
          .frame(width: plotRect.width, height: plotRect.height)
          .position(x: plotRect.midX, y: plotRect.midY)
        }

        if options.showsTooltip,
          let index = effectiveMarker,
          hoverIndex != nil,
          data.indices.contains(index)
        {
          DitherTooltip(
            heading: data[index].label,
            items: series.map { item in
              DitherTooltipItem(
                id: item.id,
                label: item.label,
                value: data[index][item.id],
                color: item.color
              )
            },
            valueFormat: options.valueFormat,
            locale: locale
          )
          .position(
            tooltipCenter(
              index: index,
              bands: bands,
              scale: scale,
              plotRect: plotRect,
              container: proxy.size
            )
          )
          .transition(.scale(scale: 0.98, anchor: .bottom).combined(with: .opacity))
        }
      }
      .onPreferenceChange(DitherTooltipSizeKey.self) { size in
        guard size.width > 0, size.height > 0 else { return }
        tooltipSize = size
      }
      .animation(
        reduceMotion ? nil : DitherMotion.update,
        value: hoverIndex
      )
      .animation(
        reduceMotion ? nil : DitherMotion.feedback,
        value: hoverIndex != nil
      )
    }
  }

  private func makePlotRect(in size: CGSize) -> CGRect {
    let width = max(0, size.width - options.margins.leading - options.margins.trailing)
    let height = max(0, size.height - options.margins.top - options.margins.bottom)
    return CGRect(
      x: options.margins.leading,
      y: options.margins.top,
      width: width,
      height: height
    )
  }

  private func validatedMarker(_ marker: Int?) -> Int? {
    guard let marker, !data.isEmpty else { return nil }
    return min(data.count - 1, max(0, marker))
  }

  private func tooltipCenter(
    index: Int,
    bands: DitherBandResult,
    scale: DitherLinearScale,
    plotRect: CGRect,
    container: CGSize
  ) -> CGPoint {
    let localX: CGFloat
    if kind == .bar {
      let band = DitherGeometry.barBand(index: index, count: data.count, width: plotRect.width)
      localX = band.x + band.width / 2
    } else {
      localX = DitherGeometry.xCenter(index: index, count: data.count, width: plotRect.width)
    }
    let candidates = series.compactMap { bands.bands[$0.id]?[safe: index]?.upper }
    let highest = candidates.max() ?? scale.upperBound
    return DitherGeometry.tooltipCenter(
      markX: plotRect.minX + localX,
      markY: plotRect.minY + scale.y(for: highest),
      container: container,
      tooltipSize: tooltipSize)
  }
}

private struct DitherCartesianInteractionLayer: View {
  let kind: DitherChartKind
  let data: [DitherDatum]
  let series: [DitherSeries]
  let stacking: DitherStacking
  let plotSize: CGSize
  @Binding var hoverIndex: Int?
  let onHoverChange: ((Int?) -> Void)?
  let onSelectSeries: (String) -> Void
  let onTap: (() -> Void)?

  var body: some View {
    #if os(tvOS)
      Color.clear.allowsHitTesting(false)
    #elseif os(iOS)
      // Hold to engage, then the chart owns the finger until it lifts — see
      // `DitherHoldInteraction`. A SwiftUI `DragGesture(minimumDistance: 0)`
      // here would instead steal every vertical pan from the page.
      DitherHoldScrubCatcher(
        onScrub: { point in
          if let point {
            update(location: point)
          } else {
            update(index: nil)
          }
        },
        onTap: { point in
          if let onTap {
            onTap()
            return
          }
          if let seriesID = DitherSelectionHitTester.seriesID(
            at: point,
            kind: kind,
            data: data,
            series: series,
            stacking: stacking,
            size: plotSize
          ) {
            onSelectSeries(seriesID)
          }
        }
      )
    #else
      Rectangle()
        .fill(Color.clear)
        .contentShape(Rectangle())
        .simultaneousGesture(
          LongPressGesture(minimumDuration: DitherHoldInteraction.holdDuration)
            .sequenced(
              before: DragGesture(minimumDistance: 0, coordinateSpace: .local)
            )
            .onChanged { value in
              switch value {
              case .second(true, let drag):
                if let drag { update(location: drag.location) }
              default: break
              }
            }
            .onEnded { _ in update(index: nil) }
        )
        .onContinuousHover { phase in
          switch phase {
          case .active(let location): update(location: location)
          case .ended: update(index: nil)
          }
        }
    #endif
  }

  private func update(location: CGPoint) {
    let index =
      kind == .bar
      ? DitherGeometry.bandIndex(x: location.x, count: data.count, width: plotSize.width)
      : DitherGeometry.nearestIndex(x: location.x, count: data.count, width: plotSize.width)
    update(index: index)
  }

  private func update(index: Int?) {
    guard hoverIndex != index else { return }
    hoverIndex = index
    onHoverChange?(index)
  }
}

extension Collection {
  fileprivate subscript(safe index: Index) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
