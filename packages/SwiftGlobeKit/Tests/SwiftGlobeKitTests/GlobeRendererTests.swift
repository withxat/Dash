#if canImport(AppKit)
  import Metal
  import MetalKit
  import Testing

  @testable import SwiftGlobeKit

  @available(macOS 10.15, *)
  @MainActor
  @Test func rendererLoadsBundledShaderAndLandMask() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
      return
    }

    let view = MTKView(
      frame: CGRect(x: 0, y: 0, width: 128, height: 128),
      device: device
    )
    let renderer = try await GlobeRenderer.make(view: view)
    renderer.update(scene: ResolvedGlobeScene(activity: .paused))

    #expect(renderer.currentRotation == .zero)
    renderer.tearDown()
    #expect(view.delegate == nil)
  }
#endif
