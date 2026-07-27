#if os(iOS)
  import MetalKit
  import SwiftUI
  import UIKit

  /// A native SwiftUI globe rendered by Metal.
  ///
  /// Use the value-based initializer when the camera belongs to the globe. Use
  /// the binding initializer when a parent needs to change the centered
  /// coordinate or observe the camera after direct manipulation.
  @available(iOS 17.0, *)
  public struct DotGlobeView: View {
    private let camera: Binding<GlobeCamera>?
    private let initialCamera: GlobeCamera
    private let style: GlobeStyle
    private let markers: [GlobeMarker]
    private let arcs: [GlobeArc]
    private let behavior: GlobeBehavior
    private let isActive: Bool
    private let accessibilityLabel: String?
    private let onMarkerTap: (@MainActor (GlobeMarker) -> Void)?

    public init(
      camera: GlobeCamera = GlobeCamera(),
      style: GlobeStyle = GlobeStyle(),
      markers: [GlobeMarker] = [],
      arcs: [GlobeArc] = [],
      behavior: GlobeBehavior = GlobeBehavior(),
      isActive: Bool = true,
      accessibilityLabel: String? = nil,
      onMarkerTap: (@MainActor (GlobeMarker) -> Void)? = nil
    ) {
      self.camera = nil
      self.initialCamera = camera
      self.style = style
      self.markers = markers
      self.arcs = arcs
      self.behavior = behavior
      self.isActive = isActive
      self.accessibilityLabel = accessibilityLabel
      self.onMarkerTap = onMarkerTap
    }

    public init(
      camera: Binding<GlobeCamera>,
      style: GlobeStyle = GlobeStyle(),
      markers: [GlobeMarker] = [],
      arcs: [GlobeArc] = [],
      behavior: GlobeBehavior = GlobeBehavior(),
      isActive: Bool = true,
      accessibilityLabel: String? = nil,
      onMarkerTap: (@MainActor (GlobeMarker) -> Void)? = nil
    ) {
      self.camera = camera
      self.initialCamera = camera.wrappedValue
      self.style = style
      self.markers = markers
      self.arcs = arcs
      self.behavior = behavior
      self.isActive = isActive
      self.accessibilityLabel = accessibilityLabel
      self.onMarkerTap = onMarkerTap
    }

    public var body: some View {
      Group {
        if let camera {
          GlobeSurface(
            camera: camera,
            style: style,
            markers: markers,
            arcs: arcs,
            behavior: behavior,
            isActive: isActive,
            accessibilityLabel: accessibilityLabel,
            onMarkerTap: onMarkerTap
          )
        } else {
          StatefulGlobeSurface(
            initialCamera: initialCamera,
            style: style,
            markers: markers,
            arcs: arcs,
            behavior: behavior,
            isActive: isActive,
            accessibilityLabel: accessibilityLabel,
            onMarkerTap: onMarkerTap
          )
        }
      }
    }
  }

  @available(iOS 17.0, *)
  private struct StatefulGlobeSurface: View {
    @State private var camera: GlobeCamera

    let style: GlobeStyle
    let markers: [GlobeMarker]
    let arcs: [GlobeArc]
    let behavior: GlobeBehavior
    let isActive: Bool
    let accessibilityLabel: String?
    let onMarkerTap: (@MainActor (GlobeMarker) -> Void)?

    init(
      initialCamera: GlobeCamera,
      style: GlobeStyle,
      markers: [GlobeMarker],
      arcs: [GlobeArc],
      behavior: GlobeBehavior,
      isActive: Bool,
      accessibilityLabel: String?,
      onMarkerTap: (@MainActor (GlobeMarker) -> Void)?
    ) {
      _camera = State(initialValue: initialCamera)
      self.style = style
      self.markers = markers
      self.arcs = arcs
      self.behavior = behavior
      self.isActive = isActive
      self.accessibilityLabel = accessibilityLabel
      self.onMarkerTap = onMarkerTap
    }

    var body: some View {
      GlobeSurface(
        camera: $camera,
        style: style,
        markers: markers,
        arcs: arcs,
        behavior: behavior,
        isActive: isActive,
        accessibilityLabel: accessibilityLabel,
        onMarkerTap: onMarkerTap
      )
    }
  }

  @available(iOS 17.0, *)
  private struct GlobeSurface: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false

    @Binding var camera: GlobeCamera
    let style: GlobeStyle
    let markers: [GlobeMarker]
    let arcs: [GlobeArc]
    let behavior: GlobeBehavior
    let isActive: Bool
    let accessibilityLabel: String?
    let onMarkerTap: (@MainActor (GlobeMarker) -> Void)?

    private var labeledMarkers: [GlobeMarker] {
      markers.filter { $0.accessibilityLabel?.isEmpty == false }
    }

    var body: some View {
      MetalGlobeView(
        camera: $camera,
        style: style,
        markers: markers,
        arcs: arcs,
        behavior: behavior,
        isActive: isActive && isVisible && scenePhase == .active,
        reduceMotion: reduceMotion,
        colorScheme: colorScheme,
        colorSchemeContrast: colorSchemeContrast,
        displayScale: displayScale,
        onMarkerTap: onMarkerTap
      )
      .accessibilityHidden(
        accessibilityLabel?.isEmpty != false && labeledMarkers.isEmpty
      )
      .accessibilityRepresentation {
        GlobeAccessibilityRepresentation(
          label: accessibilityLabel,
          markers: labeledMarkers,
          onMarkerTap: onMarkerTap
        )
      }
      .onAppear {
        isVisible = true
      }
      .onDisappear {
        isVisible = false
      }
    }
  }

  @available(iOS 17.0, *)
  private struct GlobeAccessibilityRepresentation: View {
    let label: String?
    let markers: [GlobeMarker]
    let onMarkerTap: (@MainActor (GlobeMarker) -> Void)?

    var body: some View {
      VStack {
        if let label, !label.isEmpty {
          Text(verbatim: label)
        }

        ForEach(markers) { marker in
          if let markerLabel = marker.accessibilityLabel {
            if let onMarkerTap {
              Button {
                onMarkerTap(marker)
              } label: {
                Text(verbatim: markerLabel)
              }
            } else {
              Text(verbatim: markerLabel)
            }
          }
        }
      }
    }
  }

  @available(iOS 17.0, *)
  private struct MetalGlobeConfiguration {
    var camera: GlobeCamera
    var style: GlobeStyle
    var markers: [GlobeMarker]
    var arcs: [GlobeArc]
    var behavior: GlobeBehavior
    var isActive: Bool
    var reduceMotion: Bool
    var colorScheme: ColorScheme
    var colorSchemeContrast: ColorSchemeContrast
    var displayScale: CGFloat
    var onMarkerTap: (@MainActor (GlobeMarker) -> Void)?
  }

  @available(iOS 17.0, *)
  private struct MetalGlobeView: UIViewRepresentable {
    @Binding var camera: GlobeCamera

    var style: GlobeStyle
    var markers: [GlobeMarker]
    var arcs: [GlobeArc]
    var behavior: GlobeBehavior
    var isActive: Bool
    var reduceMotion: Bool
    var colorScheme: ColorScheme
    var colorSchemeContrast: ColorSchemeContrast
    var displayScale: CGFloat
    var onMarkerTap: (@MainActor (GlobeMarker) -> Void)?

    func makeCoordinator() -> Coordinator {
      Coordinator(camera: $camera)
    }

    func makeUIView(context: Context) -> MTKView {
      let view = MTKView(frame: .zero)
      view.backgroundColor = .clear
      view.isOpaque = false
      view.clearColor = MTLClearColorMake(0, 0, 0, 0)
      view.isPaused = true
      view.enableSetNeedsDisplay = false
      view.accessibilityElementsHidden = true
      context.coordinator.attach(to: view)
      return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
      context.coordinator.update(
        configuration: MetalGlobeConfiguration(
          camera: camera,
          style: style,
          markers: markers,
          arcs: arcs,
          behavior: behavior,
          isActive: isActive,
          reduceMotion: reduceMotion,
          colorScheme: colorScheme,
          colorSchemeContrast: colorSchemeContrast,
          displayScale: displayScale,
          onMarkerTap: onMarkerTap
        ),
        camera: $camera,
        view: view
      )
    }

    static func dismantleUIView(_ view: MTKView, coordinator: Coordinator) {
      coordinator.tearDown()
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
      private static let dragRadiansPerPoint: Float = 0.005
      private static let maximumReleaseVelocity: Float = 6
      private static let navigationEdgeWidth: CGFloat = 28

      private weak var view: MTKView?
      private var renderer: GlobeRenderer?
      private var rendererSetupTask: Task<Void, Never>?
      private var camera: Binding<GlobeCamera>
      private var configuration: MetalGlobeConfiguration?
      private var markersByID: [String: GlobeMarker] = [:]
      private var panGesture: UIPanGestureRecognizer?
      private var tapGesture: UITapGestureRecognizer?
      private var powerStateObserver: (any NSObjectProtocol)?
      private var isTornDown = false

      init(camera: Binding<GlobeCamera>) {
        self.camera = camera
        super.init()
      }

      func attach(to view: MTKView) {
        guard !isTornDown else { return }
        self.view = view

        rendererSetupTask = Task { @MainActor [weak self, weak view] in
          guard let view else { return }

          do {
            let renderer = try await GlobeRenderer.make(view: view)
            guard !Task.isCancelled else {
              renderer.tearDown()
              return
            }
            guard
              let self,
              !self.isTornDown,
              self.view === view
            else {
              renderer.tearDown()
              return
            }

            self.renderer = renderer
            self.rendererSetupTask = nil
            if let configuration = self.configuration {
              self.apply(configuration, to: view)
            }
          } catch is CancellationError {
            self?.rendererSetupTask = nil
          } catch {
            self?.rendererSetupTask = nil
            assertionFailure(error.localizedDescription)
          }
        }

        let panGesture = UIPanGestureRecognizer(
          target: self,
          action: #selector(handlePan(_:))
        )
        panGesture.cancelsTouchesInView = false
        panGesture.maximumNumberOfTouches = 1
        panGesture.delegate = self
        view.addGestureRecognizer(panGesture)
        self.panGesture = panGesture

        let tapGesture = UITapGestureRecognizer(
          target: self,
          action: #selector(handleTap(_:))
        )
        tapGesture.cancelsTouchesInView = false
        tapGesture.require(toFail: panGesture)
        view.addGestureRecognizer(tapGesture)
        self.tapGesture = tapGesture

        powerStateObserver = NotificationCenter.default.addObserver(
          forName: .NSProcessInfoPowerStateDidChange,
          object: nil,
          queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated {
            self?.powerStateDidChange()
          }
        }
      }

      func update(
        configuration: MetalGlobeConfiguration,
        camera: Binding<GlobeCamera>,
        view: MTKView
      ) {
        guard !isTornDown else { return }
        self.camera = camera
        self.configuration = configuration
        self.view = view
        markersByID = Dictionary(
          configuration.markers.map { ($0.id, $0) },
          uniquingKeysWith: { _, last in last }
        )

        apply(configuration, to: view)
      }

      func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        if let powerStateObserver {
          NotificationCenter.default.removeObserver(powerStateObserver)
        }
        powerStateObserver = nil

        if let panGesture {
          view?.removeGestureRecognizer(panGesture)
        }
        if let tapGesture {
          view?.removeGestureRecognizer(tapGesture)
        }
        rendererSetupTask?.cancel()
        rendererSetupTask = nil
        panGesture?.delegate = nil
        panGesture = nil
        tapGesture = nil
        renderer?.tearDown()
        renderer = nil
        view = nil
        configuration = nil
        markersByID.removeAll(keepingCapacity: false)
      }

      func gestureRecognizerShouldBegin(
        _ gestureRecognizer: UIGestureRecognizer
      ) -> Bool {
        guard
          gestureRecognizer === panGesture,
          let configuration,
          configuration.isActive,
          configuration.behavior.allowsDragging,
          let panGesture,
          let view
        else {
          return gestureRecognizer !== panGesture
        }

        if panGesture.location(in: view).x <= Self.navigationEdgeWidth {
          return false
        }

        let velocity = panGesture.velocity(in: view)
        return abs(velocity.x) > abs(velocity.y)
      }

      @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let renderer else { return }
        switch gesture.state {
        case .began:
          guard
            let configuration,
            configuration.isActive,
            configuration.behavior.allowsDragging
          else {
            return
          }
          renderer.setAngularVelocity(.zero)
          renderer.setInteractionActive(true)
        case .changed:
          guard
            let configuration,
            configuration.isActive,
            configuration.behavior.allowsDragging,
            let view
          else {
            renderer.setInteractionActive(false)
            renderer.setAngularVelocity(.zero)
            return
          }
          let translation = gesture.translation(in: view)
          renderer.rotate(
            by: SIMD2(
              Float(translation.x) * Self.dragRadiansPerPoint,
              Float(translation.y) * Self.dragRadiansPerPoint
            )
          )
          gesture.setTranslation(.zero, in: view)
        case .ended:
          renderer.setInteractionActive(false)
          if let configuration,
            configuration.isActive,
            configuration.behavior.allowsInertia,
            !configuration.reduceMotion
          {
            guard let view else {
              renderer.setAngularVelocity(.zero)
              writeCamera(from: renderer.currentRotation)
              return
            }
            let velocity = gesture.velocity(in: view)
            renderer.setAngularVelocity(
              cappedVelocity(
                SIMD2(
                  Float(velocity.x) * Self.dragRadiansPerPoint,
                  Float(velocity.y) * Self.dragRadiansPerPoint
                )
              )
            )
          } else {
            renderer.setAngularVelocity(.zero)
          }
          writeCamera(from: renderer.currentRotation)
        case .cancelled, .failed:
          renderer.setInteractionActive(false)
          renderer.setAngularVelocity(.zero)
          writeCamera(from: renderer.currentRotation)
        default:
          break
        }
      }

      @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard
          gesture.state == .ended,
          let configuration,
          configuration.isActive,
          let onMarkerTap = configuration.onMarkerTap,
          let view,
          let markerID = renderer?.markerID(at: gesture.location(in: view)),
          let marker = markersByID[markerID]
        else {
          return
        }

        onMarkerTap(marker)
      }

      private func powerStateDidChange() {
        guard let configuration, let view else { return }
        apply(configuration, to: view)
      }

      private func apply(
        _ configuration: MetalGlobeConfiguration,
        to view: MTKView
      ) {
        let isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        let renderScale = resolvedRenderScale(
          displayScale: configuration.displayScale,
          quality: configuration.behavior.quality,
          isLowPowerModeEnabled: isLowPowerModeEnabled
        )
        if view.contentScaleFactor != renderScale {
          view.contentScaleFactor = renderScale
        }

        let preferredFramesPerSecond = resolvedFramesPerSecond(
          quality: configuration.behavior.quality,
          isLowPowerModeEnabled: isLowPowerModeEnabled
        )
        view.preferredFramesPerSecond = preferredFramesPerSecond

        let enablesDragging =
          renderer != nil
          && configuration.isActive
          && configuration.behavior.allowsDragging
        if panGesture?.isEnabled == true, !enablesDragging {
          renderer?.setInteractionActive(false)
          renderer?.setAngularVelocity(.zero)
        }
        panGesture?.isEnabled = enablesDragging
        tapGesture?.isEnabled =
          renderer != nil
          && configuration.isActive
          && configuration.onMarkerTap != nil

        let autoRotationRate =
          configuration.reduceMotion
          ? 0
          : Float(configuration.behavior.autoRotationSpeed)
        let activity: RendererActivity
        if !configuration.isActive {
          activity = .paused
        } else if autoRotationRate != 0 {
          activity = .animated(
            preferredFramesPerSecond: min(preferredFramesPerSecond, 30)
          )
        } else {
          activity = .onDemand
        }

        let traits = UITraitCollection { traits in
          traits.userInterfaceStyle =
            configuration.colorScheme == .dark ? .dark : .light
          traits.accessibilityContrast =
            configuration.colorSchemeContrast == .increased ? .high : .normal
          traits.displayScale = renderScale
        }
        let style = configuration.style
        let resolvedScene = ResolvedGlobeScene(
          phi: Float(-configuration.camera.longitude * .pi / 180),
          theta: Float(configuration.camera.latitude * .pi / 180),
          scale: Float(configuration.camera.scale),
          mapSamples: resolvedMapSamples(
            style.mapSamples,
            quality: configuration.behavior.quality,
            isLowPowerModeEnabled: isLowPowerModeEnabled
          ),
          mapBrightness: Float(style.mapBrightness),
          mapBaseBrightness: Float(style.mapBaseBrightness),
          diffuse: Float(style.diffuse),
          darkness: Float(
            style.darkness ?? (configuration.colorScheme == .dark ? 1 : 0)
          ),
          opacity: Float(style.opacity),
          baseColor: resolvedColor(style.baseColor, traits: traits),
          glowColor: resolvedColor(style.glowColor, traits: traits),
          defaultMarkerColor: resolvedColor(
            style.defaultMarkerColor,
            traits: traits
          ),
          defaultArcColor: resolvedColor(
            style.defaultArcColor,
            traits: traits
          ),
          markerElevation: Float(style.markerElevation),
          markers: configuration.markers.map {
            ResolvedMarker(
              id: $0.id,
              locationDegrees: SIMD2(
                Float($0.coordinate.latitude),
                Float($0.coordinate.longitude)
              ),
              size: Float($0.size),
              color: $0.color.map { resolvedColor($0, traits: traits) }
            )
          },
          arcs: configuration.arcs.map {
            ResolvedArc(
              id: $0.id,
              fromDegrees: SIMD2(
                Float($0.from.latitude),
                Float($0.from.longitude)
              ),
              toDegrees: SIMD2(
                Float($0.to.latitude),
                Float($0.to.longitude)
              ),
              width: Float($0.width),
              height: Float($0.height),
              color: $0.color.map { resolvedColor($0, traits: traits) }
            )
          },
          autoRotationRate: autoRotationRate,
          inertiaDamping: 5,
          thetaBounds: SIMD2(-.pi / 2, .pi / 2),
          thetaSpring: 18,
          activity: activity
        )
        renderer?.update(scene: resolvedScene)
        if !configuration.isActive
          || configuration.reduceMotion
          || !configuration.behavior.allowsInertia
        {
          renderer?.setAngularVelocity(.zero)
        }
      }

      private func writeCamera(from rotation: SIMD2<Float>) {
        camera.wrappedValue = GlobeCamera(
          longitude: Double(-rotation.x * 180 / .pi),
          latitude: Double(rotation.y * 180 / .pi),
          scale: camera.wrappedValue.scale
        )
      }

      private func cappedVelocity(
        _ velocity: SIMD2<Float>
      ) -> SIMD2<Float> {
        let length = simd_length(velocity)
        guard length > Self.maximumReleaseVelocity else { return velocity }
        return velocity / length * Self.maximumReleaseVelocity
      }

      private func resolvedRenderScale(
        displayScale: CGFloat,
        quality: GlobeQuality,
        isLowPowerModeEnabled: Bool
      ) -> CGFloat {
        let maximumScale: CGFloat
        switch quality {
        case .efficiency:
          maximumScale = 1
        case .adaptive:
          maximumScale = isLowPowerModeEnabled ? 1 : 2
        case .quality:
          maximumScale = isLowPowerModeEnabled ? 1.5 : 2
        }
        return max(1, min(displayScale, maximumScale))
      }

      private func resolvedFramesPerSecond(
        quality: GlobeQuality,
        isLowPowerModeEnabled: Bool
      ) -> Int {
        guard !isLowPowerModeEnabled else { return 30 }
        switch quality {
        case .adaptive:
          return 60
        case .efficiency:
          return 30
        case .quality:
          return 60
        }
      }

      private func resolvedMapSamples(
        _ samples: Int,
        quality: GlobeQuality,
        isLowPowerModeEnabled: Bool
      ) -> Float {
        let maximumSamples: Int
        switch quality {
        case .efficiency:
          maximumSamples = 8_000
        case .adaptive:
          maximumSamples = isLowPowerModeEnabled ? 8_000 : 16_000
        case .quality:
          maximumSamples = isLowPowerModeEnabled ? 16_000 : samples
        }
        return Float(min(samples, maximumSamples))
      }

      private func resolvedColor(
        _ color: Color,
        traits: UITraitCollection
      ) -> SIMD3<Float> {
        let resolvedColor = UIColor(color).resolvedColor(with: traits)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard
          resolvedColor.getRed(
            &red,
            green: &green,
            blue: &blue,
            alpha: &alpha
          )
        else {
          return .zero
        }
        return SIMD3(Float(red), Float(green), Float(blue))
      }
    }
  }
#endif
