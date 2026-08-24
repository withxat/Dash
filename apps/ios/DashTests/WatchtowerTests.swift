import CloudflareAPI
import CoreText
import SwiftUI
import Testing
import UIKit

@testable import Dash

@Test func watchtowerSnapshotTracksStaleness() {
  let now = Date(timeIntervalSince1970: 1_000_000)
  let snapshot = WatchtowerSnapshot(alerts: [], alertsStatus: .ok, fetchedAt: now)
  #expect(!snapshot.isStale(now: now.addingTimeInterval(299), ttl: 300))
  #expect(!snapshot.isStale(now: now.addingTimeInterval(300), ttl: 300))
  #expect(snapshot.isStale(now: now.addingTimeInterval(301), ttl: 300))
}

/// The widget counts Cloudflare's deliveries. It never characterises the
/// account: Dash no longer decides that anything is wrong.
@Test func widgetHeadlineCountsUnreadDeliveries() {
  func localized(
    _ resource: LocalizedStringResource,
    locale identifier: String
  ) -> String {
    var resource = resource
    resource.locale = Locale(identifier: identifier)
    return String(localized: resource)
  }

  let empty = WatchtowerWidgetSnapshot.headline(unreadCount: 0)
  let singular = WatchtowerWidgetSnapshot.headline(unreadCount: 1)
  let plural = WatchtowerWidgetSnapshot.headline(unreadCount: 4)
  let unavailable = WatchtowerWidgetSnapshot.headline(
    unreadCount: 0,
    alertsUnavailable: true)

  #expect(localized(empty, locale: "en") == "No unread alerts")
  #expect(localized(singular, locale: "en") == "1 unread alert")
  #expect(localized(plural, locale: "en") == "4 unread alerts")
  #expect(
    localized(unavailable, locale: "en")
      == "Alerts unavailable")
  #expect(localized(empty, locale: "zh-Hans") == "没有未读提醒")
  #expect(localized(singular, locale: "zh-Hans") == "1 条未读提醒")
  #expect(localized(plural, locale: "zh-Hans") == "4 条未读提醒")
  #expect(localized(unavailable, locale: "zh-Hans") == "提醒暂不可用")
}

@Test func analyticsChartAccessibilitySummaryIncludesTotals() {
  let summary = ZoneAnalyticsChartModel.chartAccessibilitySummary(
    rangeLabel: "Last 24 hours", requests: 1200, threats: 3)
  #expect(summary.contains("Last 24 hours"))
  #expect(summary.contains("1,200") || summary.contains("1200"))
  #expect(summary.contains("3"))
  #expect(summary.contains("threats"))
}

@Test func watchtowerAnalyticsAccessibilityNamesMetricAndTotal() {
  let summary = WatchtowerAnalyticsChartModel.accessibilitySummary(
    metric: .webTraffic,
    rangeLabel: "Last 24 hours",
    value: "12,345")
  #expect(summary.contains("Web Traffic"))
  #expect(summary.contains("Last 24 hours"))
  #expect(summary.contains("12,345"))
}

@Test func watchtowerEditorUsesLightweightChartPlaceholder() {
  let editing = WatchtowerMetricChartRenderingMode.resolved(isEditing: true)
  let normal = WatchtowerMetricChartRenderingMode.resolved(isEditing: false)

  #expect(editing == .placeholder)
  #expect(normal == .live)
}

@Test func watchtowerExpandedChartSwapUsesFastOpacityProfile() {
  let expanded = WatchtowerChartVisualSwapProfile.resolved(isExpanded: true)
  let collapsed = WatchtowerChartVisualSwapProfile.resolved(isExpanded: false)

  #expect(expanded.liveEffect == .opacityOnly)
  #expect(expanded.placeholderEffect == .opacityOnly)
  #expect(expanded.exitDuration + expanded.enterDuration <= 0.3)
  #expect(
    expanded.exitDuration + expanded.enterDuration
      < collapsed.exitDuration + collapsed.enterDuration)
  #expect(collapsed.liveEffect == .rich)
  #expect(collapsed.placeholderEffect == .rich)
}

@Test func watchtowerChartSwapFinishesOutgoingBeforeIncoming() {
  var sequence = WatchtowerChartVisualSwapSequence(mode: .live)

  let exit = sequence.request(.placeholder)
  #expect(exit == .exit(.live))
  #expect(sequence.visibleMode == .live)

  sequence.begin(exit)
  #expect(sequence.visibleMode == nil)

  let enter = sequence.finishExit(.live)
  #expect(enter == .enter(.placeholder))
  #expect(sequence.visibleMode == nil)

  sequence.begin(enter)
  #expect(sequence.visibleMode == .placeholder)
  #expect(sequence.finishEnter(.placeholder) == .none)
}

