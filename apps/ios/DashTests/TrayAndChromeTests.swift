import CloudflareAPI
import CoreText
import SwiftUI
import Testing
import UIKit

@testable import Dash

@Test func compactTrayDragDecisionUsesOriginalProjectionThresholds() {
  #expect(
    TrayDragDecision.content(translation: 40, predictedEndTranslation: 40) == .settle)
  #expect(
    TrayDragDecision.content(translation: 120, predictedEndTranslation: 120) == .settle)
  #expect(
    TrayDragDecision.content(translation: 121, predictedEndTranslation: 121) == .dismiss)
  #expect(
    TrayDragDecision.content(translation: 32, predictedEndTranslation: 161) == .dismiss)
  #expect(
    TrayDragDecision.content(translation: 31, predictedEndTranslation: 1_000) == .settle)
}

@Test func compactTrayUpwardDragUsesOriginalFixedFrictionRubberBand() {
  #expect(TrayDragDecision.rubberBand(cardTop: -100, expandedTop: 0) == -15)
  #expect(TrayDragDecision.rubberBand(cardTop: 42, expandedTop: 0) == 42)
}

@Test func compactTrayKeepsOriginalShellTokens() {
  #expect(DashTheme.Sheet.floatingMargin == 12)
  #expect(DashTheme.Sheet.floatingBottomTuck == 6)
  #expect(DashTheme.Sheet.scrimOpacity == 0.18)
  #expect(DashTheme.Sheet.scrimMaterialOpacity == 0.55)
}

@Test func compactTrayUsesSpringOnlyForPresentation() {
  #expect(DashTheme.Motion.Tray.presentResponse == 0.21)
  #expect(DashTheme.Motion.Tray.presentDampingFraction == 0.8)
}

@Test func compactTrayBottomLiftClearsHomeIndicatorUsingWindowSafeInset() {
  // The tray GeometryReader ignores the container bottom edge, so a proxy safe
  // of 0 must not be what decides resting lift — that path left the card at
  // floatingMargin (12) inside the home-indicator region forever.
  #expect(DashTrayBottomLiftRules.padding(safeBottom: 0, keyboardCovered: 0) == 12)
  #expect(DashTrayBottomLiftRules.padding(safeBottom: 34, keyboardCovered: 0) == 28)
  #expect(DashTrayBottomLiftRules.padding(safeBottom: 34, keyboardCovered: 300) == 312)
}

@Test func profileTrayPhaseTitlesStayLocalizedCatalogKeys() {
  #expect(ProfileTrayPhase.initial == .accounts)
  #expect(ProfileTrayPhase.accounts.title == "Switch account")
  #expect(ProfileTrayPhase.signOut.title == "Sign out")
}

