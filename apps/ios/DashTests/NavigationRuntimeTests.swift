import Testing
import UIKit

@testable import Dash

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
