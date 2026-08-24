import CloudflareAPI
import Foundation
import SwiftUI
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

@Test func workspacePresentFadesTheDestinationCanvasOverTheWash() {
  let workspacePresent = DashDestinationCanvasRules.preparation(
    sourceShowsDestinationCanvas: false,
    targetShowsDestinationCanvas: true,
    fadesCoverWithTransition: true)
  #expect(!workspacePresent.isHidden)
  #expect(workspacePresent.alpha == 0)

  // Dismiss still starts covered so the animator can dissolve the plate away.
  let workspaceDismiss = DashDestinationCanvasRules.preparation(
    sourceShowsDestinationCanvas: true,
    targetShowsDestinationCanvas: false,
    fadesCoverWithTransition: false)
  #expect(!workspaceDismiss.isHidden)
  #expect(workspaceDismiss.alpha == 1)

  // A fade flag must not uncover a plate that is already covering a detail.
  let detailToWorkspace = DashDestinationCanvasRules.preparation(
    sourceShowsDestinationCanvas: true,
    targetShowsDestinationCanvas: true,
    fadesCoverWithTransition: true)
  #expect(!detailToWorkspace.isHidden)
  #expect(detailToWorkspace.alpha == 1)
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
@Test func resourcesDrillsHandOffAndOnlySemanticCardSourcesMorph() throws {
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

  let workerCardContent = FeatureResourceCardContent(
    kind: .workers,
    resourceID: "card-api",
    routeKey: "card-api",
    title: "card-api",
    metadata: .worker(
      modifiedOn: "2026-08-13T00:00:00Z",
      createdOn: "2026-01-01T00:00:00Z"))
  navigator.push(
    .worker("card-api"),
    origin: DashNavigationOrigin(
      semanticID: Destination.worker("card-api").dashNavigationSemanticID,
      anchorInstanceID: UUID(),
      sourceFrame: CGRect(x: 16, y: 240, width: 361, height: 92),
      hero: .featureResourceCard(accountID: "acc", content: workerCardContent)))
  let workerCard = try #require(navigator.topEntry)
  #expect(
    DashPageTransitionRules.role(
      presentation: workerCard.presentation,
      hasHero: workerCard.origin?.hero != nil) == .card)

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
        accountID: "acc",
        zoneID: "zone-2",
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

  navigator.push(.feature(.emailRouting))
  let emailFeature = try #require(navigator.topEntry)
  #expect(
    DashPageTransitionRules.role(
      presentation: emailFeature.presentation,
      hasHero: emailFeature.origin?.hero != nil) == .flow)

  // A DNS managed-record guard opens the same screen without a card source.
  navigator.push(.zoneEmailRouting("zone-3"))
  let plainEmail = try #require(navigator.topEntry)
  #expect(
    DashPageTransitionRules.role(
      presentation: plainEmail.presentation,
      hasHero: plainEmail.origin?.hero != nil) == .flow)

  navigator.push(
    .zoneEmailRouting("zone-4"),
    origin: DashNavigationOrigin(
      semanticID: Destination.zoneEmailRouting("zone-4").dashNavigationSemanticID,
      anchorInstanceID: UUID(),
      sourceFrame: CGRect(x: 200, y: 240, width: 176, height: 128),
      hero: .emailRoutingCard(
        accountID: "acc",
        zoneID: "zone-4",
        name: "mail.example",
        status: "Ready",
        seed: "mail.example",
        fillHex: 0xB8DDA8)))
  let emailCard = try #require(navigator.topEntry)
  #expect(
    DashPageTransitionRules.role(
      presentation: emailCard.presentation,
      hasHero: emailCard.origin?.hero != nil) == .card)

  navigator.push(.pagesProject("plain-site"))
  let plainPages = try #require(navigator.topEntry)
  #expect(
    DashPageTransitionRules.role(
      presentation: plainPages.presentation,
      hasHero: plainPages.origin?.hero != nil) == .flow)

  let pagesCardContent = FeatureResourceCardContent(
    kind: .pages,
    resourceID: "pages-card",
    routeKey: "marketing-site",
    title: "marketing-site",
    metadata: .pages(
      subdomain: "marketing-site.pages.dev",
      deploymentStatus: "success"))
  navigator.push(
    .pagesProject("marketing-site"),
    origin: DashNavigationOrigin(
      semanticID: Destination.pagesProject("marketing-site").dashNavigationSemanticID,
      anchorInstanceID: UUID(),
      sourceFrame: CGRect(x: 16, y: 352, width: 361, height: 92),
      hero: .featureResourceCard(accountID: "acc", content: pagesCardContent)))
  let pagesCard = try #require(navigator.topEntry)
  #expect(
    DashPageTransitionRules.role(
      presentation: pagesCard.presentation,
      hasHero: pagesCard.origin?.hero != nil) == .card)
}

