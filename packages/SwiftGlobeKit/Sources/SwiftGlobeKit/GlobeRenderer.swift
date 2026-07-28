// Rendering structure inspired by COBE by Shu Ding (MIT):
// https://github.com/shuding/cobe
//
// SwiftGlobeKit uses an independent Metal renderer and an independently
// generated Natural Earth land mask; it does not embed COBE's JavaScript or
// compiled GLSL.

import CoreGraphics
import Foundation
import Metal
import MetalKit
import QuartzCore
import simd

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

enum GlobeRendererError: Error, LocalizedError {
  case metalUnavailable
  case commandQueueUnavailable
  case shaderLibraryLoadingFailed(Error)
  case shaderFunctionUnavailable(String)
  case pipelineCreationFailed(String)
  case landMaskUnavailable
  case landMaskLoadingFailed(Error)
  case samplerCreationFailed

  var errorDescription: String? {
    switch self {
    case .metalUnavailable:
      "Metal is unavailable on this device."
    case .commandQueueUnavailable:
      "Metal could not create a command queue."
    case .shaderLibraryLoadingFailed(let error):
      "SwiftGlobeKit could not load its bundled Metal library: \(error.localizedDescription)"
    case .shaderFunctionUnavailable(let name):
      "SwiftGlobeKit's Metal shader function \(name) is unavailable."
    case .pipelineCreationFailed(let name):
      "SwiftGlobeKit could not create its \(name) render pipeline."
    case .landMaskUnavailable:
      "SwiftGlobeKit's bundled LandMask.png resource is unavailable."
    case .landMaskLoadingFailed(let error):
      "SwiftGlobeKit could not load LandMask.png: \(error.localizedDescription)"
    case .samplerCreationFailed:
      "SwiftGlobeKit could not create its land-mask sampler."
    }
  }
}

private struct GlobeGPUUniforms {
  var resolutionRotation: SIMD4<Float>
  var samplesScaleOffset: SIMD4<Float>
  var baseColorBrightness: SIMD4<Float>
  var glowColorBaseBrightness: SIMD4<Float>
  var renderParameters: SIMD4<Float>
}

private struct MarkerGPUUniforms {
  var resolutionRotation: SIMD4<Float>
  var scaleElevationOffset: SIMD4<Float>
  var defaultColor: SIMD4<Float>
}

private struct ArcGPUUniforms {
  var resolutionRotation: SIMD4<Float>
  var scaleElevationOffset: SIMD4<Float>
  var defaultColor: SIMD4<Float>
}

private struct MarkerGPUInstance {
  var positionSize: SIMD4<Float>
  var colorAndFlag: SIMD4<Float>
}

private struct ArcGPUInstance {
  var from: SIMD4<Float>
  var to: SIMD4<Float>
  var colorAndFlag: SIMD4<Float>
  var dimensions: SIMD4<Float>
}

private struct GlobePipelineSet {
  var globe: any MTLRenderPipelineState
  var arc: any MTLRenderPipelineState
  var marker: any MTLRenderPipelineState
}

/// Metal rendering core used by the SwiftUI bridge.
///
/// All methods are main-actor isolated because `MTKView`, gesture state, and
/// SwiftUI updates share one lifecycle. GPU work itself remains asynchronous
/// after the command buffer is committed.
@available(macOS 10.15, *)
@MainActor
final class GlobeRenderer: NSObject, MTKViewDelegate {
  private static let globeRadius: Float = 0.8
  private static let arcVertexCount = 66
  private static let markerVertexCount = 6
  private static let maximumDeltaTime: CFTimeInterval = 1.0 / 15.0
  private static let velocityEpsilon: Float = 0.0001
  private static var cachedShaderLibrary: (registryID: UInt64, library: any MTLLibrary)?
  private static var cachedPipelines: (registryID: UInt64, pipelines: GlobePipelineSet)?

  private let device: any MTLDevice
  private weak var view: MTKView?

  private var commandQueue: (any MTLCommandQueue)?
  private var globePipeline: (any MTLRenderPipelineState)?
  private var arcPipeline: (any MTLRenderPipelineState)?
  private var markerPipeline: (any MTLRenderPipelineState)?
  private var landTexture: (any MTLTexture)?
  private var landSampler: (any MTLSamplerState)?

