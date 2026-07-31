import Foundation
import SwiftDitherKit
import SwiftUI

/// A period-over-period change calculated from the values already loaded for
/// a chart. Direction is always numeric. Polarity preserves whether higher or
/// lower is favorable as metric metadata; the visible red / green convention
/// follows the active language instead.
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

enum DashChartTrendColorConvention: Hashable, Sendable {
  case redUpGreenDown
  case greenUpRedDown

  static func resolved(locale: Locale) -> Self {
    locale.language.languageCode?.identifier == "zh"
      ? .redUpGreenDown
      : .greenUpRedDown
  }

  fileprivate func foreground(for direction: DashChartTrend.Direction) -> Color {
    switch (self, direction) {
    case (_, .flat):
      DashTheme.subtle
    case (.redUpGreenDown, .up), (.greenUpRedDown, .down):
      DashTheme.danger
    case (.redUpGreenDown, .down), (.greenUpRedDown, .up):
      DashTheme.success
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

/// One time-range payload inside a chart detail. Shared title / axis formats
/// live on `DashChartDetail`; this carries only what changes with the tab.
struct DashChartDetailRange: Hashable, Sendable {
  let range: AnalyticsRange
  let rangeLabel: String
  let summaryValue: String?
  let trend: DashChartTrend?
  let categoryAxisLabel: String
  let accessibilitySummary: String
  let content: DashChartDetailContent
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
  /// When two or more, the detail screen shows time tabs. Empty means a single
  /// frozen snapshot (pie charts, worker 24h, etc.).
  let ranges: [DashChartDetailRange]
  /// Initial tab when `ranges` is non-empty — matches the outer screen's
  /// current time dimension at the moment of the push.
  let selectedRange: AnalyticsRange?

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
    readScopes: Set<String> = [],
    ranges: [DashChartDetailRange] = [],
    selectedRange: AnalyticsRange? = nil
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
    self.ranges = ranges
    self.selectedRange = selectedRange
  }

  var showsRangeTabs: Bool { ranges.count >= 2 }
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
        .allowsTightening(true)
        .minimumScaleFactor(0.75)
        .foregroundStyle(trend.foreground)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
          "\(DashL10n.ui("Change")): \(percentage)")
    }
  }
}

/// The compact direction-only trend used beside a collapsed chart's primary
/// value. The full signed percentage remains available to VoiceOver and on the
/// expanded card / detail screen.
struct DashCollapsedChartTrendLabel: View {
  let trend: DashChartTrend?

  var body: some View {
    if let trend,
      let percentage = trend.formattedPercentage,
      let asset = trend.compactDirectionAsset
    {
      ZStack {
        SolarIcon(asset: asset, size: 16, color: trend.foreground)
      }
      .frame(width: 16, height: 16)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(
        "\(DashL10n.ui("Change")): \(percentage)")
    }
  }
}

/// Discrete navigation affordance for expanded / interactive chart cards.
/// Collapsed metric cards push detail from the whole surface instead — a
/// trailing chevron there is furniture next to a target that is already the
/// card.
struct DashChartDetailButton: View {
  let detail: DashChartDetail
  var accessibilityIdentifier: String? = nil
  @Environment(\.destinationNavigator) private var navigator
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  /// Painted diameter. `dashCompactHitTarget` keeps the 44pt tap area around it,
  /// which is also the trailing clearance expanded headers reserve for this
  /// control — so the plate's size must not grow.
  private static let diameter: CGFloat = 32

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
      plate
    }
    .buttonStyle(DashPressButtonStyle())
    .accessibilityLabel(
      "\(DashL10n.ui(detail.title)), \(DashL10n.ui("Details"))"
    )
    .accessibilityHint("Shows chart details")
  }

  private var glyph: some View {
    SolarIcon(
      asset: SolarAsset.chevronRight,
      size: DashTheme.Chevron.compact,
      color: DashTheme.strong
    )
    .frame(width: Self.diameter, height: Self.diameter)
  }

  /// Liquid Glass on iOS 26 — the same circular glass as the nav-bar icon
  /// actions and the floated profile / inbox controls, so a chart's detail
  /// control reads as chrome floating over the plot instead of a recessed hole
  /// punched in the card. `.interactive()` is safe here because this view *is*
  /// the button: the glass plane is not stealing hits from an enclosing row.
  /// Reduce Transparency and iOS 17–18 keep the opaque recessed circle.
  @ViewBuilder
  private var plate: some View {
    if reduceTransparency {
      recessedPlate
    } else if #available(iOS 26.0, *) {
      glyph
        .contentShape(Circle())
        .glassEffect(.regular.interactive(), in: .circle)
        .dashCompactHitTarget()
    } else {
      recessedPlate
    }
  }

  private var recessedPlate: some View {
    glyph
      .background(DashTheme.recessed, in: Circle())
      .dashCompactHitTarget()
  }
}

