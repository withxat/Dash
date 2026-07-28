import SwiftUI

extension Animation {
  /// Standard blossom animation with spring physics
  /// stiffness: 170, damping: 15 for that "pop" feel
  public static let blossom: Animation = .interpolatingSpring(stiffness: 170, damping: 15)

  public static func blossom(delay: Double) -> Animation {
    .interpolatingSpring(stiffness: 170, damping: 15).delay(delay)
  }

  public static func petalBloom(index: Int, staggerDelay: Double = 0.02) -> Animation {
    .interpolatingSpring(stiffness: 170, damping: 15).delay(Double(index) * staggerDelay)
  }
}
