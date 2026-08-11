import SwiftUI
import UIKit

private struct DashTabPageUpdate {
  let isTabActive: Bool
  let canPresentPendingHomeAction: Bool
  let splashLifted: Bool
  let workspaceWashScroll: DashWorkspaceWashScroll
  let locale: Locale
  let dynamicTypeSize: DynamicTypeSize
  let onPresentationStateChange: (DashPagePresentationState) -> Void
  let request: DashPageStackRequest
}

@MainActor
private final class DashTabPageSlot {
  let controller: UIViewController
  private let updatePage: (DashTabPageUpdate) -> Void

  init(
    controller: UIViewController,
    updatePage: @escaping (DashTabPageUpdate) -> Void
  ) {
    self.controller = controller
    self.updatePage = updatePage
  }

  func update(_ update: DashTabPageUpdate) {
    updatePage(update)
  }
}

private struct DashTabFlowRequest {
  let selection: AppTab
  let outgoingSelection: AppTab?
  let direction: DashTabTransitionDirection
  let generation: UInt64
  let reduceMotion: Bool
  let rightToLeft: Bool
  let onTransitionCompleted: (AppTab, AppTab, UInt64) -> Void
}

enum DashTabFlowReconciliationDisposition: Equatable {
  case animate
  case deferUntilVisible
  case settleOffscreen
}

enum DashTabFlowContainerRules {
  static func reconciliationDisposition(
    isContainerVisible: Bool,
    parentAppearanceTransitionActive: Bool
  ) -> DashTabFlowReconciliationDisposition {
    if isContainerVisible { return .animate }
    return parentAppearanceTransitionActive ? .deferUntilVisible : .settleOffscreen
  }
}

/// Owns the three persistent page stacks as real UIKit children. At rest only
/// the selected page participates in containment; a Family-style tab handoff
/// temporarily attaches the source and target, then detaches the source without
/// releasing it. This keeps each tab's state while giving UIKit and AX one
/// unambiguous visible-controller tree.
@MainActor
final class DashTabFlowViewController: UIViewController {
  private final class ActiveTransition {
    /// The longest timeline (the incoming settle); it owns the completion.
    let animator: UIViewPropertyAnimator
    /// Shorter concurrent timelines (fades, outgoing glide). They always end
    /// before `animator` does naturally; a forced finish jumps them first.
    let auxiliaryAnimators: [UIViewPropertyAnimator]
    let sourceTab: AppTab
    let targetTab: AppTab
    let generation: UInt64
    let source: UIViewController
    let target: UIViewController
    let appearanceWasBegun: Bool
    let onCompleted: (AppTab, AppTab, UInt64) -> Void
    var notifiesCompletion = true

    init(
      animator: UIViewPropertyAnimator,
      auxiliaryAnimators: [UIViewPropertyAnimator],
      sourceTab: AppTab,
      targetTab: AppTab,
      generation: UInt64,
      source: UIViewController,
      target: UIViewController,
      appearanceWasBegun: Bool,
      onCompleted: @escaping (AppTab, AppTab, UInt64) -> Void
    ) {
      self.animator = animator
      self.auxiliaryAnimators = auxiliaryAnimators
      self.sourceTab = sourceTab
      self.targetTab = targetTab
      self.generation = generation
      self.source = source
      self.target = target
      self.appearanceWasBegun = appearanceWasBegun
      self.onCompleted = onCompleted
    }
  }

  private let pages: [AppTab: DashTabPageSlot]
  private var currentTab: AppTab
  private var activeTransition: ActiveTransition?
  private var isContainerVisible = false
  private var parentAppearanceChild: UIViewController?
  private var pendingRequest: DashTabFlowRequest?

  override var shouldAutomaticallyForwardAppearanceMethods: Bool { false }

  fileprivate init(pages: [AppTab: DashTabPageSlot], selection: AppTab) {
    self.pages = pages
    self.currentTab = selection
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
    view.isAccessibilityElement = false
    let selected = page(for: currentTab).controller
    attach(selected, above: nil)
    exposeOnly(selected)
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    for child in children {
      DashContainmentLayout.fill(child.view, in: view.bounds)
    }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    finishParentAppearanceTransition()
    let selected = page(for: currentTab).controller
    selected.beginAppearanceTransition(true, animated: animated)
    parentAppearanceChild = selected
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    finishParentAppearanceTransition()
    isContainerVisible = true
    reconcilePendingRequestIfNeeded()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    finishParentAppearanceTransition()
    isContainerVisible = false
    finishActiveTransition(notify: false)
    let selected = page(for: currentTab).controller
    selected.beginAppearanceTransition(false, animated: animated)
    parentAppearanceChild = selected
  }

