import CloudflareAPI
import Observation
import SwiftDitherKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum WatchtowerMetricChartRenderingMode: Equatable {
  case live
  case placeholder

  static func resolved(isEditing: Bool) -> Self {
    isEditing ? .placeholder : .live
  }
}

struct WatchtowerChartVisualSwapProfile: Equatable {
  enum Effect: Equatable {
    case rich
    case opacityOnly
  }

  let liveEffect: Effect
  let placeholderEffect: Effect
  let exitDuration: Double
  let enterDuration: Double

  static func resolved(isExpanded: Bool) -> Self {
    if isExpanded {
      // A full-width chart and placeholder cover roughly four times the pixels
      // of a collapsed sparkline. Keep their entire handoff within the parent
      // editor morph and avoid offscreen blur/scale composition on both layers.
      return Self(
        liveEffect: .opacityOnly,
        placeholderEffect: .opacityOnly,
        exitDuration: 0.12,
        enterDuration: 0.16)
    }
    return Self(
      liveEffect: .rich,
      placeholderEffect: .rich,
      exitDuration: 0.28,
      enterDuration: 0.28)
  }
}

struct WatchtowerChartVisualSwapSequence: Equatable {
  enum Phase: Equatable {
    case settled(WatchtowerMetricChartRenderingMode)
    case exiting(WatchtowerMetricChartRenderingMode)
    case entering(WatchtowerMetricChartRenderingMode)
  }

  enum Step: Equatable {
    case none
    case exit(WatchtowerMetricChartRenderingMode)
    case enter(WatchtowerMetricChartRenderingMode)
  }

  private(set) var requestedMode: WatchtowerMetricChartRenderingMode
  private(set) var phase: Phase

  var visibleMode: WatchtowerMetricChartRenderingMode? {
    switch phase {
    case .settled(let mode), .entering(let mode):
      mode
    case .exiting:
      nil
    }
  }

  init(mode: WatchtowerMetricChartRenderingMode) {
    requestedMode = mode
    phase = .settled(mode)
  }

  mutating func request(_ target: WatchtowerMetricChartRenderingMode) -> Step {
    requestedMode = target
    switch phase {
    case .settled(let current):
      return target == current ? .none : .exit(current)
    case .exiting(let current):
      return target == current ? .enter(current) : .none
    case .entering(let current):
      return target == current ? .none : .exit(current)
    }
  }

  mutating func begin(_ step: Step) {
    switch step {
    case .none:
      break
    case .exit(let mode):
      phase = .exiting(mode)
    case .enter(let mode):
      phase = .entering(mode)
    }
  }

  func finishExit(_ mode: WatchtowerMetricChartRenderingMode) -> Step {
    guard phase == .exiting(mode) else { return .none }
    return .enter(requestedMode)
  }

  mutating func finishEnter(_ mode: WatchtowerMetricChartRenderingMode) -> Step {
    guard phase == .entering(mode) else { return .none }
    phase = .settled(mode)
    return requestedMode == mode ? .none : .exit(mode)
  }
}