  private var markerBuffer: (any MTLBuffer)?
  private var markerCount = 0
  private var arcBuffer: (any MTLBuffer)?
  private var arcCount = 0

  private var scene: ResolvedGlobeScene?
  private var lastExternalRotation: SIMD2<Float>?
  private var lastExternalAngularVelocity: SIMD2<Float>?
  private var angularVelocity = SIMD2<Float>.zero
  private var lastFrameTime: CFTimeInterval?
  private var isInteractionActive = false
  private var isTornDown = false
  private var appliedActivity: RendererActivity?

  /// The actual on-screen `(phi, theta)`, including renderer-owned automatic
  /// rotation and inertia. Marker/style updates do not reset this value.
  private(set) var currentRotation = SIMD2<Float>.zero

  static func make(view: MTKView) async throws -> GlobeRenderer {
    guard let resolvedDevice = view.device ?? MTLCreateSystemDefaultDevice()
    else {
      throw GlobeRendererError.metalUnavailable
    }

    let pipelines: GlobePipelineSet
    if let cachedPipelines,
      cachedPipelines.registryID == resolvedDevice.registryID
    {
      pipelines = cachedPipelines.pipelines
    } else {
      let library = try await loadShaderLibrary(device: resolvedDevice)
      pipelines = GlobePipelineSet(
        globe: try await makePipeline(
          device: resolvedDevice,
          library: library,
          vertexFunction: "swift_globe::swiftGlobeVertex",
          fragmentFunction: "swift_globe::swiftGlobeFragment",
          pixelFormat: .bgra8Unorm,
          sampleCount: 1,
          label: "globe"
        ),
        arc: try await makePipeline(
          device: resolvedDevice,
          library: library,
          vertexFunction: "swift_globe::swiftGlobeArcVertex",
          fragmentFunction: "swift_globe::swiftGlobeArcFragment",
          pixelFormat: .bgra8Unorm,
          sampleCount: 1,
          label: "arcs"
        ),
        marker: try await makePipeline(
          device: resolvedDevice,
          library: library,
          vertexFunction: "swift_globe::swiftGlobeMarkerVertex",
          fragmentFunction: "swift_globe::swiftGlobeMarkerFragment",
          pixelFormat: .bgra8Unorm,
          sampleCount: 1,
          label: "markers"
        )
      )
      cachedPipelines = (resolvedDevice.registryID, pipelines)
    }

    try Task.checkCancellation()
    return try GlobeRenderer(
      view: view,
      device: resolvedDevice,
      pipelines: pipelines
    )
  }

  private init(
    view: MTKView,
    device resolvedDevice: any MTLDevice,
    pipelines: GlobePipelineSet
  ) throws {
    view.device = resolvedDevice
    view.colorPixelFormat = .bgra8Unorm
    view.depthStencilPixelFormat = .invalid
    view.sampleCount = 1
    view.clearColor = MTLClearColorMake(0, 0, 0, 0)
    view.framebufferOnly = true
    view.autoResizeDrawable = true

    #if canImport(UIKit)
      view.isOpaque = false
    #elseif canImport(AppKit)
      view.wantsLayer = true
      view.layer?.isOpaque = false
    #endif

    guard let resolvedCommandQueue = resolvedDevice.makeCommandQueue() else {
      throw GlobeRendererError.commandQueueUnavailable
    }
    resolvedCommandQueue.label = "SwiftGlobeKit command queue"

    let landTexture = try Self.loadLandTexture(device: resolvedDevice)
    guard let landSampler = Self.makeLandSampler(device: resolvedDevice) else {
      throw GlobeRendererError.samplerCreationFailed
    }

    self.device = resolvedDevice
    self.view = view
    self.commandQueue = resolvedCommandQueue
    self.globePipeline = pipelines.globe
    self.arcPipeline = pipelines.arc
    self.markerPipeline = pipelines.marker
    self.landTexture = landTexture
    self.landSampler = landSampler

    super.init()

    view.delegate = self
    apply(activity: .onDemand)
  }

