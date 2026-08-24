import CloudflareAPI
import GradientAvatars
import SwiftUI
import UIKit

// MARK: - Custom page stack

struct DashPagePresentationState: Equatable {
  let settledDepth: Int
  let isTransitioning: Bool

  func resolvedDepth(navigatorDepth: Int) -> Int {
    // The navigator leads on push; the compositor leads on pop. Taking both
    // prevents root chrome from returning before either owner reaches root.
    max(navigatorDepth, settledDepth)
  }

  func occupiesWorkspace(navigatorDepth: Int) -> Bool {
    resolvedDepth(navigatorDepth: navigatorDepth) > 0 || isTransitioning
  }
}

@MainActor
@Observable
private final class DashPageHostContext {
  var isTabActive: Bool
  var canPresentPendingHomeAction: Bool
  var splashLifted: Bool
  var interactionLockedEntryID: DashNavigationEntry.ID?
  var workspaceWashScroll: DashWorkspaceWashScroll?
  var locale: Locale
  var dynamicTypeSize: DynamicTypeSize

  init(
    isTabActive: Bool,
    canPresentPendingHomeAction: Bool,
    splashLifted: Bool,
    workspaceWashScroll: DashWorkspaceWashScroll?,
    locale: Locale,
    dynamicTypeSize: DynamicTypeSize
  ) {
    self.isTabActive = isTabActive
    self.canPresentPendingHomeAction = canPresentPendingHomeAction
    self.splashLifted = splashLifted
    self.interactionLockedEntryID = nil
    self.workspaceWashScroll = workspaceWashScroll
    self.locale = locale
    self.dynamicTypeSize = dynamicTypeSize
  }

  func update(
    isTabActive: Bool,
    canPresentPendingHomeAction: Bool,
    splashLifted: Bool,
    workspaceWashScroll: DashWorkspaceWashScroll?,
    locale: Locale,
    dynamicTypeSize: DynamicTypeSize
  ) {
    self.isTabActive = isTabActive
    self.canPresentPendingHomeAction = canPresentPendingHomeAction
    self.splashLifted = splashLifted
    self.workspaceWashScroll = workspaceWashScroll
    self.locale = locale
    self.dynamicTypeSize = dynamicTypeSize
  }
}

@MainActor
private final class DashRootContentBox<Content: View> {
  let content: Content

  init(content: Content) {
    self.content = content
  }
}

private struct DashHostedRoot<Root: View>: View {
  let contentBox: DashRootContentBox<Root>
  let model: AppModel
  let navigator: DestinationNavigator
  let navigationCoordinator: DashNavigationCoordinator?
  let anchorRegistry: DashNavigationAnchorRegistry?
  let presentationState: DashWorkspacePresentationState?
  let hostContext: DashPageHostContext

  var body: some View {
    DashRoutePageChromeHost(entry: nil) {
      contentBox.content
    }
    .tint(DashTheme.brand)
    .environment(model)
    .environment(\.destinationNavigator, navigator)
    .environment(\.dashNavigationCoordinator, navigationCoordinator)
    .environment(\.dashNavigationAnchorRegistry, anchorRegistry)
    .environment(\.dashWorkspacePresentationState, presentationState)
    .environment(\.dashUsesCustomPageStack, true)
    .environment(\.dashNavigationEntryID, nil)
    .environment(\.dashTabActive, hostContext.isTabActive)
    .environment(\.dashSplashLifted, hostContext.splashLifted)
    .environment(
      \.dashCanPresentPendingHomeAction,
      hostContext.canPresentPendingHomeAction
    )
    .environment(
      \.dashWorkspaceWashScroll,
      hostContext.workspaceWashScroll
    )
    .environment(\.locale, hostContext.locale)
    .environment(\.dynamicTypeSize, hostContext.dynamicTypeSize)
  }
}

private struct DashHostedDestination: View {
  let entry: DashNavigationEntry
  let model: AppModel
  let navigator: DestinationNavigator
  let navigationCoordinator: DashNavigationCoordinator?
  let anchorRegistry: DashNavigationAnchorRegistry?
  let presentationState: DashWorkspacePresentationState?
  let hostContext: DashPageHostContext

  var body: some View {
    DashRoutePageChromeHost(
      entry: entry,
      allowsBodyInteraction: hostContext.interactionLockedEntryID != entry.id
    ) {
      DestinationRoutedContent(destination: entry.destination)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .modifier(DashScrollEdgeEffectsHidden())
    .background { DashScrollViewConfigurator(fill: .canvas) }
    .background(DashTheme.canvas.ignoresSafeArea())
    .tint(DashTheme.brand)
    .environment(model)
    .environment(\.destinationNavigator, navigator)
    .environment(\.dashNavigationCoordinator, navigationCoordinator)
    .environment(\.dashNavigationAnchorRegistry, anchorRegistry)
    .environment(\.dashWorkspacePresentationState, presentationState)
    .environment(\.dashUsesCustomPageStack, true)
    .environment(\.dashNavigationEntryID, entry.id)
    .environment(\.dashNavigationEntryHero, entry.origin?.hero)
    .environment(
      \.dashPageTransitionActive,
      hostContext.interactionLockedEntryID == entry.id
    )
    .environment(\.dashTabActive, hostContext.isTabActive)
    .environment(\.dashSplashLifted, hostContext.splashLifted)
    .environment(
      \.dashCanPresentPendingHomeAction,
      hostContext.canPresentPendingHomeAction
    )
    .environment(\.dashWorkspaceWashScroll, nil)
    .environment(\.locale, hostContext.locale)
    .environment(\.dynamicTypeSize, hostContext.dynamicTypeSize)
  }
}

/// The card is the only moving spatial identity. Both pages stay fixed while
/// the source context softens and the destination content resolves behind it.
enum DashCardMorphRules {
  static let movesPages = false

  /// Distance the invisible timeline driver's position travels for progress
  /// 0 → 1. Any value works — larger buys sampling resolution; the driver is
  /// zero-sized and never seen.
  static let timelineTravel: CGFloat = 320

  /// One duration for every flight makes speed proportional to distance: a
  /// bottom-row card covers three times the ground of a top-row card in the
  /// same window and reads as lunging. Flights at or under `referenceTravel`
  /// (the top rows) keep the base pace; longer ones stretch linearly up to
  /// `maxFlightStretch` at `farTravel`, so every card GROWS at roughly the
  /// same felt rate. Applies to pops too — a far card rushing home is the
  /// same lunge backwards.
  static let referenceTravel: CGFloat = 220
  static let farTravel: CGFloat = 640
  static let maxFlightStretch: Double = 1.3

  static func flightDuration(
    base: TimeInterval,
    from source: CGRect,
    to landing: CGRect
  ) -> TimeInterval {
    let travel = hypot(landing.midX - source.midX, landing.midY - source.midY)
    guard travel > referenceTravel else { return base }
    let unit = Double(
      min((travel - referenceTravel) / (farTravel - referenceTravel), 1))
    return base * (1 + (maxFlightStretch - 1) * unit)
  }

  /// Floor-clamped only. The enter spring is slightly underdamped and its
  /// overshoot past 1 extrapolates the flight a few points past the landing
  /// seat before settling back — that extrapolation IS the bounce. Every
  /// non-spatial curve (`smoothSegment` consumers) clamps internally, so the
  /// hero frame is the one place the overshoot lands.
  static func heroFrame(
    from source: CGRect,
    to landing: CGRect,
    detailProgress: CGFloat
  ) -> CGRect {
    let progress = max(detailProgress, 0)
    return CGRect(
      x: source.minX + (landing.minX - source.minX) * progress,
      y: source.minY + (landing.minY - source.minY) * progress,
      width: source.width + (landing.width - source.width) * progress,
      height: source.height + (landing.height - source.height) * progress)
  }

  static func detailPageOpacity(at detailProgress: CGFloat) -> CGFloat {
    smoothSegment(detailProgress, from: 0.2, to: 0.88)
  }

  static func departingDetailPageOpacity(at detailProgress: CGFloat) -> CGFloat {
    smoothSegment(detailProgress, from: 0.44, to: 0.94)
  }

  /// The veil only ever grows. It used to pulse — rise, then fade back off —
  /// and a full-screen blur that both arrives and leaves inside one 380ms
  /// flight reads as a blink no matter how wide the ramps are. Riding *under*
  /// the arriving page instead, it is retired by being covered: the opaque
  /// destination resolves on top of it (`detailPageOpacity`) and the veil
  /// never has to travel back down while anyone can see it. A reversed push
  /// runs this same curve backwards, continuously, under the finger.
  static func backdropOpacity(at detailProgress: CGFloat) -> CGFloat {
    smoothSegment(detailProgress, from: 0, to: 0.6)
  }

  static func detailAccessoryOpacity(at detailProgress: CGFloat) -> CGFloat {
    smoothSegment(detailProgress, from: 0.62, to: 0.9)
  }

  static func isUsableEndpoint(_ frame: CGRect, in bounds: CGRect) -> Bool {
    frame.width > 2 && frame.height > 2
      && frame.width.isFinite && frame.height.isFinite
      && frame.minX.isFinite && frame.minY.isFinite
      && frame.intersects(bounds.insetBy(dx: -2, dy: -2))
  }

