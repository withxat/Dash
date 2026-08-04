import Charts
import Foundation
import SwiftDitherKit
import SwiftUI

// MARK: - Style preference

/// Chart renderer (Settings → General). Default is Dash's dithered charts;
/// `system` is the stock Swift Charts look.
enum DashChartStylePreference: String, CaseIterable, Identifiable, Sendable {
  case dither
  case system

  static let storageKey = DashWidgetBridges.chartStyleKey
  static let defaultStyle = DashChartStylePreference.dither

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .dither: DashL10n.string("Dither")
    case .system: DashL10n.string("Swift Charts")
    }
  }

  static func resolved(stored raw: String) -> DashChartStylePreference {
    DashChartStylePreference(rawValue: raw) ?? defaultStyle
  }

  static var current: DashChartStylePreference {
    resolved(
      stored: UserDefaults.standard.string(forKey: storageKey) ?? defaultStyle.rawValue)
  }

  /// Push the in-app choice into the App Group so metrics widgets can follow
  /// Settings → Chart style, then wake their timelines.
  static func mirrorToWidgets(_ raw: String? = nil) {
    let value = raw ?? (UserDefaults.standard.string(forKey: storageKey) ?? defaultStyle.rawValue)
    DashWidgetBridges.mirrorChartStyle(value)
    DashWidgetBridges.reloadMetricsWidgets()
  }
}

// MARK: - Style-aware wrappers

/// Area chart that follows Settings → Chart style.
struct DashAreaChart: View {
  @AppStorage(DashChartStylePreference.storageKey) private var styleRaw =
    DashChartStylePreference.defaultStyle.rawValue

  let data: [DitherDatum]
  let series: [DitherSeries]
  let options: DitherCartesianOptions
  var highlighted = false
  var selection: Binding<String?>? = nil
  var onHoverChange: ((Int?) -> Void)? = nil
  var onTap: (() -> Void)? = nil

  private var style: DashChartStylePreference {
    DashChartStylePreference.resolved(stored: styleRaw)
  }

  var body: some View {
    switch style {
    case .dither:
      DitherAreaChart(
        data: data,
        series: series,
        options: options,
        highlighted: highlighted,
        selection: selection,
        onHoverChange: onHoverChange,
        onTap: onTap)
    case .system:
      DashSystemCartesianChart(
        kind: .area,
        data: data,
        series: series,
        options: options,
        onHoverChange: onHoverChange,
        onTap: onTap)
    }
  }
}

/// Line chart that follows Settings → Chart style.
struct DashLineChart: View {
  @AppStorage(DashChartStylePreference.storageKey) private var styleRaw =
    DashChartStylePreference.defaultStyle.rawValue

  let data: [DitherDatum]
  let series: [DitherSeries]
  let options: DitherCartesianOptions
  var highlighted = false
  var selection: Binding<String?>? = nil
  var onHoverChange: ((Int?) -> Void)? = nil
  var onTap: (() -> Void)? = nil

  private var style: DashChartStylePreference {
    DashChartStylePreference.resolved(stored: styleRaw)
  }

  var body: some View {
    switch style {
    case .dither:
      DitherLineChart(
        data: data,
        series: series,
        options: options,
        highlighted: highlighted,
        selection: selection,
        onHoverChange: onHoverChange,
        onTap: onTap)
    case .system:
      DashSystemCartesianChart(
        kind: .line,
        data: data,
        series: series,
        options: options,
        onHoverChange: onHoverChange,
        onTap: onTap)
    }
  }
}

/// Pie / donut chart that follows Settings → Chart style.
struct DashPieChart: View {
  @AppStorage(DashChartStylePreference.storageKey) private var styleRaw =
    DashChartStylePreference.defaultStyle.rawValue

  let slices: [DitherSlice]
  var innerRadiusRatio: Double = 0.62
  let options: DitherPolarOptions
  var selection: Binding<String?>? = nil

  private var style: DashChartStylePreference {
    DashChartStylePreference.resolved(stored: styleRaw)
  }

  var body: some View {
    switch style {
    case .dither:
      DitherPieChart(
        slices: slices,
        innerRadiusRatio: innerRadiusRatio,
        options: options,
        selection: selection)
    case .system:
      DashSystemPieChart(
        slices: slices,
        innerRadiusRatio: innerRadiusRatio,
        options: options,
        selection: selection)
    }
  }
}

// MARK: - Swift Charts renderers

private enum DashSystemCartesianKind {
  case area
  case line
}

private struct DashSystemPlotPoint: Identifiable {
  let id: String
  let index: Int
  let label: String
  let seriesID: String
  let seriesLabel: String
  let value: Double
  let color: Color
}

