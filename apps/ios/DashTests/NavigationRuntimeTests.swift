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

@Test func tabFlowOutgoingExitsOppositeTheIncomingStart() {
  #expect(
    DashTabTransitionRules.outgoingEndOffset(
      for: .forward,
      rightToLeft: false,
      reduceMotion: false) == -DashTheme.Motion.tabStepSlide)
  #expect(
    DashTabTransitionRules.outgoingEndOffset(
      for: .backward,
      rightToLeft: false,
      reduceMotion: false) == DashTheme.Motion.tabStepSlide)
  #expect(
    DashTabTransitionRules.outgoingEndOffset(
      for: .forward,
      rightToLeft: true,
      reduceMotion: false) == DashTheme.Motion.tabStepSlide)
}

@Test func pageStepSharesTabHandoffAxis() {
  #expect(DashTabTransitionRules.pageStepDirection(isPush: true) == .forward)
  #expect(DashTabTransitionRules.pageStepDirection(isPush: false) == .backward)
  #expect(DashTheme.Motion.Page.flowEnterDuration == DashTheme.Motion.tabStepSettleDuration)
  #expect(DashTheme.Motion.Page.flowDampingRatio == DashTheme.Motion.tabStepSettleDampingRatio)
}

@Test @MainActor func containmentLayoutPreservesTranslationWhileFilling() {
  let container = CGRect(x: 0, y: 0, width: 390, height: 844)
  let child = UIView(frame: .zero)
  child.transform = CGAffineTransform(translationX: -24, y: 0)
  DashContainmentLayout.fill(child, in: container)
  #expect(child.bounds.size == container.size)
  #expect(child.center == CGPoint(x: container.midX, y: container.midY))
  #expect(child.transform.tx == -24)
}

@Test func pageCloseUsesTheFineEditCloseMark() {
  #expect(
    DashPageChromeAssetRules.leadingAsset(
      for: .closeToWorkspaceRoot,
      rightToLeft: false) == SolarAsset.editClose)
  #expect(
    DashPageChromeAssetRules.leadingAsset(
      for: .back,
      rightToLeft: true) == SolarAsset.chevronRight)
}

@Test func backChevronNudgeTowardItsTipInsideCircularChrome() {
  #expect(DashChevronOpticalRules.offsetX(for: SolarAsset.chevronLeft) == -1.5)
  #expect(DashChevronOpticalRules.offsetX(for: SolarAsset.chevronRight) == 1.5)
  #expect(DashChevronOpticalRules.offsetX(for: SolarAsset.editClose) == 0)
}

/// The nudge scales with the mark. It was tuned on the navigation circle's 24pt
/// glyph; the chart card's disclosure is 14pt, so it takes 14/24 of it. The flat
/// value put that tip against the plate's edge, and none at all read left of
/// centre.
@Test func compactDisclosureSeatScalesTheChevronNudgeToItsGlyph() {
  #expect(
    DashChevronOpticalRules.offsetX(
      for: SolarAsset.chevronRight, seat: .compactDisclosure) == 0.875)
  #expect(
    DashChevronOpticalRules.offsetX(
      for: SolarAsset.chevronLeft, seat: .compactDisclosure) == -0.875)
  #expect(
    DashChevronOpticalRules.offsetX(
      for: SolarAsset.editClose, seat: .compactDisclosure) == 0)
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

  // The enter spring's overshoot extrapolates past the seat — the bounce —
  // while the floor stays clamped so a reversed entrance cannot undershoot
  // behind its own source.
  let overshoot = DashCardMorphRules.heroFrame(
    from: source,
    to: landing,
    detailProgress: 1.05)
  #expect(abs(overshoot.width - (358 + 0.05 * (358 - 164))) < 0.001)
  #expect(overshoot.width > landing.width)
  #expect(
    DashCardMorphRules.heroFrame(
      from: source,
      to: landing,
      detailProgress: -0.2) == source)
  // Enter bounces, collapse never does.
  #expect(DashTheme.Motion.Page.cardEnterDampingRatio < 1)
  #expect(DashTheme.Motion.Page.cardExitDampingRatio == 1)
}

