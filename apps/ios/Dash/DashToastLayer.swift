import SwiftUI
import UIKit

// MARK: - Cross-window channels

/// Traffic between the toast layer and the rest of the app.
///
/// The layer lives in its own `UIWindow` (see `dashToastLayer`), and a
/// preference cannot cross a window any more than it can cross a
/// `UIHostingController` — so the two values the tray and the toast used to
/// trade as preferences travel through here instead.
///
/// Every property has exactly ONE reader, the rule `DashHeaderScrollState` and
/// `DashWorkspaceWashScroll` already follow: `@Observable` tracks per property,
/// so a box several bodies read would refresh all of them on every write.
@MainActor
@Observable
final class DashToastLayerState {
  /// The visible success toast's leading mark — a scheduled flight's landing
  /// point. Written by `DashToastCard`, read by the tray that schedules one.
  var leadingMark: DashToastLeadingMark?

  /// True while a scheduled check is travelling: the toast drops its own
  /// leading mark so the arriving glyph takes that seat instead of doubling it.
  private(set) var successFlightInProgress = false

  /// The flight itself. The layer renders it, because the check has to land
  /// *on* the toast and the toast is now the topmost thing on screen.
  private(set) var flight: DashTrayCheckFlight?
  var flightProgress: CGFloat = 0

  @ObservationIgnored private var flightCompletion: (@MainActor () -> Void)?

  /// UIKit's hook for the window's touch region. Deliberately unobserved: the
  /// card republishes it on every frame it moves, and no SwiftUI body may be
  /// invalidated by that.
  @ObservationIgnored var onInteractiveFrameChange: (@MainActor (CGRect) -> Void)?

  func beginSuccessFlight(
    _ flight: DashTrayCheckFlight,
    completion: @escaping @MainActor () -> Void
  ) {
    flightProgress = 0
    flightCompletion = completion
    successFlightInProgress = true
    self.flight = flight
  }

  /// Called by the layer once the check has landed. The completion is the
  /// tray's remaining exit stage, so it runs exactly once.
  func endSuccessFlight() {
    let completion = flightCompletion
    flightCompletion = nil
    clearSuccessFlight()
    completion?()
  }

  /// Defensive teardown for a tray that goes away without its flight
  /// finishing. It drops the completion rather than running it: the exit stage
  /// belongs to a cover that is already gone, and firing it again would take
  /// `remainingExitStages` below zero and dismiss twice.
  func cancelSuccessFlight() {
    flightCompletion = nil
    clearSuccessFlight()
  }

  private func clearSuccessFlight() {
    flight = nil
    flightProgress = 0
    successFlightInProgress = false
  }

  func publishInteractiveFrame(_ frame: CGRect) {
    onInteractiveFrameChange?(frame)
  }
}

private struct DashToastLayerStateKey: EnvironmentKey {
  static let defaultValue: DashToastLayerState? = nil
}

extension EnvironmentValues {
  var dashToastLayerState: DashToastLayerState? {
    get { self[DashToastLayerStateKey.self] }
    set { self[DashToastLayerStateKey.self] = newValue }
  }
}

// MARK: - Success-check flight

/// One scheduled flight: where the check lifts off, where it lands, and the
/// pill ink it leaves in — resolved by the tray before the tray goes away,
/// because the layer that draws the arc has no tone of its own.
struct DashTrayCheckFlight: Equatable {
  let start: CGRect
  let end: CGRect
  let liftoffColor: Color
}

struct DashTrayCheckFlightEffect: ViewModifier, Animatable {
  /// Which side of the ink → green crossfade this glyph carries. The two
  /// same-silhouette layers ride identical arcs; only their opacity ramps
  /// mirror each other.
  enum ColorRole {
    case liftoff
    case landing
  }

  var progress: CGFloat
  let start: CGRect
  let end: CGRect
  /// The overlay container's global origin, subtracted so global endpoint
  /// frames position correctly inside it.
  let containerOrigin: CGPoint
  var colorRole = ColorRole.landing

  // Nonisolated for the same SE-0434 reason as DashTrayCardReveal.
  nonisolated var animatableData: CGFloat {
    get { progress }
    set { progress = newValue }
  }

  func body(content: Content) -> some View {
    let center = DashTrayFlightMath.point(
      from: CGPoint(x: start.midX, y: start.midY),
      to: CGPoint(x: end.midX, y: end.midY),
      progress: progress
    )
    let blend = DashTrayFlightMath.colorBlend(progress)
    content
      .scaleEffect(
        DashTrayFlightMath.scale(from: start.height, to: end.height, progress: progress)
      )
      .position(x: center.x - containerOrigin.x, y: center.y - containerOrigin.y)
      .opacity(
        DashTrayFlightMath.opacity(progress) * (colorRole == .landing ? blend : 1 - blend))
  }
}

// MARK: - Layer content

