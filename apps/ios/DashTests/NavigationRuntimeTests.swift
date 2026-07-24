import Testing
import UIKit

@testable import Dash

@Test func navigationScrubScheduleIsBoundedOutsideInteractivePop() {
  #expect(NavigationScrubSchedule.pathTransitionDuration == 0.55)
  #expect(NavigationScrubSchedule.interactiveSettleDuration == 0.12)
  #expect(
    NavigationScrubSchedule.shouldRun(
      now: 10.54,
      holdUntil: 10.55,
      interactivePopActive: false))
  #expect(
    !NavigationScrubSchedule.shouldRun(
      now: 10.55,
      holdUntil: 10.55,
      interactivePopActive: false))
}

@Test func navigationScrubScheduleHoldsForInteractivePop() {
  #expect(
    NavigationScrubSchedule.shouldRun(
      now: 20,
      holdUntil: 10,
      interactivePopActive: true))
}

@Test func tabPagerLockRetriesUseBoundedOffsets() {
  #expect(TabPagerLockRetrySchedule.offsetsMS == [0, 16, 64, 160])
}

@MainActor
@Test func tabPagerLockRulesGateOnlyThePagerPan() {
  let pager = UICollectionView(
    frame: CGRect(x: 0, y: 0, width: 390, height: 844),
    collectionViewLayout: UICollectionViewFlowLayout())
  pager.isScrollEnabled = false
  pager.alwaysBounceVertical = true
  pager.panGestureRecognizer.isEnabled = true

  TabPagerLockRules.apply(locked: true, to: pager)

  #expect(pager.isScrollEnabled)
  #expect(!pager.alwaysBounceVertical)
  #expect(!pager.panGestureRecognizer.isEnabled)

  TabPagerLockRules.apply(locked: false, to: pager)

  #expect(pager.isScrollEnabled)
  #expect(pager.panGestureRecognizer.isEnabled)
}