@Test func cardFlightPacesItselfToTheGroundItCovers() {
  let base = DashTheme.Motion.Page.cardEnterDuration
  let landing = CGRect(x: 16, y: 112, width: 358, height: 214.8)

  // Top rows keep the base pace.
  let near = CGRect(x: 20, y: 132, width: 164, height: 131.2)
  #expect(
    DashCardMorphRules.flightDuration(base: base, from: near, to: landing) == base)

  // A bottom-row card gets more time, capped at the far stretch.
  let far = CGRect(x: 20, y: 900, width: 164, height: 131.2)
  let farDuration = DashCardMorphRules.flightDuration(
    base: base, from: far, to: landing)
  #expect(farDuration > base)
  #expect(farDuration <= base * DashCardMorphRules.maxFlightStretch)

  let veryFar = CGRect(x: 20, y: 2000, width: 164, height: 131.2)
  #expect(
    DashCardMorphRules.flightDuration(base: base, from: veryFar, to: landing)
      == base * DashCardMorphRules.maxFlightStretch)

  // Direction-agnostic: the pop home from the same distance takes the same time.
  #expect(
    DashCardMorphRules.flightDuration(base: base, from: far, to: landing)
      == DashCardMorphRules.flightDuration(base: base, from: landing, to: far))
}

@Test func cardMorphDelaysDetailContentUntilTheCardIsUnderway() {
  #expect(DashCardMorphRules.detailPageOpacity(at: 0.12) == 0)
  #expect(DashCardMorphRules.detailPageOpacity(at: 0.92) == 1)
  #expect(DashCardMorphRules.departingDetailPageOpacity(at: 0.4) == 0)
  #expect(DashCardMorphRules.departingDetailPageOpacity(at: 0.96) == 1)
  // The veil only grows: it is retired by the arriving page covering it, not
  // by fading back off screen, so it must never come back down at the end.
  #expect(DashCardMorphRules.backdropOpacity(at: 0) == 0)
  #expect(DashCardMorphRules.backdropOpacity(at: 0.3) == 0.5)
  #expect(DashCardMorphRules.backdropOpacity(at: 0.6) == 1)
  #expect(DashCardMorphRules.backdropOpacity(at: 1) == 1)
  #expect(DashCardMorphRules.detailAccessoryOpacity(at: 0.5) == 0)
  #expect(DashCardMorphRules.detailAccessoryOpacity(at: 0.94) == 1)
}

@Test func destinationCanvasCoversTheWorkspaceBeforeTheFirstPushFrame() {
  let rootPush = DashDestinationCanvasRules.preparation(
    sourceShowsDestinationCanvas: false,
    targetShowsDestinationCanvas: true)
  #expect(!rootPush.isHidden)
  #expect(rootPush.alpha == 1)

  let popToRoot = DashDestinationCanvasRules.preparation(
    sourceShowsDestinationCanvas: true,
    targetShowsDestinationCanvas: false)
  #expect(!popToRoot.isHidden)
  #expect(popToRoot.alpha == 1)

  let rootAtRest = DashDestinationCanvasRules.preparation(
    sourceShowsDestinationCanvas: false,
    targetShowsDestinationCanvas: false)
  #expect(rootAtRest.isHidden)
  #expect(rootAtRest.alpha == 0)
}

@Test func onlyACardSourceEarnsTheMorphWhileEveryOtherDrillHandsOff() {
  #expect(DashPageTransitionRules.role(presentation: .detail, hasHero: false) == .flow)
  #expect(DashPageTransitionRules.role(presentation: .detail, hasHero: true) == .card)
  // Settings keeps its train whether or not a source hands over a card.
  #expect(
    DashPageTransitionRules.role(presentation: .workspaceOverlay, hasHero: false)
      == .workspace)
  #expect(
    DashPageTransitionRules.role(presentation: .workspaceOverlay, hasHero: true)
      == .workspace)
}

