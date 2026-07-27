import simd

/// How the Metal view should schedule frames.
///
/// The SwiftUI bridge owns visibility and scene-phase policy. The renderer only
/// translates that resolved policy into one of `MTKView`'s drawing modes.
enum RendererActivity: Equatable, Sendable {
  /// Keep the last drawable and do not schedule or request new frames.
  case paused

  /// Draw only after scene or interaction state changes.
  case onDemand

  /// Let `MTKView` drive a timed render loop.
  case animated(preferredFramesPerSecond: Int)
}

/// Marker input after the public SwiftUI-facing model has been normalized.
struct ResolvedMarker: Equatable, Sendable {
  var id: String
  /// Latitude and longitude in degrees, in that order.
  var locationDegrees: SIMD2<Float>
  /// Marker radius relative to the globe radius.
  var size: Float
  /// `nil` uses `ResolvedGlobeScene.defaultMarkerColor`.
  var color: SIMD3<Float>?

  init(
    id: String,
    locationDegrees: SIMD2<Float>,
    size: Float,
    color: SIMD3<Float>? = nil
  ) {
    self.id = id
    self.locationDegrees = locationDegrees
    self.size = size
    self.color = color
  }
}

/// Arc input after the public SwiftUI-facing model has been normalized.
struct ResolvedArc: Equatable, Sendable {
  var id: String
  /// Latitude and longitude in degrees, in that order.
  var fromDegrees: SIMD2<Float>
  /// Latitude and longitude in degrees, in that order.
  var toDegrees: SIMD2<Float>
  /// COBE-compatible visual width, normally around `0.5`.
  var width: Float
  /// Height above the globe surface in globe-radius units.
  var height: Float
  /// `nil` uses `ResolvedGlobeScene.defaultArcColor`.
  var color: SIMD3<Float>?

  init(
    id: String,
    fromDegrees: SIMD2<Float>,
    toDegrees: SIMD2<Float>,
    width: Float,
    height: Float,
    color: SIMD3<Float>? = nil
  ) {
    self.id = id
    self.fromDegrees = fromDegrees
    self.toDegrees = toDegrees
    self.width = width
    self.height = height
    self.color = color
  }
}

/// Fully resolved, renderer-only scene state.
///
/// Colors are normalized RGB component triples in the `0...1` range. `phi`,
/// `theta`, angular velocities, and rotation rates are radians. `offsetPixels`
/// is in Metal drawable pixels, with positive y moving down the screen.
struct ResolvedGlobeScene: Equatable, Sendable {
  var phi: Float
  var theta: Float
  var scale: Float
  var offsetPixels: SIMD2<Float>

  var mapSamples: Float
  var mapBrightness: Float
  var mapBaseBrightness: Float
  var diffuse: Float
  var darkness: Float
  var opacity: Float

  var baseColor: SIMD3<Float>
  var glowColor: SIMD3<Float>
  var defaultMarkerColor: SIMD3<Float>
  var defaultArcColor: SIMD3<Float>
  var markerElevation: Float

  var markers: [ResolvedMarker]
  var arcs: [ResolvedArc]

  /// Automatic longitudinal rotation, in radians per second.
  var autoRotationRate: Float
  /// Initial or externally supplied angular velocity `(phi, theta)`, in
  /// radians per second.
  var angularVelocity: SIMD2<Float>
  /// Exponential velocity decay in inverse seconds.
  var inertiaDamping: Float
  /// Inclusive `(minimum, maximum)` theta bounds, in radians.
  var thetaBounds: SIMD2<Float>
  /// Restoring acceleration used when inertia carries theta outside its bounds.
  var thetaSpring: Float
  var activity: RendererActivity

  init(
    phi: Float = 0,
    theta: Float = 0,
    scale: Float = 1,
    offsetPixels: SIMD2<Float> = .zero,
    mapSamples: Float = 16_000,
    mapBrightness: Float = 6,
    mapBaseBrightness: Float = 0,
    diffuse: Float = 1.2,
    darkness: Float = 0,
    opacity: Float = 1,
    baseColor: SIMD3<Float> = SIMD3(repeating: 1),
    glowColor: SIMD3<Float> = SIMD3(repeating: 1),
    defaultMarkerColor: SIMD3<Float> = SIMD3(0.2, 0.4, 1),
    defaultArcColor: SIMD3<Float> = SIMD3(0.3, 0.5, 1),
    markerElevation: Float = 0.02,
    markers: [ResolvedMarker] = [],
    arcs: [ResolvedArc] = [],
    autoRotationRate: Float = 0,
    angularVelocity: SIMD2<Float> = .zero,
    inertiaDamping: Float = 5,
    thetaBounds: SIMD2<Float> = SIMD2(-.pi / 2, .pi / 2),
    thetaSpring: Float = 16,
    activity: RendererActivity = .onDemand
  ) {
    self.phi = phi
    self.theta = theta
    self.scale = scale
    self.offsetPixels = offsetPixels
    self.mapSamples = mapSamples
    self.mapBrightness = mapBrightness
    self.mapBaseBrightness = mapBaseBrightness
    self.diffuse = diffuse
    self.darkness = darkness
    self.opacity = opacity
    self.baseColor = baseColor
    self.glowColor = glowColor
    self.defaultMarkerColor = defaultMarkerColor
    self.defaultArcColor = defaultArcColor
    self.markerElevation = markerElevation
    self.markers = markers
    self.arcs = arcs
    self.autoRotationRate = autoRotationRate
    self.angularVelocity = angularVelocity
    self.inertiaDamping = inertiaDamping
    self.thetaBounds = thetaBounds
    self.thetaSpring = thetaSpring
    self.activity = activity
  }
}
