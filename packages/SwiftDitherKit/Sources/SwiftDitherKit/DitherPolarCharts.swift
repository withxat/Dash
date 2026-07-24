import SwiftUI

/// Shared presentation and interaction options for pie and radar charts.
public struct DitherPolarOptions: Hashable, Sendable {
  /// Space reserved around the polar raster.
  public var margins: DitherMargins
  /// Optional glow made from the rendered raster.
  public var bloom: DitherBloom
  /// Whether chart entrances and data changes animate.
  public var animate: Bool
  /// Duration of the entrance animation.
  public var animationDuration: TimeInterval
  /// Increment this value to replay the entrance animation.
  public var replayToken: Int
  /// Whether the plot accepts pointer and touch interaction.
  public var interactive: Bool
  /// Whether the selectable slice or series legend is visible.
  public var showsLegend: Bool
  /// Whether pointer or touch scrubbing presents a value tooltip.
  public var showsTooltip: Bool
  /// Locale-aware formatting shared by tooltips and accessibility values.
  public var valueFormat: DitherValueFormat
  /// Semantic labels exposed with the chart accessibility descriptor.
  public var accessibility: DitherAccessibility

  public init(
    margins: DitherMargins = .polar,
    bloom: DitherBloom = .off,
    animate: Bool = true,
    animationDuration: TimeInterval = 0.28,
    replayToken: Int = 0,
    interactive: Bool = true,
    showsLegend: Bool = true,
    showsTooltip: Bool = true,
    valueFormat: DitherValueFormat = .automatic,
    accessibility: DitherAccessibility = DitherAccessibility()
  ) {
    self.margins = margins
    self.bloom = bloom
    self.animate = animate
    self.animationDuration = animationDuration
    self.replayToken = replayToken
    self.interactive = interactive
    self.showsLegend = showsLegend
    self.showsTooltip = showsTooltip
    self.valueFormat = valueFormat
    self.accessibility = accessibility
  }
}

/// A dithered pie or donut chart.
public struct DitherPieChart: View {
  @Environment(\.locale) private var locale
  @State private var hoverIndex: Int?
  @State private var selectedSliceID: String?

  let slices: [DitherSlice]
  let innerRadiusRatio: Double
  let options: DitherPolarOptions
  let selection: Binding<String?>?
  let onHoverChange: ((Int?) -> Void)?
  let onSelectionChange: ((String?) -> Void)?

  /// Creates a pie or donut chart.
  ///
  /// - Parameters:
  ///   - slices: The wedges to draw. Negative, infinite, and NaN values are treated as zero.
  ///   - innerRadiusRatio: The hole size for a donut, clamped to `0...0.9`.
  ///   - options: Layout, formatting, motion, and interaction options.
  ///   - selection: A binding to the selected slice ID.
  ///   - defaultSelectedSliceID: The initial selection when `selection` is omitted.
  ///   - onHoverChange: Called with the slice index under the pointer, or `nil`.
  ///   - onSelectionChange: Called when the selected slice ID changes.
  public init(
    slices: [DitherSlice],
    innerRadiusRatio: Double = 0,
    options: DitherPolarOptions = DitherPolarOptions(),
    selection: Binding<String?>? = nil,
    defaultSelectedSliceID: String? = nil,
    onHoverChange: ((Int?) -> Void)? = nil,
    onSelectionChange: ((String?) -> Void)? = nil
  ) {
    self.slices = slices
    self.innerRadiusRatio = innerRadiusRatio
    self.options = options
    self.selection = selection
    self.onHoverChange = onHoverChange
    self.onSelectionChange = onSelectionChange
    _hoverIndex = State(initialValue: nil)
    _selectedSliceID = State(
      initialValue: selection == nil ? defaultSelectedSliceID : selection?.wrappedValue
    )
  }