  private static func smoothSegment(
    _ progress: CGFloat,
    from start: CGFloat,
    to end: CGFloat
  ) -> CGFloat {
    guard end > start else { return progress >= end ? 1 : 0 }
    let unit = min(max((progress - start) / (end - start), 0), 1)
    return unit * unit * (3 - 2 * unit)
  }
}

private struct DashNavigationHeroView: View {
  let hero: DashNavigationHero
  let detailProgress: CGFloat
  let locale: Locale
  let dynamicTypeSize: DynamicTypeSize
  /// Read live, never baked into the hero value: the pin can flip while the
  /// detail is up (its own header action), and the return flight must land
  /// wearing the marker the grid card already shows.
  @AppStorage(PinnedZones.key) private var pinnedZoneData = ""
  /// Same contract for card fill — customize saves under this key on the
  /// detail screen, and a pop that still carried the push-time `fillHex`
  /// would fly the old color back into the grid.
  @AppStorage(DomainCardColors.key) private var domainCardColorData = ""

  var body: some View {
    content
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .environment(\.locale, locale)
      .environment(\.dynamicTypeSize, dynamicTypeSize)
  }

  @ViewBuilder
  private var content: some View {
    switch hero {
    case .domainCard(
      let accountID, let zoneID, let name, let status, let seed, let fillHex, let plan
    ):
      DomainCardFace(
        name: name,
        status: status,
        seed: seed,
        fillHex: DomainCardColors.hex(
          in: domainCardColorData,
          accountID: accountID,
          zoneID: zoneID,
          fallback: fillHex),
        plan: plan,
        pinMarker: PinnedZones.isPinned(pinnedZoneData, zoneID: zoneID)
          ? 1 - min(max(detailProgress, 0), 1)
          : 0,
        fillsContainer: true,
        detailReveal: detailProgress
      )
      .overlay(alignment: .bottomTrailing) {
        DomainCardCustomizeButton {}
          .opacity(DashCardMorphRules.detailAccessoryOpacity(at: detailProgress))
          .padding(12)
      }
    case .emailRoutingCard(
      let accountID, let zoneID, let name, let status, let seed, let fillHex
    ):
      DomainCardFace(
        name: name,
        status: status,
        seed: seed,
        fillHex: DomainCardColors.hex(
          in: domainCardColorData,
          accountID: accountID,
          zoneID: zoneID,
          fallback: fillHex),
        textureAsset: SolarAsset.Content.letter,
        fillsContainer: true,
        detailReveal: detailProgress
      )
    case .featureResourceCard(_, let content):
      FeatureResourceCardFace(content: content, fillsContainer: true)
    }
  }
}

/// The three page languages Dash speaks, and nothing else. `flow` is the
/// horizontal handoff every drill-down uses — the outgoing page leaves while
/// the arriving one enters, the same step a tab change makes. `card` is the
/// Family-style spatial handoff, reserved for a source that hands over a
/// concrete card (Domains, Email Routing, Workers, or Pages → their card-led
/// detail). Full-width resource cards keep the same size in both seats, so
/// this role does not imply visual enlargement. `workspace` is the Settings
/// train.
enum DashPageTransitionRole: Hashable {
  case flow
  case card
  case workspace
}

enum DashPageTransitionRules {
  /// The source decides between flow and card, never the destination: the same
  /// zone opened from a Home row or a recent is a plain drill, and only the
  /// card that publishes a semantic hero morphs.
  static func role(
    presentation: DashNavigationPresentation,
    hasHero: Bool
  ) -> DashPageTransitionRole {
    switch presentation {
    case .workspaceOverlay: .workspace
    case .detail: hasHero ? .card : .flow
    }
  }

  /// ONE pace table. The page compositor animates in UIKit and the shared
  /// header in SwiftUI, but they are two halves of the same step — read the
  /// timing from here in both, or Close outlives the train it left with.
  static func duration(for role: DashPageTransitionRole, isPush: Bool) -> TimeInterval {
    switch role {
    case .flow:
      isPush
        ? DashTheme.Motion.Page.flowEnterDuration
        : DashTheme.Motion.Page.flowExitDuration
    case .card:
      isPush
        ? DashTheme.Motion.Page.cardEnterDuration
        : DashTheme.Motion.Page.cardExitDuration
    case .workspace:
      isPush
        ? DashTheme.Motion.Page.workspaceEnterDuration
        : DashTheme.Motion.Page.workspaceExitDuration
    }
  }

  static func dampingRatio(for role: DashPageTransitionRole, isPush: Bool) -> CGFloat {
    switch role {
    case .flow: DashTheme.Motion.Page.flowDampingRatio
    case .card:
      isPush
        ? DashTheme.Motion.Page.cardEnterDampingRatio
        : DashTheme.Motion.Page.cardExitDampingRatio
    case .workspace:
      isPush
        ? DashTheme.Motion.Page.workspaceEnterDampingRatio
        : DashTheme.Motion.Page.workspaceExitDampingRatio
    }
  }
}

private enum DashPageTransitionStyle {
  case flowPush
  case flowPop
  /// A requested card step whose endpoint seats could not be resolved. It
  /// uses flow geometry, but retains the card role's pace so the UIKit page
  /// and shared SwiftUI header still settle on the same timeline.
  case cardFallbackPush
  case cardFallbackPop
  case cardPush(DashNavigationEntry)
  case cardPop(DashNavigationEntry)
  case workspacePresent(DashNavigationEntry)
  case workspaceDismiss(DashNavigationEntry)

  var isPush: Bool {
    switch self {
    case .flowPush, .cardFallbackPush, .cardPush, .workspacePresent: true
    case .flowPop, .cardFallbackPop, .cardPop, .workspaceDismiss: false
    }
  }

  var entry: DashNavigationEntry? {
    switch self {
    case .cardPush(let entry), .cardPop(let entry),
      .workspacePresent(let entry), .workspaceDismiss(let entry):
      entry
    case .flowPush, .flowPop, .cardFallbackPush, .cardFallbackPop:
      nil
    }
  }

  var role: DashPageTransitionRole {
    switch self {
    case .flowPush, .flowPop: .flow
    case .cardFallbackPush, .cardFallbackPop: .card
    case .cardPush, .cardPop: .card
    case .workspacePresent, .workspaceDismiss: .workspace
    }
  }

  var duration: TimeInterval {
    DashPageTransitionRules.duration(for: role, isPush: isPush)
  }