private struct DashSystemCartesianChart: View {
  let kind: DashSystemCartesianKind
  let data: [DitherDatum]
  let series: [DitherSeries]
  let options: DitherCartesianOptions
  var onHoverChange: ((Int?) -> Void)? = nil
  var onTap: (() -> Void)? = nil

  @Environment(\.locale) private var locale
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var selectedIndex: Int?
  /// Measured tooltip size; positioning falls back to a short single-series
  /// guess until the first preference pass lands.
  @State private var tooltipSize = CGSize(width: 160, height: 52)

  private var points: [DashSystemPlotPoint] {
    data.enumerated().flatMap { index, datum in
      series.map { series in
        DashSystemPlotPoint(
          id: "\(datum.id)-\(series.id)",
          index: index,
          label: datum.label,
          seriesID: series.id,
          seriesLabel: series.label,
          value: datum[series.id],
          color: Color(dither: series.color))
      }
    }
  }

  private var yDomain: ClosedRange<Double>? {
    if let ceiling = options.valueCeiling, ceiling > 0 {
      return 0...ceiling
    }
    return nil
  }

  private var xSelection: Binding<Int?> {
    Binding(
      get: { options.interactive ? selectedIndex : nil },
      set: { newValue in
        guard options.interactive else { return }
        selectedIndex = newValue
        onHoverChange?(newValue)
      })
  }

  var body: some View {
    chartContent
      .chartLegend(options.showsLegend ? .automatic : .hidden)
      .chartXScale(domain: 0...max(0, data.count - 1))
      .modifier(
        DashSystemChartAxisModifier(
          showsAxes: options.showsAxes,
          axisIndices: axisIndices,
          labels: data.map(\.label))
      )
      .modifier(DashSystemChartScaleModifier(domain: yDomain))
      .modifier(
        DashSystemChartSelectionModifier(
          isEnabled: options.interactive,
          selection: xSelection)
      )
      .modifier(DashSystemChartTapModifier(onTap: options.interactive ? nil : onTap))
      // Sparkline-only headroom — see `CollapsedSystemChartPlotMetrics`.
      .chartPlotStyle { plotArea in
        let inset = CollapsedSystemChartPlotMetrics.plotStyleTopInset(
          showsAxes: options.showsAxes,
          existingTop: options.margins.top)
        if inset > 0 {
          plotArea.padding(.top, inset)
        } else {
          plotArea
        }
      }
      .padding(.leading, options.showsAxes ? max(0, options.margins.leading - 38) : 0)
      // Last, so the bubble is clamped against the chart as it finally lays out
      // — including the axis gutter it is allowed to cover.
      .chartOverlay { proxy in
        GeometryReader { geometry in
          tooltip(proxy: proxy, geometry: geometry)
        }
        .allowsHitTesting(false)
        .animation(reduceMotion ? nil : DashTheme.Motion.quick, value: selectedIndex)
      }
      .onPreferenceChange(DitherTooltipSizeKey.self) { size in
        guard size.width > 0, size.height > 0 else { return }
        tooltipSize = size
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(options.accessibility.title ?? "")
      .accessibilityValue(options.accessibility.summary ?? "")
  }

  private var chartContent: some View {
    Chart(points) { point in
      switch kind {
      case .area:
        AreaMark(
          x: .value("Category", point.index),
          y: .value("Value", point.value),
          series: .value("Series", point.seriesID)
        )
        .foregroundStyle(
          LinearGradient(
            colors: [point.color.opacity(0.35), point.color.opacity(0.05)],
            startPoint: .top,
            endPoint: .bottom)
        )
        .interpolationMethod(.catmullRom)
        LineMark(
          x: .value("Category", point.index),
          y: .value("Value", point.value),
          series: .value("Series", point.seriesID)
        )
        .foregroundStyle(point.color)
        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        .interpolationMethod(.catmullRom)
      case .line:
        LineMark(
          x: .value("Category", point.index),
          y: .value("Value", point.value),
          series: .value("Series", point.seriesID)
        )
        .foregroundStyle(point.color)
        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        .interpolationMethod(.catmullRom)
        if options.showsAxes {
          PointMark(
            x: .value("Category", point.index),
            y: .value("Value", point.value)
          )
          .foregroundStyle(point.color)
          .symbolSize(24)
        }
      }

      // Marks only. The bubble itself is `DitherTooltip`, floated over the whole
      // chart in `tooltip(proxy:geometry:)` — a Swift Charts annotation can only
      // resolve its overflow against the plot it belongs to, which is how the
      // value capsule ended up hanging past the page margin. Off the marks
      // entirely, it also stops being something the value scale can pad around:
      // that default rescaled the plot the moment a scrub reached the top of the
      // series, dropping the line away under the finger.
      if let selectedIndex, selectedIndex == point.index, options.showsTooltip {
        if point.seriesID == series.first?.id {
          RuleMark(x: .value("Category", point.index))
            .foregroundStyle(DashTheme.separator)
            .lineStyle(StrokeStyle(lineWidth: 1))
            .zIndex(-1)
        }
        PointMark(
          x: .value("Category", point.index),
          y: .value("Value", point.value)
        )
        .foregroundStyle(point.color)
        .symbolSize(48)
      }
    }
  }

  /// The same tooltip the dithered charts show, over the same chart-wide
  /// container: heading, one row per series, values in the chart's own format —
  /// and `DitherTooltipPlacement` keeping all of it inside the chart's bounds.
  @ViewBuilder
  private func tooltip(proxy: ChartProxy, geometry: GeometryProxy) -> some View {
    if options.showsTooltip,
      let index = selectedIndex,
      data.indices.contains(index),
      let plotFrame = proxy.plotFrame
    {
      let plot = geometry[plotFrame]
      // Above the tallest series at that category, matching the dithered plot's
      // own marker — a bubble anchored to one series would sit under the line
      // of another.
      let peak = series.map { data[index][$0.id] }.max() ?? 0
      DitherTooltip(
        heading: data[index].label,
        items: series.map { item in
          DitherTooltipItem(
            id: item.id,
            label: item.label,
            value: data[index][item.id],
            color: item.color)
        },
        valueFormat: options.valueFormat,
        locale: locale
      )
      .position(
        DitherTooltipPlacement.center(
          markX: plot.minX + (proxy.position(forX: index) ?? plot.width / 2),
          markY: plot.minY + (proxy.position(forY: peak) ?? 0),
          container: geometry.size,
          tooltipSize: tooltipSize)
      )
      .transition(.scale(scale: 0.98, anchor: .bottom).combined(with: .opacity))
    }
  }

  private var axisIndices: [Int] {
    guard !data.isEmpty else { return [] }
    if data.count <= 6 { return Array(data.indices) }
    let step = max(1, (data.count - 1) / 4)
    var indices = Array(stride(from: 0, to: data.count, by: step))
    if indices.last != data.count - 1 {
      indices.append(data.count - 1)
    }
    return indices
  }
}

private struct DashSystemChartAxisModifier: ViewModifier {
  let showsAxes: Bool
  let axisIndices: [Int]
  let labels: [String]