@Test func profileTrayPhaseMapsRoutesToSemanticRoles() throws {
  let account = try JSONDecoder().decode(
    CloudflareAccount.self,
    from: Data(#"{"id":"account-1","name":"Example"}"#.utf8)
  )

  #expect(ProfileTrayPhase.accounts.trayRole == .root)
  #expect(ProfileTrayPhase.switchAccount(account).trayRole == .detail)
  #expect(ProfileTrayPhase.signOut.trayRole == .destructive)
}

@Test func settingsSignOutTrayStartsAtConfirmation() {
  // The Settings row is the first tap, so its tray must not repeat Sign out as
  // an intermediate menu choice before presenting the destructive decision.
  #expect(SignOutTrayStep.initial == .confirm)
  #expect(SignOutTrayStep.confirm.trayRole == .destructive)
  #expect(ProfileTrayPhase.signOut.trayRole == SignOutTrayStep.confirm.trayRole)
}

@Test @MainActor func trayFlowStackDrivesRouteAndRoleFromThePathTail() throws {
  let account = try JSONDecoder().decode(
    CloudflareAccount.self,
    from: Data(#"{"id":"account-1","name":"Example"}"#.utf8)
  )
  var path: [ProfileTrayPhase] = []
  let binding = Binding(get: { path }, set: { path = $0 })

  let atRoot = DashTrayFlow(root: .accounts, path: binding, role: \.trayRole) { _ in
    EmptyView()
  }
  #expect(atRoot.route == .accounts)
  #expect(atRoot.role == .root)
  #expect(atRoot.transitionStyle == .step)

  path = [.switchAccount(account), .signOut]
  let pushed = DashTrayFlow(
    root: .accounts,
    path: binding,
    role: \.trayRole,
    transitionStyle: .heroMorph
  ) { _ in EmptyView() }
  #expect(pushed.route == .signOut)
  #expect(pushed.role == .destructive)
  #expect(pushed.transitionStyle == .heroMorph)
}

@Test func sheetHeaderActionsDefaultToTheDestructiveCircle() {
  // Every pre-tone header action was the fixed danger circle; the tone work
  // must not silently recolor them. Only an explicit non-destructive role
  // opts an action into `\.dashTrayTone`.
  let action = DashSheetHeaderAction(
    id: "delete", icon: "TrashBinTrashOutline", accessibilityLabel: "Delete"
  ) {}
  #expect(action.role == .destructive)
}

@Test func morphingLabelSegmentsShareCharacterAffixes() {
  // Family's Continue → Confirm: the shared "Con" stays planted.
  let verb = DashMorphingLabelSegments(from: "Continue", to: "Confirm")
  #expect(verb.prefix == "Con")
  #expect(verb.changed == "firm")
  #expect(verb.suffix.isEmpty)

  // A count appearing after a stable verb — only the count run morphs.
  let count = DashMorphingLabelSegments(from: "Delete", to: "Delete 3")
  #expect(count.prefix == "Delete")
  #expect(count.changed == " 3")
  #expect(count.suffix.isEmpty)

  // Character-level diffing keeps CJK affixes intact around the number.
  let cjk = DashMorphingLabelSegments(from: "删除 3 个对象", to: "删除 12 个对象")
  #expect(cjk.prefix == "删除 ")
  #expect(cjk.changed == "12")
  #expect(cjk.suffix == " 个对象")

  // The prefix and suffix scans must never claim the same characters.
  let overlap = DashMorphingLabelSegments(from: "aa", to: "aba")
  #expect(overlap.prefix == "a")
  #expect(overlap.changed == "b")
  #expect(overlap.suffix == "a")

  // Rebuilding the segments always yields the new string verbatim.
  for split in [verb, count, cjk, overlap] {
    #expect(split.joined == split.prefix + split.changed + split.suffix)
  }
  #expect(cjk.joined == "删除 12 个对象")

  // Resting state: everything is the changeable run, so the first morph can
  // keep whatever the next string happens to share.
  let resting = DashMorphingLabelSegments(text: "Delete")
  #expect(resting.prefix.isEmpty)
  #expect(resting.changed == "Delete")
  #expect(resting.suffix.isEmpty)
}

@Test func accentTrayPillsKeepDarkInkOnTheOrangeFill() {
  // Adaptive `inverse` is near-white in light mode — ~2.4:1 on brand orange
  // `#F6821F` — so `.accent` (the R2 / storage tray tone) pins its submit-pill
  // label near-black instead. Every other tone keeps the adaptive pair.
  #expect(FeatureVisualTone.accent.vividLabel == Color(hex: 0x171717))
  #expect(FeatureVisualTone.success.vividLabel == DashTheme.inverse)
  #expect(FeatureVisualTone.brand.vividLabel == DashTheme.inverse)
}

@Test func trayBackActionEqualityIsDepthOnly() {
  var performed = 0
  let first = DashTrayBackAction(depth: 1) { performed += 1 }
  let sameDepth = DashTrayBackAction(depth: 1) {}
  let deeper = DashTrayBackAction(depth: 2) {}

  #expect(first == sameDepth)
  #expect(first != deeper)
  first.perform()
  #expect(performed == 1)
}

@Test func traySharedRevealInterpolatesOnlyShellGeometry() {
  let card = CGRect(x: 20, y: 400, width: 350, height: 300)
  let actionHeight = DashTheme.Layout.actionPillHeight
  let source = CGRect(x: 24, y: 620, width: 345, height: actionHeight)

  #expect(DashTraySharedRevealMath.rect(from: source, to: card, progress: 0) == source)
  #expect(DashTraySharedRevealMath.rect(from: source, to: card, progress: 1) == card)

  let midpoint = DashTraySharedRevealMath.rect(from: source, to: card, progress: 0.5)
  #expect(midpoint.origin.x == 22)
  #expect(midpoint.origin.y == 510)
  #expect(midpoint.width == 347.5)
  #expect(midpoint.height == (source.height + card.height) / 2)

  // Shared actions use the same fixed-height face at both endpoints; rect
  // interpolation therefore moves the control without distorting its content.
  let destination = CGRect(x: 24, y: 636, width: 345, height: actionHeight)
  let actionMidpoint = DashTraySharedRevealMath.rect(
    from: source, to: destination, progress: 0.5)
  #expect(actionMidpoint.height == DashTheme.Layout.actionPillHeight)

  #expect(DashTraySharedRevealMath.stage(0.24, from: 0.24, to: 0.62) == 0)
  #expect(DashTraySharedRevealMath.stage(0.62, from: 0.24, to: 0.62) == 1)
}

@Test func trayScrollBoundaryPaysForTheActionBandBeforeTheBody() {
  // Fits: the body keeps its natural height and nothing scrolls.
  #expect(
    DashTrayScrollBoundaryRules.bodyHeight(ideal: 200, action: 68, available: 500) == 200)

  // Outgrows the card: the band is paid for first and the body takes the rest,
  // so the two together fill the budget exactly — the card's own body scroll
  // stays inert and this one owns the finger.
  #expect(
    DashTrayScrollBoundaryRules.bodyHeight(ideal: 900, action: 68, available: 500) == 432)

  // Squeezed past the floor (a tall band under a raised keyboard): the body
  // stops shrinking, the card overflows, and its scroll takes over.
  #expect(
    DashTrayScrollBoundaryRules.bodyHeight(ideal: 900, action: 460, available: 500)
      == DashTrayScrollBoundaryRules.minimumBody)

  // No budget (outside a tray) and no measurement yet (first frame) both mean
  // "lay out naturally" — never a zero-height region.
  #expect(DashTrayScrollBoundaryRules.bodyHeight(ideal: 900, action: 68, available: nil) == nil)
  #expect(DashTrayScrollBoundaryRules.bodyHeight(ideal: 0, action: 68, available: 500) == nil)
}