@Test func watchtowerChartSwapRetargetsWithoutShowingTheObsoleteReplacement() {
  var sequence = WatchtowerChartVisualSwapSequence(mode: .live)

  let exit = sequence.request(.placeholder)
  sequence.begin(exit)
  #expect(sequence.visibleMode == nil)

  let reverse = sequence.request(.live)
  #expect(reverse == .enter(.live))
  sequence.begin(reverse)

  #expect(sequence.visibleMode == .live)
  #expect(sequence.finishEnter(.live) == .none)
}

@Test func watchtowerChartSwapCanReverseAnIncomingLayerImmediately() {
  var sequence = WatchtowerChartVisualSwapSequence(mode: .live)

  let exit = sequence.request(.placeholder)
  sequence.begin(exit)
  let enter = sequence.finishExit(.live)
  sequence.begin(enter)
  #expect(sequence.visibleMode == .placeholder)

  let reverse = sequence.request(.live)
  #expect(reverse == .exit(.placeholder))
  sequence.begin(reverse)
  #expect(sequence.visibleMode == nil)
}

@Test func watchtowerMetricRemovalExitsBeforeTheRemainingCardsReflow() {
  var sequence = WatchtowerMetricRemovalSequence()

  let beganCPUExit = sequence.begin(.cpuTime)
  #expect(beganCPUExit)
  #expect(sequence.phase == .exiting(.cpuTime))
  #expect(sequence.departingMetric == .cpuTime)
  let beganWorkerExit = sequence.begin(.workerInvocations)
  #expect(!beganWorkerExit)

  let finishedWorkerExit = sequence.finishExit(.workerInvocations)
  #expect(!finishedWorkerExit)
  let finishedCPUExit = sequence.finishExit(.cpuTime)
  #expect(finishedCPUExit)
  #expect(sequence.phase == .reflowing(.cpuTime))
  #expect(sequence.departingMetric == .cpuTime)

  sequence.finishReflow(.cpuTime)
  #expect(sequence.isIdle)
  #expect(sequence.departingMetric == nil)
}

@Test func watchtowerMetricRemovalCanCancelWithoutCommittingTheReflow() {
  var sequence = WatchtowerMetricRemovalSequence()

  let beganWebTrafficExit = sequence.begin(.webTraffic)
  #expect(beganWebTrafficExit)
  sequence.cancel()

  #expect(sequence.isIdle)
  #expect(sequence.departingMetric == nil)
  let finishedWebTrafficExit = sequence.finishExit(.webTraffic)
  #expect(!finishedWebTrafficExit)
}

@Test @MainActor func watchtowerDragOverlayLiftsToTheFingerAndEndsCleanly() {
  let visualState = WatchtowerMetricDragVisualState()
  let reference = UIView()
  let pressIdentifier = UUID()

  visualState.beginPress(
    .webTraffic,
    identifier: pressIdentifier,
    size: CGSize(width: 160, height: 220),
    fingerLocation: CGPoint(x: 220, y: 360),
    sourceCenter: CGPoint(x: 190, y: 380),
    isExpanded: true,
    reference: reference,
    reduceMotion: false)
  #expect(visualState.pressedMetric == .webTraffic)
  #expect(visualState.phase == .pressing)
  #expect(visualState.presentation?.center == CGPoint(x: 190, y: 380))
  #expect(visualState.presentation?.scale == 0.97)

  visualState.beginLift(
    metric: .webTraffic,
    size: CGSize(width: 160, height: 220),
    fingerLocation: CGPoint(x: 220, y: 360),
    sourceCenter: CGPoint(x: 190, y: 380),
    isExpanded: true,
    reference: reference,
    retaining: NSObject(),
    reduceMotion: false)

  #expect(visualState.activeReference === reference)
  #expect(visualState.pressedMetric == nil)
  #expect(visualState.phase == .lifting)
  #expect(visualState.presentation?.center == CGPoint(x: 190, y: 380))
  #expect(visualState.presentation?.scale == 0.97)

  // UIKit may cancel the source view's touch as UIDragInteraction takes over.
  visualState.endPress(identifier: pressIdentifier)
  #expect(visualState.phase == .lifting)
  #expect(visualState.presentation != nil)

  visualState.trackFinger(to: CGPoint(x: 230, y: 370))
  #expect(visualState.presentation?.center == CGPoint(x: 200, y: 390))

  visualState.liftToFinger()
  #expect(visualState.presentation?.center == CGPoint(x: 230, y: 370))
  #expect(visualState.presentation?.scale == 1)
  visualState.finishLift()
  #expect(visualState.phase == .tracking)

  visualState.trackFinger(to: CGPoint(x: 260, y: 410))
  #expect(visualState.presentation?.center == CGPoint(x: 260, y: 410))

  visualState.settle(to: CGPoint(x: 120, y: 240))
  #expect(visualState.phase == .settling)
  #expect(visualState.presentation?.center == CGPoint(x: 120, y: 240))

  visualState.finish()
  #expect(visualState.presentation == nil)
  #expect(visualState.phase == nil)
  #expect(visualState.activeReference == nil)
}