  override func viewDidDisappear(_ animated: Bool) {
    finishParentAppearanceTransition()
    super.viewDidDisappear(animated)
    settlePendingRequestOffscreenIfNeeded()
  }

  fileprivate func updatePage(_ tab: AppTab, with update: DashTabPageUpdate) {
    page(for: tab).update(update)
  }

  fileprivate func reconcile(_ request: DashTabFlowRequest) {
    loadViewIfNeeded()

    switch DashTabFlowContainerRules.reconciliationDisposition(
      isContainerVisible: isContainerVisible,
      parentAppearanceTransitionActive: parentAppearanceChild != nil)
    {
    case .animate:
      pendingRequest = nil
    case .deferUntilVisible:
      pendingRequest = request
      return
    case .settleOffscreen:
      pendingRequest = nil
      settleOffscreen(request)
      return
    }

    if let transition = activeTransition {
      let requestMatchesTransition =
        request.selection == transition.targetTab
        && request.outgoingSelection == transition.sourceTab
        && request.generation == transition.generation
      if requestMatchesTransition {
        enforceInteractionGate(for: transition)
        return
      }
      finishActiveTransition(notify: false)
    }

    guard
      let sourceTab = request.outgoingSelection,
      sourceTab != request.selection
    else {
      showOnly(request.selection)
      return
    }

    if currentTab != sourceTab {
      showOnly(sourceTab)
    }
    startTransition(
      from: sourceTab,
      to: request.selection,
      direction: request.direction,
      generation: request.generation,
      reduceMotion: request.reduceMotion,
      rightToLeft: request.rightToLeft,
      onCompleted: request.onTransitionCompleted)
  }

  private func page(for tab: AppTab) -> DashTabPageSlot {
    guard let page = pages[tab] else {
      preconditionFailure("Missing tab page for \(tab)")
    }
    return page
  }