  /// Applies bridge-resolved scene state.
  ///
  /// The external camera is accepted only when its `(phi, theta)` changed
  /// since the previous bridge update. This preserves renderer-owned
  /// auto-rotation and inertia when SwiftUI re-resolves colors, markers, or
  /// layout with an otherwise unchanged camera.
  func update(scene newScene: ResolvedGlobeScene) {
    guard !isTornDown else { return }

    let previousScene = scene
    let externalRotation = SIMD2(newScene.phi, newScene.theta)
    if lastExternalRotation != externalRotation {
      currentRotation = sanitizedRotation(externalRotation)
      lastExternalRotation = externalRotation
      lastFrameTime = nil
    }

    if lastExternalAngularVelocity != newScene.angularVelocity {
      angularVelocity = sanitizedVelocity(newScene.angularVelocity)
      lastExternalAngularVelocity = newScene.angularVelocity
      lastFrameTime = nil
    }

    if previousScene?.markers != newScene.markers {
      rebuildMarkerBuffer(for: newScene.markers)
    }
    if previousScene?.arcs != newScene.arcs {
      rebuildArcBuffer(for: newScene.arcs)
    }

    scene = newScene
    refreshActivity()
    requestOnDemandDraw()
  }

  /// Applies a direct-manipulation delta in radians.
  func rotate(by delta: SIMD2<Float>) {
    guard !isTornDown else { return }
    currentRotation += sanitizedVelocity(delta)
    if let scene {
      let lowerTheta = min(scene.thetaBounds.x, scene.thetaBounds.y)
      let upperTheta = max(scene.thetaBounds.x, scene.thetaBounds.y)
      currentRotation.y = min(max(currentRotation.y, lowerTheta), upperTheta)
    }
    refreshActivity()
    requestOnDemandDraw()
  }

  /// Supplies release velocity in radians per second.
  func setAngularVelocity(_ velocity: SIMD2<Float>) {
    guard !isTornDown else { return }
    angularVelocity = sanitizedVelocity(velocity)
    lastFrameTime = nil
    refreshActivity()
    requestOnDemandDraw()
  }

  /// Pauses automatic rotation and inertia while a gesture is active.
  func setInteractionActive(_ isActive: Bool) {
    guard !isTornDown else { return }
    isInteractionActive = isActive
    lastFrameTime = nil
    refreshActivity()
    requestOnDemandDraw()
  }

  /// Returns the closest visible marker at a point in the `MTKView`'s local
  /// coordinate space.
  func markerID(
    at point: CGPoint,
    hitRadius: CGFloat = 22
  ) -> String? {
    guard
      !isTornDown,
      let scene,
      let view,
      view.bounds.width > 0,
      view.bounds.height > 0
    else {
      return nil
    }

    var bestMatch: (id: String, distanceSquared: CGFloat, depth: Float)?
    let minimumHitRadius = max(hitRadius, 0)

    for marker in scene.markers {
      let projection = markerProjection(marker, scene: scene, view: view)
      guard projection.isVisible else { continue }

      let visualRadius =
        CGFloat(max(marker.size, 0) * max(scene.scale, 0) * Float(view.bounds.height) * 0.25)
      let resolvedRadius = max(minimumHitRadius, visualRadius)
      let deltaX = projection.point.x - point.x
      let deltaY = projection.point.y - point.y
      let distanceSquared = deltaX * deltaX + deltaY * deltaY
      guard distanceSquared <= resolvedRadius * resolvedRadius else { continue }

      let shouldReplace: Bool
      if let bestMatch {
        shouldReplace =
          distanceSquared < bestMatch.distanceSquared
          || (distanceSquared == bestMatch.distanceSquared && projection.depth > bestMatch.depth)
      } else {
        shouldReplace = true
      }

      if shouldReplace {
        bestMatch = (marker.id, distanceSquared, projection.depth)
      }
    }

    return bestMatch?.id
  }