@Test func trayMeasuredHeightIgnoresSubPointChatter() {
  #expect(DashTrayMeasuredHeight.shouldCommit(200, 200.4) == false)
  #expect(DashTrayMeasuredHeight.shouldCommit(200, 200.6) == true)
  #expect(DashTrayMeasuredHeight.shouldCommit(0, 120) == true)
  #expect(DashTrayMeasuredHeight.shouldCommit(120, .nan) == false)
  #expect(DashTrayMeasuredHeight.shouldCommit(120, -1) == false)
}

@Test @MainActor func trayAnchorSourcesMustBeOnScreenAndControlSized() {
  let bounds = CGRect(x: 0, y: 0, width: 393, height: 852)

  // A full-width primary pill: eligible as one endpoint of a paired action.
  #expect(
    DashTraySourceRegistry.isPresentableSource(
      CGRect(
        x: 24, y: 620, width: 345, height: DashTheme.Layout.actionPillHeight),
      in: bounds))

  // Scrolled fully off screen, collapsed, or oversized (a scroll container or
  // near-full-screen surface would read as a zoom glitch): bottom reveal.
  #expect(
    !DashTraySourceRegistry.isPresentableSource(
      CGRect(x: 16, y: -400, width: 120, height: 90), in: bounds))
  #expect(
    !DashTraySourceRegistry.isPresentableSource(
      CGRect(x: 16, y: 300, width: 0, height: 0), in: bounds))
  #expect(
    !DashTraySourceRegistry.isPresentableSource(
      CGRect(x: 0, y: 0, width: 393, height: 852), in: bounds))
  #expect(
    !DashTraySourceRegistry.isPresentableSource(
      CGRect(x: 16, y: 300, width: 120, height: 90), in: .zero))
}

