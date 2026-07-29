import CloudflareAPI
import GradientAvatars
import SwiftUI

// MARK: - Destination navigator

/// Per-tab push/pop surface for `Destination` values, rendered by a native
/// `NavigationStack` in `DestinationStackHost`.
@MainActor
@Observable
final class DestinationNavigator {
  var path: [Destination] = []

  var depth: Int { path.count }
  var top: Destination? { path.last }

  func push(_ destination: Destination) {
    // Debounce double-activation, or a fast double-tap stacks the screen twice.
    guard path.last != destination else { return }
    path.append(destination)
  }

  func pop() {
    guard !path.isEmpty else { return }
    path.removeLast()
  }

  func popToRoot() {
    path.removeAll()
  }

  func reset(to destination: Destination? = nil) {
    if let destination {
      path = [destination]
    } else {
      path = []
    }
  }
}

// MARK: - Environment

private struct DestinationNavigatorKey: EnvironmentKey {
  static let defaultValue: DestinationNavigator? = nil
}

private struct DashTabActiveKey: EnvironmentKey {
  static let defaultValue = true
}

extension EnvironmentValues {
  var destinationNavigator: DestinationNavigator? {
    get { self[DestinationNavigatorKey.self] }
    set { self[DestinationNavigatorKey.self] = newValue }
  }

  /// True when this tab is the selected page, regardless of push depth. Every
  /// page stays mounted for the pager, so heavy roots gate their network loads
  /// on this to defer work until the tab is actually shown.
  var dashTabActive: Bool {
    get { self[DashTabActiveKey.self] }
    set { self[DashTabActiveKey.self] = newValue }
  }
}

// MARK: - Tab stack

/// Per-tab navigation host: a native `NavigationStack` driven by the tab's
/// `DestinationNavigator` path — standard push/pop transitions and the system
/// edge-swipe back gesture. Tab roots show a titleless inline bar seating the
/// profile avatar (`dashCatalogScreen`), so a push keeps one continuous bar:
/// no height jump, and the avatar hands its slot to the back control.
struct DestinationStackHost<Root: View>: View {
  @Bindable var navigator: DestinationNavigator
  var isTabActive: Bool
  @ViewBuilder var root: () -> Root

  var body: some View {
    NavigationStack(path: $navigator.path) {
      root()
        .navigationDestination(for: Destination.self) { destination in
          DestinationRoutedContent(destination: destination)
            .navigationBarTitleDisplayMode(.inline)
            // Match tab roots (`dashCatalogScreen`): keep the bar transparent
            // so canvas shows through. Without this, push restores the system
            // material and the header reads as a gray slab.
            .toolbarBackground(.hidden, for: .navigationBar)
            // Full-bleed opaque plate for the UIKit slide: a content-sized
            // `.background` leaves clear bands where the previous screen shows
            // through mid-push.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Same scroll-edge / fill treatment as catalog roots, and re-enable
            // scrolling after the tab pager locks horizontal paging on push.
            // After the frame, so the header frost's overlay spans the screen
            // even when a destination's own content doesn't fill it.
            .dashDetailCanvasChrome()
            .background(DashTheme.canvas.ignoresSafeArea())
        }
    }
    // No host plate: the stack is transparent so its tab root shows the
    // workspace canvas + shared top wash painted behind the pager
    // (`DashWorkspaceTopWash`). Mid-push nothing leaks through — the incoming
    // destination carries its own full-bleed opaque canvas (above).
    // Kill the system push/pop gray dimming plate (`_UIParallaxDimmingView`)
    // and the drop shadow it casts onto the previous screen.
    .background {
      NavigationDimmingScrubber(pulse: navigator.path.count)
    }
    .environment(\.destinationNavigator, navigator)
    .environment(\.dashTabActive, isTabActive)
  }

}

/// Scrubs UIKit's private push/pop dimming chrome off the enclosing
/// `UINavigationController`. The stock slide transition paints a gray
/// `_UIParallaxDimmingView` (plus a soft edge shadow) onto the previous
/// screen — visible as a muddy cast over Home / catalog roots. There is no
/// public API to opt out, so clear those views for the duration of a
/// transition. Interactive pop can re-add them mid-gesture, so the scrubber
/// also follows the navigation controller's pop recognizer and keeps a short
/// tail after the gesture settles.
private struct NavigationDimmingScrubber: UIViewRepresentable {
  /// Bumps on push/pop so a brief scrub covers the animated transition.
  var pulse: Int