  var dampingRatio: CGFloat {
    DashPageTransitionRules.dampingRatio(for: role, isPush: isPush)
  }
}

struct DashPageStackRequest {
  let entries: [DashNavigationEntry]
  let revision: UInt64
  let mutation: DashNavigationMutation?
  let accountID: String?
  let reduceMotion: Bool
  let isTabActive: Bool
}

/// A UIKit containment controller, deliberately not a `UINavigationController`.
/// It caches one immutable hosting controller per route-entry UUID, while only
/// the visible page participates in the hierarchy outside a transition.
@MainActor
private final class DashPageStackViewController<Root: View>: UIViewController,
  DashScreenContainerController
{
  private struct EntryHost {
    let entry: DashNavigationEntry
    let controller: UIHostingController<DashHostedDestination>
  }

  /// A neutral full-screen surface separates the outgoing and arriving page
  /// timelines. Raster content stays at its natural size and only crossfades;
  /// the concrete source snapshot is the one local element carried across.
  private final class TransitionProxy {
    let overlay: UIView
    let shell: UIView?
    /// Sits between the stationary pages for a card transition: it softens the
    /// old context while the sharp destination resolves above it.
    let backgroundEffect: UIView?
    let outgoingContent: UIView?
    let arrivingContent: UIView?
    /// Retains the live SwiftUI card renderer for the transition and handoff beat.
    let heroController: UIHostingController<DashNavigationHeroView>?
    /// Invisible property-animation payload that gives the display-link content
    /// timeline a reversible progress source without transforming any pixels.
    let timelineDriver: UIView?
    let claimedOrigin: DashNavigationOrigin?
    /// Second claim for a destination-page landing seat, held for the same
    /// span as `claimedOrigin` so the live seat never doubles the flight.
    let claimedLanding: DashNavigationOrigin?
    /// Fixed end of a card morph's flight — the settled hero seat.
    let morphTargetFrame: CGRect?
    /// Fixed start of a morph flight, captured before the page train moves.
    let morphStartFrame: CGRect?

    init(
      overlay: UIView,
      shell: UIView?,
      backgroundEffect: UIView? = nil,
      outgoingContent: UIView?,
      arrivingContent: UIView?,
      heroController: UIHostingController<DashNavigationHeroView>? = nil,
      timelineDriver: UIView?,
      claimedOrigin: DashNavigationOrigin?,
      claimedLanding: DashNavigationOrigin? = nil,
      morphTargetFrame: CGRect? = nil,
      morphStartFrame: CGRect? = nil
    ) {
      self.overlay = overlay
      self.shell = shell
      self.backgroundEffect = backgroundEffect
      self.outgoingContent = outgoingContent
      self.arrivingContent = arrivingContent
      self.heroController = heroController
      self.timelineDriver = timelineDriver
      self.claimedOrigin = claimedOrigin
      self.claimedLanding = claimedLanding
      self.morphTargetFrame = morphTargetFrame
      self.morphStartFrame = morphStartFrame
    }

    var isCardMorph: Bool { heroController != nil }
  }

  private final class ActiveTransition {
    let animator: UIViewPropertyAnimator
    let source: UIViewController
    let target: UIViewController
    let style: DashPageTransitionStyle
    let proxy: TransitionProxy?
    var desiredEntries: [DashNavigationEntry]
    var revision: UInt64
    let appearanceWasBegun: Bool
    var isReversed = false

    init(
      animator: UIViewPropertyAnimator,
      source: UIViewController,
      target: UIViewController,
      style: DashPageTransitionStyle,
      proxy: TransitionProxy?,
      desiredEntries: [DashNavigationEntry],
      revision: UInt64,
      appearanceWasBegun: Bool
    ) {
      self.animator = animator
      self.source = source
      self.target = target
      self.style = style
      self.proxy = proxy
      self.desiredEntries = desiredEntries
      self.revision = revision
      self.appearanceWasBegun = appearanceWasBegun
    }
  }

  private let contentBox: DashRootContentBox<Root>
  private let hostContext: DashPageHostContext
  private let model: AppModel
  private let navigator: DestinationNavigator
  private let navigationCoordinator: DashNavigationCoordinator?
  private let anchorRegistry: DashNavigationAnchorRegistry?
  private let presentationState: DashWorkspacePresentationState?
  private let rootController: UIHostingController<DashHostedRoot<Root>>
  private let destinationCanvasPlate = UIView()
  private var onPresentationStateChange: (DashPagePresentationState) -> Void

  private var entryHosts: [DashNavigationEntry.ID: EntryHost] = [:]
  private var settledEntries: [DashNavigationEntry] = []
  private var settledRevision: UInt64 = 0
  private var visibleController: UIViewController?
  private var activeTransition: ActiveTransition?
  /// Landed morph overlays outliving their transition by one handoff beat.
  /// The live element underneath is revealed on a later SwiftUI commit; these
  /// must be swept before any new transition composes over them.
  private var lingeringProxies: [TransitionProxy] = []
  private var transitionContentDisplayLink: CADisplayLink?
  private var pendingRequest: DashPageStackRequest?
  private var accountID: String?
  private var isContainerVisible = false
  private var parentAppearanceIsDisappearing = false
  /// The exact child whose parent-driven appearance transition was begun.
  /// Route updates are deferred until this is ended so begin/end can never
  /// land on different cached pages.
  private var parentAppearanceTransitionChild: UIViewController?
  private var pendingPresentationReport: DashPagePresentationState?
  private var lastDeliveredPresentationState: DashPagePresentationState?
  /// Bumped on every `reportPresentationState` so an older MainActor Task
  /// cannot deliver a superseded transitioning flag after the animator has
  /// already settled (see the delivery note on that method).
  private var presentationReportGeneration: UInt64 = 0

  override var shouldAutomaticallyForwardAppearanceMethods: Bool { false }

  init(
    root: Root,
    model: AppModel,
    navigator: DestinationNavigator,
    navigationCoordinator: DashNavigationCoordinator?,
    anchorRegistry: DashNavigationAnchorRegistry?,
    presentationState: DashWorkspacePresentationState?,
    isTabActive: Bool,
    canPresentPendingHomeAction: Bool,
    splashLifted: Bool,
    workspaceWashScroll: DashWorkspaceWashScroll?,
    locale: Locale,
    dynamicTypeSize: DynamicTypeSize,
    accountID: String?,
    onPresentationStateChange: @escaping (DashPagePresentationState) -> Void
  ) {
    let contentBox = DashRootContentBox(content: root)
    let hostContext = DashPageHostContext(
      isTabActive: isTabActive,
      canPresentPendingHomeAction: canPresentPendingHomeAction,
      splashLifted: splashLifted,
      workspaceWashScroll: workspaceWashScroll,
      locale: locale,
      dynamicTypeSize: dynamicTypeSize)
    self.contentBox = contentBox
    self.hostContext = hostContext
    self.model = model
    self.navigator = navigator
    self.navigationCoordinator = navigationCoordinator
    self.anchorRegistry = anchorRegistry
    self.presentationState = presentationState
    self.accountID = accountID
    self.onPresentationStateChange = onPresentationStateChange
    self.rootController = UIHostingController(
      rootView: DashHostedRoot(
        contentBox: contentBox,
        model: model,
        navigator: navigator,
        navigationCoordinator: navigationCoordinator,
        anchorRegistry: anchorRegistry,
        presentationState: presentationState,
        hostContext: hostContext))
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
    view.isOpaque = false
    view.clipsToBounds = true
    destinationCanvasPlate.frame = view.bounds
    destinationCanvasPlate.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    destinationCanvasPlate.backgroundColor = UIColor(DashTheme.canvas)
    destinationCanvasPlate.isOpaque = true
    destinationCanvasPlate.isUserInteractionEnabled = false
    destinationCanvasPlate.isAccessibilityElement = false
    destinationCanvasPlate.accessibilityElementsHidden = true
    destinationCanvasPlate.alpha = 0
    destinationCanvasPlate.isHidden = true
    view.addSubview(destinationCanvasPlate)
    rootController.view.backgroundColor = .clear
    attach(rootController, above: nil)
    visibleController = rootController
    reportPresentationState()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    for child in children {
      DashContainmentLayout.fill(child.view, in: view.bounds)
    }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    finishParentChildAppearanceTransition()
    parentAppearanceIsDisappearing = false
    if let visibleController {
      visibleController.beginAppearanceTransition(true, animated: animated)
      parentAppearanceTransitionChild = visibleController
    }
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    finishParentChildAppearanceTransition()
    isContainerVisible = true
    reconcilePendingRequestIfNeeded()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    finishParentChildAppearanceTransition()
    isContainerVisible = false
    parentAppearanceIsDisappearing = true
    finishActiveTransitionImmediately()
    if let visibleController {
      visibleController.beginAppearanceTransition(false, animated: animated)
      parentAppearanceTransitionChild = visibleController
    }
  }

  override func viewDidDisappear(_ animated: Bool) {
    finishParentChildAppearanceTransition()
    parentAppearanceIsDisappearing = false
    super.viewDidDisappear(animated)
    reconcilePendingRequestIfNeeded()
  }

  func update(
    isTabActive: Bool,
    canPresentPendingHomeAction: Bool,
    splashLifted: Bool,
    workspaceWashScroll: DashWorkspaceWashScroll?,
    locale: Locale,
    dynamicTypeSize: DynamicTypeSize,
    onPresentationStateChange: @escaping (DashPagePresentationState) -> Void,
    request: DashPageStackRequest
  ) {
    self.onPresentationStateChange = onPresentationStateChange
    hostContext.update(
      isTabActive: isTabActive,
      canPresentPendingHomeAction: canPresentPendingHomeAction,
      splashLifted: splashLifted,
      workspaceWashScroll: workspaceWashScroll,
      locale: locale,
      dynamicTypeSize: dynamicTypeSize)
    loadViewIfNeeded()
    // SwiftUI's outer accessibility modifiers do not reliably penetrate a
    // UIViewControllerRepresentable that keeps multiple child controllers
    // cached. Enforce tab ownership at the UIKit boundary so an invisible
    // sibling can never pollute VoiceOver/XCUI visible-point resolution.
    view.isUserInteractionEnabled = isTabActive
    view.accessibilityElementsHidden = !isTabActive
    reconcile(request)
  }

  private func reportPresentationState() {
    let state = DashPagePresentationState(
      settledDepth: settledEntries.count,
      isTransitioning: activeTransition != nil)
    if lastDeliveredPresentationState == state,
      pendingPresentationReport == nil
    {
      return
    }
    // Generation-token delivery: coalescing on value equality used to cancel
    // an in-flight "transitioning" report when a fast reverse returned to the
    // pre-push state, or drop the settling "false" when a newer same-shaped
    // report replaced `pendingPresentationReport` before the Task ran — either
    // way SwiftUI could keep `isTransitioning == true` after the animator had
    // already finished, which permanently hit-muted the shared header.
    presentationReportGeneration &+= 1
    let generation = presentationReportGeneration
    pendingPresentationReport = state
    // Reconciliation runs from updateUIViewController. Publish on the next
    // MainActor turn so SwiftUI never receives a state mutation mid-update.
    Task { @MainActor [weak self] in
      guard let self, self.presentationReportGeneration == generation else { return }
      self.pendingPresentationReport = nil
      self.lastDeliveredPresentationState = state
      self.onPresentationStateChange(state)
    }
  }

  private func reconcile(_ request: DashPageStackRequest) {
    let newestKnownRevision = max(
      settledRevision,
      max(activeTransition?.revision ?? 0, pendingRequest?.revision ?? 0))
    guard request.revision >= newestKnownRevision else { return }

    if parentAppearanceTransitionChild != nil {
      storePendingRequest(request)
      return
    }

    if request.accountID != accountID {
      accountID = request.accountID
      discardPendingRequest()
      finishActiveTransitionImmediately()
      installImmediately(request.entries, revision: request.revision)
      return
    }

    if reverseActiveTransitionIfPossible(for: request) {
      return
    }

    if activeTransition != nil {
      storePendingRequest(request)
      return
    }

    let desiredIDs = request.entries.map(\.id)
    let settledIDs = settledEntries.map(\.id)
    guard desiredIDs != settledIDs else {
      settledEntries = request.entries
      settledRevision = max(settledRevision, request.revision)
      reportPresentationState()
      return
    }

    guard isContainerVisible, request.isTabActive else {
      installImmediately(request.entries, revision: request.revision)
      return
    }

    switch request.mutation?.reason {
    case .reset, .accountScopeChanged:
      installImmediately(request.entries, revision: request.revision)
      return
    default:
      break
    }

    if let reason = request.mutation?.reason,
      case .resourcePruned = reason
    {
      // The concrete resource value is irrelevant here; a middle prune whose
      // top survives should not animate or disturb the visible page.
      if desiredIDs.last == settledIDs.last {
        settledEntries = request.entries
        settledRevision = request.revision
        purgeEntryHosts(retaining: Set(desiredIDs))
        reportPresentationState()
        return
      }
    }

    guard let source = visibleController else {
      installImmediately(request.entries, revision: request.revision)
      return
    }
    let target = controller(for: request.entries)
    guard source !== target else {
      settledEntries = request.entries
      settledRevision = request.revision
      purgeEntryHosts(retaining: Set(desiredIDs))
      reportPresentationState()
      return
    }

    let style = transitionStyle(for: request)
    performTransition(
      from: source,
      to: target,
      style: style,
      request: request)
  }

  private func transitionStyle(for request: DashPageStackRequest) -> DashPageTransitionStyle {
    switch request.mutation?.reason {
    case .push:
      guard let entry = request.entries.last else { return .flowPush }
      return switch role(for: entry) {
      case .flow: .flowPush
      case .card: .cardPush(entry)
      case .workspace: .workspacePresent(entry)
      }
    case .closeToWorkspaceRoot:
      guard let entry = settledEntries.last else { return .flowPop }
      return .workspaceDismiss(entry)
    case .back, .popToRoot, .resourcePruned:
      guard let entry = request.mutation?.entry ?? settledEntries.last else { return .flowPop }
      return switch role(for: entry) {
      case .flow: .flowPop
      case .card: .cardPop(entry)
      case .workspace: .workspaceDismiss(entry)
      }
    case .reset, .accountScopeChanged, nil:
      return .flowPush
    }
  }

  private func role(for entry: DashNavigationEntry) -> DashPageTransitionRole {
    DashPageTransitionRules.role(
      presentation: entry.presentation,
      hasHero: entry.origin?.hero != nil)
  }

  private func performTransition(
    from source: UIViewController,
    to target: UIViewController,
    style requestedStyle: DashPageTransitionStyle,
    request: DashPageStackRequest
  ) {
    removeLingeringProxyOverlays()
    let targetOwnsDestinationCanvas = !request.entries.isEmpty
    // Settings' vertical train dissolves the wash on the same animator; flow
    // and card still snap the plate up before the first attached frame.
    let fadesCoverWithTransition =
      requestedStyle.role == .workspace && requestedStyle.isPush
    prepareDestinationCanvasTransition(
      targetVisible: targetOwnsDestinationCanvas,
      fadesCoverWithTransition: fadesCoverWithTransition)
    let isPush = requestedStyle.isPush
    hostContext.interactionLockedEntryID = isPush ? request.entries.last?.id : nil

    // A newly attached hosting controller may commit its first SwiftUI frame
    // during containment/layout. Put it in a non-visible push pose before it
    // enters the hierarchy so that frame can never flash above the safe area.
    resetTransitionState(source.view)
    resetTransitionState(target.view)
    if isPush { target.view.alpha = 0 }

    attach(target, above: isPush ? source : nil)
    if !isPush {
      view.insertSubview(target.view, belowSubview: source.view)
    }
    view.layoutIfNeeded()
    let style = resolvedTransitionStyle(
      requestedStyle,
      source: source.view,
      target: target.view)
    source.view.isUserInteractionEnabled = false
    // Keep the hosting view alive for Back/Close, while DashRoutePageChromeHost
    // gates the arriving page body until the transition settles. This makes a
    // deliberate immediate reversal possible without click-through routes.
    target.view.isUserInteractionEnabled = isPush
    if request.reduceMotion || style.entry == nil {
      anchorRegistry?.discardCapturedVisual(for: request.entries.last?.origin)
    }
    let proxy =
      request.reduceMotion
      ? nil
      : makeTransitionProxy(
        style: style,
        source: source.view,
        target: target.view)
    applyInitialTransitionState(
      style: style,
      source: source.view,
      target: target.view,
      reduceMotion: request.reduceMotion)

    let appearanceWasBegun = isContainerVisible && !parentAppearanceIsDisappearing
    if appearanceWasBegun {
      source.beginAppearanceTransition(false, animated: true)
      target.beginAppearanceTransition(true, animated: true)
    }

    var duration =
      request.reduceMotion
      ? DashTheme.Motion.Page.reducedDuration
      : style.duration
    // A card flight paces itself to the ground it covers; see the rule.
    if !request.reduceMotion, let proxy, proxy.isCardMorph,
      let start = proxy.morphStartFrame, let landing = proxy.morphTargetFrame
    {
      duration = DashCardMorphRules.flightDuration(
        base: duration,
        from: start,
        to: landing)
    }
    let animator = UIViewPropertyAnimator(
      duration: duration,
      dampingRatio: request.reduceMotion ? 1 : style.dampingRatio)
    animator.scrubsLinearly = false
    animator.addAnimations { [weak self, weak source, weak target] in
      guard let self, let source, let target else { return }
      self.destinationCanvasPlate.alpha = targetOwnsDestinationCanvas ? 1 : 0
      self.applyFinalTransitionState(
        style: style,
        source: source.view,
        target: target.view,
        proxy: proxy,
        reduceMotion: request.reduceMotion)
    }
    activeTransition = ActiveTransition(
      animator: animator,
      source: source,
      target: target,
      style: style,
      proxy: proxy,
      desiredEntries: request.entries,
      revision: request.revision,
      appearanceWasBegun: appearanceWasBegun)
    reportPresentationState()
    startTransitionContentTimelineIfNeeded()
    animator.addCompletion { [weak self, weak animator] position in
      guard let self, let animator,
        self.activeTransition?.animator === animator
      else { return }
      self.completeActiveTransition(at: position)
    }
    animator.startAnimation()
  }

  private func applyInitialTransitionState(
    style: DashPageTransitionStyle,
    source: UIView,
    target: UIView,
    reduceMotion: Bool
  ) {
    let rightToLeft = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
    switch style {
    case .flowPush, .flowPop, .cardFallbackPush, .cardFallbackPop:
      applyTabStepInitial(
        isPush: style.isPush,
        source: source,
        target: target,
        rightToLeft: rightToLeft,
        reduceMotion: reduceMotion)
    case .cardPush:
      target.alpha = 0
    case .cardPop:
      // Root already sits behind the detail. The display-link timeline fades
      // only the detail page, so neither page acquires spatial travel.
      target.alpha = 1
    case .workspacePresent:
      // Vertical train: the workspace descends off the bottom while settings
      // rides in from above, edge to edge in the same animator, so the two
      // pages read as one connected surface.
      if reduceMotion {
        target.alpha = 0
      } else {
        target.alpha = 1
        target.transform = CGAffineTransform(translationX: 0, y: -view.bounds.height)
      }
    case .workspaceDismiss:
      if reduceMotion {
        target.alpha = 0
      } else {
        target.alpha = 1
        target.transform = CGAffineTransform(translationX: 0, y: view.bounds.height)
      }
    }
    if source.alpha != 0 { source.alpha = 1 }
  }

  /// Flow pages use the same short directional handoff as tab changes. Card
  /// pushes stay stationary and keep their independent semantic hero timeline.
  private func applyTabStepInitial(
    isPush: Bool,
    source: UIView,
    target: UIView,
    rightToLeft: Bool,
    reduceMotion: Bool
  ) {
    let direction = DashTabTransitionRules.pageStepDirection(isPush: isPush)
    let travel = DashTabTransitionRules.signedTravel(
      for: direction,
      rightToLeft: rightToLeft,
      reduceMotion: reduceMotion)
    source.alpha = 1
    source.transform = .identity
    target.alpha = 0
    target.transform =
      reduceMotion ? .identity : CGAffineTransform(translationX: travel, y: 0)
  }

  private func applyTabStepFinal(
    isPush: Bool,
    source: UIView,
    target: UIView,
    rightToLeft: Bool,
    reduceMotion: Bool
  ) {
    let direction = DashTabTransitionRules.pageStepDirection(isPush: isPush)
    let outgoingTravel = DashTabTransitionRules.outgoingEndOffset(
      for: direction,
      rightToLeft: rightToLeft,
      reduceMotion: reduceMotion)
    target.alpha = 1
    target.transform = .identity
    source.alpha = 0
    source.transform =
      reduceMotion ? .identity : CGAffineTransform(translationX: outgoingTravel, y: 0)
  }

  private func applyFinalTransitionState(
    style: DashPageTransitionStyle,
    source: UIView,
    target: UIView,
    proxy: TransitionProxy?,
    reduceMotion: Bool
  ) {
    let rightToLeft = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
    switch style {
    case .flowPush, .flowPop, .cardFallbackPush, .cardFallbackPop:
      applyTabStepFinal(
        isPush: style.isPush,
        source: source,
        target: target,
        rightToLeft: rightToLeft,
        reduceMotion: reduceMotion)
    case .cardPush, .cardPop:
      if let proxy {
        // The card timeline rides POSITION, not opacity: a slightly
        // underdamped enter spring overshoots its end value, and a layer's
        // presentation opacity clamps at 1 — sampling it would flatten the
        // bounce into a dead stop at the seat. Position reports the raw
        // spring, so progress can pass 1 and come back.
        proxy.timelineDriver?.center = CGPoint(
          x: DashCardMorphRules.timelineTravel,
          y: 0)
      } else {
        // Reduce Motion and invalid-endpoint fallback keep a short crossfade.
        target.alpha = 1
        source.alpha = 0
      }
    case .workspacePresent:
      target.alpha = 1
      target.transform = .identity
      if !reduceMotion {
        source.transform = CGAffineTransform(translationX: 0, y: view.bounds.height)
      }
      // Morph frames are driven by the display-link timeline so they can track
      // the seat through the page train. Alphas still settle here so a morph
      // and the in-place identity crossfade share one fade curve.
      proxy?.outgoingContent?.alpha = 0
      proxy?.arrivingContent?.alpha = 1
    case .workspaceDismiss:
      target.alpha = 1
      target.transform = .identity
      if reduceMotion {
        source.alpha = 0
      } else {
        source.transform = CGAffineTransform(translationX: 0, y: -view.bounds.height)
      }
      proxy?.outgoingContent?.alpha = 0
      proxy?.arrivingContent?.alpha = 1
    }
  }

  /// The semantic card is laid out at every intermediate size. Updating bounds
  /// and center preserves the SwiftUI hierarchy's typography and avatar shape;
  /// no bitmap is ever non-uniformly scaled between the two aspect ratios.
  private func applyCardHeroFrame(_ proxy: TransitionProxy, at frame: CGRect) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for hero in [proxy.outgoingContent, proxy.arrivingContent] {
      guard let hero else { continue }
      hero.bounds = CGRect(origin: .zero, size: frame.size)
      hero.center = CGPoint(x: frame.midX, y: frame.midY)
      hero.setNeedsLayout()
      hero.layoutIfNeeded()
    }
    CATransaction.commit()
  }