  public var body: some View {
    VStack(spacing: 6) {
      DitherPiePlot(
        slices: slices,
        innerRadiusRatio: innerRadiusRatio,
        options: options,
        selectedSliceID: effectiveSelection,
        hoverIndex: $hoverIndex,
        onHoverChange: onHoverChange,
        onSelectIndex: selectSlice
      )
      if options.showsLegend, !slices.isEmpty {
        DitherLegend(
          entries: slices.map {
            DitherLegendEntry(id: $0.id, label: $0.label, color: $0.color)
          },
          selectedID: effectiveSelection,
          onSelect: selectSlice(id:)
        )
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(
      Text(verbatim: options.accessibility.title ?? "Pie chart with \(slices.count) slices")
    )
    .accessibilityChartDescriptor(
      DitherPieChartDescriptor(
        slices: slices,
        selectedSliceID: effectiveSelection,
        valueFormat: options.valueFormat,
        accessibility: options.accessibility,
        locale: locale
      )
    )
    .onChange(of: requestedSelection, initial: true) { _, selectedID in
      validateSelection(selectedID, validIDs: slices.map(\.id))
    }
    .onChange(of: slices.map(\.id)) { _, validIDs in
      validateSelection(requestedSelection, validIDs: validIDs)
    }
  }

  private func selectSlice(_ index: Int) {
    guard slices.indices.contains(index) else { return }
    selectSlice(id: slices[index].id)
  }

  private func selectSlice(id: String) {
    let next = effectiveSelection == id ? nil : id
    setSelection(next)
  }

  private var requestedSelection: String? {
    if let selection { return selection.wrappedValue }
    return selectedSliceID
  }

  private var effectiveSelection: String? {
    DitherSelection.normalized(requestedSelection, validIDs: slices.map(\.id))
  }

  private func validateSelection(_ selectedID: String?, validIDs: [String]) {
    guard selectedID != DitherSelection.normalized(selectedID, validIDs: validIDs) else { return }
    setSelection(nil)
  }

  private func setSelection(_ next: String?) {
    if let selection {
      selection.wrappedValue = next
    } else {
      selectedSliceID = next
    }
    onSelectionChange?(next)
  }
}

/// A dithered radar chart with one value per datum/spoke and one polygon per series.
public struct DitherRadarChart: View {
  @Environment(\.locale) private var locale
  @State private var hoverAxisIndex: Int?
  @State private var selectedSeriesID: String?

  let data: [DitherDatum]
  let series: [DitherSeries]
  let options: DitherPolarOptions
  let selection: Binding<String?>?
  let onHoverChange: ((Int?) -> Void)?
  let onSelectionChange: ((String?) -> Void)?

  /// Creates a radar chart.
  ///
  /// - Parameters:
  ///   - data: Spokes and values to draw.
  ///   - series: Visual configuration for each polygon.
  ///   - options: Layout, formatting, motion, and interaction options.
  ///   - selection: A binding to the selected series ID.
  ///   - defaultSelectedSeriesID: The initial selection when `selection` is omitted.
  ///   - onHoverChange: Called with the spoke index under the pointer, or `nil`.
  ///   - onSelectionChange: Called when the selected series ID changes.
  public init(
    data: [DitherDatum],
    series: [DitherSeries],
    options: DitherPolarOptions = DitherPolarOptions(),
    selection: Binding<String?>? = nil,
    defaultSelectedSeriesID: String? = nil,
    onHoverChange: ((Int?) -> Void)? = nil,
    onSelectionChange: ((String?) -> Void)? = nil
  ) {
    self.data = data
    self.series = series
    self.options = options
    self.selection = selection
    self.onHoverChange = onHoverChange
    self.onSelectionChange = onSelectionChange
    _hoverAxisIndex = State(initialValue: nil)
    _selectedSeriesID = State(
      initialValue: selection == nil ? defaultSelectedSeriesID : selection?.wrappedValue
    )
  }

  public var body: some View {
    VStack(spacing: 6) {
      DitherRadarPlot(
        data: data,
        series: series,
        options: options,
        selectedSeriesID: effectiveSelection,
        hoverAxisIndex: $hoverAxisIndex,
        onHoverChange: onHoverChange
      )
      if options.showsLegend, !series.isEmpty {
        DitherLegend(
          entries: series.map {
            DitherLegendEntry(id: $0.id, label: $0.label, color: $0.color)
          },
          selectedID: effectiveSelection,
          onSelect: selectSeries
        )
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(
      Text(
        verbatim: options.accessibility.title
          ?? "Radar chart with \(data.count) axes and \(series.count) series"
      )
    )
    .accessibilityChartDescriptor(
      DitherRadarChartDescriptor(
        data: data,
        series: series,
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

  private func selectSeries(_ id: String) {
    setSelection(effectiveSelection == id ? nil : id)
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

private struct DitherPiePlot: View {
  @Environment(\.locale) private var locale

  let slices: [DitherSlice]
  let innerRadiusRatio: Double
  let options: DitherPolarOptions
  let selectedSliceID: String?
  @Binding var hoverIndex: Int?
  let onHoverChange: ((Int?) -> Void)?
  let onSelectIndex: (Int) -> Void

  var body: some View {
    GeometryReader { proxy in
      let plotRect = makePlotRect(in: proxy.size)
      let input = DitherPieRenderInput(
        slices: slices,
        size: plotRect.size,
        innerRadiusRatio: innerRadiusRatio,
        selectedSliceID: selectedSliceID,
        hoverIndex: hoverIndex,
        highlighted: hoverIndex != nil
      )
      ZStack(alignment: .topLeading) {
        DitherAsyncRaster(
          request: .pie(input),
          size: plotRect.size,
          bloom: options.bloom,
          revealStyle: .angular,
          animate: options.animate,
          animationDuration: options.animationDuration,
          transitionKey: DitherTransitionKey.pie(
            slices: slices,
            selectedSliceID: selectedSliceID
          ),
          replayToken: options.replayToken
        )
        .position(x: plotRect.midX, y: plotRect.midY)

        if options.interactive, !slices.isEmpty {
          DitherPieInteractionLayer(
            slices: slices,
            innerRadiusRatio: innerRadiusRatio,
            plotSize: plotRect.size,
            hoverIndex: $hoverIndex,
            onHoverChange: onHoverChange,
            onSelectIndex: onSelectIndex
          )
          .frame(width: plotRect.width, height: plotRect.height)
          .position(x: plotRect.midX, y: plotRect.midY)
        }

        if options.showsTooltip,
          let index = hoverIndex,
          slices.indices.contains(index)
        {
          DitherTooltip(
            heading: slices[index].label,
            items: [
              DitherTooltipItem(
                id: slices[index].id,
                label: slices[index].label,
                value: slices[index].value,
                color: slices[index].color
              )
            ],
            valueFormat: options.valueFormat,
            locale: locale
          )
          .position(tooltipPosition(index: index, plotRect: plotRect, container: proxy.size))
          .transition(.scale(scale: 0.98, anchor: .bottom).combined(with: .opacity))
        }
      }
      .animation(DitherMotion.feedback, value: hoverIndex != nil)
    }
  }

  private func makePlotRect(in size: CGSize) -> CGRect {
    CGRect(
      x: options.margins.leading,
      y: options.margins.top,
      width: max(0, size.width - options.margins.leading - options.margins.trailing),
      height: max(0, size.height - options.margins.top - options.margins.bottom)
    )
  }

  private func tooltipPosition(index: Int, plotRect: CGRect, container: CGSize) -> CGPoint {
    let geometry = DitherPieGeometry(slices)
    guard geometry.slices.indices.contains(index) else {
      return CGPoint(x: container.width / 2, y: 48)
    }
    let angle = geometry.slices[index].middle
    let radius = min(plotRect.width, plotRect.height) * 0.24
    let rawX = plotRect.midX + cos(angle) * radius
    let rawY = plotRect.midY + sin(angle) * radius
    return CGPoint(
      x: min(max(80, rawX), max(80, container.width - 80)),
      y: min(max(42, rawY), max(42, container.height - 42))
    )
  }
}

private struct DitherRadarPlot: View {
  @Environment(\.locale) private var locale

  let data: [DitherDatum]
  let series: [DitherSeries]
  let options: DitherPolarOptions
  let selectedSeriesID: String?
  @Binding var hoverAxisIndex: Int?
  let onHoverChange: ((Int?) -> Void)?

  var body: some View {
    GeometryReader { proxy in
      let plotRect = makePlotRect(in: proxy.size)
      let input = DitherRadarRenderInput(
        data: data,
        series: series,
        size: plotRect.size,
        selectedSeriesID: selectedSeriesID,
        hoverAxisIndex: hoverAxisIndex,
        highlighted: hoverAxisIndex != nil
      )
      ZStack(alignment: .topLeading) {
        DitherRadarFrame(data: data, size: plotRect.size)
          .position(x: plotRect.midX, y: plotRect.midY)
        DitherAsyncRaster(
          request: .radar(input),
          size: plotRect.size,
          bloom: options.bloom,
          revealStyle: .radial,
          animate: options.animate,
          animationDuration: options.animationDuration,
          transitionKey: DitherTransitionKey.radar(
            data: data,
            series: series,
            selectedSeriesID: selectedSeriesID
          ),
          replayToken: options.replayToken
        )
        .position(x: plotRect.midX, y: plotRect.midY)

        if options.interactive, data.count >= 3 {
          DitherRadarInteractionLayer(
            axisCount: data.count,
            plotSize: plotRect.size,
            hoverAxisIndex: $hoverAxisIndex,
            onHoverChange: onHoverChange
          )
          .frame(width: plotRect.width, height: plotRect.height)
          .position(x: plotRect.midX, y: plotRect.midY)
        }

        if options.showsTooltip,
          let index = hoverAxisIndex,
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
            x: min(max(80, proxy.size.width / 2), max(80, proxy.size.width - 80)),
            y: 48
          )
          .transition(.scale(scale: 0.98, anchor: .bottom).combined(with: .opacity))
        }
      }
      .animation(DitherMotion.feedback, value: hoverAxisIndex != nil)
    }
  }

  private func makePlotRect(in size: CGSize) -> CGRect {
    CGRect(
      x: options.margins.leading,
      y: options.margins.top,
      width: max(0, size.width - options.margins.leading - options.margins.trailing),
      height: max(0, size.height - options.margins.top - options.margins.bottom)
    )
  }
}

private struct DitherPieInteractionLayer: View {
  let slices: [DitherSlice]
  let innerRadiusRatio: Double
  let plotSize: CGSize
  @Binding var hoverIndex: Int?
  let onHoverChange: ((Int?) -> Void)?
  let onSelectIndex: (Int) -> Void

  var body: some View {
    #if os(tvOS)
      Rectangle()
        .fill(Color.clear)
        .allowsHitTesting(false)
    #else
      Rectangle()
        .fill(Color.clear)
        .contentShape(Rectangle())
        .gesture(
          DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in update(location: value.location) }
            .onEnded { _ in update(index: nil) }
        )
        .simultaneousGesture(
          SpatialTapGesture(coordinateSpace: .local)
            .onEnded { value in
              if let index = index(at: value.location) {
                onSelectIndex(index)
              }
            }
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
    update(index: index(at: location))
  }

  private func index(at location: CGPoint) -> Int? {
    let center = CGPoint(x: plotSize.width / 2, y: plotSize.height / 2)
    let radius = hypot(location.x - center.x, location.y - center.y)
    let renderedOuter = min(plotSize.width, plotSize.height) * 0.43
    let hitOuter = renderedOuter + 6
    let inner = renderedOuter * CGFloat(min(0.9, max(0, innerRadiusRatio)))
    guard radius >= inner, radius <= hitOuter else { return nil }
    return DitherPieGeometry(slices).index(
      at: atan2(Double(location.y - center.y), Double(location.x - center.x))
    )
  }

  private func update(index: Int?) {
    guard hoverIndex != index else { return }
    hoverIndex = index
    onHoverChange?(index)
  }
}

private struct DitherRadarInteractionLayer: View {
  let axisCount: Int
  let plotSize: CGSize
  @Binding var hoverAxisIndex: Int?
  let onHoverChange: ((Int?) -> Void)?

  var body: some View {
    #if os(tvOS)
      Rectangle()
        .fill(Color.clear)
        .allowsHitTesting(false)
    #else
      Rectangle()
        .fill(Color.clear)
        .contentShape(Rectangle())
        .gesture(
          DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in update(location: value.location) }
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
    let center = CGPoint(x: plotSize.width / 2, y: plotSize.height / 2)
    let radius = hypot(location.x - center.x, location.y - center.y)
    guard radius <= min(plotSize.width, plotSize.height) * 0.48 else {
      update(index: nil)
      return
    }
    let angle = DitherGeometry.normalizedAngle(
      atan2(Double(location.y - center.y), Double(location.x - center.x))
    )
    let top = -Double.pi / 2
    let fraction = (angle - top) / (Double.pi * 2)
    let index = Int((fraction * Double(axisCount)).rounded()) % axisCount
    update(index: index)
  }

  private func update(index: Int?) {
    guard hoverAxisIndex != index else { return }
    hoverAxisIndex = index
    onHoverChange?(index)
  }
}

private struct DitherRadarLabel: Identifiable {
  let id: String
  let label: String
  let angle: Double
}

private struct DitherRadarFrame: View {
  let data: [DitherDatum]
  let size: CGSize

  var body: some View {
    ZStack {
      Canvas { context, _ in
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) * 0.39
        let stroke = GraphicsContext.Shading.color(Color.secondary.opacity(0.22))
        guard data.count >= 3 else { return }
        for ring in 1...4 {
          let ringRadius = radius * CGFloat(ring) / 4
          var polygon = Path()
          for index in data.indices {
            let point = polarPoint(index: index, radius: ringRadius, center: center)
            if index == data.startIndex {
              polygon.move(to: point)
            } else {
              polygon.addLine(to: point)
            }
          }
          polygon.closeSubpath()
          context.stroke(polygon, with: stroke, lineWidth: 0.7)
        }
        for index in data.indices {
          var spoke = Path()
          spoke.move(to: center)
          spoke.addLine(to: polarPoint(index: index, radius: radius, center: center))
          context.stroke(spoke, with: stroke, lineWidth: 0.6)
        }
      }
      ForEach(labels) { label in
        Text(verbatim: label.label)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .position(labelPosition(angle: label.angle))
      }
    }
    .frame(width: size.width, height: size.height)
    .accessibilityHidden(true)
  }

  private var labels: [DitherRadarLabel] {
    data.enumerated().map { index, datum in
      DitherRadarLabel(
        id: datum.id,
        label: datum.label,
        angle: -Double.pi / 2 + Double(index) / Double(max(data.count, 1)) * Double.pi * 2
      )
    }
  }

  private func polarPoint(index: Int, radius: CGFloat, center: CGPoint) -> CGPoint {
    let angle = -Double.pi / 2 + Double(index) / Double(max(data.count, 1)) * Double.pi * 2
    return CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
  }

  private func labelPosition(angle: Double) -> CGPoint {
    let radius = min(size.width, size.height) * 0.46
    return CGPoint(
      x: size.width / 2 + cos(angle) * radius,
      y: size.height / 2 + sin(angle) * radius
    )
  }
}