  /// Releases renderer-owned resources and disconnects from the view.
  ///
  /// The SwiftUI representable should call this from its dismantle path.
  func tearDown() {
    guard !isTornDown else { return }
    isTornDown = true

    if let view {
      view.isPaused = true
      view.delegate = nil
      view.releaseDrawables()
    }

    markerBuffer = nil
    markerCount = 0
    arcBuffer = nil
    arcCount = 0
    landTexture = nil
    landSampler = nil
    globePipeline = nil
    arcPipeline = nil
    markerPipeline = nil
    commandQueue = nil
    scene = nil
    lastFrameTime = nil
    appliedActivity = nil
  }

  func mtkView(
    _ view: MTKView,
    drawableSizeWillChange size: CGSize
  ) {
    guard !isTornDown else { return }
    lastFrameTime = nil
    requestOnDemandDraw()
  }

  func draw(in view: MTKView) {
    guard
      !isTornDown,
      let scene,
      let commandQueue,
      let globePipeline,
      let arcPipeline,
      let markerPipeline,
      let landTexture,
      let landSampler,
      let renderPassDescriptor = view.currentRenderPassDescriptor,
      let drawable = view.currentDrawable,
      let commandBuffer = commandQueue.makeCommandBuffer(),
      let encoder = commandBuffer.makeRenderCommandEncoder(
        descriptor: renderPassDescriptor
      )
    else {
      return
    }

    advanceMotion(scene: scene)

    let drawableSize = view.drawableSize
    let resolution = SIMD2(
      max(Float(drawableSize.width), 1),
      max(Float(drawableSize.height), 1)
    )
    let scale = finiteOr(scene.scale, fallback: 1, minimum: 0.0001)
    let offset = sanitizedVector(scene.offsetPixels)

    var globeUniforms = GlobeGPUUniforms(
      resolutionRotation: SIMD4(
        resolution.x,
        resolution.y,
        currentRotation.x,
        currentRotation.y
      ),
      samplesScaleOffset: SIMD4(
        finiteOr(scene.mapSamples, fallback: 16_000, minimum: 2),
        scale,
        offset.x,
        offset.y
      ),
      baseColorBrightness: SIMD4(
        sanitizedColor(scene.baseColor),
        finiteOr(scene.mapBrightness, fallback: 1, minimum: 0)
      ),
      glowColorBaseBrightness: SIMD4(
        sanitizedColor(scene.glowColor),
        clampedUnit(scene.mapBaseBrightness)
      ),
      renderParameters: SIMD4(
        finiteOr(scene.diffuse, fallback: 1.2, minimum: 0),
        clampedUnit(scene.darkness),
        clampedUnit(scene.opacity),
        0
      )
    )
    var arcUniforms = ArcGPUUniforms(
      resolutionRotation: globeUniforms.resolutionRotation,
      scaleElevationOffset: SIMD4(
        scale,
        finiteOr(scene.markerElevation, fallback: 0, minimum: 0),
        offset.x,
        offset.y
      ),
      defaultColor: SIMD4(sanitizedColor(scene.defaultArcColor), 1)
    )
    var markerUniforms = MarkerGPUUniforms(
      resolutionRotation: globeUniforms.resolutionRotation,
      scaleElevationOffset: arcUniforms.scaleElevationOffset,
      defaultColor: SIMD4(sanitizedColor(scene.defaultMarkerColor), 1)
    )

    commandBuffer.label = "SwiftGlobeKit frame"
    encoder.label = "SwiftGlobeKit globe, arcs, and markers"
    encoder.setCullMode(.none)

    // Pass 1: analytic globe on a fullscreen quad.
    encoder.setRenderPipelineState(globePipeline)
    encoder.setFragmentBytes(
      &globeUniforms,
      length: MemoryLayout<GlobeGPUUniforms>.stride,
      index: 0
    )
    encoder.setFragmentTexture(landTexture, index: 0)
    encoder.setFragmentSamplerState(landSampler, index: 0)
    encoder.drawPrimitives(
      type: .triangle,
      vertexStart: 0,
      vertexCount: Self.markerVertexCount
    )

    // Pass 2: all arcs in one instanced triangle-strip draw.
    if let arcBuffer, arcCount > 0 {
      encoder.setRenderPipelineState(arcPipeline)
      encoder.setVertexBuffer(arcBuffer, offset: 0, index: 0)
      encoder.setVertexBytes(
        &arcUniforms,
        length: MemoryLayout<ArcGPUUniforms>.stride,
        index: 1
      )
      encoder.drawPrimitives(
        type: .triangleStrip,
        vertexStart: 0,
        vertexCount: Self.arcVertexCount,
        instanceCount: arcCount
      )
    }

    // Pass 3: all marker billboards in one instanced triangle draw.
    if let markerBuffer, markerCount > 0 {
      encoder.setRenderPipelineState(markerPipeline)
      encoder.setVertexBuffer(markerBuffer, offset: 0, index: 0)
      encoder.setVertexBytes(
        &markerUniforms,
        length: MemoryLayout<MarkerGPUUniforms>.stride,
        index: 1
      )
      encoder.drawPrimitives(
        type: .triangle,
        vertexStart: 0,
        vertexCount: Self.markerVertexCount,
        instanceCount: markerCount
      )
    }

    encoder.endEncoding()
    commandBuffer.present(drawable)
    commandBuffer.commit()
  }