  @ViewBuilder
  func body(content: Content) -> some View {
    if showsAxes {
      content
        .chartXAxis {
          AxisMarks(values: axisIndices) { value in
            AxisGridLine()
            AxisValueLabel {
              if let index = value.as(Int.self), labels.indices.contains(index) {
                Text(verbatim: labels[index])
                  .dashTextStyle(.caption)
              }
            }
          }
        }
        .chartYAxis {
          AxisMarks(position: .leading) { _ in
            AxisGridLine()
            AxisValueLabel()
          }
        }
    } else {
      content
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
    }
  }
}

private struct DashSystemChartScaleModifier: ViewModifier {
  let domain: ClosedRange<Double>?

  @ViewBuilder
  func body(content: Content) -> some View {
    if let domain {
      content.chartYScale(domain: domain)
    } else {
      content
    }
  }
}

private struct DashSystemChartSelectionModifier: ViewModifier {
  let isEnabled: Bool
  let selection: Binding<Int?>

  @ViewBuilder
  func body(content: Content) -> some View {
    if isEnabled {
      content.chartXSelection(value: selection)
    } else {
      content
    }
  }
}

private struct DashSystemChartTapModifier: ViewModifier {
  let onTap: (() -> Void)?

  @ViewBuilder
  func body(content: Content) -> some View {
    if let onTap {
      content.onTapGesture(perform: onTap)
    } else {
      content
    }
  }
}

private struct DashSystemPieChart: View {
  let slices: [DitherSlice]
  let innerRadiusRatio: Double
  let options: DitherPolarOptions
  var selection: Binding<String?>? = nil

  /// Same stack as `DitherPieChart`: plot over a tappable legend. A `SectorMark`
  /// styled by a resolved color rather than `by:` produces no Swift Charts
  /// legend at all, so the donut Dash uses as a filter shipped without the
  /// control that names its slices — the plot alone can only be aimed at.
  var body: some View {
    VStack(spacing: 6) {
      chart
      if options.showsLegend, !slices.isEmpty {
        DashSystemChartLegend(
          entries: slices.map {
            DashSystemLegendEntry(id: $0.id, label: $0.label, color: Color(dither: $0.color))
          },
          selectedID: selection?.wrappedValue,
          onSelect: select(id:))
      }
    }
    .accessibilityElement(children: .contain)
    // A selection naming a slice the data no longer carries would filter the
    // list below down to nothing with no way back, so it clears itself — the
    // same guarantee `DitherPieChart` makes, which is what lets Load more widen
    // the data without the screen resetting its own filter.
    .onChange(of: slices.map(\.id), initial: true) { _, ids in
      guard let selection, let selected = selection.wrappedValue, !ids.contains(selected) else {
        return
      }
      selection.wrappedValue = nil
    }
  }

