import Foundation
import SwiftUI

/// A geographic coordinate in degrees.
///
/// Latitude is clamped to `-90...90`. Longitude wraps to `-180..<180`, making
/// equivalent coordinates compare equally across the antimeridian.
public struct GlobeCoordinate: Hashable, Sendable {
  public let latitude: Double
  public let longitude: Double

  public init(latitude: Double, longitude: Double) {
    self.latitude = GlobeMath.normalizedLatitude(latitude)
    self.longitude = GlobeMath.normalizedLongitude(longitude)
  }
}

/// The geographic point centered in the globe and its visual scale.
public struct GlobeCamera: Hashable, Sendable {
  public static let scaleRange = 0.5...2.5

  public let longitude: Double
  public let latitude: Double
  public let scale: Double

  public init(
    longitude: Double = 0,
    latitude: Double = 0,
    scale: Double = 1
  ) {
    self.longitude = GlobeMath.normalizedLongitude(longitude)
    self.latitude = GlobeMath.normalizedLatitude(latitude)
    self.scale = GlobeMath.clamped(
      scale,
      to: Self.scaleRange,
      default: 1
    )
  }

  public var coordinate: GlobeCoordinate {
    GlobeCoordinate(latitude: latitude, longitude: longitude)
  }
}

/// A highlighted point rendered above the globe surface.
@available(macOS 10.15, *)
public struct GlobeMarker: Identifiable, Hashable, Sendable {
  public static let sizeRange = 0...1.0

  public let id: String
  public let coordinate: GlobeCoordinate
  public let size: Double
  public let color: Color?
  public let accessibilityLabel: String?

  public init(
    id: String,
    coordinate: GlobeCoordinate,
    size: Double = 0.1,
    color: Color? = nil,
    accessibilityLabel: String? = nil
  ) {
    self.id = id
    self.coordinate = coordinate
    self.size = GlobeMath.clamped(
      size,
      to: Self.sizeRange,
      default: 0.1
    )
    self.color = color
    self.accessibilityLabel = accessibilityLabel
  }
}

/// A great-circle connection rendered between two geographic coordinates.
@available(macOS 10.15, *)
public struct GlobeArc: Identifiable, Hashable, Sendable {
  public static let widthRange = 0...4.0
  public static let heightRange = 0...2.0

  public let id: String
  public let from: GlobeCoordinate
  public let to: GlobeCoordinate
  public let width: Double
  public let height: Double
  public let color: Color?

  public init(
    id: String,
    from: GlobeCoordinate,
    to: GlobeCoordinate,
    width: Double = 0.5,
    height: Double = 0.2,
    color: Color? = nil
  ) {
    self.id = id
    self.from = from
    self.to = to
    self.width = GlobeMath.clamped(
      width,
      to: Self.widthRange,
      default: 0.5
    )
    self.height = GlobeMath.clamped(
      height,
      to: Self.heightRange,
      default: 0.2
    )
    self.color = color
  }
}

/// Visual controls shared by the land map, markers, arcs, and atmosphere.
@available(macOS 10.15, *)
public struct GlobeStyle: Hashable, Sendable {
  public static let mapSamplesRange = 1_000...64_000
  public static let mapBrightnessRange = 0...20.0
  public static let mapBaseBrightnessRange = 0...1.0
  public static let diffuseRange = 0...4.0
  public static let darknessRange = 0...1.0
  public static let opacityRange = 0...1.0
  public static let markerElevationRange = 0...0.5

  public let baseColor: Color
  public let glowColor: Color
  public let defaultMarkerColor: Color
  public let defaultArcColor: Color
  public let mapSamples: Int
  public let mapBrightness: Double
  public let mapBaseBrightness: Double
  public let diffuse: Double
  /// `nil` adapts to the surrounding color scheme.
  public let darkness: Double?
  public let opacity: Double
  public let markerElevation: Double

  public init(
    baseColor: Color = Color(red: 0.3, green: 0.3, blue: 0.3),
    glowColor: Color = .white,
    defaultMarkerColor: Color = Color(red: 0.1, green: 0.8, blue: 1),
    defaultArcColor: Color = Color(red: 0.1, green: 0.8, blue: 1),
    mapSamples: Int = 16_000,
    mapBrightness: Double = 6,
    mapBaseBrightness: Double = 0,
    diffuse: Double = 1.2,
    darkness: Double? = nil,
    opacity: Double = 1,
    markerElevation: Double = 0.02
  ) {
    self.baseColor = baseColor
    self.glowColor = glowColor
    self.defaultMarkerColor = defaultMarkerColor
    self.defaultArcColor = defaultArcColor
    self.mapSamples = min(
      max(mapSamples, Self.mapSamplesRange.lowerBound), Self.mapSamplesRange.upperBound)
    self.mapBrightness = GlobeMath.clamped(
      mapBrightness,
      to: Self.mapBrightnessRange,
      default: 6
    )
    self.mapBaseBrightness = GlobeMath.clamped(
      mapBaseBrightness,
      to: Self.mapBaseBrightnessRange,
      default: 0
    )
    self.diffuse = GlobeMath.clamped(
      diffuse,
      to: Self.diffuseRange,
      default: 1.2
    )
    self.darkness = darkness.map {
      GlobeMath.clamped(
        $0,
        to: Self.darknessRange,
        default: 0
      )
    }
    self.opacity = GlobeMath.clamped(
      opacity,
      to: Self.opacityRange,
      default: 1
    )
    self.markerElevation = GlobeMath.clamped(
      markerElevation,
      to: Self.markerElevationRange,
      default: 0.02
    )
  }
}

/// Rendering policy used to balance motion, energy, and visual fidelity.
public enum GlobeQuality: String, CaseIterable, Hashable, Sendable {
  /// Chooses a suitable policy for the device and current interaction.
  case adaptive
  /// Prefers fewer samples and lower frame rates.
  case efficiency
  /// Prefers denser rendering and smoother direct manipulation.
  case quality
}

/// Motion and interaction controls for a globe.
public struct GlobeBehavior: Hashable, Sendable {
  public static let autoRotationSpeedRange = -2.0...2.0

  /// Automatic longitudinal rotation in radians per second.
  public let autoRotationSpeed: Double
  public let allowsDragging: Bool
  public let allowsInertia: Bool
  public let quality: GlobeQuality

  public init(
    autoRotationSpeed: Double = 0.16,
    allowsDragging: Bool = true,
    allowsInertia: Bool = true,
    quality: GlobeQuality = .adaptive
  ) {
    self.autoRotationSpeed = GlobeMath.clamped(
      autoRotationSpeed,
      to: Self.autoRotationSpeedRange,
      default: 0.16
    )
    self.allowsDragging = allowsDragging
    self.allowsInertia = allowsInertia
    self.quality = quality
  }
}