@Test @MainActor func watchtowerDragOverlayRemovesMotionFromTheLift() {
  let visualState = WatchtowerMetricDragVisualState()
  let reference = UIView()

  visualState.beginLift(
    metric: .cpuTime,
    size: CGSize(width: 160, height: 120),
    fingerLocation: CGPoint(x: 220, y: 360),
    sourceCenter: CGPoint(x: 190, y: 380),
    isExpanded: false,
    reference: reference,
    retaining: NSObject(),
    reduceMotion: true)

  #expect(visualState.phase == .tracking)
  #expect(visualState.presentation?.center == CGPoint(x: 220, y: 360))
  #expect(visualState.presentation?.scale == 1)
}

@Test @MainActor func watchtowerDragKeepsTheLastSwiftUILayoutSlotAcrossRebuilds() {
  let visualState = WatchtowerMetricDragVisualState()
  let reference = UIView()
  let initialFrame = CGRect(x: 0, y: 20, width: 160, height: 220)
  let destinationFrame = CGRect(x: 0, y: 280, width: 160, height: 220)
  let neighborFrame = CGRect(x: 172, y: 20, width: 160, height: 120)

  visualState.updateLayoutFrames([
    .webTraffic: initialFrame,
    .cpuTime: neighborFrame,
  ])
  visualState.beginLift(
    metric: .webTraffic,
    size: initialFrame.size,
    fingerLocation: CGPoint(x: 60, y: 80),
    sourceCenter: CGPoint(x: initialFrame.midX, y: initialFrame.midY),
    isExpanded: true,
    reference: reference,
    retaining: NSObject(),
    reduceMotion: false)
  #expect(visualState.frames(for: [.webTraffic, .cpuTime])[.cpuTime] == neighborFrame)

  visualState.updateLayoutFrames([
    .webTraffic: destinationFrame,
    .cpuTime: neighborFrame,
  ])
  #expect(
    visualState.sourceCenter(for: .webTraffic)
      == CGPoint(x: destinationFrame.midX, y: destinationFrame.midY))

  // A representable can disappear for one update while the flow reorders.
  // The release target must remain the last real insertion slot, not nil.
  visualState.updateLayoutFrames([:])
  let cachedCenter = visualState.sourceCenter(for: .webTraffic)
  let expectedCenter = CGPoint(x: destinationFrame.midX, y: destinationFrame.midY)
  #expect(cachedCenter == expectedCenter)

  visualState.settle(to: expectedCenter)
  #expect(visualState.phase == .settling)
  #expect(visualState.presentation?.center == expectedCenter)
}

@Test @MainActor func watchtowerDragSourceRejectsAnOffscreenStaleRegistration() {
  let visualState = WatchtowerMetricDragVisualState()
  let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
  let liveSource = UIView(frame: CGRect(x: 24, y: 180, width: 160, height: 120))
  let staleSource = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
  window.addSubview(liveSource)

  visualState.registerSourceView(liveSource, for: .cpuTime)
  visualState.registerSourceView(staleSource, for: .cpuTime)
  visualState.beginLift(
    metric: .webTraffic,
    size: CGSize(width: 342, height: 220),
    fingerLocation: CGPoint(x: 195, y: 100),
    sourceCenter: CGPoint(x: 195, y: 100),
    isExpanded: true,
    reference: window,
    retaining: NSObject(),
    reduceMotion: false)

  #expect(visualState.frames(for: [.cpuTime])[.cpuTime] == liveSource.frame)
}

@Test @MainActor func watchtowerDragPressIgnoresAnOldViewCancellation() {
  let visualState = WatchtowerMetricDragVisualState()
  let reference = UIView()
  let oldIdentifier = UUID()
  let currentIdentifier = UUID()

  visualState.beginPress(
    .webTraffic,
    identifier: oldIdentifier,
    size: CGSize(width: 160, height: 220),
    fingerLocation: CGPoint(x: 80, y: 110),
    sourceCenter: CGPoint(x: 80, y: 110),
    isExpanded: true,
    reference: reference,
    reduceMotion: false)
  visualState.beginPress(
    .cpuTime,
    identifier: currentIdentifier,
    size: CGSize(width: 160, height: 120),
    fingerLocation: CGPoint(x: 80, y: 60),
    sourceCenter: CGPoint(x: 80, y: 60),
    isExpanded: false,
    reference: reference,
    reduceMotion: false)

  visualState.endPress(identifier: oldIdentifier)
  #expect(visualState.pressedMetric == .cpuTime)
  visualState.endPress(identifier: currentIdentifier)
  #expect(visualState.pressedMetric == nil)
  #expect(visualState.presentation == nil)
  #expect(visualState.phase == nil)
}