@Test @MainActor func traySharedSourceClaimDoesNotHideUntilActivatedAndOwnerReleases() {
  let registry = DashTraySourceRegistry()

  #expect(registry.claim("first"))
  #expect(registry.occupiedID == nil)
  #expect(registry.activate("first"))
  #expect(registry.occupiedID == AnyHashable("first"))
  #expect(!registry.claim("second"))
  #expect(registry.occupiedID == AnyHashable("first"))

  registry.release("second")
  #expect(registry.occupiedID == AnyHashable("first"))
  registry.release("first")
  #expect(registry.occupiedID == nil)
  #expect(registry.claim("second"))

  let action = DashTraySharedAction(id: "second", title: "Continue")
  var lease: DashTraySharedActionLease? = DashTraySharedActionLease(registry: registry)
  lease?.adopt(DashTraySharedActionClaim(action: action, frame: .zero))
  lease = nil
  #expect(registry.occupiedID == nil)
}

@Test func successCheckFlightArcsBetweenItsEndpointsWithALateDissolve() {
  let from = CGPoint(x: 300, y: 700)
  let to = CGPoint(x: 60, y: 120)

  // The quadratic bezier is pinned to its endpoints…
  #expect(DashTrayFlightMath.point(from: from, to: to, progress: 0) == from)
  #expect(DashTrayFlightMath.point(from: from, to: to, progress: 1) == to)

  // …and its midpoint rises above the straight line: the control point sits
  // `apexLift` above the higher endpoint, so at t = 0.5 the arc is half a
  // lift above the chord's midpoint minus the endpoint spread's pull.
  let mid = DashTrayFlightMath.point(from: from, to: to, progress: 0.5)
  #expect(mid.x == (from.x + to.x) / 2)
  #expect(mid.y < (from.y + to.y) / 2)

  // Size interpolates start → landing; a degenerate start stays untouched.
  #expect(DashTrayFlightMath.scale(from: 20, to: 10, progress: 0) == 1)
  #expect(abs(DashTrayFlightMath.scale(from: 20, to: 10, progress: 1) - 0.5) < 0.0001)
  #expect(DashTrayFlightMath.scale(from: 0, to: 10, progress: 0.5) == 1)

  // Fully visible for three quarters of the travel, then dissolving into the
  // toast mark it lands on.
  #expect(DashTrayFlightMath.opacity(0) == 1)
  #expect(DashTrayFlightMath.opacity(0.75) == 1)
  #expect(abs(DashTrayFlightMath.opacity(0.875) - 0.5) < 0.0001)
  #expect(DashTrayFlightMath.opacity(1) == 0)

  // The ink → green crossfade is pinned to pill ink at liftoff and toast
  // green well before touchdown, ramping through the middle of the travel.
  #expect(DashTrayFlightMath.colorBlend(0) == 0)
  #expect(abs(DashTrayFlightMath.colorBlend(0.5) - 0.5) < 0.0001)
  #expect(DashTrayFlightMath.colorBlend(0.7) == 1)
  #expect(DashTrayFlightMath.colorBlend(1) == 1)
}

@Test @MainActor func toastCenterSuccessReturnsThePresentedIdentity() {
  // The flight's landing match depends on `success` returning the identity
  // of the toast it actually enqueued — with an empty queue, that toast is
  // presented immediately.
  let center = DashToastCenter()
  let id = center.success("Created successfully.", haptic: false)
  #expect(center.current?.id == id)

  // A second success while the first holds the slot queues instead — its ID
  // must still name the *new* toast, not the visible one.
  let queued = center.success("Another one.", haptic: false)
  #expect(queued != id)
  #expect(center.current?.id == id)
}

/// Tab roots are transparent so all three share one `DashWorkspaceTopWash`,
/// which only works if the UIKit plates above them are punched through in both
/// appearances — light chrome is white, dark chrome is black.
@Test @MainActor func systemPlatesAreClearedInBothAppearances() {
  #expect(DashCanvasPlateRules.isSystemPlate(.white))
  #expect(DashCanvasPlateRules.isSystemPlate(.black))
  #expect(
    DashCanvasPlateRules.isSystemPlate(
      UIColor(red: 0xFB / 255, green: 0xFB / 255, blue: 0xFB / 255, alpha: 1)))
  #expect(
    DashCanvasPlateRules.isSystemPlate(
      UIColor(red: 0x03 / 255, green: 0x03 / 255, blue: 0x03 / 255, alpha: 1)))
}