  private func advanceMotion(scene: ResolvedGlobeScene) {
    let now = CACurrentMediaTime()
    defer { lastFrameTime = now }

    guard !isInteractionActive, let lastFrameTime else { return }
    let deltaTime = Float(
      min(max(now - lastFrameTime, 0), Self.maximumDeltaTime)
    )
    guard deltaTime > 0 else { return }

    currentRotation.x +=
      finiteOr(
        scene.autoRotationRate,
        fallback: 0
      ) * deltaTime

    let lowerTheta = min(scene.thetaBounds.x, scene.thetaBounds.y)
    let upperTheta = max(scene.thetaBounds.x, scene.thetaBounds.y)
    let spring = finiteOr(scene.thetaSpring, fallback: 0, minimum: 0)
    if currentRotation.y < lowerTheta {
      angularVelocity.y +=
        (lowerTheta - currentRotation.y) * spring * deltaTime
    } else if currentRotation.y > upperTheta {
      angularVelocity.y +=
        (upperTheta - currentRotation.y) * spring * deltaTime
    }

    currentRotation += angularVelocity * deltaTime

    let damping = finiteOr(scene.inertiaDamping, fallback: 5, minimum: 0)
    angularVelocity *= exp(-damping * deltaTime)
    if simd_length_squared(angularVelocity) < Self.velocityEpsilon * Self.velocityEpsilon {
      angularVelocity = .zero
    }

    if angularVelocity.y == 0,
      currentRotation.y < lowerTheta + Self.velocityEpsilon
    {
      currentRotation.y = lowerTheta
    } else if angularVelocity.y == 0,
      currentRotation.y > upperTheta - Self.velocityEpsilon
    {
      currentRotation.y = upperTheta
    }

    if abs(currentRotation.x) > .pi * 4 {
      currentRotation.x.formTruncatingRemainder(dividingBy: .pi * 2)
    }

    refreshActivity()
  }

  private func apply(activity: RendererActivity) {
    guard let view, appliedActivity != activity else { return }
    appliedActivity = activity
    lastFrameTime = nil

    switch activity {
    case .paused:
      view.isPaused = true
      view.enableSetNeedsDisplay = false
    case .onDemand:
      view.isPaused = true
      view.enableSetNeedsDisplay = true
    case .animated(let preferredFramesPerSecond):
      view.preferredFramesPerSecond = min(
        max(preferredFramesPerSecond, 1),
        120
      )
      view.enableSetNeedsDisplay = false
      view.isPaused = false
    }
  }

  private func refreshActivity() {
    guard let scene else { return }
    apply(activity: effectiveActivity(for: scene))
  }

  private func effectiveActivity(
    for scene: ResolvedGlobeScene
  ) -> RendererActivity {
    if isInteractionActive {
      switch scene.activity {
      case .paused:
        return .paused
      case .onDemand, .animated:
        return .onDemand
      }
    }

    if case .onDemand = scene.activity,
      hasTransientMotion(in: scene)
    {
      return .animated(
        preferredFramesPerSecond: view?.preferredFramesPerSecond ?? 60
      )
    }

    return scene.activity
  }