@Test func navigationOriginCarriesSemanticCardContentWithoutRequiringPixels() {
  let hero = DashNavigationHero.domainCard(
    accountID: "acc",
    zoneID: "zone-1",
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

  let emailHero = DashNavigationHero.emailRoutingCard(
    accountID: "acc",
    zoneID: "zone-2",
    name: "mail.example",
    status: "Misconfigured",
    seed: "mail.example",
    fillHex: 0xA8D8D8)
  #expect(
    DashNavigationOrigin(
      semanticID: Destination.zoneEmailRouting("zone-2").dashNavigationSemanticID,
      anchorInstanceID: UUID(),
      hero: emailHero
    ).hero == emailHero)

  let resourceHero = DashNavigationHero.featureResourceCard(
    accountID: "acc",
    content: FeatureResourceCardContent(
      kind: .pages,
      resourceID: "site-id",
      routeKey: "site",
      title: "site",
      metadata: .pages(subdomain: "site.pages.dev", deploymentStatus: "active")))
  #expect(
    DashNavigationOrigin(
      semanticID: Destination.pagesProject("site").dashNavigationSemanticID,
      anchorInstanceID: UUID(),
      hero: resourceHero
    ).hero == resourceHero)
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

@Test func headerTrailingSeatIdentityTracksOrderedActionMembership() {
  let entryID = UUID()
  let pin = DashPageActionDescriptor.text(id: "pin", title: "Pin") {}
  let updatedPin = DashPageActionDescriptor.text(
    id: "pin", title: "Pinned", isEnabled: false
  ) {}
  let save = DashPageActionDescriptor.text(id: "save", title: "Save") {}
  let upload = DashPageActionDescriptor.text(id: "upload", title: "Upload") {}
  let more = DashPageActionDescriptor.text(id: "more", title: "More") {}
  let done = DashPageActionDescriptor.text(id: "done", title: "Done") {}

  let pinIdentity = DashWorkspaceHeaderTrailing.actions([pin])
    .slotID(entryID: entryID)
  // Label/enabled changes for one logical action update the standing control.
  #expect(
    pinIdentity
      == DashWorkspaceHeaderTrailing.actions([updatedPin])
      .slotID(entryID: entryID))
  // Replacing membership remounts the whole seat through dashSeatHandoff.
  #expect(
    pinIdentity
      != DashWorkspaceHeaderTrailing.actions([save])
      .slotID(entryID: entryID))
  #expect(
    DashWorkspaceHeaderTrailing.actions([upload, more])
      .slotID(entryID: entryID)
      != DashWorkspaceHeaderTrailing.actions([done])
      .slotID(entryID: entryID))
  // Order is visual membership too: the trailing-primary glass seat changes.
  #expect(
    DashWorkspaceHeaderTrailing.actions([upload, more])
      .slotID(entryID: entryID)
      != DashWorkspaceHeaderTrailing.actions([more, upload])
      .slotID(entryID: entryID))
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
        accountID: "acc",
        zoneID: "zone-1",
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
@Test func filteredEmailCardDismissalOverrideCanRestoreCardReturn() throws {
  func makeNavigator() throws -> (DestinationNavigator, DashNavigationEntry.ID) {
    let navigator = DestinationNavigator(chromeHosting: .workspace)
    navigator.push(
      .zoneEmailRouting("zone-mail"),
      origin: DashNavigationOrigin(
        semanticID: Destination.zoneEmailRouting("zone-mail").dashNavigationSemanticID,
        anchorInstanceID: UUID(),
        sourceFrame: CGRect(x: 16, y: 240, width: 176, height: 128),
        hero: .emailRoutingCard(
          accountID: "acc",
          zoneID: "zone-mail",
          name: "mail.example",
          status: "Ready",
          seed: "mail.example",
          fillHex: 0xB8DDA8)))
    return (navigator, try #require(navigator.topEntry?.id))
  }

  let (offNavigator, offEntryID) = try makeNavigator()
  offNavigator.setCardSourceDismissalUsesFlow(true, entryID: offEntryID)
  #expect(offNavigator.topEntry?.origin?.hero != nil)
  offNavigator.pop()

  #expect(offNavigator.topEntry == nil)
  #expect(offNavigator.lastMutation?.entry?.origin?.hero == nil)
  #expect(DashWorkspaceHeaderRules.role(for: offNavigator.lastMutation) == .flow)
  let step = DashWorkspaceHeaderRules.step(
    for: offNavigator.lastMutation,
    reduceMotion: false)
  #expect(step.duration == DashTheme.Motion.Page.flowExitDuration)
  #expect(step.dampingRatio == DashTheme.Motion.Page.flowDampingRatio)

  let (reenabledNavigator, reenabledEntryID) = try makeNavigator()
  reenabledNavigator.setCardSourceDismissalUsesFlow(true, entryID: reenabledEntryID)
  reenabledNavigator.setCardSourceDismissalUsesFlow(false, entryID: reenabledEntryID)
  reenabledNavigator.pop()

  #expect(reenabledNavigator.lastMutation?.entry?.origin?.hero != nil)
  #expect(DashWorkspaceHeaderRules.role(for: reenabledNavigator.lastMutation) == .card)
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

@Test func tabBarHideRulesRespectDepthAndOverlays() {
  // Any open tray displaces the dock so the card can slide up cleanly.
  #expect(
    shouldHideTabBar(
      overlays: DashTrayPresentation(presented: true), navigationDepth: 0))
  #expect(shouldHideTabBar(overlays: DashTrayPresentation(), navigationDepth: 1))
  #expect(
    shouldHideTabBar(
      overlays: DashTrayPresentation(presented: true), navigationDepth: 2))
  #expect(!shouldHideTabBar(overlays: DashTrayPresentation(), navigationDepth: 0))
}