  private func startTransition(
    from sourceTab: AppTab,
    to targetTab: AppTab,
    direction: DashTabTransitionDirection,
    generation: UInt64,
    reduceMotion: Bool,
    rightToLeft: Bool,
    onCompleted: @escaping (AppTab, AppTab, UInt64) -> Void
  ) {
    let source = page(for: sourceTab).controller
    let target = page(for: targetTab).controller
    guard source !== target else {
      showOnly(targetTab)
      return
    }

    attach(target, above: source)
    view.layoutIfNeeded()

    let travel = DashTabTransitionRules.signedTravel(
      for: direction,
      rightToLeft: rightToLeft,
      reduceMotion: reduceMotion)
    resetVisualState(source.view)
    target.view.layer.removeAllAnimations()
    target.view.alpha = 0
    target.view.transform = CGAffineTransform(translationX: travel, y: 0)
    source.view.isUserInteractionEnabled = false
    target.view.isUserInteractionEnabled = false
    source.view.accessibilityElementsHidden = true
    target.view.accessibilityElementsHidden = true
    view.accessibilityElementsHidden = true

    let appearanceWasBegun = isContainerVisible
    if appearanceWasBegun {
      source.beginAppearanceTransition(false, animated: true)
      target.beginAppearanceTransition(true, animated: true)
    }

    let transition: ActiveTransition
    if reduceMotion {
      // Stationary complementary crossfade; `travel` is already zero here.
      let animator = UIViewPropertyAnimator(
        duration: DashTheme.Motion.Page.reducedDuration,
        timingParameters: UICubicTimingParameters(animationCurve: .easeOut))
      animator.addAnimations {
        source.view.alpha = 0
        source.view.transform = .identity
        target.view.alpha = 1
        target.view.transform = .identity
      }
      transition = ActiveTransition(
        animator: animator,
        auxiliaryAnimators: [],
        sourceTab: sourceTab,
        targetTab: targetTab,
        generation: generation,
        source: source,
        target: target,
        appearanceWasBegun: appearanceWasBegun,
        onCompleted: onCompleted)
    } else {
      // The outgoing page clears first: a front-loaded fade over a constant-
      // speed glide that is still travelling when its opacity reaches zero.
      let outgoingFade = UIViewPropertyAnimator(
        duration: DashTheme.Motion.tabStepOutgoingFadeDuration,
        timingParameters: UICubicTimingParameters(
          controlPoint1: DashTheme.Motion.tabStepOutgoingFadeControlPoint1,
          controlPoint2: DashTheme.Motion.tabStepOutgoingFadeControlPoint2))
      outgoingFade.addAnimations {
        source.view.alpha = 0
      }
      let outgoingSlide = UIViewPropertyAnimator(
        duration: DashTheme.Motion.tabStepOutgoingSlideDuration,
        timingParameters: UICubicTimingParameters(animationCurve: .linear))
      outgoingSlide.addAnimations {
        source.view.transform = CGAffineTransform(translationX: -travel, y: 0)
      }
      // The incoming page lands just after it: the S-curve's slow first frames
      // are the lag that keeps both opacities near 30% at the crossover.
      let incomingFade = UIViewPropertyAnimator(
        duration: DashTheme.Motion.tabStepIncomingFadeDuration,
        timingParameters: UICubicTimingParameters(animationCurve: .easeInOut))
      incomingFade.addAnimations {
        target.view.alpha = 1
      }
      // Soft spring settle; the fade is complete well before the ~1pt
      // overshoot, so only fully opaque content ever bounces. Longest
      // timeline, so it owns the completion.
      let settle = UIViewPropertyAnimator(
        duration: DashTheme.Motion.tabStepSettleDuration,
        timingParameters: UISpringTimingParameters(
          dampingRatio: DashTheme.Motion.tabStepSettleDampingRatio,
          initialVelocity: .zero))
      settle.addAnimations {
        target.view.transform = .identity
      }
      transition = ActiveTransition(
        animator: settle,
        auxiliaryAnimators: [outgoingFade, outgoingSlide, incomingFade],
        sourceTab: sourceTab,
        targetTab: targetTab,
        generation: generation,
        source: source,
        target: target,
        appearanceWasBegun: appearanceWasBegun,
        onCompleted: onCompleted)
    }
    activeTransition = transition
    transition.animator.addCompletion { [weak self, weak transition] _ in
      guard let self, let transition else { return }
      self.complete(transition)
    }
    for animator in transition.auxiliaryAnimators {
      animator.startAnimation()
    }
    transition.animator.startAnimation()
  }

  private func enforceInteractionGate(for transition: ActiveTransition) {
    transition.source.view.isUserInteractionEnabled = false
    transition.target.view.isUserInteractionEnabled = false
    transition.source.view.accessibilityElementsHidden = true
    transition.target.view.accessibilityElementsHidden = true
    view.accessibilityElementsHidden = true
  }

  private func complete(_ transition: ActiveTransition) {
    guard activeTransition === transition else { return }
    if transition.appearanceWasBegun {
      transition.source.endAppearanceTransition()
      transition.target.endAppearanceTransition()
    }
    resetVisualState(transition.source.view)
    resetVisualState(transition.target.view)
    detach(transition.source)
    currentTab = transition.targetTab
    exposeOnly(transition.target)
    activeTransition = nil

    if isContainerVisible {
      UIAccessibility.post(notification: .screenChanged, argument: transition.target.view)
    }
    guard transition.notifiesCompletion else { return }
    let callback = transition.onCompleted
    let sourceTab = transition.sourceTab
    let targetTab = transition.targetTab
    let generation = transition.generation
    // A property animator can be completed while SwiftUI is reconciling this
    // representable. Publish ownership on the next actor turn, never mid-update.
    Task { @MainActor in
      callback(sourceTab, targetTab, generation)
    }
  }

  private func finishActiveTransition(notify: Bool) {
    guard let transition = activeTransition else { return }
    transition.notifiesCompletion = notify
    // Auxiliary timelines may already have run out naturally; only a still-
    // active one can be stopped and jumped to its end values.
    for animator in transition.auxiliaryAnimators where animator.state == .active {
      animator.stopAnimation(false)
      if animator.state == .stopped {
        animator.finishAnimation(at: .end)
      }
    }
    transition.animator.stopAnimation(false)
    transition.animator.finishAnimation(at: .end)
  }