  private func hasTransientMotion(in scene: ResolvedGlobeScene) -> Bool {
    if simd_length_squared(angularVelocity) >= Self.velocityEpsilon * Self.velocityEpsilon {
      return true
    }

    let lowerTheta = min(scene.thetaBounds.x, scene.thetaBounds.y)
    let upperTheta = max(scene.thetaBounds.x, scene.thetaBounds.y)
    return
      currentRotation.y < lowerTheta - Self.velocityEpsilon
      || currentRotation.y > upperTheta + Self.velocityEpsilon
  }

  private func requestOnDemandDraw() {
    guard
      let view,
      case .onDemand = appliedActivity
    else {
      return
    }

    #if canImport(UIKit)
      view.setNeedsDisplay()
    #elseif canImport(AppKit)
      view.needsDisplay = true
    #endif
  }

  private func rebuildMarkerBuffer(for markers: [ResolvedMarker]) {
    let instances = markers.map { marker in
      MarkerGPUInstance(
        positionSize: SIMD4(
          unitSpherePosition(for: marker.locationDegrees),
          finiteOr(marker.size, fallback: 0, minimum: 0)
        ),
        colorAndFlag: resolvedColorAndFlag(marker.color)
      )
    }

    markerCount = instances.count
    markerBuffer = makeBuffer(
      values: instances,
      label: "SwiftGlobeKit marker instances"
    )
  }

  private func rebuildArcBuffer(for arcs: [ResolvedArc]) {
    let instances = arcs.map { arc in
      ArcGPUInstance(
        from: SIMD4(unitSpherePosition(for: arc.fromDegrees), 0),
        to: SIMD4(unitSpherePosition(for: arc.toDegrees), 0),
        colorAndFlag: resolvedColorAndFlag(arc.color),
        dimensions: SIMD4(
          finiteOr(arc.width, fallback: 0, minimum: 0),
          finiteOr(arc.height, fallback: 0, minimum: 0),
          0,
          0
        )
      )
    }

    arcCount = instances.count
    arcBuffer = makeBuffer(
      values: instances,
      label: "SwiftGlobeKit arc instances"
    )
  }

  private func makeBuffer<Element>(
    values: [Element],
    label: String
  ) -> (any MTLBuffer)? {
    guard !values.isEmpty else { return nil }

    let buffer = values.withUnsafeBufferPointer { pointer in
      guard let baseAddress = pointer.baseAddress else {
        return nil as (any MTLBuffer)?
      }
      return device.makeBuffer(
        bytes: baseAddress,
        length: MemoryLayout<Element>.stride * values.count,
        options: .storageModeShared
      )
    }
    buffer?.label = label
    return buffer
  }

  private func markerProjection(
    _ marker: ResolvedMarker,
    scene: ResolvedGlobeScene,
    view: MTKView
  ) -> (
    point: CGPoint,
    depth: Float,
    isVisible: Bool
  ) {
    let position =
      unitSpherePosition(for: marker.locationDegrees)
      * (Self.globeRadius + max(scene.markerElevation, 0))
    let rotated = rotateWorldToView(
      position,
      rotation: currentRotation
    )
    let radialDistanceSquared =
      rotated.x * rotated.x + rotated.y * rotated.y
    let isVisible =
      rotated.z >= 0 || radialDistanceSquared >= Self.globeRadius * Self.globeRadius

    let drawableSize = view.drawableSize
    let drawableWidth = max(Float(drawableSize.width), 1)
    let drawableHeight = max(Float(drawableSize.height), 1)
    let inverseAspect = drawableHeight / drawableWidth
    let scale = finiteOr(scene.scale, fallback: 1, minimum: 0.0001)
    let offset = sanitizedVector(scene.offsetPixels)
    let normalizedPosition = SIMD2(
      rotated.x * inverseAspect * scale + offset.x * scale / drawableWidth,
      rotated.y * scale - offset.y * scale / drawableHeight
    )

    let point = CGPoint(
      x: view.bounds.minX + CGFloat((normalizedPosition.x + 1) * 0.5) * view.bounds.width,
      y: view.bounds.minY + CGFloat((1 - normalizedPosition.y) * 0.5) * view.bounds.height
    )
    return (point, rotated.z, isVisible)
  }