  private func updateCardHeroContent(
    _ proxy: TransitionProxy,
    detailProgress: CGFloat
  ) {
    guard let controller = proxy.heroController else { return }
    let root = controller.rootView
    controller.rootView = DashNavigationHeroView(
      hero: root.hero,
      detailProgress: detailProgress,
      locale: root.locale,
      dynamicTypeSize: root.dynamicTypeSize)
  }

  /// A push immediately followed by its own Back/Close is the one retarget that
  /// must feel direct. `UIViewPropertyAnimator` reverses from its presentation
  /// value, so there is no jump back to either endpoint before the page returns.
  private func reverseActiveTransitionIfPossible(
    for request: DashPageStackRequest
  ) -> Bool {
    guard let transition = activeTransition, transition.style.isPush,
      request.entries.map(\.id) == settledEntries.map(\.id)
    else { return false }
    switch request.mutation?.reason {
    case .back, .closeToWorkspaceRoot, .popToRoot:
      break
    default:
      return false
    }
    guard transition.animator.state == .active, !transition.isReversed else {
      return false
    }

    discardPendingRequest()
    transition.desiredEntries = request.entries
    transition.revision = request.revision
    transition.isReversed = true
    transition.target.view.isUserInteractionEnabled = false
    transition.source.view.isUserInteractionEnabled = false

    if transition.appearanceWasBegun {
      // UIKit treats an opposite begin as cancellation of the in-flight
      // appearance. One final end per child then settles source as appeared
      // and target as disappeared, without a false didDisappear/didAppear pair.
      transition.source.beginAppearanceTransition(true, animated: true)
      transition.target.beginAppearanceTransition(false, animated: true)
    }
    transition.animator.isReversed = true
    return true
  }

