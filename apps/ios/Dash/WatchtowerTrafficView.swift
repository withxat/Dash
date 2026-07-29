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

struct WatchtowerMetricDragPresentation: Equatable {
  let metric: WatchtowerAnalyticsMetric
  let size: CGSize
  let isExpanded: Bool
  var fingerLocation: CGPoint
  var centerOffset: CGSize
  var scale: CGFloat

  var center: CGPoint {
    CGPoint(
      x: fingerLocation.x + centerOffset.width,
      y: fingerLocation.y + centerOffset.height)
  }
}

@MainActor
@Observable
final class WatchtowerMetricDragVisualState {
  enum Phase: Equatable {
    case pressing
    case lifting
    case tracking
    case settling
  }

  private struct Press: Equatable {
    let metric: WatchtowerAnalyticsMetric
    let identifier: UUID
  }

  private var press: Press?
  private(set) var presentation: WatchtowerMetricDragPresentation?
  private(set) var phase: Phase?
  @ObservationIgnored weak var coordinateView: UIView?
  /// The space the live `presentation` coordinates are expressed in. Held for
  /// the length of one session so move / settle keep measuring against the same
  /// view the lift resolved.
  @ObservationIgnored private(set) weak var activeReference: UIView?
  @ObservationIgnored private var retainedDelegate: AnyObject?
  @ObservationIgnored private var sourceViews: [WatchtowerAnalyticsMetric: WeakView] = [:]

  private final class WeakView {
    weak var value: UIView?

    init(_ value: UIView) {
      self.value = value
    }
  }

  /// The ghost card is positioned in the charts stack's own space, so the
  /// registered coordinate view is the reference we want. The window is a
  /// last-resort fallback: a lift must never be cancelled just because that
  /// registration is missing — a mispositioned ghost is recoverable, a drag
  /// that silently refuses to start is not.
  func reference(for sourceView: UIView) -> UIView? {
    coordinateView ?? sourceView.window
  }

  var pressedMetric: WatchtowerAnalyticsMetric? {
    press?.metric
  }

  var isSettling: Bool {
    phase == .settling
  }

  var animatesPresentation: Bool {
    phase == .lifting || phase == .settling
  }

  func beginPress(
    _ metric: WatchtowerAnalyticsMetric,
    identifier: UUID,
    size: CGSize,
    fingerLocation: CGPoint,
    sourceCenter: CGPoint,
    isExpanded: Bool,
    reference: UIView,
    reduceMotion: Bool
  ) {
    guard phase == nil || phase == .pressing else { return }
    press = Press(metric: metric, identifier: identifier)
    activeReference = reference
    phase = .pressing
    // Keep a hidden ghost mounted throughout the system long-press. Its pose
    // has therefore rendered before UIKit accepts the lift, giving the spring
    // a deterministic source frame instead of relying on run-loop timing.
    presentation = WatchtowerMetricDragPresentation(
      metric: metric,
      size: size,
      isExpanded: isExpanded,
      fingerLocation: fingerLocation,
      centerOffset: reduceMotion
        ? .zero
        : CGSize(
          width: sourceCenter.x - fingerLocation.x,
          height: sourceCenter.y - fingerLocation.y),
      scale: reduceMotion ? 1 : 0.97)
  }

  func endPress(identifier: UUID) {
    guard press?.identifier == identifier else { return }
    press = nil
    guard phase == .pressing else { return }
    presentation = nil
    phase = nil
    activeReference = nil
  }

  func beginLift(
    metric: WatchtowerAnalyticsMetric,
    size: CGSize,
    fingerLocation: CGPoint,
    sourceCenter: CGPoint,
    isExpanded: Bool,
    reference: UIView,
    retaining delegate: AnyObject,
    reduceMotion: Bool
  ) {
    press = nil
    retainedDelegate = delegate
    activeReference = reference
    phase = reduceMotion ? .tracking : .lifting
    presentation = WatchtowerMetricDragPresentation(
      metric: metric,
      size: size,
      isExpanded: isExpanded,
      fingerLocation: fingerLocation,
      centerOffset: reduceMotion
        ? .zero
        : CGSize(
          width: sourceCenter.x - fingerLocation.x,
          height: sourceCenter.y - fingerLocation.y),
      scale: reduceMotion ? 1 : 0.97)
  }

  /// Finger position is direct-manipulation state. The one-shot lift spring
  /// belongs to `centerOffset` and `scale`, so the panel never trails the touch.
  func trackFinger(to location: CGPoint) {
    guard var presentation else { return }
    presentation.fingerLocation = location
    self.presentation = presentation
  }

  func liftToFinger() {
    guard phase == .lifting, var presentation else { return }
    presentation.centerOffset = .zero
    presentation.scale = 1
    self.presentation = presentation
  }

  func finishLift() {
    guard phase == .lifting else { return }
    phase = .tracking
  }