@Test func sharedHeaderLeavesOnlyForACoveringPresentation() {
  // A push no longer displaces the header: it changes what the slots hold.
  #expect(
    shouldDisplaceWorkspaceHeader(overlays: DashTrayPresentation(presented: true)))
  #expect(!shouldDisplaceWorkspaceHeader(overlays: DashTrayPresentation()))
}

@Test func trayPresentationHasOneCompactState() {
  #expect(DashTrayPresentation(presented: true).presented)
  #expect(!DashTrayPresentation().presented)
}

@Test func navigatorAccountScopeWaitsForSignOutPresentationToFinish() {
  #expect(DashNavigatorAccountScopeRules.shouldSynchronize(during: .idle))
  #expect(!DashNavigatorAccountScopeRules.shouldSynchronize(during: .loading))
  #expect(!DashNavigatorAccountScopeRules.shouldSynchronize(during: .succeeded))
}

@Test func externalRoutesWaitForPresentationsAndAccountRoutingTransactions() {
  #expect(
    !DashRouteConsumptionRules.isBlocked(
      overlayPresented: false,
      coverPresented: false,
      awaitingAccountConfirmation: false,
      awaitingAccountSwitch: false,
      tabTransitionActive: false,
      pageTransitionActive: false))

  for blocker in 0..<6 {
    #expect(
      DashRouteConsumptionRules.isBlocked(
        overlayPresented: blocker == 0,
        coverPresented: blocker == 1,
        awaitingAccountConfirmation: blocker == 2,
        awaitingAccountSwitch: blocker == 3,
        tabTransitionActive: blocker == 4,
        pageTransitionActive: blocker == 5))
  }
}

@MainActor
@Test func destinationNavigatorPushPopAndReset() {
  let navigator = DestinationNavigator()
  #expect(navigator.depth == 0)
  #expect(navigator.top == nil)

  navigator.reset(to: .feature(.zones))
  #expect(navigator.depth == 1)
  #expect(navigator.top == .feature(.zones))

  navigator.push(.zone("z1"))
  #expect(navigator.depth == 2)
  #expect(navigator.top == .zone("z1"))

  navigator.popToRoot()
  #expect(navigator.depth == 0)
  #expect(navigator.top == nil)

  navigator.push(.feature(.workers))
  navigator.push(.worker("api"))
  navigator.reset()
  #expect(navigator.depth == 0)
}

@MainActor
@Test func destinationNavigatorKeepsStablePageInstanceIdentity() throws {
  let navigator = DestinationNavigator()
  let firstRootID = try #require(
    navigator.push(.r2Bucket("media", prefix: "")))
  let folderID = try #require(
    navigator.push(.r2Bucket("media", prefix: "images/")))

  #expect(firstRootID != folderID)
  #expect(navigator.contains(entryID: firstRootID))
  #expect(navigator.contains(entryID: folderID))
  #expect(navigator.push(.r2Bucket("media", prefix: "images/")) == nil)

  navigator.pop()
  #expect(navigator.contains(entryID: firstRootID))
  #expect(!navigator.contains(entryID: folderID))

  let secondRootID = try #require(
    navigator.push(.r2Bucket("media", prefix: "images/")))
  navigator.push(.r2Bucket("media", prefix: ""))
  #expect(navigator.topEntry?.id != firstRootID)
  #expect(navigator.topEntry?.id != secondRootID)
}