/// Cold-load stand-in for `WatchtowerMetricChartCard`: same panel, same header
/// rhythm, same chart heights. The metric title is known before the network is,
/// so only the total and the series are skeleton blocks.
struct WatchtowerMetricSkeletonCard: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let metric: WatchtowerAnalyticsMetric
  let isExpanded: Bool

  private var panelShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous)
  }

  private var chartHeight: CGFloat {
    isExpanded
      ? DashTheme.DitherChart.height(dynamicTypeSize: dynamicTypeSize)
      : DashTheme.DitherChart.collapsedHeight(dynamicTypeSize: dynamicTypeSize)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        Text(DashL10n.ui(metric.title))
          .dashTextStyle(.footnoteSemibold)
          .foregroundStyle(DashTheme.subtle)
          .lineLimit(2, reservesSpace: true)
          .minimumScaleFactor(0.85)
        // Redacted text, not a fixed-height bar: the block then tracks the
        // real total's type ramp at every Dynamic Type size.
        Text(verbatim: "888,888")
          .dashTextStyle(isExpanded ? .emptyTitle : .sectionTitle)
          .monospacedDigit()
          .lineLimit(1)
          .redacted(reason: .placeholder)
          .dashSkeletonPulse()
        if isExpanded {
          Text(verbatim: " ")
            .dashTextStyle(.caption)
            .lineLimit(1, reservesSpace: true)
        }
      }
      .padding(.horizontal, DashTheme.Spacing.card)
      .padding(.top, DashTheme.Spacing.card)
      .padding(.bottom, isExpanded ? 12 : 8)

      chartBlock
        .padding(.horizontal, isExpanded ? DashTheme.Spacing.card : 0)
        .padding(.bottom, isExpanded ? DashTheme.Spacing.card : 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      DashTheme.homeCardSurface.clipShape(panelShape)
    }
    .dashEmbossChrome(shape: panelShape)
    .accessibilityHidden(true)
  }

  private var chartBlock: some View {
    DashSkeletonBand()
      .frame(maxWidth: .infinity)
      .frame(height: chartHeight)
      .clipShape(
        isExpanded
          ? AnyShape(RoundedRectangle(cornerRadius: DashTheme.Radius.button, style: .continuous))
          : AnyShape(
            UnevenRoundedRectangle(
              topLeadingRadius: 0,
              bottomLeadingRadius: DashTheme.Radius.card,
              bottomTrailingRadius: DashTheme.Radius.card,
              topTrailingRadius: 0,
              style: .continuous))
      )
  }
}

/// Two-stage content replacement for chart pixels. The current layer finishes
/// its opacity / blur / scale exit before the replacement begins its entrance.
/// Explicit phases and operation IDs discard stale animation completions when
/// a rapid target change reverses the active phase.
///
/// Collapsed sparklines keep the full dissolve (blur + scale). Expanded charts
/// and their full-width placeholders use a shorter opacity-only profile: the
/// whole swap fits inside the parent editor morph and neither large layer pays
/// for offscreen blur composition. Settled hidden layers also drop blur/scale,
/// so an invisible placeholder is not carrying a permanent filter.
private struct WatchtowerChartVisualSwap<Placeholder: View, Live: View>: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let renderingMode: WatchtowerMetricChartRenderingMode
  let profile: WatchtowerChartVisualSwapProfile
  private let placeholder: () -> Placeholder
  private let live: () -> Live
  @State private var sequence: WatchtowerChartVisualSwapSequence
  @State private var keepsLiveMounted: Bool
  @State private var operationID = 0

  init(
    renderingMode: WatchtowerMetricChartRenderingMode,
    profile: WatchtowerChartVisualSwapProfile,
    @ViewBuilder placeholder: @escaping () -> Placeholder,
    @ViewBuilder live: @escaping () -> Live
  ) {
    self.renderingMode = renderingMode
    self.profile = profile
    self.placeholder = placeholder
    self.live = live
    _sequence = State(initialValue: WatchtowerChartVisualSwapSequence(mode: renderingMode))
    _keepsLiveMounted = State(initialValue: renderingMode == .live)
  }

  private var isMorphing: Bool {
    switch sequence.phase {
    case .settled:
      false
    case .exiting, .entering:
      true
    }
  }

  var body: some View {
    ZStack {
      placeholder()
        .modifier(
          WatchtowerChartSwapLayer(
            isVisible: sequence.visibleMode == .placeholder,
            isMorphing: isMorphing,
            reduceMotion: reduceMotion,
            usesRichMorph: profile.placeholderEffect == .rich)
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)

      if keepsLiveMounted {
        live()
          .modifier(
            WatchtowerChartSwapLayer(
              isVisible: sequence.visibleMode == .live,
              isMorphing: isMorphing,
              reduceMotion: reduceMotion,
              usesRichMorph: profile.liveEffect == .rich)
          )
          .allowsHitTesting(sequence.phase == .settled(.live))
      }
    }
    .onChange(of: renderingMode) { _, target in
      request(target)
    }
  }

  private func request(_ target: WatchtowerMetricChartRenderingMode) {
    if target == .live, !keepsLiveMounted {
      setLiveMounted(true)
    }
    perform(sequence.request(target))
  }

  private func perform(_ step: WatchtowerChartVisualSwapSequence.Step) {
    switch step {
    case .none:
      break
    case .exit(let mode):
      animate(step, expectedPhase: .exiting(mode), mode: mode)
    case .enter(let mode):
      animate(step, expectedPhase: .entering(mode), mode: mode)
    }
  }

  private func animate(
    _ step: WatchtowerChartVisualSwapSequence.Step,
    expectedPhase: WatchtowerChartVisualSwapSequence.Phase,
    mode: WatchtowerMetricChartRenderingMode
  ) {
    operationID += 1
    let currentOperation = operationID
    let duration: Double = {
      if reduceMotion { return 0.12 }
      switch expectedPhase {
      case .exiting: return profile.exitDuration
      case .entering: return profile.enterDuration
      case .settled: return 0
      }
    }()
    let animation: Animation =
      if reduceMotion {
        DashTheme.Motion.reduced
      } else if profile.liveEffect == .rich || profile.placeholderEffect == .rich {
        DashTheme.Motion.morph
      } else {
        DashTheme.Motion.chartSwap(duration: duration)
      }
    withAnimation(
      animation.logicallyComplete(after: duration),
      completionCriteria: .logicallyComplete
    ) {
      sequence.begin(step)
    } completion: {
      guard currentOperation == operationID, sequence.phase == expectedPhase else {
        return
      }

      switch expectedPhase {
      case .exiting:
        let next = sequence.finishExit(mode)
        // Drop the live tree as soon as it has faded out. Keeping an expanded
        // chart mounted through the placeholder entrance was free on collapsed
        // sparklines and expensive on `DashAreaChart`.
        if mode == .live {
          setLiveMounted(false)
        }
        Task { @MainActor in
          // Commit the replacement's fully hidden baseline before starting its
          // entrance. Running a nested animation in this completion transaction
          // can otherwise collapse the entrance into an immediate state change.
          await Task.yield()
          guard
            currentOperation == operationID,
            sequence.phase == expectedPhase
          else { return }
          perform(next)
        }
      case .entering:
        let next = sequence.finishEnter(mode)
        perform(next)
      case .settled:
        break
      }
    }
  }

  private func setLiveMounted(_ isMounted: Bool) {
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      keepsLiveMounted = isMounted
    }
  }
}

