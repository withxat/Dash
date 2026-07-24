import CoreGraphics
import Foundation
import SwiftUI

enum DitherMotion {
  static let defaultEntranceDuration: TimeInterval = 0.28
  static let updateDuration: TimeInterval = 0.22
  static let reducedMotionDuration: TimeInterval = 0.14
  static let feedbackDuration: TimeInterval = 0.14
  static let transitionBlur: CGFloat = 1.5

  static func entrance(duration: TimeInterval) -> Animation {
    .timingCurve(0.23, 1, 0.32, 1, duration: max(0.05, duration))
  }

  static var update: Animation {
    .timingCurve(0.77, 0, 0.175, 1, duration: updateDuration)
  }

  static var reduced: Animation {
    .timingCurve(0.23, 1, 0.32, 1, duration: reducedMotionDuration)
  }

  static var feedback: Animation {
    .timingCurve(0.23, 1, 0.32, 1, duration: feedbackDuration)
  }

  static func radarScale(progress: CGFloat) -> CGFloat {
    0.96 + clamped(progress) * 0.04
  }

  static func incomingBlur(progress: CGFloat, reduceMotion: Bool) -> CGFloat {
    reduceMotion ? 0 : (1 - clamped(progress)) * transitionBlur
  }

  static func outgoingBlur(progress: CGFloat, reduceMotion: Bool) -> CGFloat {
    reduceMotion ? 0 : clamped(progress) * transitionBlur
  }

  static func clamped(_ progress: CGFloat) -> CGFloat {
    min(1, max(0, progress))
  }
}

struct DitherRasterMotionState: Hashable, Sendable {
  let checksum: UInt64
  let transitionKey: Int
  let replayToken: Int
  let animate: Bool
  let reduceMotion: Bool
}

struct DitherRasterTransitionProgress: Equatable, Sendable {
  var entrance: CGFloat
  var update: CGFloat

  init(animate: Bool) {
    entrance = animate ? 0 : 1
    update = 1
  }

  mutating func prepare(for decision: DitherRasterMotionDecision) {
    switch decision {
    case .none:
      break
    case .replace, .settle:
      settle()
    case .crossfade:
      entrance = 1
      update = 0
    case .replay:
      entrance = 0
      update = 1
    }
  }

  mutating func settle() {
    entrance = 1
    update = 1
  }
}

enum DitherRasterMotionDecision: Equatable, Sendable {
  case none
  case replace
  case crossfade
  case replay
  case settle

  static func decide(
    from previous: DitherRasterMotionState,
    to next: DitherRasterMotionState
  ) -> Self {
    guard previous != next else { return .none }
    guard next.animate else { return .replace }

    if previous.replayToken != next.replayToken || (!previous.animate && next.animate) {
      return .replay
    }
    if previous.checksum != next.checksum {
      return previous.transitionKey == next.transitionKey ? .replace : .crossfade
    }
    if previous.reduceMotion != next.reduceMotion {
      return .settle
    }
    return .none
  }
}

enum DitherTransitionKey {
  static func cartesian(
    kind: DitherChartKind,
    data: [DitherDatum],
    series: [DitherSeries],
    stacking: DitherStacking,
    selectedSeriesID: String?,
    highlighted: Bool
  ) -> Int {
    var hasher = Hasher()
    hasher.combine(kind)
    hasher.combine(data)
    hasher.combine(series)
    hasher.combine(stacking)
    hasher.combine(selectedSeriesID)
    hasher.combine(highlighted)
    return hasher.finalize()
  }

  static func pie(slices: [DitherSlice], selectedSliceID: String?) -> Int {
    var hasher = Hasher()
    hasher.combine(slices)
    hasher.combine(selectedSliceID)
    return hasher.finalize()
  }

  static func radar(
    data: [DitherDatum],
    series: [DitherSeries],
    selectedSeriesID: String?
  ) -> Int {
    var hasher = Hasher()
    hasher.combine(data)
    hasher.combine(series)
    hasher.combine(selectedSeriesID)
    return hasher.finalize()
  }
}
