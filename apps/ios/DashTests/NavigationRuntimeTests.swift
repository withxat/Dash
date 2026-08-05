import Testing
import UIKit

@testable import Dash

@Test func tabFlowDirectionFollowsTheDestinationOrder() {
  #expect(DashTabTransitionRules.direction(from: .home, to: .features) == .forward)
  #expect(DashTabTransitionRules.direction(from: .home, to: .watchtower) == .forward)
  #expect(DashTabTransitionRules.direction(from: .watchtower, to: .home) == .backward)
  #expect(DashTabTransitionRules.direction(from: .features, to: .features) == .stationary)
}

@Test func tabFlowMotionMirrorsAndReduceMotionRemovesTravel() {
  #expect(
    DashTabTransitionRules.signedTravel(
      for: .forward,
      rightToLeft: false,
      reduceMotion: false) == DashTheme.Motion.tabStepSlide)
  #expect(
    DashTabTransitionRules.signedTravel(
      for: .forward,
      rightToLeft: true,
      reduceMotion: false) == -DashTheme.Motion.tabStepSlide)
  #expect(
    DashTabTransitionRules.signedTravel(
      for: .backward,
      rightToLeft: false,
      reduceMotion: false) == -DashTheme.Motion.tabStepSlide)
  #expect(
    DashTabTransitionRules.signedTravel(
      for: .forward,
      rightToLeft: false,
      reduceMotion: true) == 0)
}

@Test func tabFlowDefersOnlyAcrossAnActiveParentAppearanceTransition() {
  #expect(
    DashTabFlowContainerRules.reconciliationDisposition(
      isContainerVisible: true,
      parentAppearanceTransitionActive: false) == .animate)
  #expect(
    DashTabFlowContainerRules.reconciliationDisposition(
      isContainerVisible: false,
      parentAppearanceTransitionActive: true) == .deferUntilVisible)
  #expect(
    DashTabFlowContainerRules.reconciliationDisposition(
      isContainerVisible: false,
      parentAppearanceTransitionActive: false) == .settleOffscreen)
}

@Test func pageTransitionRetainsRootChromeDisplacementUntilSettled() {
  let popping = DashPagePresentationState(settledDepth: 1, isTransitioning: true)
  #expect(popping.resolvedDepth(navigatorDepth: 0) == 1)
  #expect(
    shouldHideHeaderAvatar(
      overlays: DashTrayPresentation(),
      navigationDepth: popping.resolvedDepth(navigatorDepth: 0),
      pageTransitionActive: popping.isTransitioning))
  #expect(
    shouldHideTabBar(
      overlays: DashTrayPresentation(),
      navigationDepth: popping.resolvedDepth(navigatorDepth: 0),
      pageTransitionActive: popping.isTransitioning))

  let settledRoot = DashPagePresentationState(settledDepth: 0, isTransitioning: false)
  #expect(!settledRoot.occupiesWorkspace(navigatorDepth: 0))

  let outgoingDetail = DashPagePresentationState(settledDepth: 1, isTransitioning: false)
  #expect(outgoingDetail.occupiesWorkspace(navigatorDepth: 0))
}