@MainActor
@Test func destinationNavigatorCarriesWorkspacePresentationContract() throws {
  let navigator = DestinationNavigator(accountID: "account-1")
  navigator.reset(
    to: .settings,
    presentation: .workspaceOverlay)

  let firstEntry = try #require(navigator.topEntry)
  #expect(firstEntry.presentation == .workspaceOverlay)
  #expect(firstEntry.dismissal == .closeToWorkspaceRoot)
  #expect(firstEntry.accountID == "account-1")

  navigator.reset(
    to: .settings,
    presentation: .workspaceOverlay)
  #expect(navigator.topEntry?.id != firstEntry.id)

  navigator.dismissTop()
  #expect(navigator.depth == 0)
  #expect(navigator.lastMutation?.reason == .closeToWorkspaceRoot)
}

@MainActor
@Test func destinationNavigatorDismissesOnlyTheEmittingPageInstance() throws {
  let navigator = DestinationNavigator()
  let settingsID = try #require(navigator.push(.settings))
  let profileID = try #require(navigator.push(.profile))

  navigator.dismiss(entryID: settingsID)
  #expect(navigator.entryIDs == [settingsID, profileID])

  navigator.dismiss(entryID: profileID)
  #expect(navigator.entryIDs == [settingsID])

  // A duplicate delivery from the removed page cannot dismiss Settings too.
  navigator.dismiss(entryID: profileID)
  #expect(navigator.entryIDs == [settingsID])
}

@MainActor
@Test func destinationNavigatorDefaultsSemanticPresentationByRouteShape() throws {
  let navigator = DestinationNavigator()
  // Every drill is a detail page. Settings is the one workspace-level route,
  // and the card morph is a property of the source, not of the destination.
  navigator.push(.feature(.workers))
  #expect(navigator.topEntry?.presentation == .detail)

  navigator.push(.zone("zone-1"))
  #expect(navigator.topEntry?.presentation == .detail)

  navigator.push(.dns("zone-1"))
  #expect(navigator.topEntry?.presentation == .detail)

  navigator.push(.r2Bucket("media", prefix: ""))
  #expect(navigator.topEntry?.presentation == .detail)

  navigator.push(.r2Bucket("media", prefix: "images/"))
  #expect(navigator.topEntry?.presentation == .detail)

  navigator.reset(to: .settings)
  let settings = try #require(navigator.topEntry)
  #expect(settings.presentation == .workspaceOverlay)
  #expect(settings.dismissal == .closeToWorkspaceRoot)
}

@MainActor
@Test func destinationNavigatorPrunesResourceOwnershipAtomically() throws {
  let navigator = DestinationNavigator()
  let featureID = try #require(navigator.push(.feature(.r2)))
  navigator.push(.r2Bucket("media", prefix: ""))
  navigator.push(.r2Bucket("media", prefix: "images/"))
  let unrelatedID = try #require(navigator.push(.about))

  navigator.removeAll(ownedBy: .r2Bucket("media"))

  #expect(navigator.path == [.feature(.r2), .about])
  #expect(navigator.entryIDs == [featureID, unrelatedID])
}

@MainActor
@Test func destinationNavigatorInvalidatesEntriesWhenAccountScopeChanges() throws {
  let navigator = DestinationNavigator(accountID: "account-1")
  navigator.push(.zone("zone-1"))
  #expect(navigator.topEntry?.accountID == "account-1")

  navigator.setAccountScope("account-2")
  #expect(navigator.depth == 0)
  #expect(navigator.lastMutation?.reason == .accountScopeChanged)

  navigator.push(.zone("zone-2"))
  let entry = try #require(navigator.topEntry)
  #expect(entry.accountID == "account-2")
  #expect(navigator.lastMutation?.reason == .push)
}

@MainActor
@Test func destinationNavigatorRecordsMonotonicMutationRevisions() {
  let navigator = DestinationNavigator()
  navigator.reset(to: .feature(.zones))
  let resetRevision = navigator.revision
  #expect(navigator.lastMutation?.reason == .reset)

  navigator.push(.zone("zone-1"))
  #expect(navigator.revision > resetRevision)
  #expect(navigator.lastMutation?.reason == .push)

  let pushRevision = navigator.revision
  navigator.pop()
  #expect(navigator.revision > pushRevision)
  #expect(navigator.lastMutation?.reason == .back)
}

@MainActor
@Test func navigationCoordinatorPrunesEveryTabNavigator() {
  let home = DestinationNavigator()
  let resources = DestinationNavigator()
  let watchtower = DestinationNavigator()
  let coordinator = DashNavigationCoordinator()
  coordinator.configure(navigators: [home, resources, watchtower])

  home.push(.r2Bucket("media", prefix: ""))
  resources.push(.feature(.r2))
  resources.push(.r2Bucket("media", prefix: "images/"))
  watchtower.push(.about)

  coordinator.removeAll(ownedBy: .r2Bucket("media"))

  #expect(home.depth == 0)
  #expect(resources.path == [.feature(.r2)])
  #expect(watchtower.path == [.about])
  #expect(resources.lastMutation?.reason == .resourcePruned(.r2Bucket("media")))
}