@MainActor
@Test func resourcesDrillsHandOffAndOnlyTheDomainCardMorphs() throws {
  let navigator = DestinationNavigator()
  navigator.push(.feature(.workers))
  let feature = try #require(navigator.topEntry)
  #expect(
    DashPageTransitionRules.role(
      presentation: feature.presentation,
      hasHero: feature.origin?.hero != nil) == .flow)

  navigator.push(.worker("api"))
  let worker = try #require(navigator.topEntry)
  #expect(
    DashPageTransitionRules.role(
      presentation: worker.presentation,
      hasHero: worker.origin?.hero != nil) == .flow)

  // The same zone reached without a card (a Home row, a recent) is a drill too.
  navigator.push(.zone("zone-1"))
  let plainZone = try #require(navigator.topEntry)
  #expect(
    DashPageTransitionRules.role(
      presentation: plainZone.presentation,
      hasHero: plainZone.origin?.hero != nil) == .flow)

  navigator.push(
    .zone("zone-2"),
    origin: DashNavigationOrigin(
      semanticID: Destination.zone("zone-2").dashNavigationSemanticID,
      anchorInstanceID: UUID(),
      sourceFrame: CGRect(x: 16, y: 240, width: 176, height: 128),
      hero: .domainCard(
        name: "example.com",
        status: "Active",
        seed: "example.com",
        fillHex: 0xB8DDA8,
        plan: "Free")))
  let cardZone = try #require(navigator.topEntry)
  #expect(
    DashPageTransitionRules.role(
      presentation: cardZone.presentation,
      hasHero: cardZone.origin?.hero != nil) == .card)
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

@Test func pageTransitionRetainsDockDisplacementUntilSettled() {
  let popping = DashPagePresentationState(settledDepth: 1, isTransitioning: true)
  #expect(popping.resolvedDepth(navigatorDepth: 0) == 1)
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

// MARK: - Shared header slots

@MainActor
@Test func headerSlotsSeatRootIdentityAndPageChromeInTheSameTwoSlots() {
  let root = DashWorkspaceHeaderRules.state(
    entry: nil,
    chrome: nil,
    holdoverTitle: nil,
    showsProfileControl: true,
    showsWatchtowerInbox: true,
    isEditingWatchtower: false)
  #expect(root.leading == .profile)
  #expect(root.trailing == .watchtowerInbox)
  // Tab roots keep an empty title slot; a title exists from the first drill.
  #expect(root.title == nil)

  let editing = DashWorkspaceHeaderRules.state(
    entry: nil,
    chrome: nil,
    holdoverTitle: nil,
    showsProfileControl: true,
    showsWatchtowerInbox: true,
    isEditingWatchtower: true)
  #expect(editing.leading == .watchtowerEditorCancel)
  #expect(editing.trailing == .watchtowerEditor)

  let header = DashPageHeaderDescriptor(
    icon: .solar(SolarAsset.Content.inbox),
    title: "Alerts",
    tint: DashTheme.brand)
  let detail = DashWorkspaceHeaderRules.state(
    entry: DashNavigationEntry(destination: .watchtowerInbox),
    chrome: DashPageChromePreference(header: header),
    holdoverTitle: nil,
    showsProfileControl: true,
    showsWatchtowerInbox: true,
    isEditingWatchtower: false)
  #expect(detail.leading == .dismissal(.back))
  #expect(detail.title == header)
  #expect(detail.trailing == .empty)

  let workspace = DashWorkspaceHeaderRules.state(
    entry: DashNavigationEntry(
      destination: .settings,
      presentation: .workspaceOverlay),
    chrome: nil,
    holdoverTitle: nil,
    showsProfileControl: true,
    showsWatchtowerInbox: false,
    isEditingWatchtower: false)
  #expect(workspace.leading == .dismissal(.closeToWorkspaceRoot))
}

@MainActor
@Test func headerLeadingSlotYieldsToAPageOwnedLeadingAction() {
  let action = DashPageActionDescriptor.text(id: "cancel", title: "Cancel") {}
  let state = DashWorkspaceHeaderRules.state(
    entry: DashNavigationEntry(destination: .about),
    chrome: DashPageChromePreference(leadingActions: [action]),
    holdoverTitle: nil,
    showsProfileControl: true,
    showsWatchtowerInbox: false,
    isEditingWatchtower: false)
  #expect(state.leading == .action(action))
}

@Test func headerLeadingSeatIdentityIgnoresPageWhenTheControlLooksTheSame() {
  // Card expand / drill: both pages wear Back — one seat, no remount morph.
  #expect(
    DashWorkspaceHeaderLeading.dismissal(.back).slotKind
      == DashWorkspaceHeaderLeading.dismissal(.back).slotKind)
  // Close is a different glyph, so avatar → Close and Back → Close still trade.
  #expect(
    DashWorkspaceHeaderLeading.dismissal(.back).slotKind
      != DashWorkspaceHeaderLeading.dismissal(.closeToWorkspaceRoot).slotKind)
  #expect(
    DashWorkspaceHeaderLeading.profile.slotKind
      != DashWorkspaceHeaderLeading.dismissal(.closeToWorkspaceRoot).slotKind)
}