/// Two collapsed cards over a full-width one, as the default layout paints it.
private let watchtowerDropFrames: [CGRect] = [
  CGRect(x: 0, y: 0, width: 180, height: 120),
  CGRect(x: 192, y: 0, width: 180, height: 120),
  CGRect(x: 0, y: 132, width: 372, height: 260),
]

@Test func watchtowerDropTargetingCountsCardsPassedInReadingOrder() {
  func index(_ x: CGFloat, _ y: CGFloat) -> Int {
    WatchtowerMetricDropTargeting.destinationIndex(
      point: CGPoint(x: x, y: y),
      otherFrames: watchtowerDropFrames,
      containerWidth: 372)
  }

  // Before everything.
  #expect(index(40, 10) == 0)
  // Past the first collapsed card's horizontal centre, level with it.
  #expect(index(120, 60) == 1)
  // Past both collapsed cards but above the full-width card's vertical centre.
  #expect(index(300, 60) == 2)
  // Past the full-width card's centre — the append slot, which is the run-off
  // below the last card that entry-based targeting could never reach.
  #expect(index(180, 400) == 3)
}

@Test func watchtowerDropTargetingKeepsHalfWidthReadingOrderWithoutAnExpandedPeer() {
  let collapsedOnly = Array(watchtowerDropFrames.prefix(2))

  #expect(
    WatchtowerMetricDropTargeting.destinationIndex(
      point: CGPoint(x: 120, y: 60),
      otherFrames: collapsedOnly,
      containerWidth: 372) == 1)
  #expect(
    WatchtowerMetricDropTargeting.destinationIndex(
      point: CGPoint(x: 300, y: 60),
      otherFrames: collapsedOnly,
      containerWidth: 372) == 2)
}

@Test func watchtowerDropTargetingHoldsASlotUntilTheNextCentreIsCrossed() {
  let frame = watchtowerDropFrames[0]
  // Entering the card is not enough; its centre is.
  #expect(
    !WatchtowerMetricDropTargeting.precedes(
      frame, point: CGPoint(x: frame.minX + 4, y: frame.midY), isFullWidth: false))
  #expect(
    WatchtowerMetricDropTargeting.precedes(
      frame, point: CGPoint(x: frame.midX + 4, y: frame.midY), isFullWidth: false))
  // A full-width card has no left/right neighbour, so x must not decide it.
  #expect(
    !WatchtowerMetricDropTargeting.precedes(
      watchtowerDropFrames[2],
      point: CGPoint(x: 370, y: watchtowerDropFrames[2].midY - 4),
      isFullWidth: true))
}

@Test @MainActor func watchtowerVisibleMoveKeepsHiddenMetricsInPlace() {
  let defaults = UserDefaults(suiteName: "watchtower-visible-move")!
  defaults.removePersistentDomain(forName: "watchtower-visible-move")
  let state = WatchtowerChartCustomizationState(defaults: defaults)
  state.beginEditing()

  let visible = state.visibleMetrics
  guard let first = visible.first, visible.count >= 3 else {
    Issue.record("default layout should ship at least three visible charts")
    return
  }
  let hiddenBefore = state.order.filter(state.hidden.contains)

  state.move(first, toVisibleIndex: state.visibleMetrics.count)
  #expect(state.visibleMetrics.last == first)
  #expect(state.visibleMetrics.count == visible.count)
  #expect(state.order.filter(state.hidden.contains) == hiddenBefore)
}

@Test @MainActor func watchtowerChartCustomizationAllowsOnlyOneActiveDrag() {
  let suite = "watchtower-single-active-drag-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  let state = WatchtowerChartCustomizationState(defaults: defaults)
  state.beginEditing()

  #expect(state.beginDragging(.webTraffic))
  #expect(!state.beginDragging(.cpuTime))
  #expect(state.draggedMetric == .webTraffic)

  state.finishDragging()
  #expect(state.beginDragging(.cpuTime))
}

/// A lift must never be cancelled because the charts stack's coordinate view is
/// missing — `itemsForBeginning` returning an empty array is silent, so the
/// window has to stand in.
@Test @MainActor func watchtowerDragReferenceFallsBackToTheSourceWindow() {
  let visualState = WatchtowerMetricDragVisualState()
  let window = UIWindow()
  let source = UIView()
  window.addSubview(source)

  #expect(visualState.reference(for: source) === window)

  let coordinateView = UIView()
  visualState.coordinateView = coordinateView
  #expect(visualState.reference(for: source) === coordinateView)
}