private struct WatchtowerChartSwapLayer: ViewModifier {
  let isVisible: Bool
  let isMorphing: Bool
  let reduceMotion: Bool
  var usesRichMorph = true

  @ViewBuilder
  func body(content: Content) -> some View {
    if usesRichMorph {
      let richMorph = isMorphing && !reduceMotion
      content
        .opacity(isVisible ? 1 : 0)
        // Blur/scale only while a handoff is in flight. A settled hidden layer
        // used to keep blur(8) permanently — fine under a sparkline, a steady
        // tax under every expanded chart.
        .blur(radius: richMorph && !isVisible ? 8 : 0)
        .scaleEffect(richMorph && !isVisible ? 0.75 : 1)
        .accessibilityHidden(!isVisible)
    } else {
      // Keep the large expanded layers off the filter/compositing path
      // entirely instead of retaining no-op blur and scale modifiers.
      content
        .opacity(isVisible ? 1 : 0)
        .accessibilityHidden(!isVisible)
    }
  }
}

struct WatchtowerMetricChartCard: View {
  private static let placeholderRatios: [CGFloat] = [0.28, 0.5, 0.38, 0.72, 0.56, 0.84, 0.64]

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let metric: WatchtowerAnalyticsMetric
  let overview: AccountAnalyticsOverview
  var previousOverview: AccountAnalyticsOverview? = nil
  let chart: WatchtowerAnalyticsChartModel.MetricSnapshot
  let range: AnalyticsRange
  /// Warm snapshots for every time tab so the pushed detail can switch ranges
  /// without refetching.
  var snapshotsByRange: [AnalyticsRange: WatchtowerAnalyticsChartModel.Snapshot] = [:]
  /// In-flight windows. Detail push waits until each expected range has either
  /// landed or finished trying, so a first tap cannot omit a still-loading 30d.
  var loadingRanges: Set<AnalyticsRange> = []
  let isExpanded: Bool
  let showsEditingControls: Bool
  let renderingMode: WatchtowerMetricChartRenderingMode
  let onToggleExpanded: () -> Void
  let onRemove: () -> Void
  @State private var selectedSeriesID: String?