  private func settleOffscreen(_ request: DashTabFlowRequest) {
    finishActiveTransition(notify: false)
    showOnly(request.selection)
    guard
      let sourceTab = request.outgoingSelection,
      sourceTab != request.selection
    else { return }
    let callback = request.onTransitionCompleted
    let targetTab = request.selection
    let generation = request.generation
    Task { @MainActor in
      callback(sourceTab, targetTab, generation)
    }
  }

  private func reconcilePendingRequestIfNeeded() {
    guard let pendingRequest else { return }
    self.pendingRequest = nil
    reconcile(pendingRequest)
  }

  private func settlePendingRequestOffscreenIfNeeded() {
    guard let pendingRequest else { return }
    self.pendingRequest = nil
    settleOffscreen(pendingRequest)
  }

  private func showOnly(_ tab: AppTab) {
    let target = page(for: tab).controller
    let source = page(for: currentTab).controller
    guard target !== source else {
      exposeOnly(target)
      return
    }

    attach(target, above: source)
    let forwardsAppearance = isContainerVisible
    if forwardsAppearance {
      source.beginAppearanceTransition(false, animated: false)
      target.beginAppearanceTransition(true, animated: false)
    }
    if forwardsAppearance {
      source.endAppearanceTransition()
      target.endAppearanceTransition()
    }
    resetVisualState(source.view)
    resetVisualState(target.view)
    detach(source)
    currentTab = tab
    exposeOnly(target)
    if isContainerVisible {
      UIAccessibility.post(notification: .screenChanged, argument: target.view)
    }
  }

  private func exposeOnly(_ controller: UIViewController) {
    controller.view.isUserInteractionEnabled = true
    controller.view.accessibilityElementsHidden = false
    // Let UIKit derive descendants from the one attached child. Publishing a
    // plain UIView through an explicit accessibilityElements array leaves its
    // SwiftUI descendants enumerable but without a valid XCUI visible point.
    view.accessibilityElements = nil
    view.accessibilityElementsHidden = false
  }

  private func attach(_ child: UIViewController, above sibling: UIViewController?) {
    if child.parent === self {
      DashContainmentLayout.fill(child.view, in: view.bounds)
      if let sibling, sibling.view.superview === view {
        view.insertSubview(child.view, aboveSubview: sibling.view)
      } else {
        view.bringSubviewToFront(child.view)
      }
      return
    }
    addChild(child)
    // Bounds/center keep the tab handoff translation defined during layout.
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

  private func resetVisualState(_ view: UIView) {
    view.layer.removeAllAnimations()
    view.alpha = 1
    view.transform = .identity
  }

  private func finishParentAppearanceTransition() {
    parentAppearanceChild?.endAppearanceTransition()
    parentAppearanceChild = nil
  }
}

/// One representable for the entire workspace flow. Individual page stacks are
/// cached as detached UIKit controllers instead of separate SwiftUI siblings,
/// which preserves their state without exposing invisible AX containers.
struct DashTabFlowHost<HomeRoot: View, FeaturesRoot: View, WatchtowerRoot: View>:
  UIViewControllerRepresentable
{
  @Bindable var homeNavigator: DestinationNavigator
  @Bindable var featuresNavigator: DestinationNavigator
  @Bindable var watchtowerNavigator: DestinationNavigator
  let selection: AppTab
  let outgoingSelection: AppTab?
  let transitionDirection: DashTabTransitionDirection
  let transitionGeneration: UInt64
  let canPresentPendingHomeAction: Bool
  let homeWorkspaceWashScroll: DashWorkspaceWashScroll
  let featuresWorkspaceWashScroll: DashWorkspaceWashScroll
  let watchtowerWorkspaceWashScroll: DashWorkspaceWashScroll
  let onHomePresentationStateChange: (DashPagePresentationState) -> Void
  let onFeaturesPresentationStateChange: (DashPagePresentationState) -> Void
  let onWatchtowerPresentationStateChange: (DashPagePresentationState) -> Void
  let onTransitionCompleted: (AppTab, AppTab, UInt64) -> Void
  @ViewBuilder var home: () -> HomeRoot
  @ViewBuilder var features: () -> FeaturesRoot
  @ViewBuilder var watchtower: () -> WatchtowerRoot

  @Environment(AppModel.self) private var model
  @Environment(\.dashNavigationCoordinator) private var navigationCoordinator
  @Environment(\.dashNavigationAnchorRegistry) private var anchorRegistry
  @Environment(\.dashWorkspacePresentationState) private var presentationState
  @Environment(\.locale) private var locale
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.layoutDirection) private var layoutDirection
  @Environment(\.dashSplashLifted) private var splashLifted