/// The app's ONE toast surface.
///
/// It used to be mounted twice — on the workspace canvas and again inside every
/// tray cover — because a tray is a `fullScreenCover` and a canvas-mounted
/// toast would otherwise sit under its scrim. Both hosts read the same
/// `DashToastCenter.current`, so a toast raised over a tray rendered *twice*:
/// the cover's copy started its spring about 50ms after the canvas copy and
/// slid down over it, and for those few frames the canvas copy showed as a
/// second card peeking out below. One host in a window above every
/// presentation — trays, covers, QuickLook — leaves nothing to duplicate.
private struct DashToastLayerContent: View {
  /// The device's top safe-area inset, resolved by the installer.
  ///
  /// SwiftUI cannot supply it here. The layer lays out from the window's own
  /// top edge — the origin the flight's global endpoints use — and once the
  /// root is full-bleed (`safeAreaRegions = []`), `safeAreaPadding(.top)` and
  /// `GeometryProxy.safeAreaInsets` both report zero, which parked the toast at
  /// 10pt: under the Dynamic Island. It arrives as a plain input rather than as
  /// observable state written from `layoutSubviews`, because *that* wrote into
  /// the graph from inside a layout pass the graph was driving — an
  /// AttributeGraph cycle, logged on every frame the window laid out.
  let topInset: CGFloat
  @Environment(\.dashToastLayerState) private var state

  var body: some View {
    ZStack(alignment: .top) {
      DashToastHost(topInset: topInset)
      // Above the toast: the check lands *on* the toast's leading mark, so it
      // has to be drawn in the same layer rather than in the tray it left.
      flightOverlay
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }

  /// One-shot overlay for the success-check flight. Mounted at progress 0 and
  /// animated from its own `onAppear` so the insertion is committed before the
  /// travel starts (an implicit animation on a freshly inserted view would
  /// render straight at the target). Two same-silhouette glyphs crossfade along
  /// the arc — the check lifts off in the pill's ink and lands in the toast's
  /// green, so neither endpoint pops a foreign color.
  @ViewBuilder private var flightOverlay: some View {
    if let state, let flight = state.flight {
      GeometryReader { proxy in
        let origin = proxy.frame(in: .global).origin
        ZStack {
          Color.clear
            .contentShape(Rectangle())
          flightCheck(
            flight, progress: state.flightProgress, in: origin,
            color: flight.liftoffColor, role: .liftoff)
          flightCheck(
            flight, progress: state.flightProgress, in: origin,
            color: DashTheme.success, role: .landing)
        }
        .onAppear {
          withAnimation(DashTheme.Motion.settle) {
            state.flightProgress = 1
          } completion: {
            state.endSuccessFlight()
          }
        }
      }
      .ignoresSafeArea()
      // The terminal flight owns this brief handoff. Blocking touches keeps
      // the destination toast from being dismissed before the check lands.
      .allowsHitTesting(true)
      .accessibilityHidden(true)
    }
  }

  private func flightCheck(
    _ flight: DashTrayCheckFlight, progress: CGFloat, in origin: CGPoint,
    color: Color, role: DashTrayCheckFlightEffect.ColorRole
  ) -> some View {
    SolarIcon(
      asset: SolarAsset.checkCircleFill,
      size: max(flight.start.height, 1),
      color: color
    )
    .modifier(
      DashTrayCheckFlightEffect(
        progress: progress,
        start: flight.start, end: flight.end,
        containerOrigin: origin, colorRole: role))
  }
}

// MARK: - Window

/// The layer's window takes touches only where the toast card actually is.
/// A window that swallowed the whole screen would eat the header — and the
/// tray under it — for the toast's entire dwell.
private final class DashToastLayerWindow: UIWindow {
  var interactiveFrame: CGRect = .null

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    interactiveFrame.contains(point)
  }
}

/// Zero-size anchor whose only job is to hand the installer a window scene.
/// `updateUIView` can run before the view is in a window, and `layoutSubviews`
/// may never run for an empty frame, so the move itself is the signal.
private final class DashToastLayerAnchorView: UIView {
  var onMoveToWindow: (@MainActor () -> Void)?

  override func didMoveToWindow() {
    super.didMoveToWindow()
    onMoveToWindow?()
  }
}

private struct DashToastLayerInstaller: UIViewRepresentable {
  let state: DashToastLayerState
  let model: AppModel
  let locale: Locale
  let dynamicTypeSize: DynamicTypeSize

  /// What the layer's root view is actually built from. Everything else it
  /// shows arrives by observation, inside its own window's update pass.
  struct Inputs: Equatable {
    let model: ObjectIdentifier
    let state: ObjectIdentifier
    let locale: Locale
    let dynamicTypeSize: DynamicTypeSize
    let topInset: CGFloat
  }

  private func inputs(scene: UIWindowScene?) -> Inputs {
    Inputs(
      model: ObjectIdentifier(model), state: ObjectIdentifier(state),
      locale: locale, dynamicTypeSize: dynamicTypeSize,
      topInset: Self.topInset(in: scene))
  }

