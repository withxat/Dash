import Foundation
import Testing

@testable import SwiftGlobeKit

@Test func sphereProjectionUsesDocumentedAxes() {
  expectApproximately(
    GlobeMath.spherePosition(for: GlobeCoordinate(latitude: 0, longitude: 0)),
    SIMD3(0, 0, 1)
  )
  expectApproximately(
    GlobeMath.spherePosition(for: GlobeCoordinate(latitude: 0, longitude: 90)),
    SIMD3(1, 0, 0)
  )
  expectApproximately(
    GlobeMath.spherePosition(for: GlobeCoordinate(latitude: 90, longitude: 0)),
    SIMD3(0, 1, 0)
  )
}

@Test func projectionCentersCameraCoordinate() {
  let camera = GlobeCamera(longitude: 40, latitude: 25, scale: 1.5)
  let projected = GlobeMath.projection(of: camera.coordinate, camera: camera)

  expectApproximately(projected.point.x, 0)
  expectApproximately(projected.point.y, 0)
  expectApproximately(projected.depth, 1)
  #expect(projected.isVisible)
}

@Test func projectionAppliesCameraScale() {
  let coordinate = GlobeCoordinate(latitude: 0, longitude: 30)
  let unit = GlobeMath.projection(of: coordinate, camera: GlobeCamera(scale: 1))
  let doubled = GlobeMath.projection(of: coordinate, camera: GlobeCamera(scale: 2))

  expectApproximately(doubled.point.x, unit.point.x * 2)
  expectApproximately(doubled.point.y, unit.point.y * 2)
  expectApproximately(doubled.depth, unit.depth)
}

@Test func visibilityRejectsBackHemisphere() {
  let camera = GlobeCamera(longitude: 0, latitude: 0)

  #expect(
    GlobeMath.isFrontFacing(
      GlobeCoordinate(latitude: 0, longitude: 0),
      camera: camera
    )
  )
  #expect(
    !GlobeMath.isFrontFacing(
      GlobeCoordinate(latitude: 0, longitude: -180),
      camera: camera
    )
  )
}

@Test func projectionRemainsFiniteAtPoles() {
  let camera = GlobeCamera(longitude: 120, latitude: 90)
  let projected = GlobeMath.projection(
    of: GlobeCoordinate(latitude: 45, longitude: -30),
    camera: camera
  )

  #expect(projected.point.x.isFinite)
  #expect(projected.point.y.isFinite)
  #expect(projected.depth.isFinite)
}

@Test func longitudeDeltaTakesShortestAntimeridianPath() {
  #expect(GlobeMath.shortestLongitudeDelta(from: 170, to: -170) == 20)
  #expect(GlobeMath.shortestLongitudeDelta(from: -170, to: 170) == -20)
  #expect(GlobeMath.shortestLongitudeDelta(from: 10, to: 370) == 0)
  #expect(GlobeMath.shortestLongitudeDelta(from: 0, to: 180) == -180)
}

private func expectApproximately(
  _ actual: Double,
  _ expected: Double,
  tolerance: Double = 1e-12
) {
  #expect(abs(actual - expected) <= tolerance)
}

private func expectApproximately(
  _ actual: SIMD3<Double>,
  _ expected: SIMD3<Double>,
  tolerance: Double = 1e-12
) {
  expectApproximately(actual.x, expected.x, tolerance: tolerance)
  expectApproximately(actual.y, expected.y, tolerance: tolerance)
  expectApproximately(actual.z, expected.z, tolerance: tolerance)
}
