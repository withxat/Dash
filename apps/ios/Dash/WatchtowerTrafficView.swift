import CloudflareAPI
import Observation
import SwiftDitherKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension AnalyticsRange {
  var accountAnalyticsHours: Int {
    switch self {
    case .day: 24
    case .week: 168
    case .month: 720
    }
  }

  var accountAnalyticsGranularity: AccountAnalyticsGranularity {
    switch self {
    case .day, .week: .hour
    case .month: .day
    }
  }
}

enum WatchtowerAnalyticsMetric: String, CaseIterable, Identifiable, Hashable, Sendable {
  case workerInvocations
  case workerErrors
  case cpuTime
  case webTraffic
  case totalBandwidth
  case cacheRate
  case clientRequestErrors
  case encryptedRequestsRate
  case encryptedBandwidth

  var id: String { rawValue }

  var title: String {
    switch self {
    case .workerInvocations: "Worker Invocations"
    case .workerErrors: "Workers Errors"
    case .cpuTime: "CPU Time"
    case .webTraffic: "Web Traffic"
    case .totalBandwidth: "Total Bandwidth"
    case .cacheRate: "Cache Rate"
    case .clientRequestErrors: "Client Request Errors"
    case .encryptedRequestsRate: "Encrypted Requests Rate"
    case .encryptedBandwidth: "Encrypted Bandwidth"
    }
  }

  var footnote: String? {
    switch self {
    case .cpuTime: "p90"
    default: nil
    }
  }

  var usesHTTPSeries: Bool {
    switch self {
    case .webTraffic, .totalBandwidth, .cacheRate, .clientRequestErrors,
      .encryptedRequestsRate, .encryptedBandwidth:
      true
    case .workerInvocations, .workerErrors, .cpuTime:
      false
    }
  }

  var seriesKey: String { rawValue }

  var valueAxisLabel: String {
    switch self {
    case .workerInvocations, .webTraffic: "Requests"
    case .workerErrors: "Errors"
    case .cpuTime: "Milliseconds"
    case .totalBandwidth, .encryptedBandwidth: "Bytes"
    case .cacheRate, .clientRequestErrors, .encryptedRequestsRate: "Percent"
    }
  }
}

extension [WatchtowerAnalyticsMetric] {
  fileprivate var rowID: String { map(\.rawValue).joined(separator: "|") }
}

@MainActor
@Observable
final class WatchtowerChartCustomizationState {
  private(set) var isEditing = false
  private(set) var order: [WatchtowerAnalyticsMetric]
  private(set) var collapsed: Set<WatchtowerAnalyticsMetric>
  private(set) var hidden: Set<WatchtowerAnalyticsMetric>
  private(set) var draggedMetric: WatchtowerAnalyticsMetric?
  private(set) var dropTargetMetric: WatchtowerAnalyticsMetric?

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private var savedDraft: Draft?

  private struct Draft {
    let order: [WatchtowerAnalyticsMetric]
    let collapsed: Set<WatchtowerAnalyticsMetric>
    let hidden: Set<WatchtowerAnalyticsMetric>
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    order = WatchtowerAnalyticsCardLayout.orderedMetrics(
      in: defaults.string(forKey: WatchtowerAnalyticsCardLayout.orderKey) ?? "")
    collapsed = Set(
      WatchtowerAnalyticsCardLayout.collapsedIDs(
        in: defaults.string(forKey: WatchtowerAnalyticsCardLayout.key) ?? ""
      ).compactMap(WatchtowerAnalyticsMetric.init(rawValue:)))
    hidden = Set(
      WatchtowerAnalyticsCardLayout.hiddenIDs(
        in: defaults.string(forKey: WatchtowerAnalyticsCardLayout.hiddenKey) ?? ""
      ).compactMap(WatchtowerAnalyticsMetric.init(rawValue:)))
  }

  var visibleMetrics: [WatchtowerAnalyticsMetric] {
    order.filter { !hidden.contains($0) }
  }

  var addableMetrics: [WatchtowerAnalyticsMetric] {
    WatchtowerAnalyticsMetric.allCases.filter(hidden.contains)
  }

  func isExpanded(_ metric: WatchtowerAnalyticsMetric) -> Bool {
    !collapsed.contains(metric)
  }

  func beginEditing() {
    guard !isEditing else { return }
    savedDraft = Draft(order: order, collapsed: collapsed, hidden: hidden)
    isEditing = true
  }

  func cancelEditing() {
    if let savedDraft {
      order = savedDraft.order
      collapsed = savedDraft.collapsed
      hidden = savedDraft.hidden
    }
    finishEditing()
  }

  func commitEditing() {
    defaults.set(
      WatchtowerAnalyticsCardLayout.encodeOrder(order),
      forKey: WatchtowerAnalyticsCardLayout.orderKey)
    defaults.set(
      WatchtowerAnalyticsCardLayout.encode(Set(collapsed.map(\.rawValue))),
      forKey: WatchtowerAnalyticsCardLayout.key)
    defaults.set(
      WatchtowerAnalyticsCardLayout.encodeHidden(hidden),
      forKey: WatchtowerAnalyticsCardLayout.hiddenKey)
    finishEditing()
  }

  func toggleExpanded(_ metric: WatchtowerAnalyticsMetric) {
    guard isEditing else { return }
    if collapsed.contains(metric) {
      collapsed.remove(metric)
    } else {
      collapsed.insert(metric)
    }
  }

  func remove(_ metric: WatchtowerAnalyticsMetric) {
    guard isEditing else { return }
    hidden.insert(metric)
    collapsed.remove(metric)
    if draggedMetric == metric { draggedMetric = nil }
    if dropTargetMetric == metric { dropTargetMetric = nil }
  }

  func add(_ metric: WatchtowerAnalyticsMetric) {
    guard isEditing else { return }
    hidden.remove(metric)
  }

  func move(_ metric: WatchtowerAnalyticsMetric, across target: WatchtowerAnalyticsMetric) {
    guard isEditing, !hidden.contains(metric), !hidden.contains(target) else { return }
    order = WatchtowerAnalyticsCardLayout.moving(order, item: metric, across: target)
  }