  func makeUIView(context: Context) -> NavigationDimmingScrubberView {
    NavigationDimmingScrubberView()
  }

  func updateUIView(_ uiView: NavigationDimmingScrubberView, context: Context) {
    uiView.setPulse(pulse)
  }

  static func dismantleUIView(
    _ uiView: NavigationDimmingScrubberView,
    coordinator: ()
  ) {
    uiView.tearDown()
  }
}

enum NavigationTransitionChromeRules {
  static func shouldHideDimmingView(className: String, hasSubviews: Bool) -> Bool {
    className.hasPrefix("_UI") && className.contains("Dimming") && !hasSubviews
  }
}

enum NavigationScrubSchedule {
  static let pathTransitionDuration: CFTimeInterval = 0.55
  static let interactiveSettleDuration: CFTimeInterval = 0.12

  static func shouldRun(
    now: CFTimeInterval,
    holdUntil: CFTimeInterval,
    interactivePopActive: Bool
  ) -> Bool {
    interactivePopActive || now < holdUntil
  }
}

private final class NavigationDimmingScrubberView: UIView {
  /// `CADisplayLink` isn't Sendable; only touched on the main thread / from
  /// view lifecycle callbacks, never from `deinit` (Swift 6 rejects that).
  nonisolated(unsafe) private var displayLink: CADisplayLink?
  private let linkProxy = DisplayLinkProxy()
  private var holdUntil: CFTimeInterval = 0
  private var interactivePopActive = false
  private var lastPulse: Int = .min
  private weak var navigationController: UINavigationController?
  private weak var interactivePopGesture: UIGestureRecognizer?

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    isHidden = true
    backgroundColor = .clear
    linkProxy.owner = self
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    guard window != nil else {
      tearDown()
      return
    }
    attachNavigationControllerIfNeeded()
    if lastPulse != .min {
      holdUntil = max(
        holdUntil,
        CACurrentMediaTime() + NavigationScrubSchedule.pathTransitionDuration)
      startLink()
      scrub()
    }
  }

  func setPulse(_ pulse: Int) {
    attachNavigationControllerIfNeeded()
    guard pulse != lastPulse else { return }
    lastPulse = pulse

    // Cover the ~0.35s push/pop animation after the path flips.
    let now = CACurrentMediaTime()
    holdUntil = max(
      holdUntil,
      now + NavigationScrubSchedule.pathTransitionDuration)
    startLink()
    scrub()
  }

  fileprivate func tearDown() {
    stopLink()
    unbindInteractivePopGesture()
    navigationController = nil
    interactivePopActive = false
    holdUntil = 0
  }

  @objc private func handleInteractivePop(_ gesture: UIGestureRecognizer) {
    switch gesture.state {
    case .began:
      interactivePopActive = true
      startLink()
      scrub()
    case .changed:
      guard !interactivePopActive else { return }
      interactivePopActive = true
      startLink()
      scrub()
    case .ended, .cancelled, .failed:
      settleInteractivePop()
    case .possible:
      break
    @unknown default:
      settleInteractivePop()
    }
  }

  private func settleInteractivePop() {
    interactivePopActive = false
    let now = CACurrentMediaTime()
    holdUntil = max(
      holdUntil,
      now + NavigationScrubSchedule.interactiveSettleDuration)
    startLink()
    scrub()
  }

  private func startLink() {
    guard displayLink == nil else { return }
    // Proxy breaks the CADisplayLink → target retain so lifecycle teardown can
    // release this view cleanly.
    let link = CADisplayLink(target: linkProxy, selector: #selector(DisplayLinkProxy.tick))
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  private func stopLink() {
    displayLink?.invalidate()
    displayLink = nil
  }

  fileprivate func handleTick() {
    let now = CACurrentMediaTime()
    guard
      NavigationScrubSchedule.shouldRun(
        now: now,
        holdUntil: holdUntil,
        interactivePopActive: interactivePopActive)
    else {
      stopLink()
      return
    }
    scrub()
  }

  // `@MainActor`: the link is added to the `.main` run loop, so `tick` always
  // fires on the main thread — declare it so `handleTick()` is callable.
  @MainActor
  private final class DisplayLinkProxy: NSObject {
    weak var owner: NavigationDimmingScrubberView?
    @objc func tick() { owner?.handleTick() }
  }

  private func scrub() {
    attachNavigationControllerIfNeeded()
    if let navigationController {
      Self.clearTransitionChrome(in: navigationController.view)
      return
    }
    // Fallback: dimming views are uniquely named — safe to sweep the window.
    var root: UIView = self
    while let parent = root.superview { root = parent }
    Self.clearTransitionChrome(in: root)
  }

  private func attachNavigationControllerIfNeeded() {
    if let navigationController, navigationController.view.window === window {
      bindInteractivePopGestureIfNeeded(to: navigationController)
      return
    }

    unbindInteractivePopGesture()
    navigationController = nil
    guard let resolved = enclosingNavigationController() else { return }
    navigationController = resolved
    bindInteractivePopGestureIfNeeded(to: resolved)
  }

  private func bindInteractivePopGestureIfNeeded(to navigationController: UINavigationController) {
    guard
      let gesture = navigationController.interactivePopGestureRecognizer,
      interactivePopGesture !== gesture
    else {
      return
    }
    unbindInteractivePopGesture()
    gesture.addTarget(self, action: #selector(handleInteractivePop(_:)))
    interactivePopGesture = gesture
  }

  private func unbindInteractivePopGesture() {
    interactivePopGesture?.removeTarget(self, action: #selector(handleInteractivePop(_:)))
    interactivePopGesture = nil
    interactivePopActive = false
  }

  private func enclosingNavigationController() -> UINavigationController? {
    var node: UIView? = self
    while let current = node {
      var responder: UIResponder? = current
      while let next = responder {
        if let nav = next as? UINavigationController {
          return nav
        }
        if let viewController = next as? UIViewController {
          if let nav = viewController.navigationController {
            return nav
          }
          if let nav = viewController.children.compactMap({ $0 as? UINavigationController })
            .first
          {
            return nav
          }
        }
        responder = next.next
      }
      node = current.superview
    }
    return nil
  }

  private static func clearTransitionChrome(in view: UIView) {
    let name = NSStringFromClass(type(of: view))
    // iOS 26 can use `_UIParallaxDimmingView` as the transition container
    // itself, with the incoming hosting view mounted beneath it. Hiding every
    // class containing "Dimming" therefore hides the destination content
    // until UIKit completes the push. Only hide a private UIKit leaf plate;
    // preserve any container carrying a content subtree.
    if NavigationTransitionChromeRules.shouldHideDimmingView(
      className: name,
      hasSubviews: !view.subviews.isEmpty)
    {
      view.isHidden = true
      view.alpha = 0
      view.backgroundColor = .clear
      return
    }
    if name.hasPrefix("_UI"), name.contains("Dimming") {
      view.backgroundColor = .clear
    }
    // Drop shadow the transition hangs on the previous / incoming plate.
    if name.contains("Parallax"), view.layer.shadowOpacity > 0 {
      view.layer.shadowOpacity = 0
      view.layer.shadowRadius = 0
    }
    for child in view.subviews {
      clearTransitionChrome(in: child)
    }
  }
}

// MARK: - Destination routing

struct DestinationRoutedContent: View {
  @Environment(AppModel.self) private var model
  let destination: Destination

  private var allowsWrites: Bool {
    let scopes = writeScopes(for: destination)
    return scopes.isEmpty || model.hasScopes(scopes)
  }

  var body: some View {
    Group {
      switch destination {
      case .profile: ProfileView()
      case .settings: SettingsView()
      case .about: AboutView()
      case .openSource: OpenSourceView()
      #if DEBUG
        case .debug: DebugView()
      #endif
      case .feature(let feature):
        FeatureRouterContent(feature: feature)
      case .zone(let id): ZoneDetailView(zoneID: id)
      case .dns(let id): DNSRecordsView(zoneID: id)
      case .cache(let id): CachePurgeView(zoneID: id)
      case .zoneAnalytics(let id): ZoneAnalyticsView(zoneID: id)
      case .zoneWebAnalytics(let id): WebAnalyticsView(zoneID: id)
      case .zoneWAF(let id): WAFEventsView(zoneID: id)
      case .zoneSettings(let id): ZoneSettingsView(zoneID: id)
      case .auditLogs: AuditLogView()
      case .pushAlerts: PushAlertsView()
      case .watchtowerInbox: WatchtowerInboxView()
      case .worker(let name): WorkerDetailView(name: name)
      case .pagesProject(let name): PagesProjectDetailView(projectName: name)
      case .pagesDeployment(let project, let deploymentID):
        PagesDeploymentDetailView(projectName: project, deploymentID: deploymentID)
      case .pagesDomains(let name): PagesDomainsView(projectName: name)
      case .r2Bucket(let name, let prefix): R2BucketView(bucket: name, folderPrefix: prefix)
      case .r2BucketSettings(let name): R2BucketSettingsView(bucket: name)
      case .kvNamespace(let id): KVNamespaceView(namespaceID: id)
      case .kvKey(let namespaceID, let key):
        KVKeyDetailView(namespaceID: namespaceID, key: key)
      }
    }
    .environment(\.featureAllowsWrites, allowsWrites)
    .environment(\.featureRequiredScopes, readScopes(for: destination))
    .environment(\.featureIdentity, featureID(for: destination))
  }
}

// MARK: - Detail header

/// The identity glyph a detail screen shows ahead of its inline title.
enum DetailIcon {
  case feature(FeatureID)
  case avatar(String)
  case solar(String)
}

struct DetailIconView: View {
  let icon: DetailIcon
  var tint: Color = DashTheme.brand

  var body: some View {
    switch icon {
    case .feature(let feature):
      CatalogFeatureIcon(feature: feature, size: .compact)
    case .avatar(let seed):
      GradientAvatar(seed: seed, size: 24, pattern: .dither, contentScale: 1.5)
    case .solar(let asset):
      SolarIcon(asset: asset, size: 20, color: tint)
    }
  }
}

extension View {
  /// Navigation-bar identity for a pushed detail screen: the feature glyph or
  /// avatar ahead of the title as the principal toolbar item. The plain
  /// `.navigationTitle` underneath keeps back-button labels, accessibility,
  /// and `navigationBars` test queries working.
  ///
  /// Tint resolution: explicit `tint` → feature hero → brand.
  func detailHeader(icon: DetailIcon, title: String, tint: Color? = nil) -> some View {
    modifier(DetailHeaderModifier(icon: icon, title: title, tint: tint))
  }
}

private struct DetailHeaderModifier: ViewModifier {
  /// Leaves a stable trailing region for the widest shared toolbar group
  /// (two 44pt actions plus their gap) on a compact portrait iPhone. The
  /// toolbar can still propose less space when a text action or large Dynamic
  /// Type needs it.
  private static let maximumPrincipalWidth: CGFloat = 160

  let icon: DetailIcon
  let title: String
  var tint: Color?
  @Environment(\.featureIdentity) private var featureIdentity

  private var resolvedTint: Color {
    if let tint { return tint }
    if let feature = featureIdentity {
      return FeatureVisualIdentity.heroColor(for: feature)
    }
    return DashTheme.brand
  }

  private var displayedTitle: String { DashL10n.ui(title) }

  func body(content: Content) -> some View {
    content
      .navigationTitle(displayedTitle)
      .toolbar {
        ToolbarItem(placement: .principal) {
          HStack(spacing: 6) {
            DetailIconView(icon: icon, tint: resolvedTint)
              .layoutPriority(1)
            Text(displayedTitle)
              .dashTextStyle(.sectionTitle)
              .foregroundStyle(DashTheme.strong)
              .lineLimit(1)
              .truncationMode(.tail)
          }
          .frame(maxWidth: Self.maximumPrincipalWidth)
        }
        // Root principals are a clear 1×1 prop (no glass). A real title + icon
        // principal gets iOS 26's shared Liquid Glass plate — a gray capsule
        // over the canvas — unless the shared background is hidden.
        .dashSeparateToolbarBackground()
      }
  }
}

// MARK: - Link helpers

/// Opens a `Destination` on the enclosing tab's navigation stack.
struct DestinationLink<Label: View>: View {
  let destination: Destination
  var onNavigate: (() -> Void)?
  @ViewBuilder var label: () -> Label

  @Environment(\.destinationNavigator) private var navigator

  var body: some View {
    Button {
      onNavigate?()
      navigator?.push(destination)
    } label: {
      label()
    }
    // A navigation row is a surface, not a button — it must not shrink on press.
    .buttonStyle(DashSurfaceButtonStyle())
  }
}
