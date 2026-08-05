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

@Test func cardMorphKeepsPagesStationaryAndReflowsBetweenExactSeats() {
  let source = CGRect(x: 20, y: 132, width: 164, height: 131.2)
  let landing = CGRect(x: 16, y: 112, width: 358, height: 214.8)

  #expect(!DashCardMorphRules.movesPages)
  #expect(
    DashCardMorphRules.heroFrame(
      from: source,
      to: landing,
      detailProgress: 0) == source)
  #expect(
    DashCardMorphRules.heroFrame(
      from: source,
      to: landing,
      detailProgress: 1) == landing)

  let midpoint = DashCardMorphRules.heroFrame(
    from: source,
    to: landing,
    detailProgress: 0.5)
  #expect(abs(midpoint.width - 261) < 0.001)
  #expect(abs(midpoint.height - 173) < 0.001)
}

@Test func cardMorphDelaysDetailContentUntilTheCardIsUnderway() {
  #expect(DashCardMorphRules.detailPageOpacity(at: 0.12) == 0)
  #expect(DashCardMorphRules.detailPageOpacity(at: 0.92) == 1)
  #expect(DashCardMorphRules.departingDetailPageOpacity(at: 0.4) == 0)
  #expect(DashCardMorphRules.departingDetailPageOpacity(at: 0.96) == 1)
  #expect(DashCardMorphRules.backdropOpacity(at: 0) == 0)
  #expect(DashCardMorphRules.backdropOpacity(at: 0.5) == 1)
  #expect(DashCardMorphRules.backdropOpacity(at: 1) == 0)
  #expect(DashCardMorphRules.detailAccessoryOpacity(at: 0.5) == 0)
  #expect(DashCardMorphRules.detailAccessoryOpacity(at: 0.94) == 1)
}

@Test func destinationCanvasCoversTheWorkspaceBeforeTheFirstPushFrame() {
  let rootPush = DashDestinationCanvasRules.preparation(
    sourceShowsDestinationCanvas: false,
    targetShowsDestinationCanvas: true)
  #expect(!rootPush.isHidden)
  #expect(rootPush.alpha == 1)

  let rootAtRest = DashDestinationCanvasRules.preparation(
    sourceShowsDestinationCanvas: false,
    targetShowsDestinationCanvas: false)
  #expect(rootAtRest.isHidden)
  #expect(rootAtRest.alpha == 0)
}

@Test func navigationOriginCarriesSemanticCardContentWithoutRequiringPixels() {
  let hero = DashNavigationHero.domainCard(
    name: "example.com",
    status: "Active",
    seed: "example.com",
    fillHex: 0xB8DDA8,
    plan: "Free")
  let origin = DashNavigationOrigin(
    semanticID: .init(namespace: "zone", value: "zone-1"),
    anchorInstanceID: UUID(),
    hero: hero)

  #expect(origin.hero == hero)
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