  func moveVisible(_ metric: WatchtowerAnalyticsMetric, offset: Int) {
    guard let index = visibleMetrics.firstIndex(of: metric) else { return }
    let targetIndex = index + offset
    guard visibleMetrics.indices.contains(targetIndex) else { return }
    move(metric, across: visibleMetrics[targetIndex])
  }

  @discardableResult
  func beginDragging(_ metric: WatchtowerAnalyticsMetric) -> Bool {
    guard isEditing, !hidden.contains(metric) else { return false }
    draggedMetric = metric
    dropTargetMetric = nil
    return true
  }

  func targetDrop(on metric: WatchtowerAnalyticsMetric) {
    guard draggedMetric != nil else { return }
    dropTargetMetric = metric
  }

  func clearDropTarget() {
    dropTargetMetric = nil
  }

  func finishDragging() {
    draggedMetric = nil
    dropTargetMetric = nil
  }

  private func finishEditing() {
    isEditing = false
    savedDraft = nil
    finishDragging()
  }
}

struct WatchtowerMetricDragPresentation: Equatable {
  let metric: WatchtowerAnalyticsMetric
  let size: CGSize
  let grabOffset: CGPoint
  let isExpanded: Bool
  var location: CGPoint

  var center: CGPoint {
    CGPoint(
      x: location.x - grabOffset.x,
      y: location.y - grabOffset.y)
  }
}

@MainActor
@Observable
final class WatchtowerMetricDragVisualState {
  private(set) var presentation: WatchtowerMetricDragPresentation?
  private(set) var isSettling = false
  @ObservationIgnored weak var coordinateView: UIView?
  @ObservationIgnored private var retainedDelegate: AnyObject?
  @ObservationIgnored private var sourceViews: [WatchtowerAnalyticsMetric: WeakView] = [:]

  private final class WeakView {
    weak var value: UIView?

    init(_ value: UIView) {
      self.value = value
    }
  }

  func begin(
    metric: WatchtowerAnalyticsMetric,
    size: CGSize,
    location: CGPoint,
    grabOffset: CGPoint,
    isExpanded: Bool,
    retaining delegate: AnyObject
  ) {
    retainedDelegate = delegate
    isSettling = false
    presentation = WatchtowerMetricDragPresentation(
      metric: metric,
      size: size,
      grabOffset: grabOffset,
      isExpanded: isExpanded,
      location: location)
  }

  func move(to location: CGPoint) {
    guard var presentation else { return }
    presentation.location = location
    self.presentation = presentation
  }

  func moveCenter(to center: CGPoint) {
    guard var presentation else { return }
    presentation.location = CGPoint(
      x: center.x + presentation.grabOffset.x,
      y: center.y + presentation.grabOffset.y)
    self.presentation = presentation
  }

  func registerSourceView(_ view: UIView, for metric: WatchtowerAnalyticsMetric) {
    sourceViews[metric] = WeakView(view)
  }

  func unregisterSourceView(_ view: UIView, for metric: WatchtowerAnalyticsMetric) {
    guard sourceViews[metric]?.value === view else { return }
    sourceViews[metric] = nil
  }

  func sourceCenter(for metric: WatchtowerAnalyticsMetric) -> CGPoint? {
    guard let coordinateView, let view = sourceViews[metric]?.value else { return nil }
    let frame = view.convert(view.bounds, to: coordinateView)
    guard frame.width > 0, frame.height > 0 else { return nil }
    return CGPoint(x: frame.midX, y: frame.midY)
  }

  func beginSettling() {
    guard presentation != nil else { return }
    isSettling = true
  }

  func finish() {
    presentation = nil
    isSettling = false
    retainedDelegate = nil
  }
}

enum WatchtowerAnalyticsChartModel {
  struct MetricSnapshot: Hashable, Sendable {
    static let empty = MetricSnapshot(
      expandedData: [], collapsedData: [], collapsedValueCeiling: nil)

    let expandedData: [DitherDatum]
    let collapsedData: [DitherDatum]
    let collapsedValueCeiling: Double?

    var isEmpty: Bool { expandedData.isEmpty }
  }

  struct Snapshot: Hashable, Sendable {
    let overview: AccountAnalyticsOverview
    let charts: [WatchtowerAnalyticsMetric: MetricSnapshot]
    let fetchedAt: Date
  }

  static func updatedTitle(fetchedAt: Date?, loading: Bool, now: Date = .now) -> String {
    guard let fetchedAt else {
      return loading ? DashL10n.ui("Updating…") : DashL10n.ui("Overview")
    }
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = DashL10n.activeLocale
    formatter.unitsStyle = .full
    let when = formatter.localizedString(for: fetchedAt, relativeTo: now)
    return DashL10n.string("Updated \(when)")
  }

  static func chartPoints(from points: [AccountAnalyticsPoint]) -> [(
    date: Date, point: AccountAnalyticsPoint
  )] {
    let parsers = timestampParsers()
    return chartPoints(from: points, parsers: parsers)
  }

  /// Builds every metric's render-ready series once when a network/cache
  /// snapshot enters state. SwiftUI card updates then reuse stable IDs, labels,
  /// ordering, and zero-floor data without reparsing the same timestamps.
  static func snapshot(
    from snapshot: AccountAnalyticsSnapshot,
    range: AnalyticsRange,
    locale: Locale
  ) -> Snapshot {
    let parsers = timestampParsers()
    let http = labeledPoints(
      chartPoints(from: snapshot.httpPoints, parsers: parsers),
      range: range,
      locale: locale)
    let workers = labeledPoints(
      chartPoints(from: snapshot.workerPoints, parsers: parsers),
      range: range,
      locale: locale)

    var charts: [WatchtowerAnalyticsMetric: MetricSnapshot] = [:]
    charts.reserveCapacity(WatchtowerAnalyticsMetric.allCases.count)
    for metric in WatchtowerAnalyticsMetric.allCases {
      let points = metric.usesHTTPSeries ? http : workers
      let values = points.map { seriesValue($0.point, metric: metric) }
      let collapsed = collapsedSeriesValues(values)
      charts[metric] = MetricSnapshot(
        expandedData: zip(points, values).map { point, value in
          DitherDatum(
            id: point.id,
            label: point.label,
            values: [metric.seriesKey: value])
        },
        collapsedData: zip(points, collapsed.values).map { point, value in
          DitherDatum(
            id: point.id,
            label: point.label,
            values: [metric.seriesKey: value])
        },
        collapsedValueCeiling: collapsed.valueCeiling)
    }

    return Snapshot(
      overview: snapshot.overview,
      charts: charts,
      fetchedAt: snapshot.fetchedAt)
  }

