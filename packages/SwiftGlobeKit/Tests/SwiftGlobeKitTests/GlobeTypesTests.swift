import Foundation
import Testing

@testable import SwiftGlobeKit

@Test func coordinateClampsLatitudeAndWrapsLongitude() {
  let northeast = GlobeCoordinate(latitude: 95, longitude: 181)
  #expect(northeast.latitude == 90)
  #expect(northeast.longitude == -179)

  let southwest = GlobeCoordinate(latitude: -100, longitude: -181)
  #expect(southwest.latitude == -90)
  #expect(southwest.longitude == 179)

  #expect(GlobeCoordinate(latitude: 0, longitude: 540).longitude == -180)
}

@Test func coordinateReplacesNonFiniteComponents() {
  let coordinate = GlobeCoordinate(latitude: .nan, longitude: .infinity)
  #expect(coordinate.latitude == 0)
  #expect(coordinate.longitude == 0)
}

@Test func cameraNormalizesItsCenterAndClampsScale() {
  let camera = GlobeCamera(longitude: 200, latitude: -100, scale: 99)
  #expect(camera.longitude == -160)
  #expect(camera.latitude == -90)
  #expect(camera.scale == GlobeCamera.scaleRange.upperBound)
  #expect(camera.coordinate == GlobeCoordinate(latitude: -90, longitude: -160))

  #expect(GlobeCamera(scale: -1).scale == GlobeCamera.scaleRange.lowerBound)
  #expect(GlobeCamera(scale: .nan).scale == 1)
}

@available(macOS 10.15, *)
@Test func markerAndArcClampVisualDimensions() {
  let coordinate = GlobeCoordinate(latitude: 0, longitude: 0)
  let oversizedMarker = GlobeMarker(
    id: "marker",
    coordinate: coordinate,
    size: 12
  )
  #expect(oversizedMarker.size == GlobeMarker.sizeRange.upperBound)
  #expect(GlobeMarker(id: "nan", coordinate: coordinate, size: .nan).size == 0.1)

  let arc = GlobeArc(
    id: "arc",
    from: coordinate,
    to: GlobeCoordinate(latitude: 10, longitude: 20),
    width: -4,
    height: 12
  )
  #expect(arc.width == GlobeArc.widthRange.lowerBound)
  #expect(arc.height == GlobeArc.heightRange.upperBound)
}

@available(macOS 10.15, *)
@Test func styleClampsRendererConfiguration() {
  let style = GlobeStyle(
    mapSamples: -1,
    mapBrightness: -4,
    mapBaseBrightness: 5,
    diffuse: 8,
    darkness: -1,
    opacity: 2,
    markerElevation: -1
  )

  #expect(style.mapSamples == GlobeStyle.mapSamplesRange.lowerBound)
  #expect(style.mapBrightness == GlobeStyle.mapBrightnessRange.lowerBound)
  #expect(style.mapBaseBrightness == GlobeStyle.mapBaseBrightnessRange.upperBound)
  #expect(style.diffuse == GlobeStyle.diffuseRange.upperBound)
  #expect(style.darkness == GlobeStyle.darknessRange.lowerBound)
  #expect(style.opacity == GlobeStyle.opacityRange.upperBound)
  #expect(style.markerElevation == GlobeStyle.markerElevationRange.lowerBound)

  let nonFinite = GlobeStyle(
    mapBrightness: .nan,
    mapBaseBrightness: .infinity,
    diffuse: -.infinity,
    darkness: .nan,
    opacity: .nan,
    markerElevation: .nan
  )
  #expect(nonFinite.mapBrightness == 6)
  #expect(nonFinite.mapBaseBrightness == 0)
  #expect(nonFinite.diffuse == 1.2)
  #expect(nonFinite.darkness == 0)
  #expect(nonFinite.opacity == 1)
  #expect(nonFinite.markerElevation == 0.02)
  #expect(GlobeStyle().darkness == nil)
}

@Test func behaviorClampsAutomaticRotationSpeed() {
  #expect(
    GlobeBehavior(autoRotationSpeed: 20).autoRotationSpeed
      == GlobeBehavior.autoRotationSpeedRange.upperBound
  )
  #expect(
    GlobeBehavior(autoRotationSpeed: -20).autoRotationSpeed
      == GlobeBehavior.autoRotationSpeedRange.lowerBound
  )
  #expect(GlobeBehavior(autoRotationSpeed: .nan).autoRotationSpeed == 0.16)

  let behavior = GlobeBehavior(
    allowsDragging: false,
    allowsInertia: false,
    quality: .efficiency
  )
  #expect(!behavior.allowsDragging)
  #expect(!behavior.allowsInertia)
  #expect(behavior.quality == .efficiency)
}