@MainActor
@Test func navigationAnchorRegistryResolvesTheConcreteSourceOccurrence() throws {
  let registry = DashNavigationAnchorRegistry()
  let visibleAnchorID = UUID()
  let staleAnchorID = UUID()
  let hostedFrame = CGRect(x: 20, y: 64, width: 48, height: 48)
  registry.setHostedFrame(hostedFrame, for: visibleAnchorID)

  let semanticID = DashNavigationSemanticID(
    namespace: "workspace-header",
    value: "profile-avatar")
  let visibleOrigin = registry.captureOrigin(
    semanticID: semanticID,
    anchorInstanceID: visibleAnchorID)
  let staleOrigin = DashNavigationOrigin(
    semanticID: semanticID,
    anchorInstanceID: staleAnchorID)

  #expect(registry.frame(for: visibleOrigin) == hostedFrame)
  #expect(registry.liveFrame(for: visibleOrigin) == nil)

  // Claim state reaches ONLY the registered occurrence's own box — that is
  // what keeps one card morph from invalidating every anchor on screen.
  let claim = DashNavigationAnchorClaim()
  let neighbour = DashNavigationAnchorClaim()
  registry.registerClaim(claim, for: visibleAnchorID)
  registry.registerClaim(neighbour, for: staleAnchorID)
  #expect(!claim.isClaimed)
  registry.claim(visibleOrigin)
  #expect(claim.isClaimed)
  #expect(!neighbour.isClaimed)

  // A claimed occurrence that remounts mid-flight re-arms from the registry
  // instead of coming back visible and doubling the element in flight.
  let remounted = DashNavigationAnchorClaim()
  registry.registerClaim(remounted, for: visibleAnchorID)
  #expect(remounted.isClaimed)

  registry.release(visibleOrigin)
  #expect(!remounted.isClaimed)

  // The stale box no longer owns the key, so unregistering it is a no-op.
  registry.unregisterClaim(claim, for: visibleAnchorID)
  registry.claim(visibleOrigin)
  #expect(remounted.isClaimed)

  registry.removeHostedFrame(for: visibleAnchorID)
  #expect(registry.frame(for: visibleOrigin) == hostedFrame)
  #expect(registry.frame(for: staleOrigin) == nil)
}

@MainActor
@Test func navigationAnchorRegistryFollowsAResortedSourceOccurrence() throws {
  let registry = DashNavigationAnchorRegistry()
  let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
  let container = UIView(frame: window.bounds)
  window.addSubview(container)

  let zoneSemantic = Destination.zone("zone-1").dashNavigationSemanticID
  let neighbourSemantic = Destination.zone("zone-2").dashNavigationSemanticID
  let originalID = UUID()
  let movedID = UUID()
  let originalSlot = UIView(frame: CGRect(x: 16, y: 400, width: 176, height: 128))
  let movedSlot = UIView(frame: CGRect(x: 16, y: 120, width: 176, height: 128))
  container.addSubview(originalSlot)
  container.addSubview(movedSlot)
  registry.registerSourceView(originalSlot, semanticID: zoneSemantic, for: originalID)
  registry.registerSourceView(movedSlot, semanticID: neighbourSemantic, for: movedID)

  let origin = DashNavigationOrigin(
    semanticID: zoneSemantic,
    anchorInstanceID: originalID)

  // The slot still shows the pushed zone: the pop keeps the exact occurrence.
  #expect(
    registry.currentSourceOrigin(for: origin, within: container)?
      .anchorInstanceID == originalID)

  // The covered grid re-sorted (a pin from zone detail): slot UUIDs are
  // positional, so the captured instance now paints ANOTHER zone while the
  // pushed zone's card lives in a different slot. The flight must follow it.
  registry.registerSourceView(originalSlot, semanticID: neighbourSemantic, for: originalID)
  registry.registerSourceView(movedSlot, semanticID: zoneSemantic, for: movedID)
  let retargeted = registry.currentSourceOrigin(for: origin, within: container)
  #expect(retargeted?.anchorInstanceID == movedID)
  #expect(retargeted?.semanticID == zoneSemantic)

  // No live occurrence shows the zone any more (unpinned below the fold, a
  // lazy slot never mounted): no seat, and the caller falls back to flow.
  registry.registerSourceView(movedSlot, semanticID: neighbourSemantic, for: movedID)
  #expect(registry.currentSourceOrigin(for: origin, within: container) == nil)

  // An occurrence outside the revealed page (a Home row for the same zone)
  // must never pull the flight across pages.
  let elsewhere = UIView(frame: CGRect(x: 16, y: 0, width: 176, height: 128))
  window.addSubview(elsewhere)
  registry.registerSourceView(elsewhere, semanticID: zoneSemantic, for: UUID())
  #expect(registry.currentSourceOrigin(for: origin, within: container) == nil)
}