  private func unitSpherePosition(
    for locationDegrees: SIMD2<Float>
  ) -> SIMD3<Float> {
    let latitude = finiteOr(locationDegrees.x, fallback: 0) * .pi / 180
    let longitude = finiteOr(locationDegrees.y, fallback: 0) * .pi / 180
    let latitudeRadius = cos(latitude)
    return SIMD3(
      latitudeRadius * sin(longitude),
      sin(latitude),
      latitudeRadius * cos(longitude)
    )
  }

  private func rotateWorldToView(
    _ point: SIMD3<Float>,
    rotation: SIMD2<Float>
  ) -> SIMD3<Float> {
    let cosineTheta = cos(rotation.y)
    let sineTheta = sin(rotation.y)
    let cosinePhi = cos(rotation.x)
    let sinePhi = sin(rotation.x)

    return SIMD3(
      cosinePhi * point.x + sinePhi * point.z,
      sinePhi * sineTheta * point.x + cosineTheta * point.y - cosinePhi * sineTheta * point.z,
      -sinePhi * cosineTheta * point.x + sineTheta * point.y + cosinePhi * cosineTheta * point.z
    )
  }

  private func resolvedColorAndFlag(
    _ color: SIMD3<Float>?
  ) -> SIMD4<Float> {
    guard let color else { return .zero }
    return SIMD4(sanitizedColor(color), 1)
  }

  private func sanitizedRotation(
    _ rotation: SIMD2<Float>
  ) -> SIMD2<Float> {
    SIMD2(
      finiteOr(rotation.x, fallback: 0),
      finiteOr(rotation.y, fallback: 0)
    )
  }

  private func sanitizedVelocity(
    _ velocity: SIMD2<Float>
  ) -> SIMD2<Float> {
    sanitizedVector(velocity)
  }

  private func sanitizedVector(
    _ vector: SIMD2<Float>
  ) -> SIMD2<Float> {
    SIMD2(
      finiteOr(vector.x, fallback: 0),
      finiteOr(vector.y, fallback: 0)
    )
  }

  private func sanitizedColor(
    _ color: SIMD3<Float>
  ) -> SIMD3<Float> {
    SIMD3(
      clampedUnit(color.x),
      clampedUnit(color.y),
      clampedUnit(color.z)
    )
  }

  private func clampedUnit(_ value: Float) -> Float {
    min(max(finiteOr(value, fallback: 0), 0), 1)
  }

  private func finiteOr(
    _ value: Float,
    fallback: Float,
    minimum: Float? = nil
  ) -> Float {
    let resolved = value.isFinite ? value : fallback
    guard let minimum else { return resolved }
    return max(resolved, minimum)
  }