@Test func watchtowerAnalyticsCardLayoutDefaultsExpandedAndPersistsCollapse() {
  #expect(WatchtowerAnalyticsCardLayout.isExpanded("webTraffic", raw: ""))
  #expect(WatchtowerAnalyticsCardLayout.collapsedIDs(in: "").isEmpty)

  let collapsed = WatchtowerAnalyticsCardLayout.toggled("webTraffic", in: "")
  #expect(collapsed == "webTraffic")
  #expect(!WatchtowerAnalyticsCardLayout.isExpanded("webTraffic", raw: collapsed))
  #expect(WatchtowerAnalyticsCardLayout.isExpanded("cacheRate", raw: collapsed))

  let both = WatchtowerAnalyticsCardLayout.toggled("cacheRate", in: collapsed)
  #expect(WatchtowerAnalyticsCardLayout.collapsedIDs(in: both) == ["cacheRate", "webTraffic"])

  let restored = WatchtowerAnalyticsCardLayout.toggled("webTraffic", in: both)
  #expect(restored == "cacheRate")
}

@Test func watchtowerAnalyticsCollapsedSeriesLiftsZerosOffTheFloor() {
  let lifted = WatchtowerAnalyticsChartModel.collapsedSeriesValues([0, 50, 0, 100])
  #expect(lifted.valueCeiling == nil)
  #expect(lifted.values == [10, 50, 10, 100])

  let quiet = WatchtowerAnalyticsChartModel.collapsedSeriesValues([0, 0, 0])
  #expect(quiet.valueCeiling == 1)
  #expect(quiet.values == [0.1, 0.1, 0.1])
}

@Test func watchtowerAnalyticsCardLayoutRowsKeepExpandedSolo() {
  let metrics: [WatchtowerAnalyticsMetric] = [
    .workerInvocations, .workerErrors, .webTraffic, .cacheRate,
  ]
  // All expanded → one metric per row.
  let open = WatchtowerAnalyticsCardLayout.rows(metrics, collapsedRaw: "", forceExpanded: false)
  #expect(
    open.map { $0.map(\.rawValue) } == [
      ["workerInvocations"], ["workerErrors"], ["webTraffic"], ["cacheRate"],
    ])

  // Collapse the middle two → they share a row; neighbors stay full-width.
  let packed = WatchtowerAnalyticsCardLayout.rows(
    metrics,
    collapsedRaw: "workerErrors,webTraffic",
    forceExpanded: false)
  #expect(
    packed.map { $0.map(\.rawValue) } == [
      ["workerInvocations"], ["workerErrors", "webTraffic"], ["cacheRate"],
    ])
}

@Test func watchtowerAnalyticsCardLayoutRestoresOrderAndAppendsNewMetrics() {
  let available: [WatchtowerAnalyticsMetric] = [
    .workerInvocations, .workerErrors, .webTraffic, .cacheRate,
  ]
  let restored = WatchtowerAnalyticsCardLayout.orderedMetrics(
    in: "cacheRate,unknown,workerErrors,cacheRate",
    available: available)

  #expect(restored == [.cacheRate, .workerErrors, .workerInvocations, .webTraffic])
  #expect(
    WatchtowerAnalyticsCardLayout.encodeOrder(restored)
      == "cacheRate,workerErrors,workerInvocations,webTraffic")
}

@Test func watchtowerAnalyticsCardLayoutNativeReorderCrossesItsTarget() {
  let metrics: [WatchtowerAnalyticsMetric] = [
    .workerInvocations, .workerErrors, .webTraffic, .cacheRate,
  ]

  let downward = WatchtowerAnalyticsCardLayout.moving(
    metrics, item: .workerInvocations, across: .webTraffic)
  #expect(downward == [.workerErrors, .webTraffic, .workerInvocations, .cacheRate])

  let upward = WatchtowerAnalyticsCardLayout.moving(
    metrics, item: .cacheRate, across: .workerErrors)
  #expect(upward == [.workerInvocations, .cacheRate, .workerErrors, .webTraffic])
}

@Test func watchtowerAnalyticsFreshInstallLayoutLeadsWithExpandedWebTraffic() {
  let fresh = WatchtowerAnalyticsCardLayout.layout(
    orderRaw: nil, collapsedRaw: nil, hiddenRaw: nil)

  #expect(
    fresh.order.filter { !fresh.hidden.contains($0) } == [
      .webTraffic, .cpuTime, .workerInvocations, .cacheRate, .clientRequestErrors,
    ])
  #expect(fresh.collapsed == [.cpuTime, .workerInvocations, .cacheRate, .clientRequestErrors])
  #expect(
    fresh.hidden == [.workerErrors, .totalBandwidth, .encryptedRequestsRate, .encryptedBandwidth])

  // One expanded headline card, then the four collapsed companions two-up.
  let rows = WatchtowerAnalyticsCardLayout.rows(
    fresh.order.filter { !fresh.hidden.contains($0) },
    collapsedRaw: WatchtowerAnalyticsCardLayout.encode(Set(fresh.collapsed.map(\.rawValue))),
    forceExpanded: false)
  #expect(
    rows.map { $0.map(\.rawValue) } == [
      ["webTraffic"],
      ["cpuTime", "workerInvocations"],
      ["cacheRate", "clientRequestErrors"],
    ])
}