@Test func domainCardSeatMorphRecognizesGridAspectAndLerpsRect() {
  let grid = CGRect(x: 20, y: 100, width: 160, height: 128)  // 5:4
  let hero = CGRect(x: 16, y: 120, width: 360, height: 216)  // 5:3
  #expect(abs(grid.width / grid.height - DomainCardFace.gridAspectRatio) < 0.01)
  #expect(abs(hero.width / hero.height - DomainCardFace.detailAspectRatio) < 0.01)
  #expect(
    DomainCardFace.detailAspectRatio(for: .large) == DomainCardFace.detailAspectRatio)
  #expect(
    DomainCardFace.detailAspectRatio(for: .accessibility1)
      == DomainCardFace.gridAspectRatio)
  // Which sources fly is not a frame heuristic — a tap either hands over a
  // `DashNavigationHero` or it is a flow drill (`DashPageTransitionRules`).

  let mid = CGRect(
    x: grid.minX + (hero.minX - grid.minX) * 0.5,
    y: grid.minY + (hero.minY - grid.minY) * 0.5,
    width: grid.width + (hero.width - grid.width) * 0.5,
    height: grid.height + (hero.height - grid.height) * 0.5)
  #expect(abs(mid.width - 260) < 0.01)
  #expect(abs(mid.height - 172) < 0.01)
}

@Test func cardDetailLandingSemanticsMatchTheirDestinations() {
  let destination = Destination.zone("zone-abc")
  #expect(
    destination.dashNavigationLandingSemanticID
      == DashNavigationSemanticID(namespace: "zone-hero", value: "zone-abc"))
  let emailDestination = Destination.zoneEmailRouting("zone-abc")
  #expect(
    emailDestination.dashNavigationLandingSemanticID
      == DashNavigationSemanticID(namespace: "zone-email-routing-hero", value: "zone-abc"))
  #expect(
    emailDestination.dashNavigationLandingSemanticID
      != destination.dashNavigationLandingSemanticID)
  #expect(
    Destination.worker("api").dashNavigationLandingSemanticID
      == DashNavigationSemanticID(namespace: "worker-hero", value: "api"))
  #expect(
    Destination.pagesProject("site").dashNavigationLandingSemanticID
      == DashNavigationSemanticID(namespace: "pages-project-hero", value: "site"))
  #expect(
    Destination.worker("api").dashNavigationLandingSemanticID
      != Destination.pagesProject("api").dashNavigationLandingSemanticID)
  // Seat overlay eligibility: only routes that name a landing can fly a card.
  #expect(Destination.about.dashNavigationLandingSemanticID == nil)
  #expect(Destination.feature(.zones).dashNavigationLandingSemanticID == nil)
}

@Test func fullWidthResourceCardHandoffMovesWithoutGrowing() {
  let source = CGRect(x: 16, y: 430, width: 361, height: 92)
  let landing = CGRect(x: 16, y: 118, width: 361, height: 92)
  let midpoint = DashCardMorphRules.heroFrame(
    from: source,
    to: landing,
    detailProgress: 0.5)
  #expect(midpoint.width == source.width)
  #expect(midpoint.height == source.height)
  #expect(midpoint.minX == source.minX)
  #expect(midpoint.minY == 274)
}

@Test func featureResourceLandingPinsCapturedThenAdoptsLatest() {
  let captured = FeatureResourceCardContent(
    kind: .pages,
    resourceID: "project-id",
    routeKey: "site",
    title: "site",
    metadata: .pages(subdomain: "old.pages.dev", deploymentStatus: "active"))
  let latest = FeatureResourceCardContent(
    kind: .pages,
    resourceID: "project-id",
    routeKey: "site",
    title: "site",
    metadata: .pages(subdomain: "new.pages.dev", deploymentStatus: "success"))
  let fallback = FeatureResourceCardContent(
    kind: .pages,
    resourceID: "site",
    routeKey: "site",
    title: "site",
    metadata: .pages(subdomain: nil, deploymentStatus: nil))

  #expect(
    FeatureResourceCardLandingRules.content(
      transitionActive: true,
      captured: captured,
      latest: latest,
      fallback: fallback) == captured)
  #expect(
    FeatureResourceCardLandingRules.content(
      transitionActive: false,
      captured: captured,
      latest: latest,
      fallback: fallback) == latest)
  #expect(
    FeatureResourceCardLandingRules.content(
      transitionActive: false,
      captured: captured,
      latest: nil,
      fallback: fallback) == captured)
}