  private static func makePipeline(
    device: any MTLDevice,
    library: any MTLLibrary,
    vertexFunction: String,
    fragmentFunction: String,
    pixelFormat: MTLPixelFormat,
    sampleCount: Int,
    label: String
  ) async throws -> any MTLRenderPipelineState {
    guard let vertex = library.makeFunction(name: vertexFunction) else {
      throw GlobeRendererError.shaderFunctionUnavailable(vertexFunction)
    }
    guard let fragment = library.makeFunction(name: fragmentFunction) else {
      throw GlobeRendererError.shaderFunctionUnavailable(fragmentFunction)
    }

    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.label = "SwiftGlobeKit \(label) pipeline"
    descriptor.vertexFunction = vertex
    descriptor.fragmentFunction = fragment
    descriptor.rasterSampleCount = sampleCount
    descriptor.colorAttachments[0].pixelFormat = pixelFormat
    descriptor.colorAttachments[0].isBlendingEnabled = true
    descriptor.colorAttachments[0].rgbBlendOperation = .add
    descriptor.colorAttachments[0].alphaBlendOperation = .add
    descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
    descriptor.colorAttachments[0].destinationRGBBlendFactor =
      .oneMinusSourceAlpha
    descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
    descriptor.colorAttachments[0].destinationAlphaBlendFactor =
      .oneMinusSourceAlpha

    return try await withCheckedThrowingContinuation { continuation in
      device.makeRenderPipelineState(descriptor: descriptor) {
        pipeline,
        error in
        if let pipeline {
          continuation.resume(returning: pipeline)
        } else if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(
            throwing: GlobeRendererError.pipelineCreationFailed(label)
          )
        }
      }
    }
  }

  private static func loadShaderLibrary(
    device: any MTLDevice
  ) async throws -> any MTLLibrary {
    if let cachedShaderLibrary,
      cachedShaderLibrary.registryID == device.registryID
    {
      return cachedShaderLibrary.library
    }

    let library = try await makeShaderLibrary(device: device)
    cachedShaderLibrary = (device.registryID, library)
    return library
  }

  /// Loads `GlobeShaders.metal`, preferring the library the build system
  /// compiled into the resource bundle.
  ///
  /// Xcode compiles the shader and emits `default.metallib` into
  /// `SwiftGlobeKit_SwiftGlobeKit.bundle`, so hosts get a prebuilt library.
  /// SwiftPM has no Metal compilation rule and copies the `.metal` file
  /// verbatim, so `swift build` and `swift test` produce a bundle with the
  /// source but no default library. Compiling that same source at runtime
  /// keeps the package testable outside Xcode and degrades gracefully rather
  /// than failing outright if a host's build ever stops emitting the library.
  private static func makeShaderLibrary(
    device: any MTLDevice
  ) async throws -> any MTLLibrary {
    let defaultLibraryError: Error
    do {
      return try device.makeDefaultLibrary(bundle: Bundle.module)
    } catch {
      defaultLibraryError = error
    }

    guard
      let sourceURL = Bundle.module.url(
        forResource: "GlobeShaders",
        withExtension: "metal"
      )
    else {
      throw GlobeRendererError.shaderLibraryLoadingFailed(defaultLibraryError)
    }

    do {
      let source = try String(contentsOf: sourceURL, encoding: .utf8)
      return try await withCheckedThrowingContinuation { continuation in
        device.makeLibrary(source: source, options: nil) { library, error in
          if let library {
            continuation.resume(returning: library)
          } else if let error {
            continuation.resume(throwing: error)
          } else {
            continuation.resume(
              throwing: GlobeRendererError.shaderLibraryLoadingFailed(
                defaultLibraryError
              )
            )
          }
        }
      }
    } catch {
      throw GlobeRendererError.shaderLibraryLoadingFailed(error)
    }
  }

  private static func loadLandTexture(
    device: any MTLDevice
  ) throws -> any MTLTexture {
    let resourceURL =
      Bundle.module.url(
        forResource: "LandMask",
        withExtension: "png"
      )
      ?? Bundle.module.url(
        forResource: "LandMask",
        withExtension: "png",
        subdirectory: "Resources"
      )
    guard let resourceURL else {
      throw GlobeRendererError.landMaskUnavailable
    }

    let loader = MTKTextureLoader(device: device)
    do {
      return try loader.newTexture(
        URL: resourceURL,
        options: [
          .SRGB: false,
          .generateMipmaps: false,
          .textureUsage: NSNumber(
            value: MTLTextureUsage.shaderRead.rawValue
          ),
          .textureStorageMode: NSNumber(
            value: MTLStorageMode.private.rawValue
          ),
        ]
      )
    } catch {
      throw GlobeRendererError.landMaskLoadingFailed(error)
    }
  }

  private static func makeLandSampler(
    device: any MTLDevice
  ) -> (any MTLSamplerState)? {
    let descriptor = MTLSamplerDescriptor()
    descriptor.label = "SwiftGlobeKit land mask sampler"
    descriptor.minFilter = .nearest
    descriptor.magFilter = .nearest
    descriptor.mipFilter = .notMipmapped
    descriptor.sAddressMode = .repeat
    descriptor.tAddressMode = .clampToEdge
    return device.makeSamplerState(descriptor: descriptor)
  }
}