  private static func timestampParsers() -> (
    hour: ISO8601DateFormatter,
    fractional: ISO8601DateFormatter,
    day: DateFormatter
  ) {
    let hour = ISO8601DateFormatter()
    hour.formatOptions = [.withInternetDateTime]
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let day: DateFormatter = {
      let formatter = DateFormatter()
      formatter.dateFormat = "yyyy-MM-dd"
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(identifier: "UTC")
      return formatter
    }()
    return (hour, fractional, day)
  }

  private static func chartPoints(
    from points: [AccountAnalyticsPoint],
    parsers: (
      hour: ISO8601DateFormatter,
      fractional: ISO8601DateFormatter,
      day: DateFormatter
    )
  ) -> [(date: Date, point: AccountAnalyticsPoint)] {
    let dated: [(date: Date, index: Int, point: AccountAnalyticsPoint)] =
      points.enumerated().compactMap { index, point in
        let date =
          parsers.hour.date(from: point.datetime)
          ?? parsers.fractional.date(from: point.datetime)
          ?? parsers.day.date(from: point.datetime)
        guard let date else { return nil }
        return (date: date, index: index, point: point)
      }
    return dated.sorted {
      if $0.date == $1.date { return $0.index < $1.index }
      return $0.date < $1.date
    }
    .map { ($0.date, $0.point) }
  }

  private static func labeledPoints(
    _ points: [(date: Date, point: AccountAnalyticsPoint)],
    range: AnalyticsRange,
    locale: Locale
  ) -> [(id: String, label: String, point: AccountAnalyticsPoint)] {
    var occurrences: [String: Int] = [:]
    return points.map { date, point in
      let occurrence = occurrences[point.datetime, default: 0]
      occurrences[point.datetime] = occurrence + 1
      let id = occurrence == 0 ? point.datetime : "\(point.datetime)#\(occurrence)"
      return (
        id: id,
        label: chartLabel(date, range: range, locale: locale),
        point: point
      )
    }
  }

  private static func chartLabel(_ date: Date, range: AnalyticsRange, locale: Locale) -> String {
    if range == .month {
      return date.formatted(.dateTime.month(.abbreviated).day().locale(locale))
    }
    return date.formatted(.dateTime.hour().locale(locale))
  }

  static func seriesValue(_ point: AccountAnalyticsPoint, metric: WatchtowerAnalyticsMetric)
    -> Double
  {
    switch metric {
    case .workerInvocations, .webTraffic: Double(point.requests)
    case .workerErrors: Double(point.errors)
    case .cpuTime: point.cpuTimeP90Us / 1000
    case .totalBandwidth: Double(point.bytes)
    case .cacheRate: point.cacheRate * 100
    case .clientRequestErrors: point.clientErrorRate * 100
    case .encryptedRequestsRate: point.encryptedRequestRate * 100
    case .encryptedBandwidth: Double(point.encryptedBytes)
    }
  }

  /// Collapsed sparklines lift true zeros off the floor so a quiet series still
  /// paints a short dither band (~10% of the peak). All-zero / empty series use
  /// a synthetic peak of `1` with the same floor ratio, plus a matching
  /// `valueCeiling` so the flat band does not expand to full height.
  static func collapsedSeriesValues(_ values: [Double]) -> (
    values: [Double], valueCeiling: Double?
  ) {
    let peak = values.max() ?? 0
    if peak > 0 {
      let floor = peak * 0.1
      return (values.map { max($0, floor) }, nil)
    }
    let syntheticPeak = 1.0
    let floor = syntheticPeak * 0.1
    return (values.map { _ in floor }, syntheticPeak)
  }

  static func totalValue(
    _ overview: AccountAnalyticsOverview,
    metric: WatchtowerAnalyticsMetric
  ) -> (text: String, numeric: Double) {
    switch metric {
    case .workerInvocations:
      (overview.workerInvocations.formatted(), Double(overview.workerInvocations))
    case .workerErrors:
      (overview.workerErrors.formatted(), Double(overview.workerErrors))
    case .cpuTime:
      (String(format: "%.2f ms", overview.cpuTimeP90Us / 1000), overview.cpuTimeP90Us)
    case .webTraffic:
      (overview.webRequests.formatted(), Double(overview.webRequests))
    case .totalBandwidth:
      (bandwidth(overview.bytes), Double(overview.bytes))
    case .cacheRate:
      (percent(overview.cacheRate), overview.cacheRate)
    case .clientRequestErrors:
      (percent(overview.clientErrorRate), overview.clientErrorRate)
    case .encryptedRequestsRate:
      (percent(overview.encryptedRequestRate), overview.encryptedRequestRate)
    case .encryptedBandwidth:
      (bandwidth(overview.encryptedBytes), Double(overview.encryptedBytes))
    }
  }

  static func accessibilitySummary(
    metric: WatchtowerAnalyticsMetric,
    rangeLabel: String,
    value: String
  ) -> String {
    DashL10n.string("\(metric.title) for \(rangeLabel). Total \(value).")
  }

  private static func bandwidth(_ bytes: Int64) -> String {
    bytes.formatted(.byteCount(style: .binary).locale(DashL10n.activeLocale))
  }

  private static func percent(_ rate: Double) -> String {
    rate.formatted(
      .percent.precision(.fractionLength(1)).locale(DashL10n.activeLocale))
  }
}