  func moveCenter(to center: CGPoint) {
    guard var presentation else { return }
    presentation.centerOffset = CGSize(
      width: center.x - presentation.fingerLocation.x,
      height: center.y - presentation.fingerLocation.y)
    self.presentation = presentation
  }

  func registerSourceView(_ view: UIView, for metric: WatchtowerAnalyticsMetric) {
    sourceViews[metric] = WeakView(view)
  }

  func unregisterSourceView(_ view: UIView, for metric: WatchtowerAnalyticsMetric) {
    guard sourceViews[metric]?.value === view else { return }
    sourceViews[metric] = nil
  }

  /// Live card frames in the active drag's coordinate space, for the metrics
  /// that still have a registered source view.
  func frames(for metrics: [WatchtowerAnalyticsMetric]) -> [WatchtowerAnalyticsMetric: CGRect] {
    guard let reference = activeReference ?? coordinateView else { return [:] }
    var result: [WatchtowerAnalyticsMetric: CGRect] = [:]
    for metric in metrics {
      guard let view = sourceViews[metric]?.value, view.window != nil else { continue }
      let frame = view.convert(view.bounds, to: reference)
      guard frame.width > 0, frame.height > 0 else { continue }
      result[metric] = frame
    }
    return result
  }

  func sourceCenter(for metric: WatchtowerAnalyticsMetric) -> CGPoint? {
    guard
      let reference = activeReference ?? coordinateView,
      let view = sourceViews[metric]?.value
    else { return nil }
    let frame = view.convert(view.bounds, to: reference)
    guard frame.width > 0, frame.height > 0 else { return nil }
    return CGPoint(x: frame.midX, y: frame.midY)
  }

  func beginSettling() {
    guard presentation != nil else { return }
    phase = .settling
  }

  func finish() {
    press = nil
    presentation = nil
    phase = nil
    activeReference = nil
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
      guard !Task.isCancelled, rangeLoads[target]?.id == loadID,
        model.isCurrentAccount(context)
      else { return }
      if snapshots[target] == nil {
        errorByRange[target] = error.dashActionableMessage
      }
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

struct WatchtowerTrafficView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Bindable var state: WatchtowerTrafficState
  let customization: WatchtowerChartCustomizationState
  let dragVisual: WatchtowerMetricDragVisualState
  let isEditing: Bool
  let editorControlsVisible: Bool
  let usesPlaceholderCharts: Bool
  @State private var removalSequence = WatchtowerMetricRemovalSequence()
  @State private var layoutMorphingMetric: WatchtowerAnalyticsMetric?

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
        if !isEditing {
          VStack(alignment: .leading, spacing: 8) {
            refreshHeader
              .padding(.horizontal, 4)
            DashTextTabs(
              items: [("24h", AnalyticsRange.day), ("7d", .week), ("30d", .month)],
              selection: $state.range
            )
          }
          .transition(.opacity)
        }

        if state.needsAnalyticsAccess, state.overview == nil {
          statusCard {
            emptyContent(
              title: DashL10n.string("Analytics access needed"),
              message: [
                DashL10n.string("Allow Account Analytics: Read to load account traffic."),
                DashL10n.string(
                  "Dash requests all permissions used by its current features in one authorization."
                ),
              ].joined(separator: " "),
              buttonTitle: DashL10n.string("Grant access")
            ) {
              model.requestAccess(to: DashAuthorizationScopes.accountAnalytics)
            }
          }
        } else if state.isLoadingCurrent, state.overview == nil {
          // Cold load paints the saved layout, not one generic panel: the card
          // count, order, and expanded/collapsed shape are already on disk, so
          // the arriving data lands in place instead of reflowing the screen.
          chartsSkeleton
        } else if let error = state.currentError, state.overview == nil {
          // Same contract as a cold list failure: the saved card layout stays
          // painted and the failure lands on a wash over it, so the screen the
          // user was waiting for never blinks out for one status card.
          // `error` is already an actionable, localized message — only the
          // surrounding chrome needs the catalog.
          chartsSkeleton
            .dashColdFailure(
              title: DashL10n.string("Traffic unavailable"),
              message: error,
              actionTitle: DashL10n.string("Try again")
            ) {
              Task { await state.retry(model: model) }
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
            WatchtowerMetricCardFlowLayout(spacing: DashTheme.Spacing.itemGap) {
              ForEach(customization.visibleMetrics) { metric in
                let expanded = isExpanded(metric)
                reorderableMetricCard(
                  metric,
                  overview: overview,
                  snapshot: snapshot,
                  expanded: expanded
                )
                .layoutValue(
                  key: WatchtowerMetricExpandedLayoutKey.self,
                  value: expanded)
              }
              if let error = state.currentError {
                DashNotice(kind: .warning, message: error)
                  .layoutValue(
                    key: WatchtowerMetricExpandedLayoutKey.self,
                    value: true)
              }
            }
          }
        }
      }