@Test @MainActor func featureResourceReturnHeroUsesNewestAccountScopedSnapshot() throws {
  let cache = FeatureDataCache()
  let listProject = try decodedPagesProject(
    id: "project-id", name: "site", subdomain: "list.pages.dev", status: "active")
  let detailProject = try decodedPagesProject(
    id: "project-id", name: "site", subdomain: "detail.pages.dev", status: "success")
  let refreshedListProject = try decodedPagesProject(
    id: "project-id", name: "site", subdomain: "new-list.pages.dev", status: "failure")
  cache.set(
    FeatureCacheKey.pagesProjects("account-a"), [listProject],
    fetchedAt: Date(timeIntervalSince1970: 100), ttl: nil)
  cache.set(
    FeatureCacheKey.pagesProject(accountID: "account-a", name: "site"), detailProject,
    fetchedAt: Date(timeIntervalSince1970: 200), ttl: nil)

  #expect(
    PagesResourceCardCache.latestProject(
      accountID: "account-a", projectName: "site", cache: cache) == detailProject)
  let captured = DashNavigationHero.featureResourceCard(
    accountID: "account-a",
    content: pagesResourceCardContent(listProject))
  let detailHero = DashNavigationHero.featureResourceCard(
    accountID: "account-a",
    content: pagesResourceCardContent(detailProject))
  #expect(captured.returnCacheResolution(from: cache) == .replace(detailHero))

  cache.set(
    FeatureCacheKey.pagesProjects("account-a"), [refreshedListProject],
    fetchedAt: Date(timeIntervalSince1970: 300), ttl: nil)
  #expect(
    PagesResourceCardCache.latestProject(
      accountID: "account-a", projectName: "site", cache: cache) == refreshedListProject)
  let listHero = DashNavigationHero.featureResourceCard(
    accountID: "account-a",
    content: pagesResourceCardContent(refreshedListProject))
  #expect(captured.returnCacheResolution(from: cache) == .replace(listHero))

  let otherAccount = DashNavigationHero.featureResourceCard(
    accountID: "account-b",
    content: pagesResourceCardContent(listProject))
  #expect(otherAccount.returnCacheResolution(from: cache) == .preserveCaptured)

  let oldWorker = try decodedWorkerScript(
    id: "api", modifiedOn: "2026-08-10T00:00:00Z")
  let newWorker = try decodedWorkerScript(
    id: "api", modifiedOn: "2026-08-13T00:00:00Z")
  let workerHero = DashNavigationHero.featureResourceCard(
    accountID: "account-a",
    content: workerResourceCardContent(oldWorker))
  #expect(workerHero.returnCacheResolution(from: cache) == .preserveCaptured)
  cache.set(FeatureCacheKey.workers("account-a"), [newWorker], ttl: nil)
  #expect(
    workerHero.returnCacheResolution(from: cache)
      == .replace(
        .featureResourceCard(
          accountID: "account-a",
          content: workerResourceCardContent(newWorker))))
}

@Test @MainActor func featureResourceCardInkClearsContrastAcrossTraitsAndWatermark() throws {
  for kind in [FeatureResourceCardKind.workers, .pages] {
    for style in [UIUserInterfaceStyle.light, .dark] {
      for contrast in [UIAccessibilityContrast.normal, .high] {
        let traits = UITraitCollection(traitsFrom: [
          UITraitCollection(userInterfaceStyle: style),
          UITraitCollection(accessibilityContrast: contrast),
        ])
        let canvas = try #require(testRGBA(UIColor(DashTheme.canvas), traits: traits))
        let fill = try #require(
          testRGBA(
            UIColor(FeatureResourceCardPalette.fill(for: kind)),
            traits: traits))
        let foreground = try #require(
          testRGBA(
            UIColor(FeatureResourceCardPalette.foreground(for: kind)),
            traits: traits))
        let texture = try #require(
          testRGBA(
            UIColor(FeatureResourceCardPalette.texture(for: kind)),
            traits: traits))
        let base = testComposite(fill, over: canvas)
        let watermarked = testComposite(texture, opacity: 0.1, over: base)
        #expect(testContrastRatio(foreground, base) >= 4.5)
        #expect(testContrastRatio(foreground, watermarked) >= 4.5)
        if kind == .workers {
          let white = try #require(testRGBA(UIColor.white, traits: traits))
          let brightestGrain = testRGBOffset(base, amount: 0.055 / 2)
          let brightestTopSheen = testComposite(
            white,
            opacity: style == .dark ? 0.12 : 0.18,
            over: brightestGrain
          )
          #expect(testContrastRatio(foreground, brightestTopSheen) >= 4.5)
          #expect(
            FeatureResourceCardPalette.foregroundHex(
              for: kind,
              interfaceStyle: style,
              accessibilityContrast: contrast
            ) == 0xFFFFFF
          )
          #expect(
            FeatureResourceCardPalette.textureHex(
              for: kind,
              interfaceStyle: style,
              accessibilityContrast: contrast
            ) == 0x0A0A0A
          )
        }
      }
    }
  }
}