@MainActor
@Observable
final class WatchtowerTrafficState {
  var range: AnalyticsRange = .day
  var snapshots: [AnalyticsRange: WatchtowerAnalyticsChartModel.Snapshot] = [:]
  var errorByRange: [AnalyticsRange: String] = [:]
  var loadingRanges: Set<AnalyticsRange> = []
  var needsAnalyticsAccess = false

  private var loadedContext: AccountRequestContext?
  private var rangeLoadIDs: [AnalyticsRange: UUID] = [:]

  var snapshot: WatchtowerAnalyticsChartModel.Snapshot? { snapshots[range] }
  var overview: AccountAnalyticsOverview? { snapshot?.overview }
  var fetchedAt: Date? { snapshot?.fetchedAt }
  var isLoadingCurrent: Bool { loadingRanges.contains(range) }
  /// Warm refresh — content stays on screen while ranges reload.
  var isRefreshing: Bool { !loadingRanges.isEmpty && overview != nil }
  var currentError: String? { errorByRange[range] }

  func load(model: AppModel, force: Bool = false) async {
    guard let context = model.accountRequestContext else {
      reset()
      return
    }

    if loadedContext != context {
      reset(context: context)
    }

    // Session cache paints first so tab re-entry and range switches stay warm.
    if !force {
      hydrateFromCache(model: model, context: context)
    }

    if !force,
      loadedContext == context,
      snapshots[.day] != nil,
      snapshots[.week] != nil,
      snapshots[.month] != nil
    {
      loadingRanges = []
      return
    }

    if !model.hasScopes(DashAuthorizationScopes.accountAnalytics) {
      needsAnalyticsAccess = true
      loadingRanges = []
      return
    }
    needsAnalyticsAccess = false

    let targets: [AnalyticsRange]
    if force {
      targets = AnalyticsRange.allCases
      loadingRanges = Set(targets)
    } else {
      targets = AnalyticsRange.allCases.filter { snapshots[$0] == nil }
      loadingRanges.formUnion(targets)
    }
    guard !targets.isEmpty else { return }

    async let day: Void = loadRange(.day, model: model, context: context, force: force)
    async let week: Void = loadRange(.week, model: model, context: context, force: force)
    async let month: Void = loadRange(.month, model: model, context: context, force: force)
    _ = await (day, week, month)
  }

  func retry(model: AppModel) async {
    await load(model: model, force: true)
  }

  private func hydrateFromCache(model: AppModel, context: AccountRequestContext) {
    for target in AnalyticsRange.allCases {
      let key = FeatureCacheKey.accountAnalytics(
        context.accountID, hours: target.accountAnalyticsHours)
      // Session-scoped entries use `ttl: nil`, so this survives the whole sign-in.
      if let cached: AccountAnalyticsSnapshot = model.featureCache.get(key, maxAge: nil) {
        snapshots[target] = WatchtowerAnalyticsChartModel.snapshot(
          from: cached,
          range: target,
          locale: DashL10n.activeLocale)
        errorByRange[target] = nil
      }
    }
  }

  private func loadRange(
    _ target: AnalyticsRange,
    model: AppModel,
    context: AccountRequestContext,
    force: Bool
  ) async {
    guard force || snapshots[target] == nil else {
      loadingRanges.remove(target)
      return
    }

    let key = FeatureCacheKey.accountAnalytics(
      context.accountID, hours: target.accountAnalyticsHours)
    if !force, let cached: AccountAnalyticsSnapshot = model.featureCache.get(key, maxAge: nil) {
      snapshots[target] = WatchtowerAnalyticsChartModel.snapshot(
        from: cached,
        range: target,
        locale: DashL10n.activeLocale)
      errorByRange[target] = nil
      loadingRanges.remove(target)
      return
    }

    let token = UUID()
    rangeLoadIDs[target] = token
    do {
      let rawSnapshot = try await model.client.accountAnalytics(
        accountID: context.accountID,
        hours: target.accountAnalyticsHours,
        granularity: target.accountAnalyticsGranularity)
      guard rangeLoadIDs[target] == token, model.isCurrentAccount(context) else { return }
      // Keep until sign-out / account switch — Refresh is the explicit invalidation.
      model.featureCache.set(key, rawSnapshot, ttl: nil)
      snapshots[target] = WatchtowerAnalyticsChartModel.snapshot(
        from: rawSnapshot,
        range: target,
        locale: DashL10n.activeLocale)
      errorByRange[target] = nil
    } catch {
      guard rangeLoadIDs[target] == token, model.isCurrentAccount(context) else { return }
      if snapshots[target] == nil {
        errorByRange[target] = error.dashActionableMessage
      }
      if let apiError = error as? CloudflareAPIError, apiError.isForbidden {
        needsAnalyticsAccess = true
      }
    }
    loadingRanges.remove(target)
  }

  private func reset(context: AccountRequestContext? = nil) {
    loadedContext = context
    rangeLoadIDs = [:]
    snapshots = [:]
    errorByRange = [:]
    loadingRanges = context == nil ? [] : Set(AnalyticsRange.allCases)
    needsAnalyticsAccess = false
    range = .day
  }
}

