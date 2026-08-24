import CloudflareAPI
import Observation
import SwiftDitherKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private struct WatchtowerMetricDragPresentation: Equatable {
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
  fileprivate enum Phase: Equatable {
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
  fileprivate private(set) var presentation: WatchtowerMetricDragPresentation?
  fileprivate private(set) var phase: Phase?
  @ObservationIgnored fileprivate weak var coordinateView: UIView?
  /// The space the live `presentation` coordinates are expressed in. Held for
  /// the length of one session so move / settle keep measuring against the same
  /// view the lift resolved.
  @ObservationIgnored fileprivate private(set) weak var activeReference: UIView?
  @ObservationIgnored fileprivate private(set) var activeContainerWidth: CGFloat = 0
  @ObservationIgnored private var retainedDelegate: AnyObject?
  @ObservationIgnored private var sourceViews: [WatchtowerAnalyticsMetric: WeakView] = [:]
  /// SwiftUI owns the card layout, so its measured frames are the stable source
  /// of truth for both insertion targeting and the release destination. UIKit
  /// source views are only a fallback while the first preference pass lands.
  @ObservationIgnored private var layoutFrames: [WatchtowerAnalyticsMetric: CGRect] = [:]
  /// Last valid frames expressed in `activeReference`. They intentionally
  /// survive a row reconstruction for the duration of one drag session.
  @ObservationIgnored private var sessionFrames: [WatchtowerAnalyticsMetric: CGRect] = [:]
  @ObservationIgnored private var layoutToReferenceOffset = CGSize.zero

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
  fileprivate func reference(for sourceView: UIView) -> UIView? {
    coordinateView ?? sourceView.window
  }

  var pressedMetric: WatchtowerAnalyticsMetric? {
    press?.metric
  }

  fileprivate var animatesPresentation: Bool {
    phase == .lifting || phase == .settling
  }

  fileprivate func beginPress(
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

  fileprivate func endPress(identifier: UUID) {
    guard press?.identifier == identifier else { return }
    press = nil
    guard phase == .pressing else { return }
    presentation = nil
    phase = nil
    activeReference = nil
    activeContainerWidth = 0
    sessionFrames.removeAll(keepingCapacity: true)
    layoutToReferenceOffset = .zero
  }

  fileprivate func beginLift(
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
    activeContainerWidth = max(
      reference.bounds.width,
      layoutFrames.values.map(\.maxX).max() ?? 0)
    if let sourceFrame = layoutFrames[metric] {
      layoutToReferenceOffset = CGSize(
        width: sourceCenter.x - sourceFrame.midX,
        height: sourceCenter.y - sourceFrame.midY)
      sessionFrames = adjustedLayoutFrames()
    } else {
      layoutToReferenceOffset = .zero
      sessionFrames.removeAll(keepingCapacity: true)
    }
    // The coordinator has this centre directly from the live interaction view,
    // so release always has at least one deterministic card slot to return to.
    sessionFrames[metric] = CGRect(
      x: sourceCenter.x - size.width / 2,
      y: sourceCenter.y - size.height / 2,
      width: size.width,
      height: size.height)
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
  fileprivate func trackFinger(to location: CGPoint) {
    guard var presentation else { return }
    presentation.fingerLocation = location
    self.presentation = presentation
  }

  fileprivate func liftToFinger() {
    guard phase == .lifting, var presentation else { return }
    presentation.centerOffset = .zero
    presentation.scale = 1
    self.presentation = presentation
  }

  fileprivate func finishLift() {
    guard phase == .lifting else { return }
    phase = .tracking
  }

  /// Changes both the phase and the animatable offset in one transaction. If
  /// these land in separate renders SwiftUI may see no animation and execute a
  /// completion immediately, which makes the ghost appear to snap home.
  fileprivate func settle(to center: CGPoint) {
    guard var presentation else { return }
    phase = .settling
    presentation.centerOffset = CGSize(
      width: center.x - presentation.fingerLocation.x,
      height: center.y - presentation.fingerLocation.y)
    self.presentation = presentation
  }

  func updateLayoutFrames(_ frames: [WatchtowerAnalyticsMetric: CGRect]) {
    layoutFrames = frames.filter { _, frame in
      frame.width > 0 && frame.height > 0
    }
    guard presentation != nil else { return }
    sessionFrames.merge(adjustedLayoutFrames(), uniquingKeysWith: { _, new in new })
  }

  fileprivate func registerSourceView(_ view: UIView, for metric: WatchtowerAnalyticsMetric) {
    if let current = sourceViews[metric]?.value,
      current !== view,
      current.window != nil,
      view.window == nil
    {
      // SwiftUI can update an outgoing representable after its replacement is
      // live. Never let that off-window instance steal the metric registration.
      return
    }
    sourceViews[metric] = WeakView(view)
  }

  fileprivate func unregisterSourceView(_ view: UIView, for metric: WatchtowerAnalyticsMetric) {
    guard sourceViews[metric]?.value === view else { return }
    sourceViews[metric] = nil
  }

  /// Card frames in the active drag's coordinate space. Stable SwiftUI layout
  /// measurements win; live UIKit source views only fill an initial gap.
  fileprivate func frames(for metrics: [WatchtowerAnalyticsMetric])
    -> [WatchtowerAnalyticsMetric: CGRect]
  {
    var result = sessionFrames.filter { metrics.contains($0.key) }
    if let reference = activeReference ?? coordinateView {
      for metric in metrics where result[metric] == nil {
        guard let view = sourceViews[metric]?.value, view.window != nil else { continue }
        let frame = view.convert(view.bounds, to: reference)
        guard frame.width > 0, frame.height > 0 else { continue }
        result[metric] = frame
        sessionFrames[metric] = frame
      }
    }
    return result
  }

  fileprivate func sourceCenter(for metric: WatchtowerAnalyticsMetric) -> CGPoint? {
    if let frame = sessionFrames[metric] {
      return CGPoint(x: frame.midX, y: frame.midY)
    }
    guard let reference = activeReference ?? coordinateView,
      let view = sourceViews[metric]?.value,
      view.window != nil
    else { return nil }
    let frame = view.convert(view.bounds, to: reference)
    guard frame.width > 0, frame.height > 0 else { return nil }
    sessionFrames[metric] = frame
    return CGPoint(x: frame.midX, y: frame.midY)
  }

  func finish() {
    press = nil
    presentation = nil
    phase = nil
    activeReference = nil
    activeContainerWidth = 0
    retainedDelegate = nil
    sessionFrames.removeAll(keepingCapacity: true)
    layoutToReferenceOffset = .zero
  }

  private func adjustedLayoutFrames() -> [WatchtowerAnalyticsMetric: CGRect] {
    layoutFrames.mapValues { frame in
      frame.offsetBy(
        dx: layoutToReferenceOffset.width,
        dy: layoutToReferenceOffset.height)
    }
  }
}

struct WatchtowerMetricExpandedLayoutKey: LayoutValueKey {
  static let defaultValue = false
}

struct WatchtowerMetricCardFlowLayout: Layout {
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
private enum WatchtowerMetricDropTargeting {
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
  /// is past every card, which is the append slot. Full-width identity comes
  /// from the flow width, not whichever remaining card happens to be widest.
  static func destinationIndex(
    point: CGPoint,
    otherFrames: [CGRect],
    containerWidth: CGFloat
  ) -> Int {
    return otherFrames.filter {
      // A half-width card is always narrower than half the flow after its
      // inter-column gap is removed. Comparing cards only to one another made
      // every remaining card look full-width while the sole expanded card was
      // being dragged, so horizontal movement could never cross a slot.
      precedes($0, point: point, isFullWidth: $0.width > containerWidth / 2)
    }.count
  }
}

enum WatchtowerMetricDragLayout {
  static let coordinateSpace = "watchtower.metric-drag"
  static let controlsPassthroughSize = CGSize(width: 96, height: 60)
  static let titleTrailingClearance =
    controlsPassthroughSize.width - DashTheme.Spacing.card
}

struct WatchtowerMetricFramePreferenceKey: PreferenceKey {
  static let defaultValue: [WatchtowerAnalyticsMetric: CGRect] = [:]

  static func reduce(
    value: inout [WatchtowerAnalyticsMetric: CGRect],
    nextValue: () -> [WatchtowerAnalyticsMetric: CGRect]
  ) {
    value.merge(nextValue(), uniquingKeysWith: { _, new in new })
  }
}

struct WatchtowerMetricDropPlaceholder: View {
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

final class WatchtowerDragCoordinateUIView: UIView {
  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    false
  }
}

struct WatchtowerMetricDragCoordinateView: UIViewRepresentable {
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

final class WatchtowerMetricDragSourceUIView: UIView {
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

struct WatchtowerNativeMetricDragSource: UIViewRepresentable {
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

    /// Layout frames keep changing while the previous reorder animates, so a
    /// settled slot needs a moment before the next hit test is meaningful. This
    /// is the local stand-in for `reorderingCadence`.
    private static let reorderCadence: CFTimeInterval = 0.2

    private func updateDropTarget() {
      guard customization.draggedMetric == metric,
        let center = visualState.presentation?.center
      else { return }

      // Inside the cadence window the previous reorder is still sliding, so
      // every hit test is noise — for the hover cue as much as for the next
      // move. The cached layout frames keep this deterministic even when a
      // representable is rebuilt mid-animation.
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
        point: center,
        otherFrames: otherFrames,
        containerWidth: visualState.activeContainerWidth)
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
      // `willEndWith` is the normal path, but a cancelled UIKit session can
      // arrive here directly. It deserves the same spring, not a snap.
      settleDrag()
    }

    private func settleDrag() {
      guard active, !settling else { return }
      active = false
      settling = true

      // `beginLift` seeds a session frame from the live source and subsequent
      // SwiftUI layout preferences move it with the dashed insertion slot. A
      // weak representable disappearing can therefore never erase this target.
      guard
        let targetCenter =
          visualState.sourceCenter(for: metric)
          ?? visualState.presentation?.center
      else {
        completeDrag()
        return
      }

      let reduceMotion = UIAccessibility.isReduceMotionEnabled
      if reduceMotion {
        visualState.settle(to: targetCenter)
        completeDrag()
        return
      }
      let currentDragIdentifier = dragIdentifier
      withAnimation(
        DashTheme.Motion.release,
        completionCriteria: .logicallyComplete
      ) {
        visualState.settle(to: targetCenter)
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

struct WatchtowerMetricDragOverlay: View {
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
struct WatchtowerMetricRootDropModifier: ViewModifier {
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