  private var chart: some View {
    Chart(slices) { slice in
      SectorMark(
        angle: .value(slice.label, max(0, slice.value)),
        innerRadius: .ratio(min(max(innerRadiusRatio, 0), 0.9)),
        angularInset: 1.5
      )
      .foregroundStyle(Color(dither: slice.color))
      .opacity(selectionOpacity(for: slice.id))
      .cornerRadius(3)
    }
    .chartLegend(.hidden)
    .chartBackground { _ in Color.clear }
    .chartAngleSelection(value: selectionAngleBinding)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(options.accessibility.title ?? "")
    .accessibilityValue(options.accessibility.summary ?? "")
  }

  /// Legend taps toggle, so the entry that engaged a filter also clears it.
  /// Sector taps only ever select: `chartAngleSelection` keeps writing while a
  /// finger moves across the donut, and a toggle there would flicker the filter
  /// on and off under the same gesture.
  private func select(id: String) {
    guard let selection else { return }
    selection.wrappedValue = selection.wrappedValue == id ? nil : id
  }

  private func selectionOpacity(for id: String) -> Double {
    guard let selected = selection?.wrappedValue else { return 1 }
    return selected == id ? 1 : 0.35
  }

  private var selectionAngleBinding: Binding<Double?> {
    Binding(
      get: {
        guard let selectedID = selection?.wrappedValue,
          let slice = slices.first(where: { $0.id == selectedID })
        else { return nil }
        return max(0, slice.value)
      },
      set: { newValue in
        guard let selection else { return }
        guard let newValue else {
          selection.wrappedValue = nil
          return
        }
        // Nearest slice by absolute value — angle selection hands back the
        // sector's value, not its id.
        let match = slices.min {
          abs(max(0, $0.value) - newValue) < abs(max(0, $1.value) - newValue)
        }
        selection.wrappedValue = match?.id
      })
  }
}

private struct DashSystemLegendEntry: Identifiable, Hashable {
  let id: String
  let label: String
  let color: Color
}

/// The Swift Charts counterpart to `DitherLegend`: one chip per slice, the
/// selected chip lit and the rest dimmed, laid out in a row that scrolls
/// sideways only when the labels stop fitting.
private struct DashSystemChartLegend: View {
  let entries: [DashSystemLegendEntry]
  let selectedID: String?
  let onSelect: (String) -> Void

  var body: some View {
    ViewThatFits(in: .horizontal) {
      row
      ScrollView(.horizontal) {
        row
          .padding(.horizontal, 2)
      }
      .scrollIndicators(.hidden)
    }
    .frame(minHeight: DashTheme.Layout.minimumHitTarget)
  }

  private var row: some View {
    HStack(spacing: 8) {
      ForEach(entries) { entry in
        Button {
          onSelect(entry.id)
        } label: {
          HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
              .fill(entry.color)
              .frame(width: 10, height: 10)
              .accessibilityHidden(true)
            Text(verbatim: entry.label)
              .dashTextStyle(.caption)
              .foregroundStyle(DashTheme.text)
              .lineLimit(1)
          }
          .padding(.horizontal, 8)
          .padding(.vertical, 5)
          .background(
            isLit(entry.id) ? DashTheme.recessed : Color.clear,
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
          )
          .opacity(isLit(entry.id) ? 1 : 0.45)
          .frame(minHeight: DashTheme.Layout.minimumHitTarget)
          .contentShape(Rectangle())
        }
        // A legend chip is a small text action, not a row or a card, so it
        // takes the press shrink.
        .buttonStyle(DashPressButtonStyle())
        .accessibilityLabel(
          selectedID == entry.id
            ? DashL10n.string("Deselect \(entry.label)")
            : DashL10n.string("Select \(entry.label)")
        )
        .accessibilityValue(
          selectedID == entry.id ? DashL10n.ui("Selected") : DashL10n.ui("Not selected")
        )
        .accessibilityAddTraits(selectedID == entry.id ? .isSelected : [])
      }
    }
  }

  /// Nothing selected reads as "all of it", so every chip stays lit until one
  /// of them owns the filter.
  private func isLit(_ id: String) -> Bool {
    selectedID == nil || selectedID == id
  }
}