  private func makeTransitionProxy(
    style: DashPageTransitionStyle,
    source: UIView,
    target: UIView
  ) -> TransitionProxy? {
    let requiresLiveFrame: Bool
    if case .cardPop = style {
      requiresLiveFrame = true
    } else {
      requiresLiveFrame = false
    }
    guard let entry = style.entry,
      let sourceFrame = transitionFrame(for: entry.origin, liveOnly: requiresLiveFrame)
    else { return nil }

    let overlay = UIView(frame: view.bounds)
    overlay.backgroundColor = .clear
    overlay.isOpaque = false
    overlay.isUserInteractionEnabled = false
    overlay.isAccessibilityElement = false
    overlay.accessibilityElementsHidden = true
    overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]

    var shell: UIView?
    var backgroundEffect: UIView?
    var outgoingContent: UIView?
    var arrivingContent: UIView?
    var heroController: UIHostingController<DashNavigationHeroView>?
    var timelineDriver: UIView?
    var claimedOrigin: DashNavigationOrigin?
    var claimedLanding: DashNavigationOrigin?
    var morphTargetFrame: CGRect?
    var morphStartFrame: CGRect?

    switch style {
    case .cardPush, .cardPop:
      guard let hero = entry.origin?.hero else { return nil }
      let landingPage = style.isPush ? target : source
      guard let landing = resolvedLandingOrigin(for: entry, in: landingPage),
        let landingFrame = anchorFrameInContainer(for: landing, liveOnly: true)
      else { return nil }

      let liveHero = makeNavigationHeroController(
        hero,
        detailProgress: style.isPush ? 0 : 1)
      outgoingContent = liveHero.view
      heroController = liveHero
      // Push only. Returning, the veil would have to clear before the sharp
      // list it is covering *is* the destination — the same blink, backwards.
      // The card flies home over a list that was never softened.
      if style.isPush {
        backgroundEffect = makeCardMorphBackgroundEffect()
      }
      morphStartFrame = sourceFrame
      morphTargetFrame = landingFrame
      claimedOrigin = entry.origin
      claimedLanding = landing
      timelineDriver = makeTransitionTimelineDriver()
      anchorRegistry?.discardCapturedVisual(for: entry.origin)
    case .workspacePresent:
      if let captured = anchorRegistry?.takeCapturedVisual(for: entry.origin) {
        outgoingContent = captured.view
        outgoingContent?.frame =
          frameInContainer(fromWindowFrame: captured.frame) ?? sourceFrame
      } else {
        outgoingContent = snapshotFromWindow(at: sourceFrame)
        outgoingContent?.frame = sourceFrame
      }
      shell = makeIdentityTransitionShell(frame: sourceFrame)
      // The shared header owns the in-place avatar / Close crossfade above this
      // page snapshot. The old avatar flight to a Settings profile-row landing
      // seat is gone — see `DashNavigationSemanticID`.
      // `performTransition` has already attached and laid out the target. An
      // after-screen-updates snapshot here would synchronously ask SwiftUI to
      // update it again from inside `updateUIViewController`, re-entering the
      // target's AttributeGraph while it is still being evaluated.
      arrivingContent = snapshotRegion(
        from: target,
        at: sourceFrame,
        afterScreenUpdates: false)
      arrivingContent?.alpha = 0
      // The source is captured as a SQUARE window snapshot that carries the
      // canvas behind it, so the crossfade drew it raw over the arriving page
      // — a warm square with hard corners around a round control. The shell
      // already commits to the source's circle; its content has to agree.
      configureMorphFlightLayer(outgoingContent, departingFrom: sourceFrame)
      configureMorphFlightLayer(arrivingContent, departingFrom: sourceFrame)
      claimedOrigin = entry.origin
    case .workspaceDismiss:
      // The mirror of present: an in-place crossfade in the header slot, no
      // flight home.
      outgoingContent = snapshotRegion(
        from: source,
        at: sourceFrame,
        afterScreenUpdates: false)
      arrivingContent = snapshotRegion(
        from: target,
        at: sourceFrame,
        afterScreenUpdates: false)
      arrivingContent?.alpha = 0
      shell = makeIdentityTransitionShell(frame: sourceFrame)
      // Same reason as present: square snapshots of a round control must wear
      // the shell's circle.
      configureMorphFlightLayer(outgoingContent, departingFrom: sourceFrame)
      configureMorphFlightLayer(arrivingContent, departingFrom: sourceFrame)
      claimedOrigin = entry.origin
    case .flowPush, .flowPop, .cardFallbackPush, .cardFallbackPop:
      return nil
    }