struct WatchtowerTrafficView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Bindable var state: WatchtowerTrafficState
  let customization: WatchtowerChartCustomizationState
  let isEditing: Bool
  let morphNamespace: Namespace.ID
  @State private var dragVisual = WatchtowerMetricDragVisualState()

  private var collapsedRaw: String {
    WatchtowerAnalyticsCardLayout.encode(Set(customization.collapsed.map(\.rawValue)))
  }

  private var metricRows: [[WatchtowerAnalyticsMetric]] {
    WatchtowerAnalyticsCardLayout.rows(
      customization.visibleMetrics,
      collapsedRaw: collapsedRaw,
      forceExpanded: dynamicTypeSize.isAccessibilitySize)
  }

  var body: some View {
    ZStack(alignment: .topLeading) {
      VStack(alignment: .leading, spacing: DashTheme.Spacing.section) {
        if isEditing {
          customizationHeader
        } else {
          VStack(alignment: .leading, spacing: 8) {
            refreshHeader
              .padding(.horizontal, 4)
            DashTextTabs(
              items: [("24h", AnalyticsRange.day), ("7d", .week), ("30d", .month)],
              selection: $state.range
            )
          }
        }

        if state.needsAnalyticsAccess, state.overview == nil {
          statusCard {
            emptyContent(
              title: "Analytics access needed",
              message: "Allow Account Analytics: Read to load account traffic.",
              buttonTitle: "Grant access"
            ) {
              model.requestAccess(to: DashAuthorizationScopes.accountAnalytics)
            }
          }
        } else if state.isLoadingCurrent, state.overview == nil {
          statusCard { loadingContent }
        } else if let error = state.currentError, state.overview == nil {
          statusCard {
            emptyContent(
              title: "Traffic unavailable",
              message: error,
              buttonTitle: "Try again"
            ) {
              Task { await state.retry(model: model) }
            }
          }
        } else if let overview = state.overview, let snapshot = state.snapshot {
          if customization.visibleMetrics.isEmpty {
            statusCard {
              emptyContent(
                title: DashL10n.string("No charts"),
                message: DashL10n.string("Add a chart to rebuild this view.")
              )
            }
          } else {
            VStack(alignment: .leading, spacing: DashTheme.Spacing.itemGap) {
              ForEach(metricRows, id: \.rowID) { row in
                metricRow(row, overview: overview, snapshot: snapshot)
              }
              if let error = state.currentError {
                DashNotice(kind: .warning, message: error)
              }
            }
          }
        }
      }

      if isEditing, let overview = state.overview {
        WatchtowerMetricDragOverlay(
          state: dragVisual,
          overview: overview,
          range: state.range
        )
      }
    }
    .background {
      if isEditing {
        WatchtowerMetricDragCoordinateView(state: dragVisual)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .allowsHitTesting(false)
      }
    }
    .accessibilityIdentifier(isEditing ? "watchtower-chart-editor" : "watchtower-charts")
    .onDrop(of: [UTType.plainText], isTargeted: nil) { _ in
      guard isEditing, customization.draggedMetric != nil else { return false }
      customization.clearDropTarget()
      return true
    }
  }

  private func isExpanded(_ metric: WatchtowerAnalyticsMetric) -> Bool {
    if dynamicTypeSize.isAccessibilitySize { return true }
    return customization.isExpanded(metric)
  }

  @ViewBuilder
  private func metricRow(
    _ row: [WatchtowerAnalyticsMetric],
    overview: AccountAnalyticsOverview,
    snapshot: WatchtowerAnalyticsChartModel.Snapshot
  ) -> some View {
    if row.count == 1, let metric = row.first, isExpanded(metric) {
      reorderableMetricCard(metric, overview: overview, snapshot: snapshot, expanded: true)
    } else {
      HStack(alignment: .top, spacing: DashTheme.Spacing.itemGap) {
        ForEach(row) { metric in
          reorderableMetricCard(metric, overview: overview, snapshot: snapshot, expanded: false)
            .frame(maxWidth: .infinity)
        }
        if row.count == 1 {
          Color.clear.frame(maxWidth: .infinity)
        }
      }
    }
  }

  @ViewBuilder
  private func reorderableMetricCard(
    _ metric: WatchtowerAnalyticsMetric,
    overview: AccountAnalyticsOverview,
    snapshot: WatchtowerAnalyticsChartModel.Snapshot,
    expanded: Bool
  ) -> some View {
    let card = metricCard(
      metric, overview: overview, snapshot: snapshot, expanded: expanded)
    if isEditing {
      card
        .opacity(customization.draggedMetric == metric ? 0 : 1)
        .overlay {
          if customization.draggedMetric == metric {
            WatchtowerMetricDropPlaceholder()
          }
        }
        .scaleEffect(customization.dropTargetMetric == metric ? 1.015 : 1)
        .contentShape(
          RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous)
        )
        .overlay {
          WatchtowerNativeMetricDragSource(
            metric: metric,
            isExpanded: expanded,
            customization: customization,
            visualState: dragVisual
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .accessibilityHidden(true)
        }
        .onDrop(
          of: [UTType.plainText],
          delegate: WatchtowerMetricDropDelegate(
            target: metric,
            customization: customization,
            reduceMotion: reduceMotion)
        )
        .accessibilityHint(DashL10n.string("Touch and hold, then drag to reorder"))
        .accessibilityAction(named: DashL10n.string("Move up")) {
          withAnimation(reduceMotion ? nil : DashTheme.Motion.morph) {
            customization.moveVisible(metric, offset: -1)
          }
        }
        .accessibilityAction(named: DashL10n.string("Move down")) {
          withAnimation(reduceMotion ? nil : DashTheme.Motion.morph) {
            customization.moveVisible(metric, offset: 1)
          }
        }
    } else {
      card
    }
  }

  private func metricCard(
    _ metric: WatchtowerAnalyticsMetric,
    overview: AccountAnalyticsOverview,
    snapshot: WatchtowerAnalyticsChartModel.Snapshot,
    expanded: Bool
  ) -> some View {
    WatchtowerMetricChartCard(
      metric: metric,
      overview: overview,
      // Editing never constructs a dither chart, so keep its view value free
      // of the potentially large point arrays as cards reorder.
      chart: isEditing ? .empty : snapshot.charts[metric] ?? .empty,
      range: state.range,
      isExpanded: expanded,
      isEditing: isEditing,
      renderingMode: WatchtowerMetricChartRenderingMode.resolved(isEditing: isEditing),
      morphNamespace: morphNamespace,
      onToggleExpanded: {
        withAnimation(reduceMotion ? nil : DashTheme.Motion.morph) {
          customization.toggleExpanded(metric)
        }
      },
      onRemove: {
        withAnimation(reduceMotion ? nil : DashTheme.Motion.morph) {
          customization.remove(metric)
        }
        DashDelight.selectionChanged()
      }
    )
  }

  private var customizationHeader: some View {
    HStack(spacing: 12) {
      DashSectionHeader(DashL10n.string("Charts"))
      Spacer(minLength: 0)
      addChartMenu
    }
  }

  private var addChartMenu: some View {
    Menu {
      if customization.addableMetrics.isEmpty {
        Button(DashL10n.string("All charts are shown")) {}
          .disabled(true)
      } else {
        ForEach(customization.addableMetrics) { metric in
          Button(DashL10n.ui(metric.title)) {
            withAnimation(reduceMotion ? nil : DashTheme.Motion.morph) {
              customization.add(metric)
            }
            DashDelight.selectionChanged()
          }
        }
      }
    } label: {
      SolarIcon(asset: SolarAsset.plus, size: 17, color: DashTheme.brand)
        .frame(width: 32, height: 32)
        .background(DashTheme.homeCardSurface, in: Circle())
        .dashEmbossChrome(shape: Circle())
    }
    .buttonStyle(DashPressButtonStyle())
    .accessibilityLabel(DashL10n.string("Add chart"))
    .accessibilityIdentifier("watchtower-add-chart")
  }

  /// Resources-style group title: relative “Updated …” on the leading edge,
  /// Refresh (or a spinner while warm-reloading) on the trailing edge.
  private var refreshHeader: some View {
    TimelineView(.periodic(from: .now, by: 60)) { context in
      HStack(spacing: 12) {
        Text(refreshTitle(relativeTo: context.date))
          .dashTextStyle(.supportingMedium)
          .foregroundStyle(DashTheme.listGroupTitle)
          .lineLimit(1)
          .minimumScaleFactor(0.85)
        Spacer(minLength: 0)
        if state.isRefreshing {
          DashLoadingRing(color: DashTheme.brand, size: 16, lineWidth: 2.5)
            .accessibilityLabel(DashL10n.ui("Refreshing"))
            .dashHeaderActionHitTarget()
        } else {
          Button {
            Task { await state.retry(model: model) }
          } label: {
            Text(DashL10n.ui("Refresh"))
              .dashTextStyle(.supportingMedium)
              .foregroundStyle(DashTheme.brand)
          }
          .buttonStyle(DashPressButtonStyle())
          .disabled(state.isLoadingCurrent && state.overview == nil)
          .dashHeaderActionHitTarget()
        }
      }
      .accessibilityElement(children: .combine)
    }
  }

  private func refreshTitle(relativeTo now: Date) -> String {
    WatchtowerAnalyticsChartModel.updatedTitle(
      fetchedAt: state.fetchedAt,
      loading: state.isLoadingCurrent && state.overview == nil,
      now: now)
  }

  private func statusCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous)
    return content()
      .padding(DashTheme.Spacing.card)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(DashTheme.homeCardSurface, in: shape)
      .dashEmbossChrome(shape: shape)
  }

  private var loadingContent: some View {
    VStack(spacing: 10) {
      DashLoadingRing(color: DashTheme.brand)
      Text("Loading account traffic…")
        .dashTextStyle(.caption)
        .foregroundStyle(DashTheme.placeholder)
    }
    .frame(maxWidth: .infinity, minHeight: 190)
    .accessibilityElement(children: .combine)
  }

  private func emptyContent(
    title: String,
    message: String,
    buttonTitle: String? = nil,
    action: (() -> Void)? = nil
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .dashTextStyle(.supportingMedium)
        .foregroundStyle(DashTheme.text)
      Text(message)
        .dashTextStyle(.footnote)
        .foregroundStyle(DashTheme.rowSubtitle)
        .fixedSize(horizontal: false, vertical: true)
      if let buttonTitle, let action {
        Button(buttonTitle, action: action)
          .dashTextStyle(.supportingMedium)
          .foregroundStyle(DashTheme.brand)
          .frame(minHeight: DashTheme.Layout.minimumHitTarget)
          .buttonStyle(DashPressButtonStyle())
      }
    }
    .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
  }
}