      if let overview = state.overview {
        WatchtowerMetricDragOverlay(
          state: dragVisual,
          overview: overview,
          range: state.range
        )
      }
    }
    // Every lift resolves its coordinates against this view, so it is mounted
    // unconditionally: anything that appears or disappears on `isEditing` gets
    // built during the editor morph, and a `UIViewRepresentable` inserted on
    // that frame both eats the transition and leaves a window where a lift can
    // find no reference — which `itemsForBeginning` cancels silently.
    // `topLeading` anchors its origin to the stack's, so the ghost's
    // coordinates hold even if the view resolves to a smaller size.
    .background(alignment: .topLeading) {
      WatchtowerMetricDragCoordinateView(state: dragVisual)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
    .accessibilityIdentifier(isEditing ? "watchtower-chart-editor" : "watchtower-charts")
    .modifier(
      WatchtowerMetricRootDropModifier(
        isEnabled: isEditing,
        customization: customization)
    )
    .onChange(of: isEditing) {
      if !isEditing {
        removalSequence.cancel()
        layoutMorphingMetric = nil
        dragVisual.finish()
      }
    }
  }

  private func isExpanded(_ metric: WatchtowerAnalyticsMetric) -> Bool {
    if dynamicTypeSize.isAccessibilitySize { return true }
    return customization.isExpanded(metric)
  }

  @ViewBuilder
  private func reorderableMetricCard(
    _ metric: WatchtowerAnalyticsMetric,
    overview: AccountAnalyticsOverview,
    snapshot: WatchtowerAnalyticsChartModel.Snapshot,
    expanded: Bool
  ) -> some View {
    let isDeparting = removalSequence.departingMetric == metric
    let isPressed = isEditing && dragVisual.pressedMetric == metric
    let card = metricCard(
      metric, overview: overview, snapshot: snapshot, expanded: expanded)
    card
      // Reordering is the one card interaction that intentionally borrows the
      // button press pose: the held object itself is the direct manipulation.
      .scaleEffect(isPressed && !reduceMotion ? 0.97 : 1)
      .opacity(isPressed && reduceMotion ? 0.88 : 1)
      .animation(
        reduceMotion ? DashTheme.Motion.reduced : DashTheme.Motion.press,
        value: isPressed
      )
      .opacity(
        isDeparting || (isEditing && customization.draggedMetric == metric)
          ? 0
          : 1
      )
      .blur(radius: reduceMotion || !isDeparting ? 0 : 3)
      .overlay {
        if isEditing, customization.draggedMetric == metric {
          WatchtowerMetricDropPlaceholder()
        }
      }
      .scaleEffect(
        isDeparting
          ? (reduceMotion ? 1 : 0.95)
          : (isEditing && customization.dropTargetMetric == metric ? 1.015 : 1)
      )
      .contentShape(
        RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous)
      )
      .overlay {
        WatchtowerNativeMetricDragSource(
          metric: metric,
          isExpanded: expanded,
          isEnabled: isEditing,
          customization: customization,
          visualState: dragVisual
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
      }
      .accessibilityHint(
        isEditing ? DashL10n.string("Touch and hold, then drag to reorder") : ""
      )
      .accessibilityHidden(isDeparting)
      // Only the card that is leaving stops taking touches. `removalSequence`
      // is one shared value, so gating every card on it meant a removal whose
      // two-stage completion never landed took the whole editor's gestures
      // with it. Re-entrancy is already guarded inside the handlers.
      .allowsHitTesting(!isDeparting)
      .zIndex(
        isDeparting
          ? 2
          : (layoutMorphingMetric == metric ? 1 : 0)
      )
      .accessibilityActions {
        if isEditing {
          Button(DashL10n.string("Move up")) {
            withAnimation(reduceMotion ? nil : DashTheme.Motion.morph) {
              customization.moveVisible(metric, offset: -1)
            }
          }
          Button(DashL10n.string("Move down")) {
            withAnimation(reduceMotion ? nil : DashTheme.Motion.morph) {
              customization.moveVisible(metric, offset: 1)
            }
          }
        }
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
      // The card retains this value through its two-stage visual handoff, then
      // unmounts the Dither view while editing. Arrays remain copy-on-write.
      chart: snapshot.charts[metric] ?? .empty,
      range: state.range,
      isExpanded: expanded,
      showsEditingControls: editorControlsVisible,
      renderingMode: WatchtowerMetricChartRenderingMode.resolved(
        isEditing: usesPlaceholderCharts),
      onToggleExpanded: {
        toggleMetric(metric)
      },
      onRemove: {
        removeMetric(metric)
      },
      onScrubChange: { scrubbing in
        customization.setScrubbing(scrubbing, for: metric)
      }
    )
  }

  private func toggleMetric(_ metric: WatchtowerAnalyticsMetric) {
    guard
      removalSequence.isIdle,
      layoutMorphingMetric == nil
    else { return }

    guard !reduceMotion else {
      customization.toggleExpanded(metric)
      return
    }

    layoutMorphingMetric = metric
    withAnimation(
      DashTheme.Motion.morph.logicallyComplete(after: 0.28),
      completionCriteria: .logicallyComplete
    ) {
      customization.toggleExpanded(metric)
    } completion: {
      if layoutMorphingMetric == metric {
        layoutMorphingMetric = nil
      }
    }
  }

  private func removeMetric(_ metric: WatchtowerAnalyticsMetric) {
    guard
      customization.isEditing,
      removalSequence.isIdle,
      layoutMorphingMetric == nil
    else { return }
    DashDelight.selectionChanged()

    withAnimation(
      (reduceMotion ? DashTheme.Motion.reduced : DashTheme.Motion.morphExit)
        .logicallyComplete(after: reduceMotion ? 0.12 : 0.22),
      completionCriteria: .logicallyComplete
    ) {
      _ = removalSequence.begin(metric)
    } completion: {
      guard
        customization.isEditing,
        removalSequence.finishExit(metric)
      else {
        removalSequence.cancel()
        return
      }

      withAnimation(
        (reduceMotion ? DashTheme.Motion.reduced : DashTheme.Motion.morph)
          .logicallyComplete(after: reduceMotion ? 0.12 : 0.28),
        completionCriteria: .logicallyComplete
      ) {
        customization.remove(metric)
      } completion: {
        removalSequence.finishReflow(metric)
      }
    }
  }

  /// Resources-style group title: relative “Updated …” on the leading edge. No
  /// Refresh control — pull-to-refresh owns reloading this screen, and a failed
  /// range still offers Try again inside its own card.
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
        }
      }
      .frame(minHeight: 20)
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

  @ViewBuilder
  private var chartsSkeleton: some View {
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
          if row.count == 1, let metric = row.first, isExpanded(metric) {
            WatchtowerMetricSkeletonCard(metric: metric, isExpanded: true)
          } else {
            HStack(alignment: .top, spacing: DashTheme.Spacing.itemGap) {
              ForEach(row) { metric in
                WatchtowerMetricSkeletonCard(metric: metric, isExpanded: false)
                  .frame(maxWidth: .infinity)
              }
              if row.count == 1 {
                Color.clear.frame(maxWidth: .infinity)
              }
            }
          }
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(DashL10n.ui("Loading"))
    }
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