  private var total: (text: String, numeric: Double) {
    WatchtowerAnalyticsChartModel.totalValue(overview, metric: metric)
  }

  private var trend: DashChartTrend? {
    guard let previousOverview else { return nil }
    return DashChartTrend(
      current: total.numeric,
      previous: WatchtowerAnalyticsChartModel.totalValue(
        previousOverview,
        metric: metric
      ).numeric,
      polarity: metric.trendPolarity)
  }

  private var areDetailRangesSettled: Bool {
    DashChartDetail.areSourceRangesSettled(
      expected: AnalyticsRange.allCases,
      loaded: snapshotsByRange.keys,
      loading: loadingRanges)
  }

  private var opensDetailOnTap: Bool {
    !isExpanded && !showsEditingControls && detail != nil && renderingMode == .live
      && areDetailRangesSettled
  }

  private var detail: DashChartDetail? {
    let rangeSnapshots = AnalyticsRange.allCases.compactMap { target -> DashChartDetailRange? in
      guard
        let snapshot = snapshotsByRange[target] ?? (target == range ? currentRangeSnapshot : nil)
      else { return nil }
      return detailRange(from: snapshot, range: target)
    }
    guard let current = detailRange(from: currentRangeSnapshot, range: range) else {
      return nil
    }
    return DashChartDetail(
      title: metric.title,
      rangeLabel: current.rangeLabel,
      summaryValue: current.summaryValue,
      summaryNumericValue: current.summaryNumericValue,
      trend: current.trend,
      categoryAxisLabel: current.categoryAxisLabel,
      valueAxisLabel: metric.valueAxisLabel,
      axisValueFormat: metric.axisValueFormat,
      tableValueFormat: metric.tableValueFormat,
      accessibilitySummary: current.accessibilitySummary,
      content: current.content,
      featureID: nil,
      readScopes: DashAuthorizationScopes.accountAnalytics,
      ranges: rangeSnapshots,
      selectedRange: range)
  }

  private var currentRangeSnapshot: WatchtowerAnalyticsChartModel.Snapshot {
    WatchtowerAnalyticsChartModel.Snapshot(
      overview: overview,
      previousOverview: previousOverview,
      charts: [metric: chart],
      fetchedAt: .now)
  }

  private func detailRange(
    from snapshot: WatchtowerAnalyticsChartModel.Snapshot,
    range target: AnalyticsRange
  ) -> DashChartDetailRange? {
    let metricChart = snapshot.charts[metric] ?? .empty
    guard !metricChart.isEmpty,
      metricChart.expandedData.count == metricChart.tableLabels.count
    else { return nil }
    let total = WatchtowerAnalyticsChartModel.totalValue(snapshot.overview, metric: metric)
    let trend: DashChartTrend? = {
      guard let previous = snapshot.previousOverview else { return nil }
      return DashChartTrend(
        current: total.numeric,
        previous: WatchtowerAnalyticsChartModel.totalValue(previous, metric: metric).numeric,
        polarity: metric.trendPolarity)
    }()
    let points = zip(metricChart.expandedData, metricChart.tableLabels).map { datum, tableLabel in
      DashChartDataPoint(
        datum: DitherDatum(
          id: datum.id,
          label: datum.label,
          values: [
            metric.seriesKey: metric.detailValue(datum[metric.seriesKey])
          ]),
        tableLabel: tableLabel)
    }
    return DashChartDetailRange(
      range: target,
      rangeLabel: target.totalsHeading,
      summaryValue: total.text,
      summaryNumericValue: total.numeric,
      trend: trend,
      categoryAxisLabel: target == .month ? "Day" : "Hour",
      accessibilitySummary: WatchtowerAnalyticsChartModel.accessibilitySummary(
        metric: metric,
        rangeLabel: DashL10n.ui(target.totalsHeading),
        value: total.text),
      content: .area(points: points, series: chartSeries))
  }

