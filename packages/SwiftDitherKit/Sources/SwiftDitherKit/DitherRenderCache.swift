import CoreGraphics

enum DitherRenderRequest: Hashable, Sendable {
  case cartesian(DitherCartesianRenderInput)
  case pie(DitherPieRenderInput)
  case radar(DitherRadarRenderInput)

  func render() -> DitherRaster {
    switch self {
    case .cartesian(let input):
      DitherRenderer.cartesian(input)
    case .pie(let input):
      DitherRenderer.pie(input)
    case .radar(let input):
      DitherRenderer.radar(input)
    }
  }

  func renderFrame() -> DitherRenderedRaster {
    let raster = render()
    let sparkleField: DitherSparkleField
    switch self {
    case .cartesian(let input):
      sparkleField = .cartesian(input, width: raster.width, height: raster.height)
    case .pie, .radar:
      sparkleField = .empty(width: raster.width, height: raster.height)
    }
    return DitherRenderedRaster(raster: raster, sparkleField: sparkleField)
  }
}

/// An immutable Core Graphics frame created away from the main actor.
///
/// `CGImage` instances are immutable. The unchecked conformance only bridges
/// Core Graphics' missing annotation so frames can cross the cache actor boundary.
struct DitherRenderedRaster: @unchecked Sendable {
  let image: CGImage?
  let checksum: UInt64
  let byteCount: Int
  let sparkleField: DitherSparkleField

  init(
    raster: DitherRaster,
    sparkleField: DitherSparkleField? = nil
  ) {
    let resolvedSparkleField =
      sparkleField ?? .empty(width: raster.width, height: raster.height)
    image = raster.makeCGImage()
    checksum = resolvedSparkleField.combiningChecksum(raster.checksum)
    byteCount = raster.bytes.count
    self.sparkleField = resolvedSparkleField
  }
}

actor DitherRenderCache {
  struct Statistics: Equatable, Sendable {
    let entryCount: Int
    let byteCount: Int
    let hitCount: Int
    let missCount: Int
  }

  static let shared = DitherRenderCache()

  private struct Entry: Sendable {
    let frame: DitherRenderedRaster
  }

  private let maximumByteCount: Int
  private var entries: [DitherRenderRequest: Entry] = [:]
  private var recency: [DitherRenderRequest] = []
  private var byteCount = 0
  private var hitCount = 0
  private var missCount = 0

  /// Creates a cache with an approximate pixel-memory limit.
  ///
  /// The default keeps no more than 16 MiB of rendered RGBA frames. A single
  /// frame larger than the limit is returned without being cached.
  init(maximumByteCount: Int = 16 * 1_024 * 1_024) {
    self.maximumByteCount = max(0, maximumByteCount)
  }

  func frame(for request: DitherRenderRequest) throws -> DitherRenderedRaster {
    try Task.checkCancellation()

    if let entry = entries[request] {
      hitCount += 1
      touch(request)
      return entry.frame
    }

    missCount += 1
    let frame = request.renderFrame()
    insert(frame, for: request)
    return frame
  }

  func statistics() -> Statistics {
    Statistics(
      entryCount: entries.count,
      byteCount: byteCount,
      hitCount: hitCount,
      missCount: missCount
    )
  }

  func removeAll() {
    entries.removeAll(keepingCapacity: false)
    recency.removeAll(keepingCapacity: false)
    byteCount = 0
    hitCount = 0
    missCount = 0
  }

  private func insert(_ frame: DitherRenderedRaster, for request: DitherRenderRequest) {
    guard maximumByteCount > 0, frame.byteCount <= maximumByteCount else { return }

    while byteCount + frame.byteCount > maximumByteCount, let oldest = recency.first {
      recency.removeFirst()
      if let evicted = entries.removeValue(forKey: oldest) {
        byteCount -= evicted.frame.byteCount
      }
    }

    entries[request] = Entry(frame: frame)
    recency.append(request)
    byteCount += frame.byteCount
  }

  private func touch(_ request: DitherRenderRequest) {
    if let index = recency.firstIndex(of: request) {
      recency.remove(at: index)
    }
    recency.append(request)
  }
}