private struct WatchtowerMetricExpandedLayoutKey: LayoutValueKey {
  static let defaultValue = false
}

private struct WatchtowerMetricCardFlowLayout: Layout {
  let spacing: CGFloat

  private struct Result {
    let frames: [CGRect]
    let size: CGSize
  }

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) -> CGSize {
    result(width: resolvedWidth(proposal, subviews: subviews), subviews: subviews).size
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) {
    let layout = result(width: bounds.width, subviews: subviews)
    for (index, subview) in subviews.enumerated() {
      let frame = layout.frames[index]
      subview.place(
        at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
        anchor: .topLeading,
        proposal: ProposedViewSize(width: frame.width, height: frame.height))
    }
  }

  private func resolvedWidth(
    _ proposal: ProposedViewSize,
    subviews: Subviews
  ) -> CGFloat {
    if let width = proposal.width, width.isFinite {
      return max(0, width)
    }
    return subviews.reduce(CGFloat.zero) { width, subview in
      max(width, subview.sizeThatFits(.unspecified).width)
    }
  }

  private func result(width: CGFloat, subviews: Subviews) -> Result {
    let columnWidth = max(0, (width - spacing) / 2)
    var frames = Array(repeating: CGRect.zero, count: subviews.count)
    var pendingCollapsedHeight: CGFloat?
    var y: CGFloat = 0

    func flushCollapsed() {
      guard let pendingHeight = pendingCollapsedHeight else { return }
      y += pendingHeight + spacing
      pendingCollapsedHeight = nil
    }

    for (index, subview) in subviews.enumerated() {
      if subview[WatchtowerMetricExpandedLayoutKey.self] {
        flushCollapsed()
        let size = subview.sizeThatFits(
          ProposedViewSize(width: width, height: nil))
        frames[index] = CGRect(x: 0, y: y, width: width, height: size.height)
        y += size.height + spacing
      } else {
        let size = subview.sizeThatFits(
          ProposedViewSize(width: columnWidth, height: nil))
        if let pendingHeight = pendingCollapsedHeight {
          frames[index] = CGRect(
            x: columnWidth + spacing,
            y: y,
            width: columnWidth,
            height: size.height)
          y += max(pendingHeight, size.height) + spacing
          pendingCollapsedHeight = nil
        } else {
          frames[index] = CGRect(
            x: 0,
            y: y,
            width: columnWidth,
            height: size.height)
          pendingCollapsedHeight = size.height
        }
      }
    }

    flushCollapsed()
    return Result(
      frames: frames,
      size: CGSize(width: width, height: max(0, y - spacing)))
  }
}

