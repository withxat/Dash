import CoreGraphics
import Testing

@testable import SwiftGlobeKit

/// The tuning is asserted literally on purpose: `SwiftDitherKit` carries the
/// same two numbers for charts, and the pair is only in step as long as
/// changing one is a visible edit here.
@Test func holdTuningMatchesTheSharedEngageContract() {
  #expect(GlobeHoldInteraction.holdDuration == 0.35)
  #expect(GlobeHoldInteraction.holdSlop == 10)
}

@Test func holdClaimTakesOnlyForeignDirectionalGestures() {
  #expect(
    GlobeHoldClaimRules.claims(isDirectional: true, isEnabled: true, isOwn: false))
  // A tap or press elsewhere cannot steal a drag, so it is left alone.
  #expect(
    !GlobeHoldClaimRules.claims(isDirectional: false, isEnabled: true, isOwn: false))
  // Already off: claiming it would mean switching it back on at release,
  // undoing whatever the host app disabled it for.
  #expect(
    !GlobeHoldClaimRules.claims(isDirectional: true, isEnabled: false, isOwn: false))
  // The globe's own pan is the interaction, not competition for it.
  #expect(
    !GlobeHoldClaimRules.claims(isDirectional: true, isEnabled: true, isOwn: true))
}