/// A real surface — a card fill, a tinted plate, anything already translucent —
/// is somebody's content, not system chrome, and must survive untouched.
@Test @MainActor func contentPlatesSurviveTheClearPass() {
  #expect(!DashCanvasPlateRules.isSystemPlate(nil))
  #expect(!DashCanvasPlateRules.isSystemPlate(.systemOrange))
  #expect(!DashCanvasPlateRules.isSystemPlate(UIColor(white: 0.5, alpha: 1)))
  #expect(!DashCanvasPlateRules.isSystemPlate(UIColor(white: 1, alpha: 0.5)))
}

/// Vertical content scrolls must never be mistaken for a tab pager just because
/// paging is enabled — that skip leaves the header permanently unfrosted.
@Test @MainActor func contentScrollIsNotSkippedAsTabPager() {
  let vertical = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
  vertical.isPagingEnabled = true
  vertical.contentSize = CGSize(width: 390, height: 2000)
  #expect(!DashScrollViewConfigurator.isTabPager(vertical))

  let horizontalPager = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
  horizontalPager.isPagingEnabled = true
  horizontalPager.contentSize = CGSize(width: 390 * 3, height: 700)
  #expect(DashScrollViewConfigurator.isTabPager(horizontalPager))
}

/// The frost is a threshold, not a scrub: it arms once content has genuinely
/// gone under the bar, and disarms only back at the top. Between the two lines
/// it holds whatever it already was, so resting a finger there can't chatter it.
@Test func headerFrostArmsAndDisarmsOnSeparateThresholds() {
  let enter = DashHeaderScrimMetrics.enter
  let exit = DashHeaderScrimMetrics.exit
  #expect(enter > exit)

  #expect(!DashHeaderScrimRules.isScrolled(distance: -40, wasScrolled: false))
  #expect(!DashHeaderScrimRules.isScrolled(distance: enter, wasScrolled: false))
  #expect(DashHeaderScrimRules.isScrolled(distance: enter + 1, wasScrolled: false))

  // Armed, and still armed inside the dead band between the thresholds.
  #expect(DashHeaderScrimRules.isScrolled(distance: enter - 1, wasScrolled: true))
  #expect(DashHeaderScrimRules.isScrolled(distance: exit + 1, wasScrolled: true))
  #expect(!DashHeaderScrimRules.isScrolled(distance: exit, wasScrolled: true))
  #expect(!DashHeaderScrimRules.isScrolled(distance: -40, wasScrolled: true))
}

/// The frost and the glow answer to different things: the frost is chrome and
/// stays pinned to the window's top edge, the glow belongs to the top of the
/// content and leaves with it. Same probe, same distance, two behaviours.
@Test func workspaceGlowRidesTheScrollItIsMeasuredAgainst() {
  #expect(DashWorkspaceWashRules.lift(for: 0) == 0)
  #expect(DashWorkspaceWashRules.lift(for: 1) == 1)
  // Past the frost's own threshold the glow is still just tracking, not
  // flipping: it has no armed state to hold on to.
  #expect(DashWorkspaceWashRules.lift(for: DashHeaderScrimMetrics.enter) > 0)
  #expect(DashWorkspaceWashRules.lift(for: 120) == 120)
  #expect(DashWorkspaceWashRules.blendedDistance(from: 120, to: 0, progress: 0) == 120)
  #expect(DashWorkspaceWashRules.blendedDistance(from: 120, to: 0, progress: 0.5) == 60)
  #expect(DashWorkspaceWashRules.blendedDistance(from: 120, to: 0, progress: 1) == 0)
}

/// Clamped at both ends. A rubber-band pull past the top would otherwise push
/// the light down off its own edge and leave bare canvas above it, and once the
/// field has travelled its full depth there is nothing left on screen to move.
@Test func workspaceGlowNeverTravelsBelowItsEdgeOrPastItsDepth() {
  let depth = DashWorkspaceWashRules.depth
  #expect(depth > 0)
  #expect(DashWorkspaceWashRules.lift(for: -1) == 0)
  #expect(DashWorkspaceWashRules.lift(for: -400) == 0)
  #expect(DashWorkspaceWashRules.lift(for: depth) == depth)
  #expect(DashWorkspaceWashRules.lift(for: depth + 800) == depth)
}