/// A saved layout wins over the fresh-install defaults — including one that
/// deliberately hides nothing, which stores an empty string, not a missing key.
@Test func watchtowerAnalyticsSavedLayoutSurvivesTheFreshInstallDefaults() {
  let saved = WatchtowerAnalyticsCardLayout.layout(
    orderRaw: "cacheRate,webTraffic",
    collapsedRaw: "",
    hiddenRaw: "")

  #expect(Array(saved.order.prefix(2)) == [.cacheRate, .webTraffic])
  #expect(saved.collapsed.isEmpty)
  #expect(saved.hidden.isEmpty)
  #expect(saved.order.count == WatchtowerAnalyticsMetric.allCases.count)

  // The three independently persisted keys can be observed partway through a
  // write or sync; preserve that partial layout instead of replacing it.
  let partial = WatchtowerAnalyticsCardLayout.layout(
    orderRaw: nil, collapsedRaw: "cacheRate", hiddenRaw: nil)
  #expect(partial.order == Array(WatchtowerAnalyticsMetric.allCases))
  #expect(partial.collapsed == [.cacheRate])
  #expect(partial.hidden.isEmpty)
}

@Test @MainActor func watchtowerChartCustomizationCommitsAndCancelsDrafts() throws {
  let suite = "dash-tests-watchtower-layout-\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  // Seed a saved layout so the draft assertions below describe editing, not the
  // fresh-install defaults.
  defaults.set(
    WatchtowerAnalyticsCardLayout.encodeOrder(Array(WatchtowerAnalyticsMetric.allCases)),
    forKey: WatchtowerAnalyticsCardLayout.orderKey)
  defaults.set("", forKey: WatchtowerAnalyticsCardLayout.key)
  defaults.set("", forKey: WatchtowerAnalyticsCardLayout.hiddenKey)
  let customization = WatchtowerChartCustomizationState(defaults: defaults)

  customization.beginEditing()
  customization.move(.cacheRate, across: .workerInvocations)
  customization.remove(.workerErrors)
  customization.toggleExpanded(.webTraffic)
  customization.cancelEditing()

  #expect(customization.order.first == .workerInvocations)
  #expect(customization.visibleMetrics.contains(.workerErrors))
  #expect(customization.isExpanded(.webTraffic))

  customization.beginEditing()
  customization.move(.cacheRate, across: .workerInvocations)
  customization.remove(.workerErrors)
  customization.toggleExpanded(.webTraffic)
  customization.commitEditing()

  #expect(
    defaults.string(forKey: WatchtowerAnalyticsCardLayout.orderKey)?.hasPrefix("cacheRate") == true)
  #expect(defaults.string(forKey: WatchtowerAnalyticsCardLayout.hiddenKey) == "workerErrors")
  #expect(defaults.string(forKey: WatchtowerAnalyticsCardLayout.key) == "webTraffic")
}

extension LocalizationTests {
  @Test func watchtowerAnalyticsUpdatedBadgeUsesRelativeTime() {
    let previousLocale = DashL10n.localeOverrideForTesting
    DashL10n.localeOverrideForTesting = Locale(identifier: "en")
    defer { DashL10n.localeOverrideForTesting = previousLocale }

    // No snapshot yet: the skeleton and the pull-to-refresh spinner are the only
    // loading signals, so the header shows no freshness text at all.
    #expect(WatchtowerAnalyticsChartModel.updatedBadge(fetchedAt: nil) == nil)

    let now = Date()
    let badge = WatchtowerAnalyticsChartModel.updatedBadge(
      fetchedAt: now.addingTimeInterval(-180),
      now: now)
    #expect(badge?.contains("minute") == true || badge?.contains("seconds") == true)
    // Visible string is the bare fragment; only VoiceOver gets the subject.
    #expect(badge?.hasPrefix("Updated") == false)
    #expect(
      WatchtowerAnalyticsChartModel.updatedAccessibilityLabel("3 minutes ago")
        == "Updated 3 minutes ago")

    // A TimelineView tick can lag the wall clock, so a just-fetched stamp looks
    // slightly in the future. The zero/sub-second formatter boundary must stay
    // a positive, localized "just now" result rather than "in 0 seconds".
    let futureClamped = WatchtowerAnalyticsChartModel.updatedBadge(
      fetchedAt: now.addingTimeInterval(45),
      now: now)
    #expect(futureClamped == "just now")
    #expect(
      WatchtowerAnalyticsChartModel.updatedBadge(
        fetchedAt: now.addingTimeInterval(-0.5),
        now: now) == "just now")
  }
}