@Test func headerDirectionFollowsTheMutation() {
  #expect(DashWorkspaceHeaderRules.direction(for: .push) == .forward)
  #expect(DashWorkspaceHeaderRules.direction(for: .back) == .backward)
  #expect(DashWorkspaceHeaderRules.direction(for: .closeToWorkspaceRoot) == .backward)
  #expect(DashWorkspaceHeaderRules.direction(for: nil) == .stationary)
}

@Test func headerSlotsNeverTravel() {
  // Leading morphs in place, title swaps instantly, and a leftover Settings
  // Y-ride was sliding the Watchtower inbox — distance stays zero on every
  // role. Pace still comes from `step`'s duration / damping.
  for role in [DashPageTransitionRole.flow, .card, .workspace] {
    for direction in [
      DashTabTransitionDirection.forward, .backward, .stationary,
    ] {
      #expect(
        DashWorkspaceHeaderRules.travel(
          role: role,
          direction: direction,
          reduceMotion: false) == .zero)
    }
  }
  #expect(
    DashWorkspaceHeaderRules.travel(
      role: .workspace,
      direction: .forward,
      reduceMotion: true) == .zero)
}

@MainActor
@Test func headerStepSharesThePageCompositorsRoleAndPace() {
  let navigator = DestinationNavigator(chromeHosting: .workspace)
  navigator.push(.settings)
  let present = DashWorkspaceHeaderRules.step(
    for: navigator.lastMutation,
    reduceMotion: false)
  #expect(DashWorkspaceHeaderRules.role(for: navigator.lastMutation) == .workspace)
  #expect(present.travel == .zero)
  #expect(present.duration == DashTheme.Motion.Page.workspaceEnterDuration)
  #expect(present.dampingRatio == DashTheme.Motion.Page.workspaceEnterDampingRatio)

  navigator.closeToWorkspaceRoot()
  let dismiss = DashWorkspaceHeaderRules.step(
    for: navigator.lastMutation,
    reduceMotion: false)
  // The mutation still names the page that left, so Close settles on the
  // train's own quicker exit — a dismissal has no top entry to ask.
  #expect(DashWorkspaceHeaderRules.role(for: navigator.lastMutation) == .workspace)
  #expect(dismiss.travel == .zero)
  #expect(dismiss.duration == DashTheme.Motion.Page.workspaceExitDuration)
  #expect(dismiss.dampingRatio == DashTheme.Motion.Page.workspaceExitDampingRatio)

  navigator.push(
    .zone("zone-1"),
    origin: DashNavigationOrigin(
      semanticID: Destination.zone("zone-1").dashNavigationSemanticID,
      anchorInstanceID: UUID(),
      sourceFrame: CGRect(x: 16, y: 240, width: 176, height: 128),
      hero: .domainCard(
        name: "example.com",
        status: "Active",
        seed: "example.com",
        fillHex: 0xB8DDA8,
        plan: "Free")))
  let card = DashWorkspaceHeaderRules.step(
    for: navigator.lastMutation,
    reduceMotion: false)
  #expect(DashWorkspaceHeaderRules.role(for: navigator.lastMutation) == .card)
  // Still in place, but on the card's own slower pace rather than flow's.
  #expect(card.travel == .zero)
  #expect(card.duration == DashTheme.Motion.Page.cardEnterDuration)
  #expect(card.dampingRatio == DashTheme.Motion.Page.cardEnterDampingRatio)

  navigator.push(.feature(.workers))
  let drill = DashWorkspaceHeaderRules.step(
    for: navigator.lastMutation,
    reduceMotion: false)
  #expect(drill.travel == .zero)
  #expect(drill.duration == DashTheme.Motion.Page.flowEnterDuration)
  #expect(drill.dampingRatio == DashTheme.Motion.Page.flowDampingRatio)
}