    guard shell != nil || outgoingContent != nil || arrivingContent != nil else {
      return nil
    }
    // Between the pages, not in the proxy overlay above them: the veil has to
    // be something the arriving page can cover, or it can only leave by fading
    // in full view. Every teardown path removes it from its own superview.
    if let backgroundEffect {
      view.insertSubview(backgroundEffect, belowSubview: target)
    }
    if let shell { overlay.addSubview(shell) }
    if let outgoingContent {
      if heroController == nil {
        configureTransitionSnapshot(outgoingContent)
      } else {
        configureNavigationHeroLayer(outgoingContent)
      }
      overlay.addSubview(outgoingContent)
    }
    if let arrivingContent {
      if heroController == nil {
        configureTransitionSnapshot(arrivingContent)
      } else {
        configureNavigationHeroLayer(arrivingContent)
      }
      overlay.addSubview(arrivingContent)
    }
    if let timelineDriver { overlay.addSubview(timelineDriver) }
    view.addSubview(overlay)
    anchorRegistry?.claim(claimedOrigin)
    anchorRegistry?.claim(claimedLanding)
    return TransitionProxy(
      overlay: overlay,
      shell: shell,
      backgroundEffect: backgroundEffect,
      outgoingContent: outgoingContent,
      arrivingContent: arrivingContent,
      heroController: heroController,
      timelineDriver: timelineDriver,
      claimedOrigin: claimedOrigin,
      claimedLanding: claimedLanding,
      morphTargetFrame: morphTargetFrame,
      morphStartFrame: morphStartFrame)
  }

  /// A flight layer travels over both moving pages, so its baked-in corner
  /// pixels no longer match what is behind it; clipping every layer to the
  /// avatar's own circle keeps the trip clean end to end.
  private func configureMorphFlightLayer(
    _ layerView: UIView?,
    departingFrom frame: CGRect
  ) {
    guard let layerView else { return }
    layerView.frame = frame
    layerView.layer.cornerRadius = min(frame.width, frame.height) / 2
    layerView.layer.masksToBounds = true
  }

  private func makeNavigationHeroController(
    _ hero: DashNavigationHero,
    detailProgress: CGFloat
  ) -> UIHostingController<DashNavigationHeroView> {
    let controller = UIHostingController(
      rootView: DashNavigationHeroView(
        hero: hero,
        detailProgress: detailProgress,
        locale: hostContext.locale,
        dynamicTypeSize: hostContext.dynamicTypeSize))
    controller.loadViewIfNeeded()
    controller.view.backgroundColor = .clear
    controller.view.isOpaque = false
    return controller
  }

  private func configureNavigationHeroLayer(_ hero: UIView) {
    hero.backgroundColor = .clear
    hero.isOpaque = false
    hero.isAccessibilityElement = false
    hero.accessibilityElementsHidden = true
    hero.isUserInteractionEnabled = false
    hero.clipsToBounds = false
    hero.layer.masksToBounds = false
  }

  private func makeCardMorphBackgroundEffect() -> UIView {
    let background: UIView
    if UIAccessibility.isReduceTransparencyEnabled {
      let veil = UIView()
      veil.backgroundColor = UIColor(DashTheme.canvas).resolvedColor(
        with: traitCollection
      ).withAlphaComponent(0.9)
      background = veil
    } else {
      let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
      blur.backgroundColor = UIColor(DashTheme.canvas).resolvedColor(
        with: traitCollection
      ).withAlphaComponent(0.12)
      background = blur
    }
    background.frame = view.bounds
    background.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    background.alpha = 0
    background.isUserInteractionEnabled = false
    background.isAccessibilityElement = false
    background.accessibilityElementsHidden = true
    return background
  }

  /// The landing seat the entry's destination publishes, if any. Resolved per
  /// transition because every page instance registers its own occurrence.
  private func landingOrigin(for entry: DashNavigationEntry) -> DashNavigationOrigin? {
    guard let semanticID = entry.destination.dashNavigationLandingSemanticID else {
      return nil
    }
    return anchorRegistry?.landingOrigin(for: semanticID)
  }

  /// Freshly attached SwiftUI pages sometimes register their landing probe one
  /// layout pass late. One synchronous retry covers the settings avatar seat
  /// without waiting a runloop, which would let the page train start unmorphed.
  private func resolvedLandingOrigin(
    for entry: DashNavigationEntry,
    in page: UIView
  ) -> DashNavigationOrigin? {
    if let landing = landingOrigin(for: entry),
      anchorFrameInContainer(for: landing, liveOnly: true) != nil
    {
      return landing
    }
    page.setNeedsLayout()
    page.layoutIfNeeded()
    return landingOrigin(for: entry)
  }

  /// Container-space frame for a morph endpoint. Unlike `transitionFrame`, this
  /// keeps off-screen seats — the settings avatar starts above the canvas on
  /// present and leaves above it on dismiss, and the flight still needs them.
  private func anchorFrameInContainer(
    for origin: DashNavigationOrigin?,
    liveOnly: Bool = false
  ) -> CGRect? {
    guard let origin,
      let globalFrame = liveOnly
        ? anchorRegistry?.liveFrame(for: origin)
        : anchorRegistry?.frame(for: origin),
      globalFrame.width.isFinite, globalFrame.height.isFinite,
      globalFrame.minX.isFinite, globalFrame.minY.isFinite
    else { return nil }
    let localFrame = view.convert(globalFrame, from: nil)
    guard localFrame.width > 2, localFrame.height > 2 else { return nil }
    return localFrame
  }

  private func resolvedTransitionStyle(
    _ style: DashPageTransitionStyle,
    source: UIView,
    target: UIView
  ) -> DashPageTransitionStyle {
    switch style {
    case .cardPush(let entry), .cardPop(let entry):
      let isPush = style.isPush
      let landingPage = isPush ? target : source
      // A pop flies home to wherever the source occurrence lives NOW. The list
      // under the detail can have re-sorted (pinning the domain from its own
      // screen), leaving the captured instance parked on a slot that paints a
      // different resource — retarget by semantic identity, and let claims,
      // endpoint frames, and the per-frame seat tracking all follow the entry.
      // Email Routing settings can change while its detail is open. Resolve
      // that cache before looking for a live source: an explicitly off domain
      // has no card in the filtered catalog, so its pop must use flow. A still-
      // configured card carries the latest status/name into relocation and the
      // flight proxy from this single resolved entry.
      let cacheResolvedEntry: DashNavigationEntry
      if !isPush, let origin = entry.origin, let capturedHero = origin.hero {
        let resolution = capturedHero.returnCacheResolution(from: model.featureCache)
        guard let resolvedHero = resolution.resolvedHero(preserving: capturedHero) else {
          return .cardFallbackPop
        }
        cacheResolvedEntry = DashNavigationEntry(
          id: entry.id,
          destination: entry.destination,
          presentation: entry.presentation,
          origin: DashNavigationOrigin(
            semanticID: origin.semanticID,
            anchorInstanceID: origin.anchorInstanceID,
            sourceFrame: origin.sourceFrame,
            hero: resolvedHero),
          accountID: entry.accountID,
          ownership: entry.ownership)
      } else {
        cacheResolvedEntry = entry
      }

      let resolvedEntry: DashNavigationEntry?
      if isPush {
        resolvedEntry = cacheResolvedEntry
      } else if let origin = cacheResolvedEntry.origin,
        let current = anchorRegistry?.currentSourceOrigin(for: origin, within: target)
      {
        resolvedEntry =
          current == origin
          ? cacheResolvedEntry
          : DashNavigationEntry(
            id: cacheResolvedEntry.id,
            destination: cacheResolvedEntry.destination,
            presentation: cacheResolvedEntry.presentation,
            origin: current,
            accountID: cacheResolvedEntry.accountID,
            ownership: cacheResolvedEntry.ownership)
      } else {
        resolvedEntry = nil
      }
      guard let resolvedEntry,
        resolvedEntry.origin?.hero != nil,
        let sourceFrame = transitionFrame(for: resolvedEntry.origin, liveOnly: !isPush),
        let landing = resolvedLandingOrigin(for: resolvedEntry, in: landingPage),
        let landingFrame = anchorFrameInContainer(for: landing, liveOnly: true),
        DashCardMorphRules.isUsableEndpoint(sourceFrame, in: view.bounds),
        DashCardMorphRules.isUsableEndpoint(landingFrame, in: view.bounds)
      else {
        // No usable pair of seats: fall back to the same handoff every other
        // drill uses rather than inventing a third language for the failure.
        return isPush ? .cardFallbackPush : .cardFallbackPop
      }
      return isPush ? .cardPush(resolvedEntry) : .cardPop(resolvedEntry)
    default:
      return style
    }
  }

  private func transitionFrame(
    for origin: DashNavigationOrigin?,
    liveOnly: Bool = false
  ) -> CGRect? {
    guard let origin,
      let globalFrame = liveOnly
        ? anchorRegistry?.liveFrame(for: origin)
        : anchorRegistry?.frame(for: origin),
      globalFrame.width.isFinite, globalFrame.height.isFinite,
      globalFrame.minX.isFinite, globalFrame.minY.isFinite
    else { return nil }
    let localFrame = view.convert(globalFrame, from: nil)
    guard localFrame.width > 2, localFrame.height > 2,
      localFrame.intersects(view.bounds.insetBy(dx: -2, dy: -2))
    else { return nil }
    return localFrame
  }

  private func makeTransitionTimelineDriver() -> UIView {
    let driver = UIView(frame: .zero)
    driver.alpha = 0
    driver.isUserInteractionEnabled = false
    return driver
  }

  private func makeIdentityTransitionShell(frame: CGRect) -> UIView {
    let shell = UIView(frame: frame)
    shell.backgroundColor = UIColor(DashTheme.canvas).resolvedColor(with: traitCollection)
    shell.isOpaque = true
    shell.isUserInteractionEnabled = false
    shell.clipsToBounds = true
    shell.layer.cornerCurve = .continuous
    shell.layer.cornerRadius = min(frame.width, frame.height) / 2
    return shell
  }

  private func configureTransitionSnapshot(_ snapshot: UIView) {
    snapshot.isAccessibilityElement = false
    snapshot.accessibilityElementsHidden = true
    snapshot.isUserInteractionEnabled = false
    snapshot.clipsToBounds = true
    snapshot.layer.cornerCurve = .continuous
  }

  private func frameInContainer(fromWindowFrame frame: CGRect) -> CGRect? {
    guard let window = view.window else { return nil }
    return view.convert(frame, from: window)
  }

  private func snapshotFromWindow(at localFrame: CGRect) -> UIView? {
    guard let window = view.window else { return nil }
    let windowFrame = window.convert(localFrame, from: view)
    return window.resizableSnapshotView(
      from: windowFrame,
      afterScreenUpdates: false,
      withCapInsets: .zero)
  }

  private func snapshotRegion(
    from source: UIView,
    at containerFrame: CGRect,
    afterScreenUpdates: Bool
  ) -> UIView? {
    let sourceRect = source.convert(containerFrame, from: view)
      .intersection(source.bounds)
    guard !sourceRect.isNull, sourceRect.width > 2, sourceRect.height > 2 else {
      return nil
    }
    let snapshot = source.resizableSnapshotView(
      from: sourceRect,
      afterScreenUpdates: afterScreenUpdates,
      withCapInsets: .zero)
    snapshot?.frame = view.convert(sourceRect, from: source)
    return snapshot
  }

  /// A freshly reattached SwiftUI hierarchy may not have committed every text
  /// layer to the render server yet. `resizableSnapshotView` can therefore
  /// return the row background and image while omitting its labels. Drawing the
  /// already-laid-out target hierarchy into one immutable raster keeps the
  /// source row atomic during the return handoff.
  private func rasterSnapshotRegion(
    from source: UIView,
    at containerFrame: CGRect,
    afterScreenUpdates: Bool
  ) -> UIView? {
    let sourceRect = source.convert(containerFrame, from: view)
      .intersection(source.bounds)
    guard !sourceRect.isNull, sourceRect.width > 2, sourceRect.height > 2 else {
      return nil
    }

    let format = UIGraphicsImageRendererFormat()
    format.scale = view.window?.screen.scale ?? traitCollection.displayScale
    format.opaque = false
    let renderer = UIGraphicsImageRenderer(size: sourceRect.size, format: format)
    let image = renderer.image { context in
      context.cgContext.translateBy(x: -sourceRect.minX, y: -sourceRect.minY)
      if !source.drawHierarchy(
        in: source.bounds,
        afterScreenUpdates: afterScreenUpdates)
      {
        source.layer.render(in: context.cgContext)
      }
    }
    let snapshot = UIImageView(image: image)
    snapshot.contentMode = .scaleToFill
    snapshot.frame = view.convert(sourceRect, from: source)
    return snapshot
  }

  private func completeReversedTransition(_ transition: ActiveTransition) {
    hostContext.interactionLockedEntryID = nil
    resetTransitionState(transition.source.view)
    transition.source.view.isUserInteractionEnabled = true
    transition.target.view.isUserInteractionEnabled = true
    if transition.appearanceWasBegun {
      transition.source.endAppearanceTransition()
      transition.target.endAppearanceTransition()
    }
    // Keep the losing page at its animated endpoint until it is out of the
    // hierarchy. Restoring alpha first can briefly put two complete pages
    // behind a nearly transparent proxy at the completion boundary.
    detach(transition.target)
    resetTransitionState(transition.target.view)
    releaseAndRemoveAfterHandoff(transition.proxy)
    visibleController = transition.source
    settledEntries = transition.desiredEntries
    settledRevision = transition.revision
    activeTransition = nil
    purgeEntryHosts(retaining: Set(settledEntries.map(\.id)))
    setDestinationCanvasVisible(!settledEntries.isEmpty)
    reportPresentationState()
    if isContainerVisible, hostContext.isTabActive {
      UIAccessibility.post(notification: .screenChanged, argument: transition.source.view)
    }
    if let pendingRequest = takePendingRequest() {
      reconcile(pendingRequest)
    }
  }

  private func completeActiveTransition(at position: UIViewAnimatingPosition) {
    guard let transition = activeTransition else { return }
    stopTransitionContentTimeline(
      settlingAt: transition.isReversed || position == .start ? 0 : 1)
    if transition.isReversed || position == .start {
      completeReversedTransition(transition)
      return
    }
    hostContext.interactionLockedEntryID = nil
    resetTransitionState(transition.target.view)
    transition.source.view.isUserInteractionEnabled = true
    transition.target.view.isUserInteractionEnabled = true
    if transition.appearanceWasBegun {
      transition.source.endAppearanceTransition()
      transition.target.endAppearanceTransition()
    }
    detach(transition.source)
    resetTransitionState(transition.source.view)
    releaseAndRemoveAfterHandoff(transition.proxy)
    visibleController = transition.target
    settledEntries = transition.desiredEntries
    settledRevision = transition.revision
    activeTransition = nil
    purgeEntryHosts(retaining: Set(settledEntries.map(\.id)))
    setDestinationCanvasVisible(!settledEntries.isEmpty)
    reportPresentationState()
    let pendingChangesVisiblePage =
      pendingRequest.map {
        $0.entries.last?.id != transition.desiredEntries.last?.id
      } ?? false
    if isContainerVisible, hostContext.isTabActive, !pendingChangesVisiblePage {
      UIAccessibility.post(notification: .screenChanged, argument: transition.target.view)
    }
    if let pendingRequest = takePendingRequest() {
      reconcile(pendingRequest)
    }
  }

  private func finishActiveTransitionImmediately() {
    removeLingeringProxyOverlays()
    guard let transition = activeTransition else { return }
    stopTransitionContentTimeline(settlingAt: transition.isReversed ? 0 : 1)
    hostContext.interactionLockedEntryID = nil
    transition.animator.stopAnimation(true)
    let winner = transition.isReversed ? transition.source : transition.target
    let loser = transition.isReversed ? transition.target : transition.source
    resetTransitionState(winner.view)
    transition.source.view.isUserInteractionEnabled = true
    transition.target.view.isUserInteractionEnabled = true
    if transition.appearanceWasBegun {
      transition.source.endAppearanceTransition()
      transition.target.endAppearanceTransition()
    }
    detach(loser)
    resetTransitionState(loser.view)
    visibleController = winner
    releaseAndRemove(transition.proxy)
    settledEntries = transition.desiredEntries
    settledRevision = transition.revision
    activeTransition = nil
    purgeEntryHosts(retaining: Set(settledEntries.map(\.id)))
    setDestinationCanvasVisible(!settledEntries.isEmpty)
    reportPresentationState()
  }

  private func finishParentChildAppearanceTransition() {
    parentAppearanceTransitionChild?.endAppearanceTransition()
    parentAppearanceTransitionChild = nil
  }

  private func reconcilePendingRequestIfNeeded() {
    guard let pendingRequest = takePendingRequest() else { return }
    reconcile(pendingRequest)
  }

  private func installImmediately(_ entries: [DashNavigationEntry], revision: UInt64) {
    hostContext.interactionLockedEntryID = nil
    anchorRegistry?.discardCapturedVisual(for: entries.last?.origin)
    finishActiveTransitionImmediately()
    let target = controller(for: entries)
    if visibleController !== target {
      let source = visibleController
      let forwardsAppearance = isContainerVisible && !parentAppearanceIsDisappearing
      attach(target, above: source)
      if forwardsAppearance {
        source?.beginAppearanceTransition(false, animated: false)
        target.beginAppearanceTransition(true, animated: false)
      }
      if forwardsAppearance {
        source?.endAppearanceTransition()
        target.endAppearanceTransition()
      }
      if let source { detach(source) }
      visibleController = target
      if forwardsAppearance, hostContext.isTabActive {
        UIAccessibility.post(notification: .screenChanged, argument: target.view)
      }
    }
    resetTransitionState(target.view)
    target.view.isUserInteractionEnabled = true
    settledEntries = entries
    settledRevision = revision
    purgeEntryHosts(retaining: Set(entries.map(\.id)))
    setDestinationCanvasVisible(!entries.isEmpty)
    reportPresentationState()
  }

  private func setDestinationCanvasVisible(_ visible: Bool) {
    destinationCanvasPlate.layer.removeAllAnimations()
    destinationCanvasPlate.alpha = visible ? 1 : 0
    destinationCanvasPlate.isHidden = !visible
  }

  private func prepareDestinationCanvasTransition(
    targetVisible: Bool,
    fadesCoverWithTransition: Bool
  ) {
    let sourceVisible = !settledEntries.isEmpty
    let preparation = DashDestinationCanvasRules.preparation(
      sourceShowsDestinationCanvas: sourceVisible,
      targetShowsDestinationCanvas: targetVisible,
      fadesCoverWithTransition: fadesCoverWithTransition)
    destinationCanvasPlate.layer.removeAllAnimations()
    destinationCanvasPlate.isHidden = preparation.isHidden
    destinationCanvasPlate.alpha = preparation.alpha
  }

  /// A deferred route may be replaced before its transition starts. Its source
  /// snapshot is registry-owned, so dropping the request must drop that visual
  /// too. The same concrete anchor is exempt because a newer capture replaces
  /// the old value under the same key before this method runs.
  private func storePendingRequest(_ request: DashPageStackRequest) {
    let previousOrigin = pendingRequest?.entries.last?.origin
    let nextOrigin = request.entries.last?.origin
    if previousOrigin?.anchorInstanceID != nextOrigin?.anchorInstanceID {
      anchorRegistry?.discardCapturedVisual(for: previousOrigin)
    }
    pendingRequest = request
  }

  private func discardPendingRequest() {
    anchorRegistry?.discardCapturedVisual(for: pendingRequest?.entries.last?.origin)
    pendingRequest = nil
  }

  /// Taking transfers snapshot ownership to `reconcile`; it must not discard
  /// the visual that the imminent transition is about to consume.
  private func takePendingRequest() -> DashPageStackRequest? {
    let request = pendingRequest
    pendingRequest = nil
    return request
  }

  private func controller(for entries: [DashNavigationEntry]) -> UIViewController {
    guard let entry = entries.last else { return rootController }
    if let cached = entryHosts[entry.id] { return cached.controller }
    let controller = UIHostingController(
      rootView: DashHostedDestination(
        entry: entry,
        model: model,
        navigator: navigator,
        navigationCoordinator: navigationCoordinator,
        anchorRegistry: anchorRegistry,
        presentationState: presentationState,
        hostContext: hostContext))
    // A pushed page owns the whole physical container, including both safe-area
    // bands. UIKit's backing plate closes any gap before SwiftUI's ignored-safe-
    // area background has rendered its first frame.
    controller.view.backgroundColor = UIColor(DashTheme.canvas)
    controller.view.isOpaque = true
    entryHosts[entry.id] = EntryHost(entry: entry, controller: controller)
    return controller
  }

  private func purgeEntryHosts(retaining retainedIDs: Set<DashNavigationEntry.ID>) {
    let removedIDs = entryHosts.keys.filter { !retainedIDs.contains($0) }
    for id in removedIDs {
      if let controller = entryHosts[id]?.controller,
        controller !== visibleController
      {
        detach(controller)
      }
      presentationState?.removePresentationReporters(forEntryID: id)
      entryHosts[id] = nil
    }
  }

  private func attach(_ child: UIViewController, above sibling: UIViewController?) {
    guard child.parent !== self else {
      DashContainmentLayout.fill(child.view, in: view.bounds)
      if let sibling, sibling.view.superview === view {
        view.insertSubview(child.view, aboveSubview: sibling.view)
      } else {
        view.bringSubviewToFront(child.view)
      }
      return
    }
    addChild(child)
    // Bounds/center remain valid while the page owns a transition transform.
    child.view.autoresizingMask = []
    DashContainmentLayout.fill(child.view, in: view.bounds)
    if let sibling, sibling.view.superview === view {
      view.insertSubview(child.view, aboveSubview: sibling.view)
    } else {
      view.addSubview(child.view)
    }
    child.didMove(toParent: self)
  }

  private func detach(_ child: UIViewController) {
    guard child.parent === self else { return }
    child.willMove(toParent: nil)
    child.view.removeFromSuperview()
    child.removeFromParent()
  }

  private func resetTransitionState(_ view: UIView) {
    view.layer.removeAllAnimations()
    view.alpha = 1
    view.transform = .identity
  }

  /// The card morph's only timeline: its hero is re-laid-out per frame between
  /// two live seats. Every other style settles inside the property animator —
  /// workspace routes are a plain crossfade in a fixed slot and need no link.
  private func startTransitionContentTimelineIfNeeded() {
    guard let transition = activeTransition, transition.proxy != nil else { return }
    switch transition.style {
    case .cardPush, .cardPop:
      break
    case .workspacePresent, .workspaceDismiss, .flowPush, .flowPop,
      .cardFallbackPush, .cardFallbackPop:
      return
    }
    stopTransitionContentTimeline()
    updateTransitionContentTimeline(transition, progress: 0)
    let displayLink = CADisplayLink(
      target: self,
      selector: #selector(displayLinkDidRefreshTransitionContent))
    displayLink.add(to: .main, forMode: .common)
    transitionContentDisplayLink = displayLink
  }

  @objc private func displayLinkDidRefreshTransitionContent() {
    guard let transition = activeTransition else {
      stopTransitionContentTimeline()
      return
    }
    let progress: CGFloat
    if transition.proxy?.isCardMorph == true,
      let driver = transition.proxy?.timelineDriver,
      let presentation = driver.layer.presentation()
    {
      // Deliberately unclamped: the enter spring's overshoot past 1 IS the
      // bounce, and only the hero frame consumes it — every opacity curve
      // clamps internally.
      progress = presentation.position.x / DashCardMorphRules.timelineTravel
    } else {
      progress = CGFloat(transition.animator.fractionComplete)
    }
    updateTransitionContentTimeline(transition, progress: progress)
  }

  private func updateTransitionContentTimeline(
    _ transition: ActiveTransition,
    progress rawProgress: CGFloat
  ) {
    guard let proxy = transition.proxy else { return }
    let progress = min(max(rawProgress, 0), 1)
    UIView.performWithoutAnimation {
      switch transition.style {
      case .cardPush, .cardPop:
        // Push keeps the raw value so the enter spring's overshoot reaches the
        // hero frame. Pop is critically damped and reads the clamped copy —
        // a collapse must never extrapolate ahead of the seat it returns to.
        let detailProgress =
          transition.style.isPush ? max(rawProgress, 0) : 1 - progress
        if transition.style.isPush {
          transition.source.view.alpha = 1
          transition.target.view.alpha =
            DashCardMorphRules.detailPageOpacity(at: detailProgress)
        } else {
          transition.source.view.alpha =
            DashCardMorphRules.departingDetailPageOpacity(at: detailProgress)
          transition.target.view.alpha = 1
        }
        proxy.backgroundEffect?.alpha =
          DashCardMorphRules.backdropOpacity(at: detailProgress)
        updateCardHeroContent(proxy, detailProgress: detailProgress)
        proxy.outgoingContent?.alpha = 1
        // SwiftUI can finish propagating the destination's safe-area inset one
        // layout pass after the controller is attached. Track both concrete
        // seats while they are live instead of freezing that provisional first
        // frame and jumping when the proxy hands back to the real card.
        if let sourceFrame = transitionFrame(
          for: proxy.claimedOrigin,
          liveOnly: true) ?? proxy.morphStartFrame,
          let landingFrame = anchorFrameInContainer(
            for: proxy.claimedLanding,
            liveOnly: true) ?? proxy.morphTargetFrame
        {
          applyCardHeroFrame(
            proxy,
            at: DashCardMorphRules.heroFrame(
              from: sourceFrame,
              to: landingFrame,
              detailProgress: detailProgress))
        }
      case .workspacePresent, .workspaceDismiss, .flowPush, .flowPop,
        .cardFallbackPush, .cardFallbackPop:
        break
      }
    }
  }

  private func stopTransitionContentTimeline(settlingAt progress: CGFloat? = nil) {
    if let progress, let transition = activeTransition {
      updateTransitionContentTimeline(transition, progress: progress)
    }
    transitionContentDisplayLink?.invalidate()
    transitionContentDisplayLink = nil
  }

  private func releaseAndRemove(_ proxy: TransitionProxy?) {
    guard let proxy else { return }
    anchorRegistry?.release(proxy.claimedOrigin)
    anchorRegistry?.release(proxy.claimedLanding)
    proxy.backgroundEffect?.removeFromSuperview()
    proxy.overlay.removeFromSuperview()
  }

  /// Completion variant for landed morph flights. Claims are released now so
  /// the live element re-renders beneath the pixel-matching proxy, but the
  /// overlay leaves only after that reveal has had a SwiftUI commit — the
  /// header avatar additionally waits on the asynchronous presentation-state
  /// publish. Removing it in the same runloop blinks the element the eye just
  /// tracked to its seat.
  private func releaseAndRemoveAfterHandoff(_ proxy: TransitionProxy?) {
    guard let proxy else { return }
    guard proxy.morphTargetFrame != nil else {
      releaseAndRemove(proxy)
      return
    }
    anchorRegistry?.release(proxy.claimedOrigin)
    anchorRegistry?.release(proxy.claimedLanding)
    proxy.backgroundEffect?.removeFromSuperview()
    lingeringProxies.append(proxy)
    let handoffDelay: Int64 = proxy.isCardMorph ? 100 : 140
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(handoffDelay))
      proxy.overlay.removeFromSuperview()
      self?.lingeringProxies.removeAll { $0 === proxy }
    }
  }

  private func removeLingeringProxyOverlays() {
    guard !lingeringProxies.isEmpty else { return }
    for proxy in lingeringProxies {
      proxy.backgroundEffect?.removeFromSuperview()
      proxy.overlay.removeFromSuperview()
    }
    lingeringProxies.removeAll()
  }
}

