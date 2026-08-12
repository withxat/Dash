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
  /// Draws the pattern in motion instead of as one cached still.
  ///
  /// Honoured by `.dither` alone, and only up to
  /// `AvatarMotion.animatablePixelSize`: every frame is a fresh CPU raster, so
  /// a grid of animated rows would cost what one animated hero does.
  private let animated: Bool

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.displayScale) private var displayScale
  @State private var renderedImage: AvatarImageSnapshot?

  public init(
    seed: String,
    size: CGFloat = 32,
    pattern: AvatarPattern = .gradient,
    cornerRadius: CGFloat? = nil,
    contentScale: CGFloat = 1,
    animated: Bool = false
  ) {
    self.init(
      seed: AvatarSeed(seed),
      size: size,
      pattern: pattern,
      cornerRadius: cornerRadius,
      contentScale: contentScale,
      animated: animated
    )
  }

  public init(
    seed: UInt32,
    size: CGFloat = 32,
    pattern: AvatarPattern = .gradient,
    cornerRadius: CGFloat? = nil,
    contentScale: CGFloat = 1,
    animated: Bool = false
  ) {
    self.init(
      seed: AvatarSeed(seed),
      size: size,
      pattern: pattern,
      cornerRadius: cornerRadius,
      contentScale: contentScale,
      animated: animated
    )
  }

  public init(
    seed: AvatarSeed,
    size: CGFloat = 32,
    pattern: AvatarPattern = .gradient,
    cornerRadius: CGFloat? = nil,
    contentScale: CGFloat = 1,
    animated: Bool = false
  ) {
    self.seed = seed
    self.size = max(1, size)
    self.pattern = pattern
    self.cornerRadius = cornerRadius
    self.contentScale = max(1, contentScale)
    self.animated = animated
  }

  public var body: some View {
    let request = AvatarImageRequest(
      seed: seed,
      pixelSize: Int((size * displayScale).rounded(.up)),
      pattern: pattern
    )
    let moves = moves(request)

    Group {
      if moves {
        AnimatedAvatarFace(
          seed: seed,
          pixelSize: request.pixelSize,
          pattern: pattern,
          displayScale: displayScale,
          contentScale: contentScale
        )
      } else if let snapshot = snapshot(for: request) {
        face(snapshot.image)
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
      guard !moves, renderedImage?.request != request else { return }
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

  private func moves(_ request: AvatarImageRequest) -> Bool {
    animated
      && !reduceMotion
      && pattern == .dither
      && request.pixelSize <= AvatarMotion.animatablePixelSize
  }

  private func snapshot(for request: AvatarImageRequest) -> AvatarImageSnapshot? {
    if renderedImage?.request == request { return renderedImage }
    if let exact = AvatarImageCache.shared.cachedImage(for: request) { return exact }
    return standIn(for: request)
  }

  /// The same avatar at the wrong size, held until the right one is drawn.
  ///
  /// `.resizable()` means any raster fills the frame, so a size the cache
  /// already has is a sharpness away from correct — where a miss is a hole. It
  /// must be the same face, though: a seat handed a new seed blanks rather than
  /// spend a frame claiming to be the avatar it just stopped being.
  private func standIn(for request: AvatarImageRequest) -> AvatarImageSnapshot? {
    if let rendered = renderedImage,
      rendered.request.seed == request.seed,
      rendered.request.pattern == request.pattern
    {
      return rendered
    }
    return AvatarImageCache.shared.standInImage(for: request)
  }

  private func face(_ image: CGImage) -> some View {
    Image(decorative: image, scale: displayScale)
      .resizable()
      .interpolation(pattern == .dither ? .none : .high)
      .scaleEffect(contentScale)
  }
}

/// The moving pose of `GradientAvatar`.
///
/// Deliberately outside the cache: a frame is worth drawing once and throwing
/// away, and keeping twenty of them per second per avatar would evict every
/// still the rest of the app is scrolling past.
private struct AnimatedAvatarFace: View {
  let seed: AvatarSeed
  let pixelSize: Int
  let pattern: AvatarPattern
  let displayScale: CGFloat
  let contentScale: CGFloat

  var body: some View {
    TimelineView(.animation(minimumInterval: AvatarMotion.frameInterval)) { timeline in
      face(at: timeline.date)
    }
  }

  @ViewBuilder
  private func face(at date: Date) -> some View {
    if let image = AvatarRenderer.image(
      seed: seed,
      size: pixelSize,
      pattern: pattern,
      phase: AvatarMotion.phase(at: date)
    ) {
      Image(decorative: image, scale: displayScale)
        .resizable()
        .interpolation(.none)
        .scaleEffect(contentScale)
    } else {
      Color.clear
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

  /// Identifies the picture rather than the raster, so a request that has not
  /// been drawn at this size yet can borrow one that has.
  fileprivate var faceKey: NSString {
    "\(seed.rawValue):\(pattern.rawValue)" as NSString
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
  /// The last raster drawn of each face, whatever size it was.
  ///
  /// An avatar that changes size — the domain card growing out of the grid into
  /// the zone hero — asks for a raster nobody has drawn yet, and the honest
  /// answer takes an actor hop. Handing back the size that *is* warm keeps the
  /// picture on screen and lets the exact one replace it when it lands, instead
  /// of punching a hole in the first frames of the morph.
  private let faces = NSCache<NSString, AvatarImageSnapshot>()

  init(
    countLimit: Int = 256,
    totalCostLimit: Int = 32 * 1_024 * 1_024
  ) {
    cache.countLimit = countLimit
    cache.totalCostLimit = totalCostLimit
    faces.countLimit = countLimit
    faces.totalCostLimit = totalCostLimit
  }

  func snapshot(for request: AvatarImageRequest) -> AvatarImageSnapshot? {
    cache.object(forKey: request.cacheKey)
  }

  /// A raster of the same face at some other size, or nil if this avatar has
  /// never been drawn.
  func standIn(for request: AvatarImageRequest) -> AvatarImageSnapshot? {
    faces.object(forKey: request.faceKey)
  }

  func insert(_ snapshot: AvatarImageSnapshot) {
    let cost = snapshot.image.bytesPerRow * snapshot.image.height
    cache.setObject(snapshot, forKey: snapshot.request.cacheKey, cost: cost)
    faces.setObject(snapshot, forKey: snapshot.request.faceKey, cost: cost)
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

  nonisolated func standInImage(
    for request: AvatarImageRequest
  ) -> AvatarImageSnapshot? {
    memory.standIn(for: request)
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
