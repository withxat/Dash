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
  @State private var renderedImage: AvatarImageSnapshot?

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
    let request = AvatarImageRequest(
      seed: seed,
      pixelSize: Int((size * displayScale).rounded(.up)),
      pattern: pattern
    )
    let snapshot =
      renderedImage?.request == request
      ? renderedImage
      : AvatarImageCache.shared.cachedImage(for: request)

    Group {
      if let snapshot {
        Image(decorative: snapshot.image, scale: displayScale)
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
    .task(id: request) {
      guard renderedImage?.request != request else { return }
      if let cached = AvatarImageCache.shared.cachedImage(for: request) {
        renderedImage = cached
        return
      }
      guard let snapshot = await AvatarImageCache.shared.image(for: request) else {
        return
      }
      guard !Task.isCancelled else { return }
      renderedImage = snapshot
    }
  }
}

struct AvatarImageRequest: Hashable, Sendable {
  let seed: AvatarSeed
  let pixelSize: Int
  let pattern: AvatarPattern

  init(seed: AvatarSeed, pixelSize: Int, pattern: AvatarPattern) {
    self.seed = seed
    self.pixelSize = max(1, pixelSize)
    self.pattern = pattern
  }

  fileprivate var cacheKey: NSString {
    "\(seed.rawValue):\(pixelSize):\(pattern.rawValue)" as NSString
  }
}

final class AvatarImageSnapshot: @unchecked Sendable {
  let request: AvatarImageRequest
  let image: CGImage

  init(request: AvatarImageRequest, image: CGImage) {
    self.request = request
    self.image = image
  }
}

final class AvatarRenderedImage: @unchecked Sendable {
  let image: CGImage

  init(_ image: CGImage) {
    self.image = image
  }
}

/// Thread-safe warm snapshot used by `GradientAvatar.body`.
///
/// `NSCache` synchronizes its own access, so a cache hit can remain synchronous
/// while all expensive rendering is actor-isolated below.
final class AvatarImageMemoryCache: @unchecked Sendable {
  private let cache = NSCache<NSString, AvatarImageSnapshot>()

  init(
    countLimit: Int = 256,
    totalCostLimit: Int = 32 * 1_024 * 1_024
  ) {
    cache.countLimit = countLimit
    cache.totalCostLimit = totalCostLimit
  }

  func snapshot(for request: AvatarImageRequest) -> AvatarImageSnapshot? {
    cache.object(forKey: request.cacheKey)
  }

  func insert(_ snapshot: AvatarImageSnapshot) {
    let cost = snapshot.image.bytesPerRow * snapshot.image.height
    cache.setObject(snapshot, forKey: snapshot.request.cacheKey, cost: cost)
  }
}

/// Serializes cache misses away from the main actor.
///
/// Rendering one miss at a time prevents a fast scroll from creating a CPU
/// stampede. Calls for the same request observe the first completed snapshot;
/// canceled calls waiting for the actor return before starting renderer work.
actor AvatarImageCache {
  typealias Renderer = @Sendable (AvatarImageRequest) -> AvatarRenderedImage?

  static let shared = AvatarImageCache()

  nonisolated private let memory: AvatarImageMemoryCache
  private let renderer: Renderer

  init(
    memory: AvatarImageMemoryCache = AvatarImageMemoryCache(),
    renderer: @escaping Renderer = AvatarImageCache.render
  ) {
    self.memory = memory
    self.renderer = renderer
  }

  nonisolated func cachedImage(
    for request: AvatarImageRequest
  ) -> AvatarImageSnapshot? {
    memory.snapshot(for: request)
  }

  func image(for request: AvatarImageRequest) -> AvatarImageSnapshot? {
    if let cached = memory.snapshot(for: request) {
      return cached
    }

    guard !Task.isCancelled else { return nil }
    guard let rendered = renderer(request) else { return nil }

    // Once rendering has paid its full cost, keep the result even if the
    // original row disappeared. A later waiter then gets the warm snapshot
    // instead of repeating the same work.
    let snapshot = AvatarImageSnapshot(request: request, image: rendered.image)
    memory.insert(snapshot)

    guard !Task.isCancelled else { return nil }
    return snapshot
  }

  private static func render(
    request: AvatarImageRequest
  ) -> AvatarRenderedImage? {
    guard
      let image = AvatarRenderer.image(
        seed: request.seed,
        size: request.pixelSize,
        pattern: request.pattern
      )
    else {
      return nil
    }
    return AvatarRenderedImage(image)
  }
}