@MainActor
func dashMakePageStackViewController<Root: View>(
  root: Root,
  model: AppModel,
  navigator: DestinationNavigator,
  navigationCoordinator: DashNavigationCoordinator?,
  anchorRegistry: DashNavigationAnchorRegistry?,
  presentationState: DashWorkspacePresentationState?,
  isTabActive: Bool,
  canPresentPendingHomeAction: Bool,
  splashLifted: Bool,
  workspaceWashScroll: DashWorkspaceWashScroll?,
  locale: Locale,
  dynamicTypeSize: DynamicTypeSize,
  accountID: String?,
  onPresentationStateChange: @escaping (DashPagePresentationState) -> Void
) -> UIViewController {
  DashPageStackViewController(
    root: root,
    model: model,
    navigator: navigator,
    navigationCoordinator: navigationCoordinator,
    anchorRegistry: anchorRegistry,
    presentationState: presentationState,
    isTabActive: isTabActive,
    canPresentPendingHomeAction: canPresentPendingHomeAction,
    splashLifted: splashLifted,
    workspaceWashScroll: workspaceWashScroll,
    locale: locale,
    dynamicTypeSize: dynamicTypeSize,
    accountID: accountID,
    onPresentationStateChange: onPresentationStateChange)
}

@MainActor
func dashUpdatePageStackViewController<Root: View>(
  _ uiViewController: UIViewController,
  rootType _: Root.Type,
  isTabActive: Bool,
  canPresentPendingHomeAction: Bool,
  splashLifted: Bool,
  workspaceWashScroll: DashWorkspaceWashScroll?,
  locale: Locale,
  dynamicTypeSize: DynamicTypeSize,
  onPresentationStateChange: @escaping (DashPagePresentationState) -> Void,
  request: DashPageStackRequest
) {
  guard let uiViewController = uiViewController as? DashPageStackViewController<Root> else {
    preconditionFailure("Unexpected Dash page stack controller type")
  }
  uiViewController.update(
    isTabActive: isTabActive,
    canPresentPendingHomeAction: canPresentPendingHomeAction,
    splashLifted: splashLifted,
    workspaceWashScroll: workspaceWashScroll,
    locale: locale,
    dynamicTypeSize: dynamicTypeSize,
    onPresentationStateChange: onPresentationStateChange,
    request: request)
}
