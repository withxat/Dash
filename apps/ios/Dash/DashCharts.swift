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

  @State private var selectedIndex: Int?

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
      .padding(.leading, options.showsAxes ? max(0, options.margins.leading - 38) : 0)
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

      if let selectedIndex, selectedIndex == point.index, options.showsTooltip {
        RuleMark(x: .value("Category", point.index))
          .foregroundStyle(DashTheme.separator)
          .lineStyle(StrokeStyle(lineWidth: 1))
          .zIndex(-1)
        if point.seriesID == series.first?.id {
          PointMark(
            x: .value("Category", point.index),
            y: .value("Value", point.value)
          )
          .foregroundStyle(point.color)
          .symbolSize(48)
          .annotation(position: .top, spacing: 6) {
            Text(
              verbatim: point.value.formatted(
                .number
                  .notation(.compactName)
                  .precision(.fractionLength(0...1))
                  .locale(DashL10n.activeLocale))
            )
            .dashTextStyle(.captionSemibold)
            .monospacedDigit()
            .foregroundStyle(DashTheme.strong)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(DashTheme.homeCardSurface, in: Capsule())
          }
        }
      }
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

  var body: some View {
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
    .chartLegend(options.showsLegend ? .automatic : .hidden)
    .chartBackground { _ in Color.clear }
    .chartAngleSelection(value: selectionAngleBinding)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(options.accessibility.title ?? "")
    .accessibilityValue(options.accessibility.summary ?? "")
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
