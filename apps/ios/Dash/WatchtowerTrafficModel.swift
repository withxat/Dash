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

  var trendPolarity: DashChartTrend.Polarity {
    switch self {
    case .workerErrors, .cpuTime, .clientRequestErrors:
      .lowerIsBetter
    case .cacheRate, .encryptedRequestsRate:
      .higherIsBetter
    case .workerInvocations, .webTraffic, .totalBandwidth, .encryptedBandwidth:
      .neutral
    }
  }

  var axisValueFormat: DashChartValueFormat {
    switch self {
    case .workerInvocations, .workerErrors, .webTraffic:
      .compact
    case .cpuTime:
      .milliseconds(maximumFractionDigits: 2)
    case .totalBandwidth, .encryptedBandwidth:
      .byteCount
    case .cacheRate, .clientRequestErrors, .encryptedRequestsRate:
      .percent(maximumFractionDigits: 1)
    }
  }

  var tableValueFormat: DashChartValueFormat {
    switch self {
    case .workerInvocations, .workerErrors, .webTraffic:
      .number(maximumFractionDigits: 0)
    default:
      axisValueFormat
    }
  }

  /// Watchtower's compact cards historically plot rates on a 0...100 scale.
  /// The shared detail formatter follows Foundation's percentage convention
  /// where `1 == 100%`, so normalize only the detail snapshot.
  func detailValue(_ plottedValue: Double) -> Double {
    switch self {
    case .cacheRate, .clientRequestErrors, .encryptedRequestsRate:
      plottedValue / 100
    default:
      plottedValue
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
  /// Expanded charts whose tooltip currently owns the finger. An engaged scrub
  /// already switches the pager's own pan off (`DitherHoldInteraction`); this
  /// keeps it off across a SwiftUI rebuild mid-scrub, which would otherwise
  /// hand the pan back and page Watchtower away underneath a live tooltip.
  private(set) var scrubbingMetrics: Set<WatchtowerAnalyticsMetric> = []

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private var savedDraft: Draft?
  @ObservationIgnored private var hasPendingPersistedLayout = false

  private struct Draft {
    let order: [WatchtowerAnalyticsMetric]
    let collapsed: Set<WatchtowerAnalyticsMetric>
    let hidden: Set<WatchtowerAnalyticsMetric>
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let layout = Self.persistedLayout(in: defaults)
    order = layout.order
    collapsed = layout.collapsed
    hidden = layout.hidden
  }

  private static func persistedLayout(in defaults: UserDefaults)
    -> WatchtowerAnalyticsCardLayout.Layout
  {
    WatchtowerAnalyticsCardLayout.layout(
      orderRaw: defaults.string(forKey: WatchtowerAnalyticsCardLayout.orderKey),
      collapsedRaw: defaults.string(forKey: WatchtowerAnalyticsCardLayout.key),
      hiddenRaw: defaults.string(forKey: WatchtowerAnalyticsCardLayout.hiddenKey))
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

  /// True while any expanded chart is being scrubbed — `MainTabView` holds the
  /// tab pager still for the duration.
  var isScrubbing: Bool { !scrubbingMetrics.isEmpty }

  func setScrubbing(_ scrubbing: Bool, for metric: WatchtowerAnalyticsMetric) {
    if scrubbing {
      scrubbingMetrics.insert(metric)
    } else {
      scrubbingMetrics.remove(metric)
    }
  }

  func beginEditing() {
    guard !isEditing else { return }
    savedDraft = Draft(order: order, collapsed: collapsed, hidden: hidden)
    // Live charts hand off to placeholders here; nothing is left to scrub.
    scrubbingMetrics.removeAll()
    isEditing = true
  }

  func cancelEditing() {
    if hasPendingPersistedLayout {
      finishEditing()
      applyPersistedLayout()
      return
    }
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
    hasPendingPersistedLayout = false
    finishEditing()
  }

  /// Rehydrates the current instance after iCloud updates the local defaults.
  /// An active edit owns the screen until Done or Cancel: Cancel adopts the
  /// incoming layout, while Done persists the user's newer local draft.
  func reloadPersistedLayout() {
    guard !isEditing else {
      hasPendingPersistedLayout = true
      return
    }
    applyPersistedLayout()
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

  /// `index` addresses `visibleMetrics` with `metric` removed; `order` may also
  /// hold hidden metrics, so the slot is translated through the visible list
  /// rather than applied to `order` directly.
  func move(_ metric: WatchtowerAnalyticsMetric, toVisibleIndex index: Int) {
    guard isEditing, !hidden.contains(metric) else { return }
    var remaining = visibleMetrics
    guard let current = remaining.firstIndex(of: metric) else { return }
    remaining.remove(at: current)
    let slot = min(max(index, 0), remaining.count)
    remaining.insert(metric, at: slot)
    guard remaining != visibleMetrics else { return }

    // Permute only the visible slots. A hidden metric keeps its position in
    // `order`, which is where re-adding it puts it back.
    var next: [WatchtowerAnalyticsMetric] = []
    var visible = remaining[...]
    for existing in order {
      if hidden.contains(existing) {
        next.append(existing)
      } else if let first = visible.first {
        next.append(first)
        visible = visible.dropFirst()
      }
    }
    order = next
  }

  func moveVisible(_ metric: WatchtowerAnalyticsMetric, offset: Int) {
    guard let index = visibleMetrics.firstIndex(of: metric) else { return }
    let targetIndex = index + offset
    guard visibleMetrics.indices.contains(targetIndex) else { return }
    move(metric, across: visibleMetrics[targetIndex])
  }

  @discardableResult
  func beginDragging(_ metric: WatchtowerAnalyticsMetric) -> Bool {
    guard
      isEditing,
      draggedMetric == nil,
      !hidden.contains(metric)
    else { return false }
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

  private func applyPersistedLayout() {
    let layout = Self.persistedLayout(in: defaults)
    order = layout.order
    collapsed = layout.collapsed
    hidden = layout.hidden
    hasPendingPersistedLayout = false
  }
}

struct WatchtowerMetricRemovalSequence: Equatable {
  enum Phase: Equatable {
    case idle
    case exiting(WatchtowerAnalyticsMetric)
    case reflowing(WatchtowerAnalyticsMetric)
  }

  private(set) var phase: Phase = .idle

  var departingMetric: WatchtowerAnalyticsMetric? {
    switch phase {
    case .idle:
      nil
    case .exiting(let metric), .reflowing(let metric):
      metric
    }
  }

  var isIdle: Bool { phase == .idle }

  @discardableResult
  mutating func begin(_ metric: WatchtowerAnalyticsMetric) -> Bool {
    guard isIdle else { return false }
    phase = .exiting(metric)
    return true
  }

  @discardableResult
  mutating func finishExit(_ metric: WatchtowerAnalyticsMetric) -> Bool {
    guard phase == .exiting(metric) else { return false }
    phase = .reflowing(metric)
    return true
  }

  mutating func finishReflow(_ metric: WatchtowerAnalyticsMetric) {
    guard phase == .reflowing(metric) else { return }
    phase = .idle
  }

  mutating func cancel() {
    phase = .idle
  }
}

enum WatchtowerAnalyticsChartModel {
  struct MetricSnapshot: Hashable, Sendable {
    static let empty = MetricSnapshot(
      expandedData: [], tableLabels: [], collapsedData: [], collapsedValueCeiling: nil)

    let expandedData: [DitherDatum]
    /// Full date/time labels aligned one-to-one with `expandedData`. Axis
    /// labels intentionally stay terse, but a seven-day table cannot repeat
    /// the same 24 hour labels without their dates.
    let tableLabels: [String]
    let collapsedData: [DitherDatum]
    let collapsedValueCeiling: Double?

    var isEmpty: Bool { expandedData.isEmpty }
  }

  struct Snapshot: Hashable, Sendable {
    let overview: AccountAnalyticsOverview
    let previousOverview: AccountAnalyticsOverview?
    let charts: [WatchtowerAnalyticsMetric: MetricSnapshot]
    let fetchedAt: Date
  }

  /// Freshness for the Charts section header, as a bare relative fragment
  /// ("3 minutes ago"). `nil` before the first snapshot lands: the skeleton
  /// and the pull-to-refresh spinner already say "loading", so this never
  /// carries a second loading label of its own.
  ///
  /// `now` often comes from a `TimelineView` schedule tick, which can lag the
  /// wall clock by up to the period. A just-fetched stamp then looks slightly
  /// in the future. `RelativeDateTimeFormatter` also renders a zero or
  /// sub-second age as "in 0 seconds", so handle that boundary explicitly.
  static func updatedBadge(fetchedAt: Date?, now: Date = .now) -> String? {
    guard let fetchedAt else { return nil }
    guard now.timeIntervalSince(fetchedAt) >= 1 else {
      return DashL10n.string("just now")
    }
    return DashDateFormatting.fullRelativeTime(fetchedAt, relativeTo: now)
  }

  /// The fragment alone needs its subject back for VoiceOver.
  static func updatedAccessibilityLabel(_ badge: String) -> String {
    DashL10n.string("Updated \(badge)")
  }

  static func chartPoints(from points: [AccountAnalyticsPoint]) -> [(
    date: Date, point: AccountAnalyticsPoint
  )] {
    let dated: [(date: Date, index: Int, point: AccountAnalyticsPoint)] =
      points.enumerated().compactMap { index, point in
        guard let date = DashDateFormatting.date(fromISO8601: point.datetime) else {
          return nil
        }
        return (date: date, index: index, point: point)
      }
    return dated.sorted {
      if $0.date == $1.date { return $0.index < $1.index }
      return $0.date < $1.date
    }
    .map { ($0.date, $0.point) }
  }

  /// Builds every metric's render-ready series once when a network/cache
  /// snapshot enters state. SwiftUI card updates then reuse stable IDs, labels,
  /// ordering, and zero-floor data without reparsing the same timestamps.
  static func snapshot(
    from snapshot: AccountAnalyticsSnapshot,
    range: AnalyticsRange,
    locale: Locale
  ) -> Snapshot {
    let http = labeledPoints(
      chartPoints(from: snapshot.httpPoints),
      range: range,
      locale: locale)
    let workers = labeledPoints(
      chartPoints(from: snapshot.workerPoints),
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
        tableLabels: points.map { $0.tableLabel },
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
      previousOverview: snapshot.previousOverview,
      charts: charts,
      fetchedAt: snapshot.fetchedAt)
  }

  private static func labeledPoints(
    _ points: [(date: Date, point: AccountAnalyticsPoint)],
    range: AnalyticsRange,
    locale: Locale
  ) -> [(id: String, label: String, tableLabel: String, point: AccountAnalyticsPoint)] {
    var occurrences: [String: Int] = [:]
    return points.map { date, point in
      let occurrence = occurrences[point.datetime, default: 0]
      occurrences[point.datetime] = occurrence + 1
      let id = occurrence == 0 ? point.datetime : "\(point.datetime)#\(occurrence)"
      return (
        id: id,
        label: chartLabel(date, range: range, locale: locale),
        tableLabel: detailLabel(date, range: range, locale: locale),
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

  private static func detailLabel(_ date: Date, range: AnalyticsRange, locale: Locale) -> String {
    if range == .month {
      return date.formatted(
        .dateTime.year().month(.abbreviated).day().locale(locale))
    }
    return date.formatted(
      .dateTime.month(.abbreviated).day().hour().locale(locale))
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
    let trend = CollapsedDitherTrendSeries(values: values)
    return (trend.values, trend.valueCeiling)
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
    DashL10n.string("\(DashL10n.ui(metric.title)) for \(rangeLabel). Total \(value).")
  }

  private static func bandwidth(_ bytes: Int64) -> String {
    formatBinaryByteCount(bytes, locale: DashL10n.activeLocale)
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

  private struct RangeLoad {
    let id: UUID
    let task: Task<Void, Never>
  }

  private var loadedContext: AccountRequestContext?
  private var rangeLoads: [AnalyticsRange: RangeLoad] = [:]

  var snapshot: WatchtowerAnalyticsChartModel.Snapshot? { snapshots[range] }
  var overview: AccountAnalyticsOverview? { snapshot?.overview }
  var fetchedAt: Date? { snapshot?.fetchedAt }
  var isLoadingCurrent: Bool { loadingRanges.contains(range) }
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
      guard snapshots[target] == nil else { continue }
      let key = FeatureCacheKey.accountAnalytics(
        context.accountID, hours: target.accountAnalyticsHours)
      // Session-scoped entries use `ttl: nil`, so this survives the whole sign-in.
      if let cached: AccountAnalyticsSnapshot = model.featureCache.get(key, maxAge: nil) {
        commit(cached, for: target)
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

    if force {
      rangeLoads.removeValue(forKey: target)?.task.cancel()
    } else if let existing = rangeLoads[target] {
      await existing.task.value
      return
    }

    let key = FeatureCacheKey.accountAnalytics(
      context.accountID, hours: target.accountAnalyticsHours)
    if !force, let cached: AccountAnalyticsSnapshot = model.featureCache.get(key, maxAge: nil) {
      commit(cached, for: target)
      loadingRanges.remove(target)
      return
    }

    let loadID = UUID()
    let task = Task { [weak self] in
      guard let self else { return }
      await self.performRangeLoad(
        target,
        loadID: loadID,
        key: key,
        model: model,
        context: context)
    }
    rangeLoads[target] = RangeLoad(id: loadID, task: task)
    await task.value
    guard rangeLoads[target]?.id == loadID else { return }
    rangeLoads.removeValue(forKey: target)
    loadingRanges.remove(target)
  }

  private func performRangeLoad(
    _ target: AnalyticsRange,
    loadID: UUID,
    key: String,
    model: AppModel,
    context: AccountRequestContext
  ) async {
    guard !Task.isCancelled else { return }
    do {
      let rawSnapshot = try await model.client.accountAnalytics(
        accountID: context.accountID,
        hours: target.accountAnalyticsHours,
        granularity: target.accountAnalyticsGranularity)
      guard !Task.isCancelled, rangeLoads[target]?.id == loadID,
        model.isCurrentAccount(context)
      else { return }
      // Keep until sign-out / account switch — Refresh is the explicit invalidation.
      model.featureCache.set(key, rawSnapshot, ttl: nil)
      commit(rawSnapshot, for: target)
      MetricsWidgetPublisher.publishAccount(
        snapshot: rawSnapshot,
        accountID: context.accountID,
        accountName: model.activeAccount?.name ?? context.accountID,
        range: target)
    } catch {
      guard !Task.isCancelled, !error.dashIsCancellation, rangeLoads[target]?.id == loadID,
        model.isCurrentAccount(context)
      else { return }
      // Warm too: `commit` clears this slot on the next success, and gating it
      // on `snapshots[target] == nil` made the warm banner below the charts
      // unreachable — a failed pull-to-refresh over live charts ended silent.
      errorByRange[target] = error.dashActionableMessage
      if let apiError = error as? CloudflareAPIError, apiError.isForbidden {
        needsAnalyticsAccess = true
      }
    }
  }

  private func commit(
    _ rawSnapshot: AccountAnalyticsSnapshot,
    for target: AnalyticsRange
  ) {
    snapshots[target] = WatchtowerAnalyticsChartModel.snapshot(
      from: rawSnapshot,
      range: target,
      locale: DashL10n.activeLocale)
    errorByRange[target] = nil
  }

  private func reset(context: AccountRequestContext? = nil) {
    for load in rangeLoads.values {
      load.task.cancel()
    }
    loadedContext = context
    rangeLoads = [:]
    snapshots = [:]
    errorByRange = [:]
    loadingRanges = context == nil ? [] : Set(AnalyticsRange.allCases)
    needsAnalyticsAccess = false
    range = .day
  }
}