@MainActor
@Test func pageChromePreferencesMergeOuterHeaderWithInnerActions() {
  var preference = DashPageChromePreference()
  DashPageChromePreferenceKey.reduce(value: &preference) {
    DashPageChromePreference(
      header: DashPageHeaderDescriptor(
        icon: .solar("header"),
        title: "Domains",
        tint: .blue))
  }
  DashPageChromePreferenceKey.reduce(value: &preference) {
    DashPageChromePreference(
      trailingActions: [
        .icon(
          id: "add",
          asset: SolarAsset.plus,
          accessibilityLabel: "Add"
        ) {}
      ])
  }

  #expect(preference.header?.title == "Domains")
  #expect(preference.trailingActions.map(\.id) == ["add"])
}

@MainActor
@Test func workspacePresentationStateClearsRemovedEntryReporters() {
  let state = DashWorkspacePresentationState()
  let entryID = UUID()
  state.setTrayPresented(true, reporterID: UUID(), entryID: entryID)
  state.setCoverPresented(true, reporterID: UUID(), entryID: entryID)
  state.setTrayPresented(false, reporterID: UUID(), entryID: UUID())
  #expect(state.trayPresented)
  #expect(state.coverPresented)

  state.removePresentationReporters(forEntryID: entryID)
  #expect(!state.trayPresented)
  #expect(!state.coverPresented)
}

private struct TestRGBA {
  let red: Double
  let green: Double
  let blue: Double
  let alpha: Double
}

private func testRGBA(_ color: UIColor, traits: UITraitCollection) -> TestRGBA? {
  var red: CGFloat = 0
  var green: CGFloat = 0
  var blue: CGFloat = 0
  var alpha: CGFloat = 0
  guard
    color.resolvedColor(with: traits).getRed(
      &red, green: &green, blue: &blue, alpha: &alpha)
  else { return nil }
  return TestRGBA(
    red: Double(red),
    green: Double(green),
    blue: Double(blue),
    alpha: Double(alpha))
}

private func testComposite(
  _ foreground: TestRGBA,
  opacity: Double = 1,
  over background: TestRGBA
) -> TestRGBA {
  let alpha = foreground.alpha * opacity
  let outputAlpha = alpha + background.alpha * (1 - alpha)
  guard outputAlpha > 0 else {
    return TestRGBA(red: 0, green: 0, blue: 0, alpha: 0)
  }
  func channel(_ foreground: Double, _ background: Double) -> Double {
    (foreground * alpha + background * background.alpha * (1 - alpha)) / outputAlpha
  }
  return TestRGBA(
    red: channel(foreground.red, background.red),
    green: channel(foreground.green, background.green),
    blue: channel(foreground.blue, background.blue),
    alpha: outputAlpha)
}

private func testRGBOffset(_ color: TestRGBA, amount: Double) -> TestRGBA {
  TestRGBA(
    red: min(1, max(0, color.red + amount)),
    green: min(1, max(0, color.green + amount)),
    blue: min(1, max(0, color.blue + amount)),
    alpha: color.alpha)
}

private func testContrastRatio(_ first: TestRGBA, _ second: TestRGBA) -> Double {
  func luminance(_ color: TestRGBA) -> Double {
    func linearized(_ component: Double) -> Double {
      component <= 0.04045
        ? component / 12.92
        : pow((component + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linearized(color.red)
      + 0.7152 * linearized(color.green)
      + 0.0722 * linearized(color.blue)
  }
  let firstLuminance = luminance(first)
  let secondLuminance = luminance(second)
  return (max(firstLuminance, secondLuminance) + 0.05)
    / (min(firstLuminance, secondLuminance) + 0.05)
}

private func decodedPagesProject(
  id: String,
  name: String,
  subdomain: String,
  status: String
) throws -> PagesProject {
  try JSONDecoder().decode(
    PagesProject.self,
    from: Data(
      """
      {
        "id":"\(id)",
        "name":"\(name)",
        "subdomain":"\(subdomain)",
        "latest_deployment":{
          "id":"deployment",
          "latest_stage":{"name":"deploy","status":"\(status)"}
        }
      }
      """.utf8))
}

private func decodedWorkerScript(id: String, modifiedOn: String) throws -> WorkerScript {
  try JSONDecoder().decode(
    WorkerScript.self,
    from: Data(
      """
      {"id":"\(id)","modified_on":"\(modifiedOn)"}
      """.utf8))
}