/// Where a dragged card belongs, decided from one place: the ghost's centre
/// against the other cards' frames.
///
/// The previous scheme let each card's SwiftUI `onDrop` reorder the moment the
/// finger entered it. Reordering reflows the layout under the finger, so the
/// card beneath it changed and fired the opposite move a frame later — the
/// placeholder visibly jumped and snapped back. Crossing a *centre* instead of
/// an *edge* makes each slot a fixed point: once the card lands in a slot the
/// pointer sits inside it, and only travelling past the next centre moves it
/// again. Entering a card's region was also the only thing that could reorder,
/// so gaps between cards and the run-off below the last one addressed nothing.
enum WatchtowerMetricDropTargeting {
  /// True when the point has passed this card in the flow's reading order:
  /// below its band outright, or level with it and past its horizontal centre.
  /// Full-width cards have no left/right neighbour, so they compare on the
  /// vertical centre alone.
  static func precedes(_ frame: CGRect, point: CGPoint, isFullWidth: Bool) -> Bool {
    if isFullWidth { return point.y > frame.midY }
    if point.y < frame.minY { return false }
    if point.y > frame.maxY { return true }
    return point.x > frame.midX
  }

  /// Slot for the dragged card, counted over `otherFrames` — the remaining
  /// cards in their current order. Returns `otherFrames.count` when the point
  /// is past every card, which is the append slot.
  static func destinationIndex(point: CGPoint, otherFrames: [CGRect]) -> Int {
    guard let widest = otherFrames.map(\.width).max() else { return 0 }
    return otherFrames.filter {
      precedes($0, point: point, isFullWidth: $0.width >= widest - 1)
    }.count
  }
}

private enum WatchtowerMetricDragLayout {
  static let controlsPassthroughSize = CGSize(width: 96, height: 60)
  static let titleTrailingClearance =
    controlsPassthroughSize.width - DashTheme.Spacing.card
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
    // A view on its way out of the hierarchy must never reclaim the
    // registration from the one replacing it: the stale winner then
    // deallocates, the weak reference goes nil, and every later lift is
    // cancelled with no feedback at all.
    if let current = state.coordinateView,
      current !== uiView,
      current.window != nil,
      uiView.window == nil
    {
      return
    }
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
  var onPressChanged: (@MainActor (WatchtowerMetricDragSourceUIView, Bool, CGPoint?) -> Void)?
  /// The bridge stays mounted outside the editor so entering it never inserts
  /// UIKit views mid-morph. Disabled it must be fully transparent to touches —
  /// the expanded chart underneath owns a selection gesture of its own.
  var isDragEnabled = false {
    didSet {
      if !isDragEnabled {
        setPressing(false)
      }
    }
  }
  var dragInteraction: UIDragInteraction?
  private var isPressing = false

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    guard isDragEnabled, super.point(inside: point, with: event) else { return false }
    let width = min(bounds.width, passthroughSize.width)
    let height = min(bounds.height, passthroughSize.height)
    let x =
      effectiveUserInterfaceLayoutDirection == .rightToLeft
      ? bounds.minX
      : bounds.maxX - width
    let controlsFrame = CGRect(x: x, y: bounds.minY, width: width, height: height)
    return !controlsFrame.contains(point)
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    super.touchesBegan(touches, with: event)
    guard isDragEnabled else { return }
    setPressing(true, location: touches.first?.location(in: self))
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    super.touchesEnded(touches, with: event)
    setPressing(false)
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
    super.touchesCancelled(touches, with: event)
    setPressing(false)
  }

  func cancelPress() {
    setPressing(false)
  }

  private func setPressing(_ pressing: Bool, location: CGPoint? = nil) {
    guard isPressing != pressing else { return }
    isPressing = pressing
    onPressChanged?(self, pressing, location)
  }
}

private struct WatchtowerNativeMetricDragSource: UIViewRepresentable {
  let metric: WatchtowerAnalyticsMetric
  let isExpanded: Bool
  let isEnabled: Bool
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
    view.onPressChanged = {
      [weak coordinator = context.coordinator] sourceView, pressed, sourceLocation in
      coordinator?.setPressed(
        pressed,
        sourceView: sourceView,
        sourceLocation: sourceLocation)
    }