  func makeUIViewController(context: Context) -> DashTabFlowViewController {
    navigationCoordinator?.register(homeNavigator)
    navigationCoordinator?.register(featuresNavigator)
    navigationCoordinator?.register(watchtowerNavigator)
    let pages = [
      AppTab.home: makePage(
        root: home(),
        navigator: homeNavigator,
        isTabActive: selection == .home,
        canPresentPendingHomeAction: canPresentPendingHomeAction,
        workspaceWashScroll: homeWorkspaceWashScroll,
        onPresentationStateChange: onHomePresentationStateChange),
      AppTab.features: makePage(
        root: features(),
        navigator: featuresNavigator,
        isTabActive: selection == .features,
        canPresentPendingHomeAction: true,
        workspaceWashScroll: featuresWorkspaceWashScroll,
        onPresentationStateChange: onFeaturesPresentationStateChange),
      AppTab.watchtower: makePage(
        root: watchtower(),
        navigator: watchtowerNavigator,
        isTabActive: selection == .watchtower,
        canPresentPendingHomeAction: true,
        workspaceWashScroll: watchtowerWorkspaceWashScroll,
        onPresentationStateChange: onWatchtowerPresentationStateChange),
    ]
    return DashTabFlowViewController(pages: pages, selection: selection)
  }

  func updateUIViewController(
    _ uiViewController: DashTabFlowViewController,
    context: Context
  ) {
    navigationCoordinator?.register(homeNavigator)
    navigationCoordinator?.register(featuresNavigator)
    navigationCoordinator?.register(watchtowerNavigator)
    let participatingTabs = Set([selection, outgoingSelection].compactMap { $0 })
    uiViewController.updatePage(
      .home,
      with: pageUpdate(
        navigator: homeNavigator,
        isTabActive: participatingTabs.contains(.home),
        canPresentPendingHomeAction: canPresentPendingHomeAction,
        workspaceWashScroll: homeWorkspaceWashScroll,
        onPresentationStateChange: onHomePresentationStateChange))
    uiViewController.updatePage(
      .features,
      with: pageUpdate(
        navigator: featuresNavigator,
        isTabActive: participatingTabs.contains(.features),
        canPresentPendingHomeAction: true,
        workspaceWashScroll: featuresWorkspaceWashScroll,
        onPresentationStateChange: onFeaturesPresentationStateChange))
    uiViewController.updatePage(
      .watchtower,
      with: pageUpdate(
        navigator: watchtowerNavigator,
        isTabActive: participatingTabs.contains(.watchtower),
        canPresentPendingHomeAction: true,
        workspaceWashScroll: watchtowerWorkspaceWashScroll,
        onPresentationStateChange: onWatchtowerPresentationStateChange))
    uiViewController.reconcile(
      DashTabFlowRequest(
        selection: selection,
        outgoingSelection: outgoingSelection,
        direction: transitionDirection,
        generation: transitionGeneration,
        reduceMotion: reduceMotion,
        rightToLeft: layoutDirection == .rightToLeft,
        onTransitionCompleted: onTransitionCompleted))
  }