@MainActor
@Test func anArrivingPageHoldsTheLastTitleUntilItPublishesItsOwn() {
  let held = DashPageHeaderDescriptor(
    icon: .feature(.workers),
    title: "Workers",
    tint: DashTheme.brand)
  let arriving = DashNavigationEntry(destination: .worker("api"))

  // Mid-drill: the page is mounted but its chrome has not resolved yet. The
  // slot must keep the standing title, or every drill is remove → gap →
  // insert and the two parts never get a counterpart to morph against.
  let inFlight = DashWorkspaceHeaderRules.state(
    entry: arriving,
    chrome: nil,
    holdoverTitle: held,
    showsProfileControl: true,
    showsWatchtowerInbox: false,
    isEditingWatchtower: false)
  #expect(inFlight.title == held)
  // Actions never hold over — the previous page's Delete must not sit over
  // the page that replaced it.
  #expect(inFlight.trailing == .empty)
  #expect(inFlight.leading == .dismissal(.back))

  // "Has not spoken" and "has no title" are different answers: a screen that
  // publishes a header-less preference clears the slot for real.
  let titleless = DashWorkspaceHeaderRules.state(
    entry: arriving,
    chrome: DashPageChromePreference(),
    holdoverTitle: held,
    showsProfileControl: true,
    showsWatchtowerInbox: false,
    isEditingWatchtower: false)
  #expect(titleless.title == nil)

  // A root never holds anything over: leaving the stack empties the slot.
  let root = DashWorkspaceHeaderRules.state(
    entry: nil,
    chrome: nil,
    holdoverTitle: held,
    showsProfileControl: true,
    showsWatchtowerInbox: false,
    isEditingWatchtower: false)
  #expect(root.title == nil)
}

@MainActor
@Test func pageChromeLeavesTheStackWithItsPage() throws {
  let navigator = DestinationNavigator(chromeHosting: .workspace)
  navigator.reset(to: .feature(.zones))
  let featureEntry = try #require(navigator.topEntry)
  navigator.pageChrome.publish(
    DashPageChromePreference(
      header: DashPageHeaderDescriptor(
        icon: .feature(.zones),
        title: "Domains",
        tint: DashTheme.brand)),
    for: featureEntry.id)
  #expect(navigator.pageChrome.chrome(for: featureEntry.id)?.header?.title == "Domains")

  navigator.push(.zone("zone-1"))
  // The feature page is still in the stack, so its slots stay published.
  #expect(navigator.pageChrome.chrome(for: featureEntry.id) != nil)

  navigator.popToRoot()
  #expect(navigator.pageChrome.chrome(for: featureEntry.id) == nil)
  #expect(navigator.pageChrome.pages.isEmpty)
}

@MainActor
@Test func onlyWorkspaceHostedStacksHandTheirChromeToTheSharedHeader() {
  #expect(DestinationNavigator().chromeHosting == .page)
  #expect(
    DestinationNavigator(chromeHosting: .workspace).chromeHosting == .workspace)
}