struct DashChartDetailView: View {
  let detail: DashChartDetail
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var range: AnalyticsRange

  init(detail: DashChartDetail) {
    self.detail = detail
    let preferred = detail.selectedRange
    let initial: AnalyticsRange = {
      if let preferred, detail.ranges.contains(where: { $0.range == preferred }) {
        return preferred
      }
      return detail.ranges.first?.range ?? .day
    }()
    _range = State(initialValue: initial)
  }

  var body: some View {
    DashFeatureList(
      header: {
        if detail.showsRangeTabs {
          DashTextTabs(
            items: detail.ranges.map { ($0.range.title, $0.range) },
            selection: $range
          )
        }
      }
    ) {
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

  private var active: DashChartDetailActiveSnapshot {
    if let match = detail.ranges.first(where: { $0.range == range }) {
      return DashChartDetailActiveSnapshot(range: match)
    }
    return DashChartDetailActiveSnapshot(detail: detail)
  }

  private var summaryCard: some View {
    DashGlassCard {
      VStack(alignment: .leading, spacing: DashTheme.Spacing.itemGap) {
        // Tabs already name the window when present; keep the prose heading
        // only for single-snapshot details (Deployments, Loaded records, …).
        if !detail.showsRangeTabs {
          Text(DashL10n.ui(active.rangeLabel))
            .dashTextStyle(.footnoteSemibold)
            .foregroundStyle(DashTheme.subtle)
        }

        if active.summaryValue != nil || active.trend?.formattedPercentage != nil {
          HStack(alignment: .lastTextBaseline, spacing: 8) {
            if let summaryValue = active.summaryValue {
              Text(verbatim: summaryValue)
                .dashChartPrimaryMetricValue()
            }
            DashChartTrendLabel(trend: active.trend)
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
    switch active.content {
    case .area(let points, let series):
      DashAreaChart(
        data: points.map(\.datum),
        series: series,
        options: cartesianOptions(series: series))
    case .line(let points, let series):
      DashLineChart(
        data: points.map(\.datum),
        series: series,
        options: cartesianOptions(series: series))
    case .pie(let slices, let innerRadiusRatio):
      DashPieChart(
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
      summary: active.accessibilitySummary,
      categoryAxisLabel: DashL10n.ui(active.categoryAxisLabel),
      valueAxisLabel: DashL10n.ui(detail.valueAxisLabel))
  }

  private var chartHeight: CGFloat {
    let showsLegend =
      switch active.content {
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
    switch active.content {
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

/// Resolved fields for the detail screen's active time tab (or the single
/// frozen snapshot when the push carried no range list).
private struct DashChartDetailActiveSnapshot {
  let rangeLabel: String
  let summaryValue: String?
  let trend: DashChartTrend?
  let categoryAxisLabel: String
  let accessibilitySummary: String
  let content: DashChartDetailContent

  init(range: DashChartDetailRange) {
    rangeLabel = range.rangeLabel
    summaryValue = range.summaryValue
    trend = range.trend
    categoryAxisLabel = range.categoryAxisLabel
    accessibilitySummary = range.accessibilitySummary
    content = range.content
  }

  init(detail: DashChartDetail) {
    rangeLabel = detail.rangeLabel
    summaryValue = detail.summaryValue
    trend = detail.trend
    categoryAxisLabel = detail.categoryAxisLabel
    accessibilitySummary = detail.accessibilitySummary
    content = detail.content
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
  fileprivate var compactDirectionAsset: String? {
    switch direction {
    case .up: SolarAsset.arrowRightUpBold
    case .down: SolarAsset.arrowRightDownBold
    case .flat: nil
    }
  }

  var formattedPercentage: String? {
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
    DashChartTrendColorConvention
      .resolved(locale: DashL10n.activeLocale)
      .foreground(for: direction)
  }
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