  private func makePage<Root: View>(
    root: Root,
    navigator: DestinationNavigator,
    isTabActive: Bool,
    canPresentPendingHomeAction: Bool,
    workspaceWashScroll: DashWorkspaceWashScroll,
    onPresentationStateChange: @escaping (DashPagePresentationState) -> Void
  ) -> DashTabPageSlot {
    let controller = dashMakePageStackViewController(
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
      accountID: navigator.accountID,
      onPresentationStateChange: onPresentationStateChange)
    return DashTabPageSlot(controller: controller) { [weak controller] update in
      guard let controller else { return }
      dashUpdatePageStackViewController(
        controller,
        rootType: Root.self,
        isTabActive: update.isTabActive,
        canPresentPendingHomeAction: update.canPresentPendingHomeAction,
        splashLifted: update.splashLifted,
        workspaceWashScroll: update.workspaceWashScroll,
        locale: update.locale,
        dynamicTypeSize: update.dynamicTypeSize,
        onPresentationStateChange: update.onPresentationStateChange,
        request: update.request)
    }
  }

  private func pageUpdate(
    navigator: DestinationNavigator,
    isTabActive: Bool,
    canPresentPendingHomeAction: Bool,
    workspaceWashScroll: DashWorkspaceWashScroll,
    onPresentationStateChange: @escaping (DashPagePresentationState) -> Void
  ) -> DashTabPageUpdate {
    DashTabPageUpdate(
      isTabActive: isTabActive,
      canPresentPendingHomeAction: canPresentPendingHomeAction,
      splashLifted: splashLifted,
      workspaceWashScroll: workspaceWashScroll,
      locale: locale,
      dynamicTypeSize: dynamicTypeSize,
      onPresentationStateChange: onPresentationStateChange,
      request: DashPageStackRequest(
        entries: navigator.entries,
        revision: navigator.revision,
        mutation: navigator.lastMutation,
        accountID: navigator.accountID,
        reduceMotion: reduceMotion,
        isTabActive: isTabActive))
  }
}

private struct DashPageStackHost<Root: View>: UIViewControllerRepresentable {
  @Bindable var navigator: DestinationNavigator
  var isTabActive: Bool
  var canPresentPendingHomeAction: Bool
  var onPresentationStateChange: (DashPagePresentationState) -> Void
  @ViewBuilder var root: () -> Root

  @Environment(AppModel.self) private var model
  @Environment(\.dashNavigationCoordinator) private var navigationCoordinator
  @Environment(\.dashNavigationAnchorRegistry) private var anchorRegistry
  @Environment(\.dashWorkspacePresentationState) private var presentationState
  @Environment(\.dashWorkspaceWashScroll) private var workspaceWashScroll
  @Environment(\.locale) private var locale
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dashSplashLifted) private var splashLifted

  func makeUIViewController(context: Context) -> UIViewController {
    dashMakePageStackViewController(
      root: root(),
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
      accountID: navigator.accountID,
      onPresentationStateChange: onPresentationStateChange)
  }

  func updateUIViewController(
    _ uiViewController: UIViewController,
    context: Context
  ) {
    dashUpdatePageStackViewController(
      uiViewController,
      rootType: Root.self,
      isTabActive: isTabActive,
      canPresentPendingHomeAction: canPresentPendingHomeAction,
      splashLifted: splashLifted,
      workspaceWashScroll: workspaceWashScroll,
      locale: locale,
      dynamicTypeSize: dynamicTypeSize,
      onPresentationStateChange: onPresentationStateChange,
      request: DashPageStackRequest(
        entries: navigator.entries,
        revision: navigator.revision,
        mutation: navigator.lastMutation,
        accountID: navigator.accountID,
        reduceMotion: reduceMotion,
        isTabActive: isTabActive))
  }
}

// MARK: - Tab stack

/// Per-tab host for Dash's own page stack. Every route is a cached SwiftUI page
/// controller inside a plain UIKit container — no `UINavigationController`,
/// system stack, or edge-pop recognizer participates.
struct DestinationStackHost<Root: View>: View {
  @Bindable var navigator: DestinationNavigator
  @Environment(\.dashNavigationCoordinator) private var navigationCoordinator
  var isTabActive: Bool
  var canPresentPendingHomeAction = true
  var onPresentationStateChange: (DashPagePresentationState) -> Void = { _ in }
  @ViewBuilder var root: () -> Root

  var body: some View {
    DashPageStackHost(
      navigator: navigator,
      isTabActive: isTabActive,
      canPresentPendingHomeAction: canPresentPendingHomeAction,
      onPresentationStateChange: onPresentationStateChange,
      root: root
    )
    .onAppear {
      navigationCoordinator?.register(navigator)
    }
  }

}