  private var chartAccessibility: DitherAccessibility {
    DitherAccessibility(
      title: DashL10n.ui(metric.title),
      summary: WatchtowerAnalyticsChartModel.accessibilitySummary(
        metric: metric,
        rangeLabel: DashL10n.ui(range.totalsHeading),
        value: total.text),
      categoryAxisLabel: DashL10n.ui(range == .month ? "Day" : "Hour"),
      valueAxisLabel: DashL10n.ui(metric.valueAxisLabel))
  }

  private var panelShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous)
  }

  private var collapsedHeight: CGFloat {
    DashTheme.DitherChart.collapsedHeight(dynamicTypeSize: dynamicTypeSize)
  }

  private var expandedHeight: CGFloat {
    DashTheme.DitherChart.height(dynamicTypeSize: dynamicTypeSize)
  }

  private var overlayIsInteractive: Bool {
    showsEditingControls
      || (isExpanded && detail != nil && renderingMode == .live && !showsEditingControls)
  }

  var body: some View {
    Group {
      if opensDetailOnTap, let detail {
        DashNavigationSource(destination: .chartDetail(detail)) { navigate in
          Button(action: navigate) {
            cardChrome
          }
          .buttonStyle(DashSurfaceButtonStyle())
          .accessibilityHint("Shows chart details")
          .accessibilityIdentifier("watchtower-chart-detail-\(metric.rawValue)")
        }
      } else {
        cardChrome
      }
    }
    .onChange(of: range) { selectedSeriesID = nil }
    .onChange(of: isExpanded) { selectedSeriesID = nil }
    .onChange(of: renderingMode) {
      if renderingMode == .placeholder {
        selectedSeriesID = nil
      }
    }
  }

  private var cardChrome: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      chartBody
        .padding(.horizontal, isExpanded ? DashTheme.Spacing.card : 0)
        .padding(.bottom, isExpanded ? DashTheme.Spacing.card : 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    // Clip only the fill — not the whole card — so expanded-chart tooltips can
    // paint past the panel edge. Chart bodies that sit flush still clip locally.
    .background {
      DashTheme.homeCardSurface
        .clipShape(panelShape)
    }
    .dashEmbossChrome(shape: panelShape)
    .overlay(alignment: .topTrailing) {
      ZStack(alignment: .topTrailing) {
        // Expanded charts keep a discrete detail control so hold-to-scrub is
        // not also a navigation target. Collapsed cards push from the surface.
        if let detail, isExpanded, renderingMode == .live, !showsEditingControls {
          DashChartDetailButton(
            detail: detail,
            isEnabled: areDetailRangesSettled,
            accessibilityIdentifier: "watchtower-chart-detail-\(metric.rawValue)"
          )
          .padding(8)
          .transition(reduceMotion ? .opacity : .dashMorph)
        }
        if showsEditingControls {
          cardControls
            .transition(reduceMotion ? .opacity : .dashMorph)
        }
      }
      .allowsHitTesting(overlayIsInteractive)
      .accessibilityHidden(!overlayIsInteractive)
    }
  }

  private var header: some View {
    headerContent
  }

  private var headerContent: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(DashL10n.ui(metric.title))
        .dashTextStyle(.footnoteSemibold)
        .foregroundStyle(DashTheme.subtle)
        // Reserve two lines so a one-line title ("CPU Time") stands the same
        // height as a wrapped one ("Encrypted Requests Rate") — paired collapsed
        // cards and every row then share one card height.
        .lineLimit(2, reservesSpace: true)
        .minimumScaleFactor(0.85)
        .padding(
          .trailing,
          renderingMode == .placeholder
            ? WatchtowerMetricDragLayout.titleTrailingClearance
            : (isExpanded && detail != nil) ? DashTheme.Layout.minimumHitTarget : 0)
      HStack(
        alignment: isExpanded ? .lastTextBaseline : .center,
        spacing: isExpanded ? 8 : 6
      ) {
        Text(total.text)
          .dashChartPrimaryMetricValue()
          .contentTransition(
            reduceMotion ? .opacity : .numericText(value: total.numeric)
          )
        if isExpanded {
          DashChartTrendLabel(trend: trend)
        } else {
          DashCollapsedChartTrendLabel(trend: trend)
        }
        Spacer(minLength: 4)
      }
      if isExpanded {
        // Reserve the footnote line on every expanded card so CPU Time (the one
        // metric with a "p90" footnote) doesn't sit a row taller than the rest.
        Text(metric.footnote.map { DashL10n.ui($0) } ?? "")
          .dashTextStyle(.caption)
          .foregroundStyle(DashTheme.subtle)
          .lineLimit(1, reservesSpace: true)
          .accessibilityHidden(metric.footnote == nil)
      }
    }
    .padding(.horizontal, DashTheme.Spacing.card)
    .padding(.top, DashTheme.Spacing.card)
    .padding(.bottom, isExpanded ? 12 : 8)
    .accessibilityElement(children: .combine)
  }

  private var chartBody: some View {
    WatchtowerChartVisualSwap(
      renderingMode: renderingMode,
      profile: .resolved(isExpanded: isExpanded),
      placeholder: { editingPlaceholder },
      live: { liveChartBody }
    )
  }

  @ViewBuilder
  private var liveChartBody: some View {
    if isExpanded {
      expandedChart
    } else {
      // Flush to the card’s bottom edge; only the bottom corners need the panel
      // radius so the dither does not square off the embossed fill.
      collapsedSparkline
        .frame(maxWidth: .infinity)
        .frame(height: collapsedHeight)
        .clipShape(
          UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: DashTheme.Radius.card,
            bottomTrailingRadius: DashTheme.Radius.card,
            topTrailingRadius: 0,
            style: .continuous)
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
  }

  @ViewBuilder
  private var expandedChart: some View {
    if chart.isEmpty {
      Text(DashL10n.ui("No data in this range"))
        .dashTextStyle(.footnote)
        .foregroundStyle(DashTheme.placeholder)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: expandedHeight, alignment: .leading)
    } else {
      DashAreaChart(
        data: chart.expandedData,
        series: chartSeries,
        options: DashTheme.DitherChart.options(
          showsLegend: false,
          accessibility: chartAccessibility),
        highlighted: selectedSeriesID != nil,
        selection: $selectedSeriesID
      )
      .frame(height: expandedHeight)
    }
  }

  @ViewBuilder
  private var editingPlaceholder: some View {
    if isExpanded {
      placeholderBars(height: expandedHeight, inset: 16, spacing: 6)
        .clipShape(
          RoundedRectangle(cornerRadius: DashTheme.Radius.button, style: .continuous)
        )
        .accessibilityHidden(true)
    } else {
      placeholderBars(height: collapsedHeight, inset: 10, spacing: 4)
        .clipShape(
          UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: DashTheme.Radius.card,
            bottomTrailingRadius: DashTheme.Radius.card,
            topTrailingRadius: 0,
            style: .continuous)
        )
        .accessibilityHidden(true)
    }
  }

  private func placeholderBars(
    height: CGFloat,
    inset: CGFloat,
    spacing: CGFloat
  ) -> some View {
    let availableHeight = max(1, height - inset * 2)
    let color = placeholderColor

    return ZStack(alignment: .bottom) {
      color.opacity(colorScheme == .dark ? 0.12 : 0.07)
      HStack(alignment: .bottom, spacing: spacing) {
        ForEach(Self.placeholderRatios.indices, id: \.self) { index in
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(color.opacity(colorScheme == .dark ? 0.34 : 0.24))
            .frame(maxWidth: .infinity)
            .frame(height: availableHeight * Self.placeholderRatios[index])
        }
      }
      .padding(.horizontal, inset)
      .padding(.vertical, inset)
    }
    .frame(maxWidth: .infinity)
    .frame(height: height)
  }

  private var placeholderColor: Color {
    let color = seriesColor
    return Color(
      .sRGB,
      red: color.red,
      green: color.green,
      blue: color.blue,
      opacity: 1)
  }

  /// Flush to the panel edges. Zeros (including all-zero) lift off the floor so
  /// the sparkline still paints a short band.
  private var collapsedSparkline: some View {
    DashAreaChart(
      data: chart.collapsedData,
      series: chartSeries,
      options: DashTheme.DitherChart.sparklineOptions(
        accessibility: chartAccessibility,
        valueCeiling: chart.collapsedValueCeiling),
      highlighted: false,
      selection: nil
    )
  }

  private var chartSeries: [DitherSeries] {
    [
      DitherSeries(
        id: metric.seriesKey,
        label: DashL10n.ui(metric.title),
        color: seriesColor,
        variant: .gradient)
    ]
  }

  private var cardControls: some View {
    HStack(spacing: 2) {
      chartControl(
        accessibilityLabel: DashL10n.string("Remove \(metric.title)"),
        action: onRemove
      ) {
        SolarIcon(asset: SolarAsset.trash, size: 14, color: DashTheme.danger)
      }

      chartControl(
        accessibilityLabel: DashL10n.ui(isExpanded ? "Collapse chart" : "Expand chart"),
        action: onToggleExpanded
      ) {
        Image(
          systemName: isExpanded
            ? "arrow.down.right.and.arrow.up.left"
            : "arrow.up.left.and.arrow.down.right"
        )
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(DashTheme.brand)
      }
      .disabled(dynamicTypeSize.isAccessibilitySize)
      .opacity(dynamicTypeSize.isAccessibilitySize ? 0.42 : 1)
    }
    .padding(8)
    .frame(
      width: WatchtowerMetricDragLayout.controlsPassthroughSize.width,
      height: WatchtowerMetricDragLayout.controlsPassthroughSize.height,
      alignment: .topTrailing)
  }

  /// Editor controls sit in the same top-right corner as `DashChartDetailButton`
  /// and take the same Liquid Glass circle, so entering the editor swaps the
  /// control set without swapping the material. Keep the 28pt plate and its 4pt
  /// padding: `WatchtowerMetricDragSourceUIView` punches exactly
  /// `controlsPassthroughSize` (96×60) out of the drag bridge for this cluster,
  /// and a larger plate would push a button under the lift gesture.
  private func chartControl<Label: View>(
    accessibilityLabel: String,
    action: @escaping () -> Void,
    @ViewBuilder label: () -> Label
  ) -> some View {
    Button(action: action) {
      chartControlPlate { label() }
    }
    .buttonStyle(DashPressButtonStyle())
    .accessibilityLabel(accessibilityLabel)
  }

  /// The glyph keeps its own tint (danger for remove, brand for the size toggle)
  /// on a neutral plate — a tinted glass circle would read as a filled
  /// destructive button rather than editor chrome.
  @ViewBuilder
  private func chartControlPlate<Label: View>(
    @ViewBuilder label: () -> Label
  ) -> some View {
    let glyph = label().frame(width: 28, height: 28)
    if reduceTransparency {
      embossedControlPlate(glyph)
    } else if #available(iOS 26.0, *) {
      glyph
        .glassEffect(.regular.interactive(), in: .circle)
        // Same padded circle the embossed plate offers, so the tap area does not
        // shrink to the 28pt glass.
        .padding(4)
        .contentShape(Circle())
    } else {
      embossedControlPlate(glyph)
    }
  }

  private func embossedControlPlate(_ glyph: some View) -> some View {
    glyph
      .background(DashTheme.homeCardSurface, in: Circle())
      .dashEmbossChrome(shape: Circle())
      .padding(4)
      .contentShape(Circle())
  }

  private var seriesColor: DitherColor {
    switch metric {
    case .workerErrors, .clientRequestErrors:
      DashTheme.DitherChart.negative(
        colorScheme: colorScheme, contrast: colorSchemeContrast)
    case .totalBandwidth, .encryptedBandwidth:
      DashTheme.DitherChart.accentTeal(
        colorScheme: colorScheme, contrast: colorSchemeContrast)
    case .cacheRate, .encryptedRequestsRate:
      DashTheme.DitherChart.positive(
        colorScheme: colorScheme, contrast: colorSchemeContrast)
    case .cpuTime:
      DashTheme.DitherChart.accentPurple(
        colorScheme: colorScheme, contrast: colorSchemeContrast)
    case .workerInvocations, .webTraffic:
      DashTheme.DitherChart.brand(
        colorScheme: colorScheme, contrast: colorSchemeContrast)
    }
  }
}