/// Keep the reference implementation's deliberately restrained blur and tint
/// tuning in one shared contract, so the SwiftUI wrapper cannot quietly drift
/// back toward the taller, heavier material slab this replaced.
@Test func headerVariableBlurKeepsReferenceTuning() {
  #expect(DashHeaderScrimMetrics.maxBlurRadius == 5)
  #expect(DashHeaderScrimMetrics.startOffset == 0)
  #expect(DashHeaderScrimMetrics.tail == 40)
  #expect(DashHeaderScrimMetrics.tintOpacityTop == 0.7)
  #expect(DashHeaderScrimMetrics.tintOpacityMiddle == 0.5)
  #expect(DashHeaderScrimMetrics.tintMiddleY == 56)
}

/// Scroll edges reuse the header's restrained variable blur, including the
/// inverse source seat needed to rotate the package's vertical-only mask onto
/// physical left/right edges. Semantic leading/trailing must mirror in RTL.
@Test func scrollEdgeVariableBlurMapsAllFourEdges() {
  #expect(DashScrollEdgeFadeMetrics.thickness == 28)
  #expect(DashScrollEdgeBlurRules.maxBlurRadius == DashHeaderScrimMetrics.maxBlurRadius)
  #expect(DashScrollEdgeBlurRules.startOffset == DashHeaderScrimMetrics.startOffset)

  #expect(
    DashScrollEdgeBlurRules.physicalEdge(.leading, layoutDirection: .leftToRight)
      == .leading
  )
  #expect(
    DashScrollEdgeBlurRules.physicalEdge(.leading, layoutDirection: .rightToLeft)
      == .trailing
  )
  #expect(
    DashScrollEdgeBlurRules.physicalEdge(.trailing, layoutDirection: .rightToLeft)
      == .leading
  )

  #expect(DashScrollEdgeBlurRules.rotationDegrees(forPhysicalEdge: .top) == 0)
  #expect(DashScrollEdgeBlurRules.rotationDegrees(forPhysicalEdge: .bottom) == 0)
  #expect(DashScrollEdgeBlurRules.rotationDegrees(forPhysicalEdge: .leading) == -90)
  #expect(DashScrollEdgeBlurRules.rotationDegrees(forPhysicalEdge: .trailing) == 90)

  let verticalSeat = CGSize(width: DashScrollEdgeFadeMetrics.thickness, height: 240)
  #expect(
    DashScrollEdgeBlurRules.sourceSize(forPhysicalEdge: .top, in: verticalSeat)
      == verticalSeat
  )
  #expect(
    DashScrollEdgeBlurRules.sourceSize(forPhysicalEdge: .leading, in: verticalSeat)
      == CGSize(width: 240, height: DashScrollEdgeFadeMetrics.thickness)
  )

  #expect(
    DashScrollEdgeBlurRules.mountsVariableBlur(
      style: .fadeAndBlur,
      reduceTransparency: false,
      strength: 0.05
    )
  )
  #expect(
    !DashScrollEdgeBlurRules.mountsVariableBlur(
      style: .fadeAndBlur,
      reduceTransparency: false,
      strength: 0
    )
  )
  #expect(
    !DashScrollEdgeBlurRules.mountsVariableBlur(
      style: .fadeAndBlur,
      reduceTransparency: true,
      strength: 1
    )
  )
  #expect(
    !DashScrollEdgeBlurRules.mountsVariableBlur(
      style: .fade,
      reduceTransparency: false,
      strength: 1
    )
  )
}

/// The conditionally mounted backdrop enters far enough from its final
/// position to hide the filter's first frame. A full-width atmospheric layer
/// gets the same calm duration in either direction, with a smaller exit lift.
@Test func headerFrostUsesMatchedBidirectionalTiming() {
  #expect(DashHeaderScrimMotion.insertionOffsetY == -8)
  #expect(DashHeaderScrimMotion.removalOffsetY == -3)
  #expect(DashHeaderScrimMotion.insertionDuration == 0.36)
  #expect(DashHeaderScrimMotion.removalDuration == 0.36)
  #expect(DashHeaderScrimMotion.insertionDuration > 0)
  #expect(DashHeaderScrimMotion.removalDuration > 0)
  #expect(abs(DashHeaderScrimMotion.removalOffsetY) < abs(DashHeaderScrimMotion.insertionOffsetY))
  #expect(DashHeaderScrimMotion.insertionDuration == DashHeaderScrimMotion.removalDuration)
  #expect(DashHeaderScrimMotion.insertionDuration <= 0.4)
}

