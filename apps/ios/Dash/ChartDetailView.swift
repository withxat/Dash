import CloudflareAPI
import Foundation
import SwiftDitherKit
import SwiftUI

/// A period-over-period change calculated from the values already loaded for
/// a chart. Direction is always numeric. Polarity preserves whether higher or
/// lower is favorable as metric metadata; the visible red / green convention
/// follows the active language instead.
struct DashChartTrend: Hashable, Sendable {
  typealias Direction = DashChartTrendDirection

  enum Polarity: Hashable, Sendable {
    case neutral
    case higherIsBetter
    case lowerIsBetter
  }

  private let comparison: DashChartTrendComparison
  let polarity: Polarity

  var direction: Direction { comparison.direction }
  var percentChange: Double? { comparison.percentChange }

  /// Returns nil when there is no comparable period or either input is not
  /// finite. A zero baseline has no meaningful percentage unless both periods
  /// are zero, so presentation omits the comparison text in that case.
  init?(
    current: Double,
    previous: Double?,
    polarity: Polarity = .neutral
  ) {
    guard let comparison = DashChartTrendComparison(current: current, previous: previous) else {
      return nil
    }
    self.comparison = comparison
    self.polarity = polarity
  }
}

extension DashChartTrendColorConvention {
  fileprivate func foreground(for direction: DashChartTrend.Direction) -> Color {
    switch (self, direction) {
    case (_, .flat):
      DashTheme.subtle
    case (.redUpGreenDown, .up), (.greenUpRedDown, .down):
      DashTheme.chartTrendRed
    case (.redUpGreenDown, .down), (.greenUpRedDown, .up):
      DashTheme.chartTrendGreen
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
///
/// Time series only. Donuts (DNS record types, Pages build outcomes) are filter
/// controls for the list under them, not metrics with a history worth pushing:
/// their legend already names every slice and the filter strip already states
/// the count, so a detail screen would restate the card and hand the user a
/// second, unfiltered copy of the same selection.
enum DashChartDetailContent: Hashable, Sendable {
  case area(points: [DashChartDataPoint], series: [DitherSeries])
  case line(points: [DashChartDataPoint], series: [DitherSeries])
}

/// A geographic breakdown of the very metric a detail plots, carried into the
/// push as data.
///
/// A breakdown of one metric is not a second metric: the source screen shows
/// that metric once — its total over its history — and the map that says where
/// those events came from belongs behind the same tap, not beside the card.
/// On the detail it stands in for the exact-value table, which only spells out
/// the plot the user is already looking at.
/// `buckets` are label / count pairs ranked by the pushing screen; a label is
/// an ISO 3166-1 alpha-2 code wherever Cloudflare resolved one, and anything
/// else still renders as a plain row.
struct DashChartCountryBreakdown: Hashable, Sendable {
  /// Catalog key for the section title.
  let title: String
  let buckets: [FirewallEventsBucket]
  /// Already-localized sentence describing the whole breakdown.
  let accessibilitySummary: String
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
  /// frozen snapshot (worker 24h, etc.).
  let ranges: [DashChartDetailRange]
  /// Initial tab when `ranges` is non-empty — matches the outer screen's
  /// current time dimension at the moment of the push.
  let selectedRange: AnalyticsRange?
  /// Where the plotted events came from, when the source has that dimension.
  /// Frozen at push time like every other field here, and shared across tabs:
  /// it describes the metric, not one window of it.
  ///
  /// Setting it takes the exact-value table off the page — the breakdown is
  /// the reading the table cannot give.
  let countryBreakdown: DashChartCountryBreakdown?

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
    selectedRange: AnalyticsRange? = nil,
    countryBreakdown: DashChartCountryBreakdown? = nil
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
    self.countryBreakdown = countryBreakdown
  }

  var showsRangeTabs: Bool { ranges.count >= 2 }

  /// Multi-range details freeze whatever windows are warm at push time and
  /// never refetch. Block the push only while an expected window is still
  /// in flight with no snapshot yet — a failed or empty settle must not keep
  /// the chevron locked, and a warm refresh that already has last-good data
  /// stays open.
  static func areSourceRangesSettled(
    expected: some Sequence<AnalyticsRange>,
    loaded: some Sequence<AnalyticsRange>,
    loading: Set<AnalyticsRange>
  ) -> Bool {
    let loadedSet = Set(loaded)
    for range in expected {
      if loading.contains(range), !loadedSet.contains(range) {
        return false
      }
    }
    return true
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
  /// False while sibling time windows are still loading into the frozen
  /// multi-range payload — keeps the plate seated so the title does not jump.
  var isEnabled: Bool = true
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
      guard isEnabled else { return }
      navigator?.push(.chartDetail(detail))
    } label: {
      plate
    }
    .buttonStyle(DashPressButtonStyle())
    .disabled(!isEnabled)
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
    // Render-ready snapshot — never refetches. Without `hasContent`, the list
    // phase settles empty and the default skeleton stays up forever.
    DashFeatureList(
      hasContent: true,
      header: {
        if detail.showsRangeTabs {
          DashTextTabs(
            items: detail.ranges.map { ($0.range.title, $0.range) },
            selection: $range
          )
        }
      }
    ) { _ in
      summaryHeader
      chart
        .frame(maxWidth: .infinity)
        .frame(height: chartHeight)
        .dashSectionBoundary()
      // A breakdown replaces the table rather than sitting above it. The table
      // only transcribes the plot — one row per point — so it earns the page
      // when the page has nothing else to say about the data; where the events
      // came from is a second reading of the same series, and the transcript
      // under it would be furniture the user scrolls past.
      if let countryBreakdown = detail.countryBreakdown {
        DashChartCountryBreakdownSection(breakdown: countryBreakdown)
          .dashSectionBoundary()
      } else {
        // Home's Shortcuts / Recently used frame, emitted lazily: the table can
        // run to a few hundred rows, which is more than the eager
        // `DashInfoGroup` stack should hold.
        dashTwoToneGroupHeader(title: "Details")
          .dashSectionBoundary()
        dashTwoToneCardRows(items: tableRows) { row in
          DashChartTableRow(row: row)
        }
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

  /// Value first, comparison opposite it, the range named underneath — page
  /// chrome above the plot. The chart sits directly in the scroll stack, not
  /// inside a card panel.
  private var summaryHeader: some View {
    VStack(alignment: .leading, spacing: 4) {
      if active.summaryValue != nil || active.trend?.formattedPercentage != nil {
        HStack(alignment: .firstTextBaseline, spacing: DashTheme.Spacing.itemGap) {
          if let summaryValue = active.summaryValue {
            Text(verbatim: summaryValue)
              .dashChartPrimaryMetricValue()
          }
          Spacer(minLength: 4)
          DashChartDetailTrendLabel(trend: active.trend)
        }
      }
      // Tabs already name the window when present; keep the prose heading
      // only for single-snapshot details (Deployments, Loaded records, …).
      if !detail.showsRangeTabs {
        Text(DashL10n.ui(active.rangeLabel))
          .dashTextStyle(.footnote)
          .foregroundStyle(DashTheme.subtle)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private var chart: some View {
    switch active.content {
    case .area(let points, let series):
      DashAreaChart(
        data: points.map(\.datum),
        series: series,
        options: cartesianOptions)
    case .line(let points, let series):
      DashLineChart(
        data: points.map(\.datum),
        series: series,
        options: cartesianOptions)
    }
  }

  /// Coordinate grid and axis gutters, no legend — every detail is a single
  /// series the header already names. Metrics stay above; the series keeps
  /// whatever fill the source chose (area stays area).
  private var cartesianOptions: DitherCartesianOptions {
    DashTheme.DitherChart.options(
      showsLegend: false,
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

  /// No legend, so the plot can take the full reserved height.
  private var chartHeight: CGFloat {
    dynamicTypeSize.isAccessibilitySize ? 332 : 284
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
    }
  }
}

/// The detail screen's comparison label: an arrow beside the signed percentage,
/// scaled up to sit opposite the primary value. `DashChartTrendLabel` stays the
/// compact caption used on cards.
private struct DashChartDetailTrendLabel: View {
  let trend: DashChartTrend?

  var body: some View {
    if let trend, let percentage = trend.formattedPercentage {
      HStack(spacing: 2) {
        if let asset = trend.compactDirectionAsset {
          SolarIcon(asset: asset, size: 20, color: trend.foreground)
        }
        Text(verbatim: percentage.trimmingSign)
          .dashTextStyle(.sectionTitle)
          .monospacedDigit()
          .lineLimit(1)
          .allowsTightening(true)
          .minimumScaleFactor(0.75)
          .foregroundStyle(trend.foreground)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("\(DashL10n.ui("Change")): \(percentage)")
    }
  }
}

extension String {
  /// The arrow already states direction, so the glyph beside it would repeat
  /// the sign. Only a leading +/− is dropped; the digits are untouched.
  fileprivate var trimmingSign: String {
    var text = self
    for sign in ["+", "-", "\u{2212}"] where text.hasPrefix(sign) {
      text.removeFirst()
      break
    }
    return text
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
      } else if row.values.count == 1, let value = row.values.first {
        singleValueLayout(value)
      } else {
        compactLayout
      }
    }
    // The 44pt floor is the row rhythm the two-tone card carries everywhere
    // (`DashInfoRow`, Home's Recently used); only the taller two-series cells
    // need padding of their own.
    .padding(.vertical, row.values.count == 1 ? 0 : 6)
    .frame(minHeight: DashTheme.Layout.minimumHitTarget)
    .accessibilityElement(children: .combine)
  }

  /// One series: the plain spec-sheet row — category leading, value trailing.
  /// Naming the series on every row would just repeat the chart's one value
  /// axis, and its color has nothing to be told apart from.
  private func singleValueLayout(_ value: DashChartTableValue) -> some View {
    HStack(spacing: 12) {
      Text(verbatim: row.label)
        .dashTextStyle(.supporting)
        .foregroundStyle(DashTheme.subtle)
        .lineLimit(1)
      Spacer(minLength: 0)
      Text(verbatim: value.value)
        .dashTextStyle(.supporting)
        .monospacedDigit()
        .foregroundStyle(DashTheme.text)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }
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
    comparison.formattedPercentage(locale: DashL10n.activeLocale)
  }

  fileprivate var foreground: Color {
    DashChartTrendColorConvention
      .resolved(locale: DashL10n.activeLocale)
      .foreground(for: direction)
  }
}

extension DashChartValueFormat {
  /// Leading gutter so Y-axis labels ("17.4 MB", "12.5 ms") are not clipped.
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