    let interaction = UIDragInteraction(delegate: context.coordinator)
    view.addInteraction(interaction)
    view.dragInteraction = interaction
    visualState.registerSourceView(view, for: metric)
    return view
  }

  func updateUIView(_ uiView: WatchtowerMetricDragSourceUIView, context: Context) {
    let previousMetric = context.coordinator.metric
    if previousMetric != metric {
      uiView.cancelPress()
    }
    uiView.isDragEnabled = isEnabled
    uiView.dragInteraction?.isEnabled = isEnabled
    let previousVisualState = context.coordinator.visualState
    if previousVisualState !== visualState {
      uiView.cancelPress()
      previousVisualState.unregisterSourceView(uiView, for: previousMetric)
      context.coordinator.visualState = visualState
    } else if previousMetric != metric {
      visualState.unregisterSourceView(uiView, for: previousMetric)
    }
    visualState.registerSourceView(uiView, for: metric)
    context.coordinator.metric = metric
    context.coordinator.isExpanded = isExpanded
  }

  static func dismantleUIView(
    _ uiView: WatchtowerMetricDragSourceUIView,
    coordinator: Coordinator
  ) {
    uiView.cancelPress()
    uiView.onPressChanged = nil
    coordinator.visualState.unregisterSourceView(uiView, for: coordinator.metric)
  }

  @MainActor
  final class Coordinator: NSObject, UIDragInteractionDelegate {
    var metric: WatchtowerAnalyticsMetric
    var isExpanded: Bool
    private let customization: WatchtowerChartCustomizationState
    fileprivate var visualState: WatchtowerMetricDragVisualState
    private var active = false
    private var settling = false
    private var activeInteraction: UIDragInteraction?
    private var pressReleaseTask: Task<Void, Never>?
    private var lastReorder: CFTimeInterval = 0
    private let pressIdentifier = UUID()
    private var dragIdentifier: UUID?
    private var liftOrigin: CGPoint?
    private var movedDuringLift = false

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

    func setPressed(
      _ pressed: Bool,
      sourceView: WatchtowerMetricDragSourceUIView,
      sourceLocation: CGPoint?
    ) {
      if pressed {
        guard
          !active,
          !settling,
          customization.draggedMetric == nil
        else { return }
        pressReleaseTask?.cancel()
        pressReleaseTask = nil
        guard let reference = visualState.reference(for: sourceView) else { return }
        let sourceCenter = sourceView.convert(
          CGPoint(x: sourceView.bounds.midX, y: sourceView.bounds.midY),
          to: reference)
        let fingerLocation = sourceView.convert(
          sourceLocation
            ?? CGPoint(x: sourceView.bounds.midX, y: sourceView.bounds.midY),
          to: reference)
        visualState.beginPress(
          metric,
          identifier: pressIdentifier,
          size: sourceView.bounds.size,
          fingerLocation: fingerLocation,
          sourceCenter: sourceCenter,
          isExpanded: isExpanded,
          reference: reference,
          reduceMotion: UIAccessibility.isReduceMotionEnabled)
      } else {
        pressReleaseTask?.cancel()
        let pressedVisualState = visualState
        let currentPressIdentifier = pressIdentifier
        pressReleaseTask = Task { @MainActor [weak self] in
          // UIDragInteraction may cancel the UIView touch as it accepts the
          // same lift. Give `itemsForBeginning` one display interval to claim
          // the pre-mounted pose before treating cancellation as release.
          try? await Task.sleep(for: .milliseconds(16))
          guard !Task.isCancelled, self?.active != true else { return }
          pressedVisualState.endPress(identifier: currentPressIdentifier)
          self?.pressReleaseTask = nil
        }
      }
    }

    func dragInteraction(
      _ interaction: UIDragInteraction,
      itemsForBeginning session: any UIDragSession
    ) -> [UIDragItem] {
      // Returning an empty array cancels the lift with no feedback at all, so
      // nothing here may depend on state that can go missing between mounting
      // the bridge and the touch — `reference(for:)` always resolves.
      pressReleaseTask?.cancel()
      pressReleaseTask = nil
      guard let sourceView = interaction.view,
        let reference = visualState.reference(for: sourceView)
      else {
        visualState.endPress(identifier: pressIdentifier)
        return []
      }
      guard customization.beginDragging(metric) else {
        visualState.endPress(identifier: pressIdentifier)
        return []
      }

      let location = session.location(in: reference)
      let sourceCenter = sourceView.convert(
        CGPoint(x: sourceView.bounds.midX, y: sourceView.bounds.midY),
        to: reference)
      let reduceMotion = UIAccessibility.isReduceMotionEnabled
      let currentDragIdentifier = UUID()

      active = true
      activeInteraction = interaction
      dragIdentifier = currentDragIdentifier
      liftOrigin = location
      movedDuringLift = false
      lastReorder = 0
      visualState.beginLift(
        metric: metric,
        size: sourceView.bounds.size,
        fingerLocation: location,
        sourceCenter: sourceCenter,
        isExpanded: isExpanded,
        reference: reference,
        retaining: self,
        reduceMotion: reduceMotion)

      if !reduceMotion {
        withAnimation(
          DashTheme.Motion.pop.logicallyComplete(after: 0.3),
          completionCriteria: .logicallyComplete
        ) {
          visualState.liftToFinger()
        } completion: { [weak self] in
          guard let self,
            self.active,
            !self.settling,
            self.dragIdentifier == currentDragIdentifier
          else { return }
          self.visualState.finishLift()
          if self.movedDuringLift {
            self.updateDropTarget()
          }
        }
      }

      // `previewForLifting` returns nil to suppress the system lift preview in
      // favour of the ghost card, which takes its feedback with it.
      DashDelight.dragLift()

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
      guard active, let reference = visualState.activeReference else { return }
      let location = session.location(in: reference)
      visualState.trackFinger(to: location)
      if visualState.phase == .tracking {
        updateDropTarget()
      } else if visualState.phase == .lifting,
        let liftOrigin
      {
        let deltaX = location.x - liftOrigin.x
        let deltaY = location.y - liftOrigin.y
        if deltaX * deltaX + deltaY * deltaY >= 16 {
          movedDuringLift = true
          // Deliberate motion takes priority over the threshold pop. Tracking
          // now owns the position transaction, so the reorder morph cannot
          // leak animation into the finger's `.position`.
          visualState.finishLift()
          updateDropTarget()
        }
      }
    }

    /// Frames are read from live views that are still animating the previous
    /// reorder, so a settled slot needs a moment before the next hit test is
    /// meaningful. This is the local stand-in for `reorderingCadence`.
    private static let reorderCadence: CFTimeInterval = 0.2

    private func updateDropTarget() {
      guard customization.draggedMetric == metric,
        let center = visualState.presentation?.center
      else { return }

      // Frames come from live views. Inside the cadence window the previous
      // reorder is still sliding, so every hit test against them is noise —
      // for the hover cue as much as for the next move.
      let now = CACurrentMediaTime()
      guard now - lastReorder >= Self.reorderCadence else { return }

      let order = customization.visibleMetrics
      let frames = visualState.frames(for: order)
      let others = order.filter { $0 != metric }
      let otherFrames = others.compactMap { frames[$0] }
      // A partial read means cards are still being laid out; acting on it would
      // reorder against a frame set that does not describe the screen.
      guard otherFrames.count == others.count else { return }

      let hovered = others.first { frames[$0]?.contains(center) == true }
      if customization.dropTargetMetric != hovered {
        if let hovered {
          customization.targetDrop(on: hovered)
        } else {
          customization.clearDropTarget()
        }
      }

      let destination = WatchtowerMetricDropTargeting.destinationIndex(
        point: center, otherFrames: otherFrames)
      guard let current = order.firstIndex(of: metric), current != destination else { return }
      lastReorder = now

      withAnimation(
        UIAccessibility.isReduceMotionEnabled ? nil : DashTheme.Motion.morph
      ) {
        customization.move(metric, toVisibleIndex: destination)
      }
      DashDelight.selectionChanged()
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
      if reduceMotion {
        visualState.moveCenter(to: targetCenter)
        completeDrag()
        return
      }
      let currentDragIdentifier = dragIdentifier
      withAnimation(
        DashTheme.Motion.morph,
        completionCriteria: .removed
      ) {
        visualState.moveCenter(to: targetCenter)
      } completion: { [weak self] in
        guard let self,
          self.settling,
          self.dragIdentifier == currentDragIdentifier
        else { return }
        self.completeDrag()
      }
    }

    private func completeDrag() {
      pressReleaseTask?.cancel()
      pressReleaseTask = nil
      active = false
      settling = false
      activeInteraction = nil
      dragIdentifier = nil
      liftOrigin = nil
      movedDuringLift = false
      customization.finishDragging()
      visualState.finish()
    }
  }
}

