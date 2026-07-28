import CoreGraphics
import Testing

@testable import SwiftDitherKit

/// The tuning is asserted literally on purpose: `SwiftGlobeKit` carries the
/// same two numbers for the globe, and the pair is only in step as long as
/// changing one is a visible edit here.
@Test func holdTuningMatchesTheSharedEngageContract() {
  #expect(DitherHoldInteraction.holdDuration == 0.35)
  #expect(DitherHoldInteraction.holdSlop == 10)
}

@Test func holdClaimTakesOnlyForeignDirectionalGestures() {
  #expect(
    DitherHoldClaimRules.claims(isDirectional: true, isEnabled: true, isOwn: false))
  // A tap or press elsewhere cannot steal a scrub, so it is left alone.
  #expect(
    !DitherHoldClaimRules.claims(isDirectional: false, isEnabled: true, isOwn: false))
  // Already off: claiming it would mean switching it back on at release,
  // undoing whatever the host app disabled it for.
  #expect(
    !DitherHoldClaimRules.claims(isDirectional: true, isEnabled: false, isOwn: false))
  // The chart's own recognizers are the interaction, not competition for it.
  #expect(
    !DitherHoldClaimRules.claims(isDirectional: true, isEnabled: true, isOwn: true))
}
