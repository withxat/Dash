import Foundation
import SwiftDitherKit
import SwiftUI

/// A period-over-period change calculated from the values already loaded for
/// a chart. Direction is always numeric; polarity only decides whether that
/// direction is good, bad, or deliberately neutral in the presentation.
struct DashChartTrend: Hashable, Sendable {
  enum Direction: Hashable, Sendable {
    case up
    case down
    case flat
  }

  enum Polarity: Hashable, Sendable {
    case neutral
    case higherIsBetter
    case lowerIsBetter
  }

  let direction: Direction
  let percentChange: Double?
  let polarity: Polarity

  /// Returns nil when there is no comparable period or either input is not
  /// finite. A zero baseline has no meaningful percentage unless both periods
  /// are zero, so presentation omits the comparison text in that case.
  init?(
    current: Double,
    previous: Double?,
    polarity: Polarity = .neutral
  ) {
    guard current.isFinite, let previous, previous.isFinite else { return nil }

    if current > previous {
      direction = .up
    } else if current < previous {
      direction = .down
    } else {
      direction = .flat
    }
    self.polarity = polarity

    if previous == 0 {
      percentChange = current == 0 ? 0 : nil
    } else {
      let comparison = (current - previous) / abs(previous)
      percentChange = comparison.isFinite ? comparison : nil
    }
  }
}

/// Formatting shared by the expanded Dither chart and its exact-value table.
/// Axes may use a compact format while the table keeps the unabridged value.
enum DashChartValueFormat: Hashable, Sendable {
  case number(maximumFractionDigits: Int = 2)
  case compact
  /// Foundation convention: `1` represents one hundred percent.
  case percent(maximumFractionDigits: Int = 1)
  case byteCount
  case milliseconds(maximumFractionDigits: Int = 1)

  var ditherValueFormat: DitherValueFormat {
    switch self {
    case .number(let maximumFractionDigits):
      .number(maximumFractionDigits: maximumFractionDigits)
    case .compact:
      .compact
    case .percent(let maximumFractionDigits):
      .percent(maximumFractionDigits: maximumFractionDigits)
    case .byteCount:
      .byteCount(style: .binary)
    case .milliseconds(let maximumFractionDigits):
      .number(maximumFractionDigits: maximumFractionDigits)
    }
  }

  func tableString(
    _ value: Double,
    locale: Locale = DashL10n.activeLocale
  ) -> String {
    let finiteValue = value.isFinite ? value : 0
    switch self {
    case .number(let maximumFractionDigits):
      return finiteValue.formatted(
        .number
          .precision(.fractionLength(0...max(0, maximumFractionDigits)))
          .locale(locale))
    case .compact:
      return finiteValue.formatted(
        .number
          .notation(.compactName)
          .precision(.fractionLength(0...1))
          .locale(locale))
    case .percent(let maximumFractionDigits):
      return finiteValue.formatted(
        .percent
          .precision(.fractionLength(0...max(0, maximumFractionDigits)))
          .locale(locale))
    case .byteCount:
      let bytes = Int64(min(max(finiteValue.rounded(), -9e18), 9e18))
      return bytes.formatted(.byteCount(style: .binary).locale(locale))
    case .milliseconds(let maximumFractionDigits):
      let number = finiteValue.formatted(
        .number
          .precision(.fractionLength(0...max(0, maximumFractionDigits)))
          .locale(locale))
      return "\(number) ms"
    }
  }
}

/// A short axis label and the full label used by the detail table, wrapped
/// around the exact Dither datum that was visible when the user tapped.
struct DashChartDataPoint: Hashable, Sendable, Identifiable {
  let datum: DitherDatum
  let tableLabel: String

  var id: String { datum.id }

  init(datum: DitherDatum, tableLabel: String) {
    self.datum = datum
    self.tableLabel = tableLabel
  }

  init(
    id: String,
    label: String,
    tableLabel: String,
    values: [String: Double]
  ) {
    self.init(
      datum: DitherDatum(id: id, label: label, values: values),
      tableLabel: tableLabel)
  }
}

/// A render-ready chart snapshot. It intentionally contains values and visual
/// series rather than a loader so a pushed detail exactly matches its source.
enum DashChartDetailContent: Hashable, Sendable {
  case area(points: [DashChartDataPoint], series: [DitherSeries])
  case line(points: [DashChartDataPoint], series: [DitherSeries])
  case pie(slices: [DitherSlice], innerRadiusRatio: Double = 0.62)
}

struct DashChartDetail: Hashable, Sendable {
  let title: String
  let rangeLabel: String
  let summaryValue: String?
  let trend: DashChartTrend?
  let categoryAxisLabel: String
  let valueAxisLabel: String
  let axisValueFormat: DashChartValueFormat
  let tableValueFormat: DashChartValueFormat
  let accessibilitySummary: String
  let content: DashChartDetailContent
  let featureID: FeatureID?
  let readScopes: Set<String>