private struct WatchtowerMetricDragOverlay: View {
  let state: WatchtowerMetricDragVisualState
  let overview: AccountAnalyticsOverview
  let range: AnalyticsRange

  var body: some View {
    ZStack(alignment: .topLeading) {
      if let presentation = state.presentation {
        WatchtowerMetricChartCard(
          metric: presentation.metric,
          overview: overview,
          chart: .empty,
          range: range,
          isExpanded: presentation.isExpanded,
          showsEditingControls: true,
          renderingMode: .placeholder,
          onToggleExpanded: {},
          onRemove: {}
        )
        .frame(width: presentation.size.width, height: presentation.size.height)
        .scaleEffect(presentation.scale)
        // Direct finger motion and the one-shot lift offset stay in separate
        // animatable properties, so the spring can resolve without adding lag.
        .position(presentation.fingerLocation)
        .offset(presentation.centerOffset)
        .opacity(state.phase == .pressing ? 0 : 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .zIndex(1)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .allowsHitTesting(false)
    // Finger tracking must not inherit the row-reorder morph animation.
    .transaction { transaction in
      if !state.animatesPresentation {
        transaction.animation = nil
      }
    }
  }
}

/// Keeps the charts stack a valid destination so a released drag ends as a drop
/// rather than a cancel. Targeting itself belongs to the drag source, which owns
/// the one hit test in `WatchtowerMetricDropTargeting` — per-card `onDrop`
/// delegates reordered on entry and fought each other across the reflow.
///
/// `onDrop` is applied unconditionally: an `if isEnabled` branch here changes
/// the stack's structural identity the moment editing starts, tearing down and
/// rebuilding the subtree on the editor morph's first frame.
private struct WatchtowerMetricRootDropModifier: ViewModifier {
  let isEnabled: Bool
  let customization: WatchtowerChartCustomizationState

  func body(content: Content) -> some View {
    content.onDrop(of: [UTType.plainText], isTargeted: nil) { _ in
      guard isEnabled, customization.draggedMetric != nil else { return false }
      customization.clearDropTarget()
      return true
    }
  }
}

/// Cold-load stand-in for `WatchtowerMetricChartCard`: same panel, same header
/// rhythm, same chart heights. The metric title is known before the network is,
/// so only the total and the series are skeleton blocks.
private struct WatchtowerMetricSkeletonCard: View {
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
    DashTheme.fill.opacity(0.4)
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
private struct WatchtowerChartVisualSwap<Placeholder: View, Live: View>: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let renderingMode: WatchtowerMetricChartRenderingMode
  private let placeholder: () -> Placeholder
  private let live: () -> Live
  @State private var sequence: WatchtowerChartVisualSwapSequence
  @State private var keepsLiveMounted: Bool
  @State private var operationID = 0

  init(
    renderingMode: WatchtowerMetricChartRenderingMode,
    @ViewBuilder placeholder: @escaping () -> Placeholder,
    @ViewBuilder live: @escaping () -> Live
  ) {
    self.renderingMode = renderingMode
    self.placeholder = placeholder
    self.live = live
    _sequence = State(initialValue: WatchtowerChartVisualSwapSequence(mode: renderingMode))
    _keepsLiveMounted = State(initialValue: renderingMode == .live)
  }

  var body: some View {
    ZStack {
      placeholder()
        .modifier(
          WatchtowerChartSwapLayer(
            isVisible: sequence.visibleMode == .placeholder,
            reduceMotion: reduceMotion)
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)

      if keepsLiveMounted {
        live()
          .modifier(
            WatchtowerChartSwapLayer(
              isVisible: sequence.visibleMode == .live,
              reduceMotion: reduceMotion)
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
    withAnimation(
      DashTheme.Motion.morph.logicallyComplete(after: reduceMotion ? 0.12 : 0.28),
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
        if mode == .placeholder, next == .none {
          setLiveMounted(false)
        }
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
  let reduceMotion: Bool

  func body(content: Content) -> some View {
    content
      .opacity(isVisible ? 1 : 0)
      .blur(radius: reduceMotion || isVisible ? 0 : 8)
      .scaleEffect(reduceMotion || isVisible ? 1 : 0.75)
      .accessibilityHidden(!isVisible)
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
  let showsEditingControls: Bool
  let renderingMode: WatchtowerMetricChartRenderingMode
  let onToggleExpanded: () -> Void
  let onRemove: () -> Void
  /// Called with `true` while the expanded chart's tooltip owns the finger.
  var onScrubChange: (Bool) -> Void = { _ in }
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
        if showsEditingControls {
          cardControls
            .transition(reduceMotion ? .opacity : .dashMorph)
        }
      }
      .allowsHitTesting(showsEditingControls)
      .accessibilityHidden(!showsEditingControls)
    }
    .onChange(of: range) { selectedSeriesID = nil }
    // Collapse, the editor's placeholder swap, and unmount all take the live
    // chart away without an end-of-scrub callback — release the pager by hand
    // so a chart that vanished mid-hold can't strand the tab swipe.
    .onChange(of: isExpanded) {
      selectedSeriesID = nil
      onScrubChange(false)
    }
    .onChange(of: renderingMode) {
      if renderingMode == .placeholder {
        selectedSeriesID = nil
        onScrubChange(false)
      }
    }
    .onDisappear { onScrubChange(false) }
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
        .padding(
          .trailing,
          renderingMode == .placeholder
            ? WatchtowerMetricDragLayout.titleTrailingClearance
            : 0)
      Text(total.text)
        .dashTextStyle(isExpanded ? .emptyTitle : .sectionTitle)
        .monospacedDigit()
        .foregroundStyle(DashTheme.strong)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .contentTransition(
          reduceMotion ? .opacity : .numericText(value: total.numeric)
        )
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
        // A refresh that empties the range takes the chart — and its
        // end-of-scrub callback — with it.
        .onAppear { onScrubChange(false) }
    } else {
      DitherAreaChart(
        data: chart.expandedData,
        series: chartSeries,
        options: DashTheme.DitherChart.options(
          showsLegend: false,
          accessibility: chartAccessibility),
        highlighted: selectedSeriesID != nil,
        selection: $selectedSeriesID,
        onHoverChange: { index in onScrubChange(index != nil) }
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