@Test func watchtowerAnalyticsChartPointsParseHourAndDayStamps() {
  let points = WatchtowerAnalyticsChartModel.chartPoints(from: [
    AccountAnalyticsPoint(datetime: "2026-07-22T10:00:00Z", requests: 10, bytes: 100),
    AccountAnalyticsPoint(datetime: "2026-07-21", requests: 20, bytes: 200),
    AccountAnalyticsPoint(datetime: "2026-07-22T11:00:00Z", requests: 30, bytes: 300),
  ])
  #expect(points.map(\.point.requests) == [20, 10, 30])
}

@Test func watchtowerWidgetSnapshotMapsAndRoundTrips() throws {
  let suite = "dash.tests.widget-snapshot.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  let formatter = ISO8601DateFormatter()
  let old = NotificationHistoryEntry(
    historyID: "old", name: "Older delivery", alertType: "test",
    sent: formatter.string(from: Date(timeIntervalSince1970: 100)))

  // The first page is the local read baseline, so it lands in history.
  let baseline = WatchtowerSnapshot(
    alerts: [old], alertsStatus: .ok, fetchedAt: Date(timeIntervalSince1970: 1_000_000)
  ).widgetSnapshot(accountID: "account-1", accountName: "Acme", defaults: defaults)
  #expect(baseline.unreadCount == 0)
  #expect(baseline.alerts.isEmpty)

  let fresh = NotificationHistoryEntry(
    historyID: "fresh", name: "Tunnel health", alertType: "tunnel_health_event",
    alertBody: "homelab-01 disconnected",
    sent: formatter.string(from: Date(timeIntervalSinceNow: 60)))
  let widget = WatchtowerSnapshot(
    alerts: [fresh, old], alertsStatus: .ok, fetchedAt: Date(timeIntervalSince1970: 1_000_000)
  ).widgetSnapshot(accountID: "account-1", accountName: "Acme", defaults: defaults)

  #expect(widget.unreadCount == 1)
  #expect(widget.alerts.map(\.title) == ["Tunnel health"])
  #expect(!widget.alertsUnavailable)
  #expect(widget.accountID == "account-1")
  #expect(widget.accountName == "Acme")
  #expect(widget.deepLinkURL?.absoluteString == "dash://watchtower?account=account-1")

  // A failed history fetch says so instead of claiming an empty inbox.
  let unavailable = WatchtowerSnapshot(
    alerts: [], alertsStatus: .error, fetchedAt: Date(timeIntervalSince1970: 1_000_000)
  ).widgetSnapshot(accountID: "account-1", accountName: nil, defaults: defaults)
  #expect(unavailable.alertsUnavailable)

  // Codable round-trips through the App Group file format.
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("watchtower-\(UUID().uuidString).json")
  try widget.write(to: url)
  let loaded = try WatchtowerWidgetSnapshot.load(from: url)
  #expect(loaded == widget)
  try WatchtowerWidgetSnapshot.clear(at: url)

  var whitespaceAccount = widget
  whitespaceAccount.accountID = "  "
  #expect(whitespaceAccount.deepLinkURL == nil)
}

@Test func watchtowerWidgetStalenessTiers() {
  let base = WatchtowerWidgetSnapshot(
    unreadCount: 0, alerts: [], accountID: "preview-account", accountName: nil,
    fetchedAt: Date(timeIntervalSince1970: 0))
  #expect(base.staleness(now: Date(timeIntervalSince1970: 3600)) == .fresh)
  #expect(base.staleness(now: Date(timeIntervalSince1970: 3 * 3600)) == .aging)
  #expect(base.staleness(now: Date(timeIntervalSince1970: 25 * 3600)) == .stale)
  // Widget copy still uses Bundle `String(localized:)` — compare against the
  // same resolver so the assertion holds on zh-Hans simulators too.
  let agingRelative = String(localized: "\(3) hr ago")
  #expect(
    WatchtowerFreshness.checkedText(
      fetchedAt: base.fetchedAt,
      now: Date(timeIntervalSince1970: 3 * 3_600))
      == String(localized: "Checked \(agingRelative) · Refresh recommended"))
  let staleRelative = String(localized: "1 day ago")
  #expect(
    WatchtowerFreshness.checkedText(
      fetchedAt: base.fetchedAt,
      now: Date(timeIntervalSince1970: 25 * 3_600))
      == String(localized: "Checked \(staleRelative) · Refresh now"))
}