enum WatchtowerMetricChartRenderingMode: Equatable {
  case live
  case placeholder

  static func resolved(isEditing: Bool) -> Self {
    isEditing ? .placeholder : .live
  }

  var usesDitherChart: Bool { self == .live }
}

private enum WatchtowerMetricDragLayout {
  static let controlsPassthroughSize = CGSize(width: 96, height: 60)
}

private struct WatchtowerMetricDropPlaceholder: View {
  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous)
  }

  var body: some View {
    shape
      .fill(DashTheme.recessed.opacity(0.34))
      .overlay {
        shape.strokeBorder(
          DashTheme.brand.opacity(0.52),
          style: StrokeStyle(
            lineWidth: 1.5,
            lineCap: .round,
            lineJoin: .round,
            dash: [7, 5])
        )
      }
      .accessibilityHidden(true)
  }
}

private final class WatchtowerDragCoordinateUIView: UIView {
  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    false
  }
}

private struct WatchtowerMetricDragCoordinateView: UIViewRepresentable {
  let state: WatchtowerMetricDragVisualState

  func makeUIView(context: Context) -> WatchtowerDragCoordinateUIView {
    let view = WatchtowerDragCoordinateUIView()
    view.backgroundColor = .clear
    view.isOpaque = false
    state.coordinateView = view
    return view
  }

  func updateUIView(_ uiView: WatchtowerDragCoordinateUIView, context: Context) {
    if state.coordinateView !== uiView {
      state.coordinateView = uiView
    }
  }

  static func dismantleUIView(
    _ uiView: WatchtowerDragCoordinateUIView,
    coordinator: Void
  ) {
    // An active drag can outlive a SwiftUI row reconstruction. The weak
    // coordinate reference is replaced by the next mounted host if needed.
  }
}

private final class WatchtowerMetricDragSourceUIView: UIView {
  var passthroughSize = WatchtowerMetricDragLayout.controlsPassthroughSize

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    guard super.point(inside: point, with: event) else { return false }
    let width = min(bounds.width, passthroughSize.width)
    let height = min(bounds.height, passthroughSize.height)
    let x =
      effectiveUserInterfaceLayoutDirection == .rightToLeft
      ? bounds.minX
      : bounds.maxX - width
    let controlsFrame = CGRect(x: x, y: bounds.minY, width: width, height: height)
    return !controlsFrame.contains(point)
  }
}