/// The store carries the hysteresis: it is asked with a raw scroll distance and
/// remembers what it answered, so a screen parked between the two thresholds
/// keeps whatever it already had. A screen with no scroll view clears outright.
@Test @MainActor func headerFrostStateRemembersWhatItAnswered() {
  let state = DashHeaderScrollState()
  #expect(!state.isFrosted)

  state.report(distance: DashHeaderScrimMetrics.enter)
  #expect(!state.isFrosted)

  state.report(distance: DashHeaderScrimMetrics.enter + 1)
  #expect(state.isFrosted)

  // Between the thresholds: holds.
  state.report(distance: DashHeaderScrimMetrics.exit + 1)
  #expect(state.isFrosted)

  state.report(distance: 0)
  #expect(!state.isFrosted)

  state.report(distance: DashHeaderScrimMetrics.enter + 1)
  #expect(state.isFrosted)
  state.clear()
  #expect(!state.isFrosted)
}

/// A bounded accessibility mask must reach fully clear at its own extent and
/// stay there, or its fallback canvas paints a hard step over the content.
@Test func headerAccessibilityMaskClearsAtItsConfiguredExtent() {
  let stops = DashHeaderScrimRules.maskStops(solidFraction: 0.2, extent: 0.5)
  #expect(stops.first?.opacity == 1)
  #expect(stops.contains { $0.opacity == 1 && $0.location == 0.2 })
  #expect(stops.contains { $0.opacity == 0 && $0.location == 0.5 })
  #expect(stops.last?.location == 1)
  #expect(stops.last?.opacity == 0)
  // A layer whose plateau already fills its extent still has to close out.
  let degenerate = DashHeaderScrimRules.maskStops(solidFraction: 0.9, extent: 0.4)
  #expect(degenerate.last?.opacity == 0)
  #expect(degenerate.last?.location == 1)
}

/// The band is solid across the status bar and then eases to fully clear — a
/// hard stop at the bottom is exactly the edge this gradient exists to avoid.
@Test func headerFrostFadesOutInsteadOfEndingOnAnEdge() {
  let stops = DashHeaderScrimRules.maskStops(solidFraction: 0.5)
  #expect(stops.first?.opacity == 1)
  #expect(stops.first?.location == 0)
  #expect(stops.last?.opacity == 0)
  #expect(stops.last?.location == 1)
  // Solid all the way through the bar, then never brightening again.
  #expect(stops.contains { $0.opacity == 1 && $0.location == 0.5 })
  #expect(
    stops.indices.dropFirst().allSatisfy { index in
      stops[index].opacity <= stops[index - 1].opacity
        && stops[index].location >= stops[index - 1].location
    })
}

@Test @MainActor func toastCenterQueuesAndPromotesAutomaticToasts() {
  let model = AppModel(configuration: AppConfiguration(clientID: "", redirectURI: ""))
  #expect(model.toasts.current == nil)

  model.toasts.success("Uploaded logo.png.", haptic: false)
  let first = model.toasts.current
  #expect(first?.kind == .success)
  #expect(first?.message == "Uploaded logo.png.")
  #expect(first?.duration == DashToast.Kind.success.duration)

  model.toasts.error("Permission denied.", title: "R2", haptic: false)
  #expect(model.toasts.current?.id == first?.id)

  model.toasts.dismiss(id: first!.id)
  let second = model.toasts.current
  #expect(second?.id != first?.id)
  #expect(second?.kind == .error)
  #expect(second?.resolvedTitle == "R2")
  #expect(second?.duration == DashToast.Kind.error.duration)

  model.toasts.dismiss(id: first!.id)
  #expect(model.toasts.current?.id == second?.id)

  model.toasts.dismiss()
  #expect(model.toasts.current == nil)
}

@Test func toastDurationsPreferShorterSuccessWindows() {
  #expect(DashToast.Kind.success.duration < DashToast.Kind.warning.duration)
  #expect(DashToast.Kind.warning.duration < DashToast.Kind.error.duration)
  #expect(DashToast(kind: .success, message: "ok", duration: 1).duration == 1)
}
