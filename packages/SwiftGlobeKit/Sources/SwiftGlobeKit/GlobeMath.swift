import Foundation

enum GlobeMath {
  static let degreesPerTurn = 360.0
  static let radiansPerDegree = Double.pi / 180

  static func normalizedLatitude(_ latitude: Double) -> Double {
    clamped(latitude, to: -90...90, default: 0)
  }

  static func normalizedLongitude(_ longitude: Double) -> Double {
    guard longitude.isFinite else { return 0 }
    let wrapped =
      (longitude + 180)
      .truncatingRemainder(dividingBy: degreesPerTurn)
    return (wrapped < 0 ? wrapped + degreesPerTurn : wrapped) - 180
  }

  static func shortestLongitudeDelta(from: Double, to: Double) -> Double {
    normalizedLongitude(to - from)
  }

  static func spherePosition(for coordinate: GlobeCoordinate) -> SIMD3<Double> {
    let latitude = coordinate.latitude * radiansPerDegree
    let longitude = coordinate.longitude * radiansPerDegree
    let latitudeRadius = cos(latitude)
    return SIMD3(
      latitudeRadius * sin(longitude),
      sin(latitude),
      latitudeRadius * cos(longitude)
    )
  }

  static func isFrontFacing(
    _ coordinate: GlobeCoordinate,
    camera: GlobeCamera
  ) -> Bool {
    projection(of: coordinate, camera: camera).isVisible
  }

  static func projection(
    of coordinate: GlobeCoordinate,
    camera: GlobeCamera
  ) -> GlobeProjection {
    let position = spherePosition(for: coordinate)
    let forward = spherePosition(for: camera.coordinate)
    let worldUp =
      abs(forward.y) > 0.999
      ? SIMD3<Double>(0, 0, 1)
      : SIMD3<Double>(0, 1, 0)
    let right = normalized(cross(worldUp, forward))
    let up = normalized(cross(forward, right))
    let depth = dot(position, forward)

    return GlobeProjection(
      point: SIMD2(
        dot(position, right) * camera.scale,
        dot(position, up) * camera.scale
      ),
      depth: depth,
      isVisible: depth >= 0
    )
  }

  static func clamped<T: BinaryFloatingPoint>(
    _ value: T,
    to range: ClosedRange<T>,
    default defaultValue: T
  ) -> T {
    guard value.isFinite else { return defaultValue }
    return min(max(value, range.lowerBound), range.upperBound)
  }

  private static func dot(_ lhs: SIMD3<Double>, _ rhs: SIMD3<Double>) -> Double {
    lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z
  }

  private static func cross(
    _ lhs: SIMD3<Double>,
    _ rhs: SIMD3<Double>
  ) -> SIMD3<Double> {
    SIMD3(
      lhs.y * rhs.z - lhs.z * rhs.y,
      lhs.z * rhs.x - lhs.x * rhs.z,
      lhs.x * rhs.y - lhs.y * rhs.x
    )
  }

  private static func normalized(_ vector: SIMD3<Double>) -> SIMD3<Double> {
    let magnitude = sqrt(dot(vector, vector))
    guard magnitude > .ulpOfOne else { return .zero }
    return vector / magnitude
  }
}

struct GlobeProjection: Equatable, Sendable {
  let point: SIMD2<Double>
  let depth: Double
  let isVisible: Bool
}