  /// Read from the app's own window, not the layer's: same device, same inset,
  /// and that one is laid out long before a toast can be raised. The layer's
  /// window is never key, so `keyWindow` is always the app's.
  ///
  /// Resolved here — during a SwiftUI *update* — rather than from the layer
  /// window's `layoutSubviews`. That is the same value either way, but writing
  /// it from layout meant writing into the graph from inside a pass the graph
  /// was driving, which AttributeGraph reports as a cycle on every frame the
  /// window lays out.
  private static func topInset(in scene: UIWindowScene?) -> CGFloat {
    scene?.keyWindow?.safeAreaInsets.top ?? 0
  }

  func makeCoordinator() -> Coordinator { Coordinator(state: state) }

  func makeUIView(context: Context) -> UIView {
    let view = DashToastLayerAnchorView()
    view.isUserInteractionEnabled = false
    view.backgroundColor = .clear
    view.onMoveToWindow = { [weak view, coordinator = context.coordinator] in
      let scene = view?.window?.windowScene
      coordinator.sync(
        scene: scene, inputs: inputs(scene: scene), rootView: rootView(scene: scene))
    }
    return view
  }

  func updateUIView(_ uiView: UIView, context: Context) {
    let scene = uiView.window?.windowScene
    context.coordinator.sync(
      scene: scene, inputs: inputs(scene: scene), rootView: rootView(scene: scene))
  }

  static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
    coordinator.teardown()
  }

  /// A window is a fresh SwiftUI root and inherits nothing, so everything a
  /// tray resolves through the app's environment is re-applied here by hand:
  /// the model, the in-app locale (`DashL10n` and absolute dates read it), the
  /// effective Dynamic Type size, and the brand tint.
  private func rootView(scene: UIWindowScene?) -> AnyView {
    AnyView(
      DashToastLayerContent(topInset: Self.topInset(in: scene))
        .environment(model)
        .environment(\.locale, locale)
        .environment(\.dynamicTypeSize, dynamicTypeSize)
        .environment(\.dashToastLayerState, state)
        .tint(DashTheme.brand)
    )
  }

  @MainActor
  final class Coordinator {
    private let state: DashToastLayerState
    private var window: DashToastLayerWindow?
    private var host: UIHostingController<AnyView>?
    private var appliedInputs: Inputs?

    init(state: DashToastLayerState) {
      self.state = state
      state.onInteractiveFrameChange = { [weak self] frame in
        self?.window?.interactiveFrame = frame
      }
    }

    /// Reassigns `rootView` ONLY when what it is built from changed — a
    /// language switch, effectively.
    ///
    /// `updateUIView` runs inside the *app* window's update pass, and assigning
    /// `rootView` pushes that pass's transaction into the layer's window. Doing
    /// it unconditionally meant any app-tree invalidation flushed the layer
    /// with animations off: the entrance spring was cut about halfway, and a
    /// dismissal — which invalidates the tray through `leadingMark` — landed
    /// in the very same pass, so the toast vanished in a single frame. The
    /// layer must update from its own observation, in its own transaction.
    func sync(scene: UIWindowScene?, inputs: Inputs, rootView: @autoclosure () -> AnyView) {
      guard let scene else { return }
      if let window, window.windowScene === scene {
        guard appliedInputs != inputs else { return }
        appliedInputs = inputs
        host?.rootView = rootView()
        return
      }
      teardown()
      appliedInputs = inputs
      let host = UIHostingController(rootView: rootView())
      host.view.backgroundColor = .clear
      host.view.isOpaque = false
      // Full-bleed on purpose: the layer positions the toast from the window's
      // top edge, the same origin the flight's global endpoints use. The inset
      // it pads by is an input to `rootView`, not SwiftUI's own.
      host.safeAreaRegions = []
      let window = DashToastLayerWindow(windowScene: scene)
      window.rootViewController = host
      window.backgroundColor = .clear
      window.isOpaque = false
      // Above every in-app presentation, below `.statusBar`: the toast kept
      // sitting under the clock on the canvas and must keep doing so.
      window.windowLevel = .normal + 1
      // Shown, never made key — a toast must not take first responder away
      // from the field in the tray it is reporting on.
      window.isHidden = false
      self.window = window
      self.host = host
    }

    func teardown() {
      window?.isHidden = true
      window?.rootViewController = nil
      window = nil
      host = nil
      appliedInputs = nil
    }
  }
}

private struct DashToastLayerModifier: ViewModifier {
  let state: DashToastLayerState
  let model: AppModel
  let locale: Locale
  let dynamicTypeSize: DynamicTypeSize

  func body(content: Content) -> some View {
    content.background {
      DashToastLayerInstaller(
        state: state, model: model, locale: locale, dynamicTypeSize: dynamicTypeSize
      )
      .frame(width: 0, height: 0)
      .accessibilityHidden(true)
    }
  }
}

extension View {
  /// Installs the app's one toast layer in its own window. Call exactly once,
  /// from the app root; `\.dashToastLayerState` carries the same state object
  /// down the normal tree so trays can reach it.
  func dashToastLayer(
    _ state: DashToastLayerState,
    model: AppModel,
    locale: Locale,
    dynamicTypeSize: DynamicTypeSize
  ) -> some View {
    modifier(
      DashToastLayerModifier(
        state: state, model: model, locale: locale, dynamicTypeSize: dynamicTypeSize))
  }
}