  init(
    title: String,
    rangeLabel: String,
    summaryValue: String? = nil,
    trend: DashChartTrend? = nil,
    categoryAxisLabel: String,
    valueAxisLabel: String,
    axisValueFormat: DashChartValueFormat = .compact,
    tableValueFormat: DashChartValueFormat? = nil,
    accessibilitySummary: String,
    content: DashChartDetailContent,
    featureID: FeatureID? = nil,
    readScopes: Set<String> = []
  ) {
    self.title = title
    self.rangeLabel = rangeLabel
    self.summaryValue = summaryValue
    self.trend = trend
    self.categoryAxisLabel = categoryAxisLabel
    self.valueAxisLabel = valueAxisLabel
    self.axisValueFormat = axisValueFormat
    self.tableValueFormat = tableValueFormat ?? axisValueFormat
    self.accessibilitySummary = accessibilitySummary
    self.content = content
    self.featureID = featureID
    self.readScopes = readScopes
  }
}

/// The relative magnitude shown immediately after a chart's primary value. A
/// missing or incomparable prior period renders nothing rather than inventing
/// a zero comparison.
struct DashChartTrendLabel: View {
  let trend: DashChartTrend?

  var body: some View {
    if let trend, let percentage = trend.formattedPercentage {
      Text(verbatim: percentage)
        .dashTextStyle(.captionSemibold)
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .foregroundStyle(trend.foreground)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
          "\(DashL10n.ui("Change")): \(percentage)")
    }
  }
}

/// The only navigation affordance on a chart card. Keeping this as a discrete
/// 44-point button leaves the chart itself free for selection and hold-to-scrub
/// interactions without making the whole card an ambiguous navigation target.
struct DashChartDetailButton: View {
  let detail: DashChartDetail
  var accessibilityIdentifier: String? = nil
  @Environment(\.destinationNavigator) private var navigator

  @ViewBuilder
  var body: some View {
    if let accessibilityIdentifier {
      button
        .accessibilityIdentifier(accessibilityIdentifier)
    } else {
      button
    }
  }

  private var button: some View {
    Button {
      navigator?.push(.chartDetail(detail))
    } label: {
      SolarIcon(
        asset: SolarAsset.chevronRight,
        size: DashTheme.Chevron.compact,
        color: DashTheme.strong
      )
      .frame(width: 32, height: 32)
      .background(DashTheme.recessed, in: Circle())
      .dashCompactHitTarget()
    }
    .buttonStyle(DashPressButtonStyle())
    .accessibilityLabel(
      "\(DashL10n.ui(detail.title)), \(DashL10n.ui("Details"))"
    )
    .accessibilityHint("Shows chart details")
  }
}

struct DashChartDetailView: View {
  let detail: DashChartDetail
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    DashFeatureList {
      summaryCard
      DashListGroupHeader(title: DashL10n.ui("Details"))
        .padding(.horizontal, DashTheme.Spacing.rowInset)
        .dashSectionBoundary()
      dashListCardRows(items: tableRows) { row in
        DashChartTableRow(row: row)
      }
    }
    .detailHeader(
      icon: .solar(SolarAsset.Content.chart),
      title: detail.title)
  }

  private var summaryCard: some View {
    DashGlassCard {
      VStack(alignment: .leading, spacing: DashTheme.Spacing.itemGap) {
        Text(DashL10n.ui(detail.rangeLabel))
          .dashTextStyle(.footnoteSemibold)
          .foregroundStyle(DashTheme.subtle)

        if detail.summaryValue != nil || detail.trend?.formattedPercentage != nil {
          HStack(alignment: .lastTextBaseline, spacing: 8) {
            if let summaryValue = detail.summaryValue {
              Text(verbatim: summaryValue)
                .dashTextStyle(.emptyTitle)
                .monospacedDigit()
                .foregroundStyle(DashTheme.strong)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
            DashChartTrendLabel(trend: detail.trend)
            Spacer(minLength: 4)
          }
        }

        chart
          .frame(height: chartHeight)
      }
    }
  }

  @ViewBuilder
  private var chart: some View {
    switch detail.content {
    case .area(let points, let series):
      DitherAreaChart(
        data: points.map(\.datum),
        series: series,
        options: cartesianOptions(series: series))
    case .line(let points, let series):
      DitherLineChart(
        data: points.map(\.datum),
        series: series,
        options: cartesianOptions(series: series))
    case .pie(let slices, let innerRadiusRatio):
      DitherPieChart(
        slices: slices,
        innerRadiusRatio: innerRadiusRatio,
        options: DitherPolarOptions(
          bloom: .off,
          interactive: true,
          showsLegend: true,
          showsTooltip: true,
          valueFormat: detail.axisValueFormat.ditherValueFormat,
          accessibility: chartAccessibility))
    }
  }

  private func cartesianOptions(series: [DitherSeries]) -> DitherCartesianOptions {
    DashTheme.DitherChart.options(
      showsLegend: series.count > 1,
      accessibility: chartAccessibility,
      valueFormat: detail.axisValueFormat.ditherValueFormat,
      leadingMargin: detail.axisValueFormat.leadingMargin)
  }

  private var chartAccessibility: DitherAccessibility {
    DitherAccessibility(
      title: DashL10n.ui(detail.title),
      summary: detail.accessibilitySummary,
      categoryAxisLabel: DashL10n.ui(detail.categoryAxisLabel),
      valueAxisLabel: DashL10n.ui(detail.valueAxisLabel))
  }

  private var chartHeight: CGFloat {
    let showsLegend =
      switch detail.content {
      case .area(_, let series), .line(_, let series):
        series.count > 1
      case .pie:
        true
      }
    if dynamicTypeSize.isAccessibilitySize {
      return showsLegend ? 340 : 312
    }
    return showsLegend ? 284 : 260
  }

  private var tableRows: [DashChartTableRowModel] {
    switch detail.content {
    case .area(let points, let series), .line(let points, let series):
      return points.map { point in
        DashChartTableRowModel(
          id: point.id,
          label: point.tableLabel,
          values: series.map { series in
            DashChartTableValue(
              id: series.id,
              label: series.label,
              value: detail.tableValueFormat.tableString(point.datum[series.id]),
              color: series.color)
          })
      }
    case .pie(let slices, _):
      return slices.map { slice in
        DashChartTableRowModel(
          id: slice.id,
          label: slice.label,
          values: [
            DashChartTableValue(
              id: slice.id,
              label: detail.valueAxisLabel,
              value: detail.tableValueFormat.tableString(slice.value),
              color: slice.color)
          ])
      }
    }
  }
}