private struct WatchtowerNativeMetricDragSource: UIViewRepresentable {
  let metric: WatchtowerAnalyticsMetric
  let isExpanded: Bool
  let customization: WatchtowerChartCustomizationState
  let visualState: WatchtowerMetricDragVisualState

  func makeCoordinator() -> Coordinator {
    Coordinator(
      metric: metric,
      isExpanded: isExpanded,
      customization: customization,
      visualState: visualState)
  }

  func makeUIView(context: Context) -> WatchtowerMetricDragSourceUIView {
    let view = WatchtowerMetricDragSourceUIView()
    view.backgroundColor = .clear
    view.isOpaque = false
    view.accessibilityElementsHidden = true

    let interaction = UIDragInteraction(delegate: context.coordinator)
    interaction.isEnabled = true
    view.addInteraction(interaction)
    visualState.registerSourceView(view, for: metric)
    return view
  }

  func updateUIView(_ uiView: WatchtowerMetricDragSourceUIView, context: Context) {
    let previousMetric = context.coordinator.metric
    if previousMetric != metric {
      visualState.unregisterSourceView(uiView, for: previousMetric)
      visualState.registerSourceView(uiView, for: metric)
    }
    context.coordinator.metric = metric
    context.coordinator.isExpanded = isExpanded
  }

  static func dismantleUIView(
    _ uiView: WatchtowerMetricDragSourceUIView,
    coordinator: Coordinator
  ) {
    coordinator.visualState.unregisterSourceView(uiView, for: coordinator.metric)
  }

  @MainActor
  final class Coordinator: NSObject, UIDragInteractionDelegate {
    var metric: WatchtowerAnalyticsMetric
    var isExpanded: Bool
    private let customization: WatchtowerChartCustomizationState
    fileprivate let visualState: WatchtowerMetricDragVisualState
    private var active = false
    private var settling = false
    private var activeInteraction: UIDragInteraction?
    private var settleTask: Task<Void, Never>?

    init(
      metric: WatchtowerAnalyticsMetric,
      isExpanded: Bool,
      customization: WatchtowerChartCustomizationState,
      visualState: WatchtowerMetricDragVisualState
    ) {
      self.metric = metric
      self.isExpanded = isExpanded
      self.customization = customization
      self.visualState = visualState
    }

    func dragInteraction(
      _ interaction: UIDragInteraction,
      itemsForBeginning session: any UIDragSession
    ) -> [UIDragItem] {
      guard let sourceView = interaction.view,
        let coordinateView = visualState.coordinateView,
        customization.beginDragging(metric)
      else { return [] }

      let location = session.location(in: coordinateView)
      let sourceLocation = session.location(in: sourceView)
      let grabOffset = CGPoint(
        x: sourceLocation.x - sourceView.bounds.midX,
        y: sourceLocation.y - sourceView.bounds.midY)

      active = true
      activeInteraction = interaction
      visualState.begin(
        metric: metric,
        size: sourceView.bounds.size,
        location: location,
        grabOffset: grabOffset,
        isExpanded: isExpanded,
        retaining: self)

      let provider = NSItemProvider(object: metric.rawValue as NSString)
      let item = UIDragItem(itemProvider: provider)
      item.localObject = metric.rawValue
      return [item]
    }

    func dragInteraction(
      _ interaction: UIDragInteraction,
      previewForLifting item: UIDragItem,
      session: any UIDragSession
    ) -> UITargetedDragPreview? {
      // UIKit documents nil as an invisible item with no system lift preview.
      nil
    }

    func dragInteraction(
      _ interaction: UIDragInteraction,
      sessionDidMove session: any UIDragSession
    ) {
      guard active, let coordinateView = visualState.coordinateView else { return }
      visualState.move(to: session.location(in: coordinateView))
    }

    func dragInteraction(
      _ interaction: UIDragInteraction,
      sessionIsRestrictedToDraggingApplication session: any UIDragSession
    ) -> Bool {
      true
    }

    func dragInteraction(
      _ interaction: UIDragInteraction,
      session: any UIDragSession,
      willEndWith operation: UIDropOperation
    ) {
      settleDrag()
    }

    func dragInteraction(
      _ interaction: UIDragInteraction,
      session: any UIDragSession,
      didEndWith operation: UIDropOperation
    ) {
      guard active, !settling else { return }
      completeDrag()
    }

    private func settleDrag() {
      guard active, !settling else { return }
      active = false
      settling = true

      guard let targetCenter = visualState.sourceCenter(for: metric) else {
        completeDrag()
        return
      }

      let reduceMotion = UIAccessibility.isReduceMotionEnabled
      visualState.beginSettling()
      withAnimation(reduceMotion ? DashTheme.Motion.reduced : DashTheme.Motion.morph) {
        visualState.moveCenter(to: targetCenter)
      }

      let delay = reduceMotion ? 120 : 280
      settleTask = Task { @MainActor [weak self] in
        try? await Task.sleep(for: .milliseconds(delay))
        guard !Task.isCancelled else { return }
        self?.completeDrag()
      }
    }

    private func completeDrag() {
      settleTask?.cancel()
      settleTask = nil
      active = false
      settling = false
      activeInteraction = nil
      customization.finishDragging()
      visualState.finish()
    }
  }
}

private struct WatchtowerMetricDragOverlay: View {
  let state: WatchtowerMetricDragVisualState
  let overview: AccountAnalyticsOverview
  let range: AnalyticsRange
  @Namespace private var previewNamespace