@Test @MainActor func watchtowerInboxStateRejectsStaleAccountLoads() {
  let accountA = AccountRequestContext(accountID: "account-a", generation: 1)
  let accountB = AccountRequestContext(accountID: "account-b", generation: 2)
  let state = WatchtowerInboxScreenState()
  let loadA = state.beginLoad(for: accountA)
  let entry = WatchtowerInboxEntry(
    id: "cf:hist-1",
    title: "Tunnel health",
    detail: "homelab-01 disconnected",
    sentAt: Date(timeIntervalSince1970: 100),
    category: .unread)
  state.contents = WatchtowerInboxContents(
    unreadNotifications: [entry],
    history: [],
    ignored: [])
  state.ignoredIDs = [entry.id]
  state.alertsStatus = .ok
  state.loading = false
  state.hasPresentedContent = true

  state.reset(for: accountB)

  #expect(state.loadedContext == accountB)
  #expect(state.contents.isEmpty)
  #expect(state.ignoredIDs.isEmpty)
  #expect(state.alertsStatus == .loading)
  #expect(state.loading)
  #expect(!state.hasPresentedContent)
  #expect(!state.ownsLoad(loadA, context: accountA))
  let loadB = state.beginLoad(for: accountB)
  #expect(state.ownsLoad(loadB, context: accountB))
}

/// Nothing Dash detects reaches the inbox — only Cloudflare's deliveries do,
/// and ignoring one is local to this iPhone.
@Test func watchtowerInboxCarriesCloudflareDeliveriesOnly() {
  let suite = "dash.tests.inbox.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  let account = "acct-1"

  let alerts = [
    NotificationHistoryEntry(
      historyID: "hist-1",
      policyID: "pol-1",
      name: "Tunnel health",
      alertType: "tunnel_health_event",
      mechanism: "email",
      alertBody: "homelab-01 disconnected from Cloudflare",
      description: nil,
      sent: ISO8601DateFormatter().string(from: Date.now.addingTimeInterval(60)))
  ]
  // The first Cloudflare page is history, not a synthetic unread row.
  _ = WatchtowerInboxStore.unreadCount(
    accountID: account, alerts: [], defaults: defaults)
  let contents = WatchtowerInboxStore.contents(
    accountID: account, alerts: alerts, defaults: defaults)
  #expect(contents.unreadNotifications.map(\.id) == ["cf:hist-1"])
  #expect(contents.history.isEmpty)

  let entryID = "cf:hist-1"
  WatchtowerInboxStore.ignore([entryID], accountID: account, defaults: defaults)
  #expect(WatchtowerInboxStore.isIgnored(entryID, accountID: account, defaults: defaults))
  #expect(
    WatchtowerInboxStore.unreadCount(
      accountID: account, alerts: alerts, defaults: defaults) == 0)
  #expect(
    WatchtowerInboxStore.contents(
      accountID: account, alerts: alerts, defaults: defaults
    ).ignored.map(\.id) == [entryID])

  WatchtowerInboxStore.unignore(entryID, accountID: account, defaults: defaults)
  #expect(
    WatchtowerInboxStore.unreadCount(
      accountID: account, alerts: alerts, defaults: defaults) == 1)
}

@Test func watchtowerInboxSeparatesUnreadFromHistory() {
  let suite = "dash.tests.inbox-semantics.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  let account = "acct-semantics"
  let formatter = ISO8601DateFormatter()
  let history = NotificationHistoryEntry(
    historyID: "history",
    name: "Older delivery",
    alertType: "test",
    sent: formatter.string(from: Date(timeIntervalSince1970: 100)))

  // Existing Cloudflare rows establish the account's first local read baseline.
  #expect(
    WatchtowerInboxStore.unreadCount(
      accountID: account, alerts: [history], defaults: defaults) == 0)
  var contents = WatchtowerInboxStore.contents(
    accountID: account, alerts: [history], defaults: defaults)
  #expect(contents.history.map(\.id) == ["cf:history"])
  #expect(contents.unreadNotifications.isEmpty)
  let persistedReadJSON = defaults.data(forKey: WatchtowerInboxStore.readKey).flatMap {
    try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
  }
  #expect(persistedReadJSON?["baselineByAccount"] != nil)

  let newer = NotificationHistoryEntry(
    historyID: "new",
    name: "New delivery",
    alertType: "test",
    sent: formatter.string(from: Date.now.addingTimeInterval(60)))
  contents = WatchtowerInboxStore.contents(
    accountID: account, alerts: [newer, history], defaults: defaults)
  #expect(contents.unreadNotifications.map(\.id) == ["cf:new"])
  #expect(contents.history.map(\.id) == ["cf:history"])
  #expect(
    WatchtowerInboxStore.unreadCount(
      accountID: account, alerts: [newer, history], defaults: defaults) == 1)

  WatchtowerInboxStore.markRead(["cf:new"], accountID: account, defaults: defaults)
  contents = WatchtowerInboxStore.contents(
    accountID: account, alerts: [newer, history], defaults: defaults)
  #expect(contents.unreadNotifications.isEmpty)
  #expect(Set(contents.history.map(\.id)) == ["cf:new", "cf:history"])
  #expect(
    WatchtowerInboxStore.unreadCount(
      accountID: account, alerts: [newer, history], defaults: defaults) == 0)
}