private struct DashChartTableRowModel: Identifiable {
  let id: String
  let label: String
  let values: [DashChartTableValue]
}

private struct DashChartTableValue: Identifiable {
  let id: String
  let label: String
  let value: String
  let color: DitherColor
}

private struct DashChartTableRow: View {
  let row: DashChartTableRowModel
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    Group {
      if dynamicTypeSize.isAccessibilitySize || row.values.count > 2 {
        accessibleLayout
      } else {
        compactLayout
      }
    }
    .padding(.vertical, 12)
    .frame(minHeight: DashTheme.Layout.minimumHitTarget)
    .accessibilityElement(children: .combine)
  }

  private var compactLayout: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(verbatim: row.label)
        .dashTextStyle(.supporting)
        .foregroundStyle(DashTheme.text)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lineLimit(2)
      ForEach(row.values) { value in
        compactValue(value)
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
    }
  }

  private var accessibleLayout: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(verbatim: row.label)
        .dashTextStyle(.supportingMedium)
        .foregroundStyle(DashTheme.text)
      ForEach(row.values) { value in
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          valueLabel(value)
          Spacer(minLength: 8)
          Text(verbatim: value.value)
            .dashTextStyle(.supportingSemibold)
            .monospacedDigit()
            .foregroundStyle(DashTheme.strong)
            .multilineTextAlignment(.trailing)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func compactValue(_ value: DashChartTableValue) -> some View {
    VStack(alignment: .trailing, spacing: 2) {
      valueLabel(value)
      Text(verbatim: value.value)
        .dashTextStyle(.supportingSemibold)
        .monospacedDigit()
        .foregroundStyle(DashTheme.strong)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }
  }

  private func valueLabel(_ value: DashChartTableValue) -> some View {
    HStack(spacing: 4) {
      Circle()
        .fill(Color(dither: value.color))
        .frame(width: 7, height: 7)
        .accessibilityHidden(true)
      Text(verbatim: value.label)
        .dashTextStyle(.caption)
        .foregroundStyle(DashTheme.subtle)
        .lineLimit(1)
    }
  }
}

extension DashChartTrend {
  fileprivate var formattedPercentage: String? {
    guard let percentChange else { return nil }
    let magnitude = abs(percentChange).formatted(
      .percent
        .precision(.fractionLength(0...1))
        .locale(DashL10n.activeLocale))
    switch direction {
    case .up: return "+\(magnitude)"
    case .down: return "−\(magnitude)"
    case .flat: return magnitude
    }
  }

  fileprivate var foreground: Color {
    switch sentiment {
    case .positive: DashTheme.success
    case .negative: DashTheme.danger
    case .neutral: DashTheme.subtle
    }
  }

  private var sentiment: DashChartTrendSentiment {
    switch (polarity, direction) {
    case (.higherIsBetter, .up), (.lowerIsBetter, .down):
      .positive
    case (.higherIsBetter, .down), (.lowerIsBetter, .up):
      .negative
    case (.neutral, _), (_, .flat):
      .neutral
    }
  }
}

private enum DashChartTrendSentiment {
  case positive
  case negative
  case neutral
}

extension DashChartValueFormat {
  fileprivate var leadingMargin: CGFloat {
    switch self {
    case .byteCount:
      58
    case .milliseconds:
      50
    case .number, .compact, .percent:
      42
    }
  }
}
