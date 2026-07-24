import CoreGraphics
import Foundation
import SwiftUI

/// A deterministic, locally rendered SwiftUI avatar.
public struct GradientAvatar: View {
  private let seed: AvatarSeed
  private let size: CGFloat
  private let pattern: AvatarPattern
  private let cornerRadius: CGFloat?
  /// Zooms the rendered pattern inside the same outer frame (1 = fill).
  private let contentScale: CGFloat

  @Environment(\.displayScale) private var displayScale

  public init(
    seed: String,
    size: CGFloat = 32,
    pattern: AvatarPattern = .mesh,
    cornerRadius: CGFloat? = nil,
    contentScale: CGFloat = 1
  ) {
    self.init(
      seed: AvatarSeed(seed),
      size: size,
      pattern: pattern,
      cornerRadius: cornerRadius,
      contentScale: contentScale
    )
  }

  public init(
    seed: UInt32,
    size: CGFloat = 32,
    pattern: AvatarPattern = .mesh,
    cornerRadius: CGFloat? = nil,
    contentScale: CGFloat = 1
  ) {
    self.init(
      seed: AvatarSeed(seed),
      size: size,
      pattern: pattern,
      cornerRadius: cornerRadius,
      contentScale: contentScale
    )
  }

  public init(
    seed: AvatarSeed,
    size: CGFloat = 32,
    pattern: AvatarPattern = .mesh,
    cornerRadius: CGFloat? = nil,
    contentScale: CGFloat = 1
  ) {
    self.seed = seed
    self.size = max(1, size)
    self.pattern = pattern
    self.cornerRadius = cornerRadius
    self.contentScale = max(1, contentScale)
  }

  public var body: some View {
    let pixelSize = max(1, Int((size * displayScale).rounded(.up)))
    Group {
      if let image = AvatarImageCache.shared.image(
        seed: seed,
        size: pixelSize,
        pattern: pattern
      ) {
        Image(decorative: image, scale: displayScale)
          .resizable()
          .interpolation(pattern == .dither ? .none : .high)
          .scaleEffect(contentScale)
      } else {
        Color.clear
      }
    }
    .frame(width: size, height: size)
    .clipShape(
      RoundedRectangle(
        cornerRadius: max(0, cornerRadius ?? (size / 2)),
        style: .continuous
      )
    )
    .accessibilityHidden(true)
  }
}

private final class AvatarImageCache: @unchecked Sendable {
  static let shared = AvatarImageCache()

  private let cache = NSCache<NSString, ImageBox>()

  private init() {
    cache.countLimit = 256
  }

  func image(
    seed: AvatarSeed,
    size: Int,
    pattern: AvatarPattern
  ) -> CGImage? {
    let key = "\(seed.rawValue):\(size):\(pattern.rawValue)" as NSString
    if let cached = cache.object(forKey: key) {
      return cached.image
    }
    guard
      let image = AvatarRenderer.image(
        seed: seed,
        size: size,
        pattern: pattern
      )
    else {
      return nil
    }
    cache.setObject(ImageBox(image), forKey: key)
    return image
  }
}

private final class ImageBox: @unchecked Sendable {
  let image: CGImage

  init(_ image: CGImage) {
    self.image = image
  }
}