  var body: some View {
    ZStack(alignment: .topLeading) {
      if let presentation = state.presentation {
        WatchtowerMetricChartCard(
          metric: presentation.metric,
          overview: overview,
          chart: .empty,
          range: range,
          isExpanded: presentation.isExpanded,
          isEditing: true,
          renderingMode: .placeholder,
          morphNamespace: previewNamespace,
          onToggleExpanded: {},
          onRemove: {}
        )
        .frame(width: presentation.size.width, height: presentation.size.height)
        .position(presentation.center)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .zIndex(1)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .allowsHitTesting(false)
    // Finger tracking must not inherit the row-reorder morph animation.
    .transaction { transaction in
      if !state.isSettling {
        transaction.animation = nil
      }
    }
  }
}

private struct WatchtowerMetricDropDelegate: DropDelegate {
  let target: WatchtowerAnalyticsMetric
  let customization: WatchtowerChartCustomizationState
  let reduceMotion: Bool

  func dropEntered(info: DropInfo) {
    guard let dragged = customization.draggedMetric, dragged != target else { return }
    customization.targetDrop(on: target)
    withAnimation(reduceMotion ? nil : DashTheme.Motion.morph) {
      customization.move(dragged, across: target)
    }
    DashDelight.selectionChanged()
  }

  func dropExited(info: DropInfo) {
    if customization.dropTargetMetric == target {
      customization.clearDropTarget()
    }
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    DropProposal(operation: .move)
  }

  func performDrop(info: DropInfo) -> Bool {
    // The source UIDragInteraction owns the visual session lifetime. Keep the
    // slot in place until its delegate receives the matching native end event.
    customization.clearDropTarget()
    return true
  }
}

private enum WatchtowerAnalyticsMorphID {
  static func card(_ metric: WatchtowerAnalyticsMetric) -> String {
    "wt.analytics.\(metric.rawValue).card"
  }
  static func title(_ metric: WatchtowerAnalyticsMetric) -> String {
    "wt.analytics.\(metric.rawValue).title"
  }
  static func value(_ metric: WatchtowerAnalyticsMetric) -> String {
    "wt.analytics.\(metric.rawValue).value"
  }
  static func toggle(_ metric: WatchtowerAnalyticsMetric) -> String {
    "wt.analytics.\(metric.rawValue).toggle"
  }
  static func chart(_ metric: WatchtowerAnalyticsMetric) -> String {
    "wt.analytics.\(metric.rawValue).chart"
  }
}

private struct WatchtowerMetricChartCard: View {
  private static let placeholderRatios: [CGFloat] = [0.28, 0.5, 0.38, 0.72, 0.56, 0.84, 0.64]

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let metric: WatchtowerAnalyticsMetric
  let overview: AccountAnalyticsOverview
  let chart: WatchtowerAnalyticsChartModel.MetricSnapshot
  let range: AnalyticsRange
  let isExpanded: Bool
  let isEditing: Bool
  let renderingMode: WatchtowerMetricChartRenderingMode
  let morphNamespace: Namespace.ID
  let onToggleExpanded: () -> Void
  let onRemove: () -> Void
  @State private var selectedSeriesID: String?

  private var total: (text: String, numeric: Double) {
    WatchtowerAnalyticsChartModel.totalValue(overview, metric: metric)
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

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      chartBody
        .matchedGeometryEffect(
          id: WatchtowerAnalyticsMorphID.chart(metric), in: morphNamespace
        )
        .padding(.horizontal, isExpanded ? DashTheme.Spacing.card : 0)
        .padding(.bottom, isExpanded ? DashTheme.Spacing.card : 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    // Clip only the fill — not the whole card — so expanded-chart tooltips can
    // paint past the panel edge. Chart bodies that sit flush still clip locally.
    .background {
      DashTheme.homeCardSurface
        .clipShape(panelShape)
        .matchedGeometryEffect(
          id: WatchtowerAnalyticsMorphID.card(metric), in: morphNamespace)
    }
    .dashEmbossChrome(shape: panelShape)
    .shadow(
      color: isEditing
        ? Color.black.opacity(colorScheme == .dark ? 0.28 : 0.12) : .clear,
      radius: isEditing ? 12 : 0,
      y: isEditing ? 6 : 0
    )
    .overlay(alignment: .topTrailing) {
      if isEditing {
        cardControls
      }
    }
    .onChange(of: range) { selectedSeriesID = nil }
    .onChange(of: isExpanded) { selectedSeriesID = nil }
    .onChange(of: renderingMode) {
      if renderingMode == .placeholder { selectedSeriesID = nil }
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(DashL10n.ui(metric.title))
        .dashTextStyle(.footnoteSemibold)
        .foregroundStyle(DashTheme.subtle)
        // Reserve two lines so a one-line title ("CPU Time") stands the same
        // height as a wrapped one ("Encrypted Requests Rate") — paired collapsed
        // cards and every row then share one card height.
        .lineLimit(2, reservesSpace: true)
        .minimumScaleFactor(0.85)
        .padding(.trailing, isEditing ? 78 : 0)
        .matchedGeometryEffect(
          id: WatchtowerAnalyticsMorphID.title(metric), in: morphNamespace)
      Text(total.text)
        .dashTextStyle(isExpanded ? .emptyTitle : .sectionTitle)
        .monospacedDigit()
        .foregroundStyle(DashTheme.strong)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .contentTransition(
          reduceMotion ? .opacity : .numericText(value: total.numeric)
        )
        .matchedGeometryEffect(
          id: WatchtowerAnalyticsMorphID.value(metric), in: morphNamespace)
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

  @ViewBuilder
  private var chartBody: some View {
    if renderingMode == .placeholder {
      editingPlaceholder
    } else if isExpanded {
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
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
    } else {
      DitherAreaChart(
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
  /// the sparkline still paints a short dither band.
  private var collapsedSparkline: some View {
    DitherAreaChart(
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
      .matchedGeometryEffect(
        id: WatchtowerAnalyticsMorphID.toggle(metric), in: morphNamespace)
    }
    .padding(8)
    .frame(
      width: WatchtowerMetricDragLayout.controlsPassthroughSize.width,
      height: WatchtowerMetricDragLayout.controlsPassthroughSize.height,
      alignment: .topTrailing)
  }

  private func chartControl<Label: View>(
    accessibilityLabel: String,
    action: @escaping () -> Void,
    @ViewBuilder label: () -> Label
  ) -> some View {
    Button(action: action) {
      label()
        .frame(width: 28, height: 28)
        .background(DashTheme.homeCardSurface, in: Circle())
        .dashEmbossChrome(shape: Circle())
        .padding(4)
        .contentShape(Circle())
    }
    .buttonStyle(DashPressButtonStyle())
    .accessibilityLabel(accessibilityLabel)
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
