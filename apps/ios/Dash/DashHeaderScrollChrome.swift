import SwiftUI
import UIKit

// MARK: - Root chrome

/// Shared profile avatar control: ONE instance, floated by `MainTabView`
/// above the pager so it doesn't ride along on tab swipes (and doesn't get
/// squashed by the nav bar's item-height clamp). It is positioned over the
/// leading slot of the roots' titleless nav bars, so on push it fades out
/// exactly where the system back control fades in — same spot, same glass
/// circle — reading as one control trading places.
struct HeaderProfileButton: View {
  @Environment(AppModel.self) private var model
  let action: @MainActor () -> Void

  private var accountLabel: String {
    model.activeAccount?.name ?? model.profileTitle
  }

  /// Circular glass matching the system back control. Without
  /// `buttonBorderShape(.circle)`, iOS 26 paints a square glass plate around
  /// the 44×44 avatar bounds and flashes its white corner during push morph.
  /// The negative padding pulls the glass in so the ring hugs the avatar
  /// instead of leaving a gap around it.
  var body: some View {
    let email = model.user?.email ?? ""
    if #available(iOS 26.0, *) {
      Button {
        DashDelight.lightImpact()
        action()
      } label: {
        HeaderProfileAvatar(email: email)
          .frame(width: AvatarHeaderMetrics.barSize, height: AvatarHeaderMetrics.barSize)
          .padding(-7)
      }
      .buttonStyle(.glass)
      .buttonBorderShape(.circle)
      .accessibilityLabel("Profile, \(accountLabel)")
    } else {
      Button(action: action) {
        HeaderProfileAvatar(email: email)
      }
      .buttonStyle(DashPressButtonStyle())
      .accessibilityLabel("Profile, \(accountLabel)")
    }
  }
}

/// Trailing Watchtower inbox control — same 44pt glass circle as the leading
/// profile avatar. Floated by `MainTabView` (not a toolbar item) so the nav
/// bar's item-height clamp cannot squash it into a capsule. The count badge
/// overlays the glass corner (not a sibling ZStack that floats away).
struct HeaderInboxButton: View {
  let count: Int
  let action: @MainActor () -> Void
  /// Long-press opens the shared Ignore-all confirmation when there are actives.
  var onLongPress: (@MainActor () -> Void)? = nil

  private var accessibilityLabel: String {
    count > 0
      ? DashL10n.string("Alerts, \(count) pending")
      : DashL10n.string("Alerts")
  }

  var body: some View {
    circleButton
      // Lock the layout to the avatar's 44pt slot so the badge anchors to
      // the same circle the glass paints, not an inflated button bounds.
      .frame(width: AvatarHeaderMetrics.barSize, height: AvatarHeaderMetrics.barSize)
      .overlay(alignment: .topTrailing) { countBadge }
      .simultaneousGesture(
        LongPressGesture(minimumDuration: 0.35).onEnded { _ in
          guard count > 0, let onLongPress else { return }
          DashDelight.lightImpact()
          onLongPress()
        }
      )
      .accessibilityIdentifier("watchtower-inbox-button")
      .accessibilityHint(
        count > 0 && onLongPress != nil
          ? DashL10n.string("Long press to ignore all alerts") : ""
      )
      .accessibilityAction(named: DashL10n.string("Ignore all alerts")) {
        guard count > 0 else { return }
        onLongPress?()
      }
  }

  @ViewBuilder
  private var countBadge: some View {
    if count > 0 {
      Text(count > 9 ? "9+" : "\(count)")
        .font(.system(size: 11, weight: .bold))
        .monospacedDigit()
        .foregroundStyle(.white)
        .padding(.horizontal, count > 9 ? 5 : 0)
        .frame(minWidth: 18, minHeight: 18)
        .background(DashTheme.danger, in: Capsule(style: .continuous))
        .offset(x: 4, y: -4)
        .accessibilityHidden(true)
    }
  }

  @ViewBuilder
  private var circleButton: some View {
    if #available(iOS 26.0, *) {
      Button {
        DashDelight.lightImpact()
        action()
      } label: {
        SolarIcon(asset: SolarAsset.inbox, size: 24, color: DashTheme.strong)
          .frame(width: AvatarHeaderMetrics.barSize, height: AvatarHeaderMetrics.barSize)
          .padding(-7)
      }
      .buttonStyle(.glass)
      .buttonBorderShape(.circle)
      .accessibilityLabel(accessibilityLabel)
    } else {
      Button(action: action) {
        SolarIcon(asset: SolarAsset.inbox, size: 24, color: DashTheme.strong)
          .frame(width: AvatarHeaderMetrics.barSize, height: AvatarHeaderMetrics.barSize)
          .background(DashTheme.elevated, in: Circle())
          .overlay { Circle().stroke(DashTheme.line, lineWidth: 0.5) }
      }
      .buttonStyle(DashPressButtonStyle())
      .accessibilityLabel(accessibilityLabel)
    }
  }
}

extension View {
  /// Chrome for a tab-root screen: a transparent page plus every fix needed to
  /// keep the system's white slabs from painting over the workspace canvas
  /// (UIKit scroll fill, iOS 26 edge pockets, nav-bar background).
  ///
  /// The root shows a REAL navigation bar — no title, no items. Keeping the
  /// bar mounted is what makes a push seamless: the bar's height never
  /// changes (no content shift), and the back control lands in the leading
  /// slot where the shared floating avatar sits (`MainTabView` renders that
  /// avatar once, above the pager, so it doesn't ride along on tab swipes;
  /// seating it as a toolbar item would also squash it against the bar's
  /// item-height clamp).
  ///
  /// Roots paint NO background of their own. The canvas and the single
  /// `DashWorkspaceTopWash` live behind the pager in `MainTabView`, so all
  /// three tabs share one light field: the glow holds still while pages slide
  /// across it. Give a root an opaque plate again and it goes dark on that tab.
  func dashCatalogScreen() -> some View {
    navigationTitle("")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        // Invisible prop: a titleless bar with no items collapses to zero
        // inset. A clear principal keeps the root bar at standard height —
        // principal items carry no glass plate, so nothing shows — and the
        // content rest line lands exactly where pushed screens put it.
        ToolbarItem(placement: .principal) {
          Color.clear.frame(width: 1, height: 1)
        }
      }
      // The bar itself stays fully transparent so the canvas and the shared
      // wash show through; scrolled content frosts under the status bar only
      // via the shared appearance, never a slab.
      .toolbarBackground(.hidden, for: .navigationBar)
      .scrollContentBackground(.hidden)
      .modifier(DashScrollEdgeEffectsHidden())
      // Punches the UIKit scroll/hosting/navigation plates clear so the
      // workspace canvas + wash behind the pager are what the root shows.
      // The probe feeds this screen's scroll position to the shared header
      // frost (`DashHeaderScrim`), which is floated by `MainTabView`.
      .background {
        DashScrollViewConfigurator(fill: .clear)
        DashHeaderScrollProbe()
      }
  }

  /// Canvas scroll chrome for pushed feature/detail screens. Tab roots use
  /// `dashCatalogScreen`; destinations need the same edge-pocket kill so iOS
  /// 26 doesn't leave a white slab under the (now hidden) dock — and the same
  /// header-frost probe, so a pushed screen frosts its bar exactly like a root.
  func dashDetailCanvasChrome() -> some View {
    modifier(DashScrollEdgeEffectsHidden())
      .background {
        DashScrollViewConfigurator(fill: .canvas)
        DashHeaderScrollProbe()
      }
  }

}

/// iOS 26 paints a white “scroll edge pocket” above floating chrome; kill it
/// on canvas screens so the warm canvas shows through under the custom tab bar.
struct DashScrollEdgeEffectsHidden: ViewModifier {
  func body(content: Content) -> some View {
    if #available(iOS 26.0, *) {
      content.scrollEdgeEffectHidden(true, for: .all)
    } else {
      content
    }
  }
}

// MARK: - Header scrim

/// Geometry of the shared header frost. The band is pinned to the physical top
/// edge: solid across the status bar and the inline nav bar, then eased to
/// nothing, so its lower edge never draws a line across the content.
enum DashHeaderScrimMetrics {
  /// Inline navigation-bar height — the slot the avatar and detail titles sit in.
  static let bar: CGFloat = 44
  /// Soft tail below the bar. The frost eases out across it instead of stopping.
  static let fade: CGFloat = 44
  /// How far past the status bar the frost stays fully opaque: far enough to
  /// carry a pushed screen's title and the avatar, short enough that the ease
  /// owns most of the band.
  static let solid: CGFloat = 24
  /// Scroll distance over which the frost ramps 0 → 1 — short enough that the
  /// band has arrived by the time the first row has slid under the bar.
  static let ramp: CGFloat = 28
}

/// One screen's claim on the header frost.
struct DashHeaderScrollEntry: Equatable {
  /// False for the two tab pages that stay mounted but aren't selected.
  var isTabActive: Bool
  /// Index in the tab's navigation stack — 0 for the root, 1+ for a push.
  var depth: Int
  /// 0…1 frost strength for this screen's own scroll position.
  var progress: CGFloat
}

enum DashHeaderScrimRules {
  /// Frost strength for a scroll `distance` past the resting offset. Quantized
  /// so a per-frame probe only re-renders the band when a step actually changes.
  static func progress(
    distance: CGFloat,
    ramp: CGFloat = DashHeaderScrimMetrics.ramp
  ) -> CGFloat {
    guard ramp > 0 else { return distance > 0 ? 1 : 0 }
    let raw = min(1, max(0, distance / ramp))
    return (raw * 50).rounded() / 50
  }

  /// The screen the frost follows: the deepest push on the selected tab. Every
  /// page stays mounted (the pager needs neighbours renderable) and a push
  /// leaves its root mounted underneath, so several screens report at once.
  static func frontmost<Key: Hashable & Comparable>(
    of entries: [Key: DashHeaderScrollEntry]
  ) -> Key? {
    entries
      .filter { $0.value.isTabActive }
      .max { ($0.value.depth, $0.key) < ($1.value.depth, $1.key) }?
      .key
  }

  /// Mask ramp for the band: solid down to `solidFraction`, then an ease-out
  /// tail that reaches fully clear at the bottom. Deliberately not a linear
  /// ramp to a hard stop — the whole point is that no edge lands on content.
  static func maskStops(solidFraction: CGFloat) -> [(opacity: CGFloat, location: CGFloat)] {
    let solid = min(max(solidFraction, 0), 1)
    let tail = 1 - solid
    let ease: [(CGFloat, CGFloat)] = [
      (1, 0), (0.94, 0.18), (0.78, 0.36), (0.52, 0.56), (0.24, 0.76), (0.06, 0.9), (0, 1),
    ]
    var stops: [(opacity: CGFloat, location: CGFloat)] = [(opacity: 1, location: 0)]
    for step in ease {
      stops.append((opacity: step.0, location: solid + tail * step.1))
    }
    return stops
  }
}

/// Frost strength for whichever screen is in front, written per scroll frame by
/// `DashHeaderScrollProbe` and read ONLY by `DashHeaderScrim`.
///
/// `MainTabView.body` must never read `progress`. Per-frame values landing in
/// the tab container's own `@State` re-apply the `NavigationStack` path
/// mid-push, UIKit cancels the running transition, and the pushed screen's
/// content is left permanently unmounted.
@MainActor
@Observable
final class DashHeaderScrollState {
  /// 0…1 — drives the band's opacity.
  private(set) var progress: CGFloat = 0

  @ObservationIgnored private var entries: [ObjectIdentifier: DashHeaderScrollEntry] = [:]
  @ObservationIgnored private var owner: ObjectIdentifier?

  func report(_ entry: DashHeaderScrollEntry, from token: ObjectIdentifier) {
    guard entries[token] != entry else { return }
    entries[token] = entry
    resolve()
  }

  func withdraw(_ token: ObjectIdentifier) {
    guard entries.removeValue(forKey: token) != nil else { return }
    resolve()
  }

  private func resolve() {
    let next = DashHeaderScrimRules.frontmost(of: entries)
    let value = next.flatMap { entries[$0]?.progress } ?? 0
    let handover = next != owner
    owner = next
    guard value != progress else { return }
    // Scrolling tracks the finger, so those steps land instantly. A handover
    // (push, pop, tab switch) jumps between two screens' scroll positions —
    // ease that or the band snaps on mid-transition.
    if handover {
      withAnimation(DashTheme.Motion.settle) { progress = value }
    } else {
      progress = value
    }
  }
}

/// The workspace's header frost. ONE instance, floated by `MainTabView` above
/// the pager — shared chrome of the same kind as `DashWorkspaceTopWash` and the
/// profile avatar. It fades in with the frontmost screen's scroll so a scrolled
/// screen gets a readable bar, and fades out downward so nothing draws a line
/// across the content.
///
/// Do not copy it into a page: a page cannot paint the status bar (the pager
/// clips it), and three bands would ride their pages on a tab swipe.
struct DashHeaderScrim: View {
  @Environment(DashHeaderScrollState.self) private var scroll: DashHeaderScrollState?
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var body: some View {
    GeometryReader { proxy in
      let progress = scroll?.progress ?? 0
      // Mounted only while it shows something: a `Material` at zero opacity is
      // still a live backdrop filter over every screen in the app.
      if progress > 0 {
        let inset = proxy.safeAreaInsets.top
        let height = inset + DashHeaderScrimMetrics.bar + DashHeaderScrimMetrics.fade
        band(solidFraction: (inset + DashHeaderScrimMetrics.solid) / height)
          .frame(width: proxy.size.width, height: height)
          // The reader lays out inside the safe area; the band belongs to the
          // physical top edge, status bar included.
          .offset(y: -inset)
          .opacity(progress)
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private func band(solidFraction: CGFloat) -> some View {
    frost.mask {
      LinearGradient(
        stops: DashHeaderScrimRules.maskStops(solidFraction: solidFraction).map {
          Gradient.Stop(color: .white.opacity($0.opacity), location: $0.location)
        },
        startPoint: .top,
        endPoint: .bottom
      )
    }
  }

  /// `Material.bar` is the system's own bar frost. Reduce Transparency swaps it
  /// for the flat canvas so the gradient still hides the seam without a blur.
  @ViewBuilder
  private var frost: some View {
    if reduceTransparency {
      DashTheme.canvas
    } else {
      Rectangle().fill(Material.bar)
    }
  }
}

/// Reports the enclosing screen's scroll position to `DashHeaderScrollState`.
/// Installed by `dashCatalogScreen()` / `dashDetailCanvasChrome()`, so every
/// tab root and every pushed destination feeds the shared header frost without
/// a single feature screen knowing it exists.
struct DashHeaderScrollProbe: UIViewRepresentable {
  @Environment(DashHeaderScrollState.self) private var state: DashHeaderScrollState?
  @Environment(\.dashTabActive) private var isTabActive

  func makeUIView(context: Context) -> DashHeaderScrollProbeView {
    DashHeaderScrollProbeView()
  }

  func updateUIView(_ uiView: DashHeaderScrollProbeView, context: Context) {
    uiView.configure(state: state, isTabActive: isTabActive)
  }

  static func dismantleUIView(_ uiView: DashHeaderScrollProbeView, coordinator: ()) {
    uiView.tearDown()
  }
}

/// KVO on the screen's own scroll view — not a SwiftUI preference. Global-frame
/// probes bubbling through the pager re-evaluate the tab container on every
/// scrolled frame, which cancels a running push; an observation writing into an
/// `@Observable` store re-renders only the band that reads it.
final class DashHeaderScrollProbeView: UIView {
  private weak var state: DashHeaderScrollState?
  private var isTabActive = true
  private var depth = 0
  private weak var scrollView: UIScrollView?
  private var offsetObservation: NSKeyValueObservation?

  private var token: ObjectIdentifier { ObjectIdentifier(self) }

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    isHidden = true
    backgroundColor = .clear
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  func configure(state: DashHeaderScrollState?, isTabActive: Bool) {
    if self.state !== state {
      self.state?.withdraw(token)
      self.state = state
    }
    self.isTabActive = isTabActive
    attachIfNeeded()
    report()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    guard window != nil else { return }
    attachIfNeeded()
    report()
  }

  override func willMove(toWindow newWindow: UIWindow?) {
    // A pop detaches the screen's view: drop the claim so the screen underneath
    // takes the frost back instead of leaving a stale band over the canvas.
    if newWindow == nil { detach() }
    super.willMove(toWindow: newWindow)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    // The scroll view and the stack index both settle a beat after the screen
    // mounts — re-resolve on every layout pass instead of guessing a delay.
    attachIfNeeded()
    report()
  }

  func tearDown() {
    detach()
    state = nil
  }

  private func detach() {
    offsetObservation = nil
    scrollView = nil
    state?.withdraw(token)
  }

  private func attachIfNeeded() {
    guard let window else { return }
    depth = Self.navigationDepth(from: self)
    if let scrollView, scrollView.window === window, offsetObservation != nil { return }
    offsetObservation = nil
    guard let scroll = DashScreenScrollLocator.contentScrollView(from: self) else {
      scrollView = nil
      return
    }
    scrollView = scroll
    offsetObservation = scroll.observe(\.contentOffset) { [weak self] _, _ in
      MainActor.assumeIsolated { self?.report() }
    }
  }

  /// A screen with no scroll view still claims the frost at zero: otherwise a
  /// pushed screen that cannot scroll would inherit the band its root left on.
  private func report() {
    guard let state, window != nil else { return }
    var progress: CGFloat = 0
    if let scrollView, scrollView.window != nil {
      let distance = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
      progress = DashHeaderScrimRules.progress(distance: distance)
    }
    state.report(
      DashHeaderScrollEntry(isTabActive: isTabActive, depth: depth, progress: progress),
      from: token)
  }

  /// Index of this screen's view controller in its navigation stack: 0 for a
  /// tab root, 1+ for a push.
  private static func navigationDepth(from view: UIView) -> Int {
    guard
      let controller = DashScreenScrollLocator.enclosingViewController(from: view),
      let stack = controller.navigationController
    else { return 0 }
    return stack.viewControllers.firstIndex(of: controller) ?? stack.viewControllers.count
  }
}

// MARK: - Scroll edge fades

/// Vertical `ScrollView` with soft top/bottom surface fades for nested or
/// height-capped regions where overflow is easy to miss (Domains viewport,
/// build log, tray bodies). Full-page canvas scrolls stay plain `ScrollView`.
///
/// Pass the fill *behind* the scroll content as `surface` so the fade matches
/// (sheet, card, domains tint, …). Nested instances are safe: each keeps its
/// own probe id so preferences do not collide.
///
/// Opacity ramps over the first ~36pt past an edge (tracks the finger); large
/// layout jumps ease over 0.22s so the fade never pops.
struct DashFadedScrollView<Content: View>: View {
  var surface: Color
  var maxHeight: CGFloat? = nil
  var showsIndicators: Bool = false
  var bounceBasedOnSize: Bool = false
  var dismissesKeyboardInteractively: Bool = false
  @ViewBuilder var content: () -> Content

  @State private var spaceID = UUID()
  /// 0…1 strength; ramps with distance past the edge so show/hide is not a pop.
  @State private var topOpacity: CGFloat = 0
  @State private var bottomOpacity: CGFloat = 0
  /// Mutable sample so mid-scroll offset chatter does not re-render the list
  /// except when a quantized opacity step changes.
  @State private var sample = ScrollEdgeSample()

  private var spaceName: String { "dashFadedScroll.\(spaceID.uuidString)" }
  /// Distance (pt) over which the edge fade eases from 0 → 1.
  private let softRange: CGFloat = 36
  private let fadeHeight: CGFloat = 32

  var body: some View {
    ScrollView(showsIndicators: showsIndicators) {
      content()
        .background {
          GeometryReader { geo in
            let frame = geo.frame(in: .named(spaceName))
            Color.clear.preference(
              key: DashScrollEdgeProbeKey.self,
              value: [
                spaceID: DashScrollEdgeProbe(
                  offset: -frame.minY,
                  contentHeight: geo.size.height,
                  viewportHeight: nil
                )
              ]
            )
          }
        }
    }
    .coordinateSpace(name: spaceName)
    .background {
      GeometryReader { geo in
        Color.clear.preference(
          key: DashScrollEdgeProbeKey.self,
          value: [
            spaceID: DashScrollEdgeProbe(
              offset: nil,
              contentHeight: nil,
              viewportHeight: geo.size.height
            )
          ]
        )
      }
    }
    .onPreferenceChange(DashScrollEdgeProbeKey.self) { probes in
      guard let probe = probes[spaceID] else { return }
      ingest(probe)
    }
    .modifier(DashScrollBounceBasedOnSize(enabled: bounceBasedOnSize))
    .modifier(DashScrollDismissesKeyboard(enabled: dismissesKeyboardInteractively))
    .frame(maxHeight: maxHeight)
    .overlay(alignment: .top) {
      edgeFade(leadingFromTop: true)
        .opacity(topOpacity)
    }
    .overlay(alignment: .bottom) {
      edgeFade(leadingFromTop: false)
        .opacity(bottomOpacity)
    }
  }

  /// Soft ease for layout jumps (content size change); continuous scroll already
  /// ramps via `softRange` so it tracks the finger without lag.
  /// Computed: generic types cannot hold static stored properties.
  private static var edgeAnimation: Animation {
    .easeInOut(duration: 0.22)
  }

  private func ingest(_ probe: DashScrollEdgeProbe) {
    if let offset = probe.offset {
      sample.offset = offset
    }
    if let contentHeight = probe.contentHeight, contentHeight > 0 {
      sample.contentHeight = contentHeight
    }
    if let viewportHeight = probe.viewportHeight, viewportHeight > 0 {
      sample.viewportHeight = viewportHeight
    }
    recomputeEdges()
  }

  private func recomputeEdges() {
    let viewport = sample.viewportHeight
    let content = sample.contentHeight
    guard viewport > 0, content > 0 else { return }
    let remaining = content - viewport - sample.offset
    let nextTop = Self.softOpacity(distance: sample.offset, range: softRange)
    let nextBottom = Self.softOpacity(distance: remaining, range: softRange)
    setEdgeOpacity(nextTop, current: topOpacity) { topOpacity = $0 }
    setEdgeOpacity(nextBottom, current: bottomOpacity) { bottomOpacity = $0 }
  }

  /// Finger-tracking steps update immediately; large jumps (layout / content
  /// size) ease so the fade never pops.
  private func setEdgeOpacity(
    _ next: CGFloat, current: CGFloat, set: (CGFloat) -> Void
  ) {
    guard next != current else { return }
    if abs(next - current) > 0.35 {
      withAnimation(Self.edgeAnimation) { set(next) }
    } else {
      set(next)
    }
  }

  /// Maps overflow distance into a stepped 0…1 opacity so the fade eases in
  /// over `range` points instead of flipping on a 1pt threshold.
  private static func softOpacity(distance: CGFloat, range: CGFloat) -> CGFloat {
    guard range > 0 else { return distance > 0 ? 1 : 0 }
    let raw = min(1, max(0, distance / range))
    // ~20 steps: smooth enough to read, sparse enough to avoid per-frame churn.
    return (raw * 20).rounded() / 20
  }

  private func edgeFade(leadingFromTop: Bool) -> some View {
    LinearGradient(
      colors: leadingFromTop
        ? [surface, surface.opacity(0)]
        : [surface.opacity(0), surface],
      startPoint: .top,
      endPoint: .bottom
    )
    .frame(height: fadeHeight)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

/// Reference-type sample so preference updates can mutate without `@State` churn.
private final class ScrollEdgeSample {
  var offset: CGFloat = 0
  var contentHeight: CGFloat = 0
  var viewportHeight: CGFloat = 0
}

private struct DashScrollEdgeProbe: Equatable {
  var offset: CGFloat?
  var contentHeight: CGFloat?
  var viewportHeight: CGFloat?

  func merging(_ other: DashScrollEdgeProbe) -> DashScrollEdgeProbe {
    DashScrollEdgeProbe(
      offset: other.offset ?? offset,
      contentHeight: other.contentHeight ?? contentHeight,
      viewportHeight: other.viewportHeight ?? viewportHeight
    )
  }
}

private enum DashScrollEdgeProbeKey: PreferenceKey {
  static let defaultValue: [UUID: DashScrollEdgeProbe] = [:]

  static func reduce(
    value: inout [UUID: DashScrollEdgeProbe],
    nextValue: () -> [UUID: DashScrollEdgeProbe]
  ) {
    value.merge(nextValue()) { $0.merging($1) }
  }
}

private struct DashScrollBounceBasedOnSize: ViewModifier {
  var enabled: Bool

  func body(content: Content) -> some View {
    if enabled {
      content.scrollBounceBehavior(.basedOnSize)
    } else {
      content
    }
  }
}

private struct DashScrollDismissesKeyboard: ViewModifier {
  var enabled: Bool

  func body(content: Content) -> some View {
    if enabled {
      content.scrollDismissesKeyboard(.interactively)
    } else {
      content
    }
  }
}

/// Which container plates a transparent (tab-root) screen may punch through so
/// the workspace canvas and its shared top wash show. UIKit's own chrome is
/// flat white or flat black in the two appearances — and `DashTheme.canvas` is
/// itself near-white / near-black — so those two bands cover both the system
/// default and a plate an earlier pass already painted. Anything in between is
/// somebody's real surface and stays.
/// Finds the UIKit pieces of "this screen" from any view planted inside it.
/// Shared so the canvas fill, the header-frost probe, and R2's two-finger
/// multi-select all agree on which view controller and which scroll view a
/// screen owns — a pushed destination and its tab root must never resolve to
/// each other's.
@MainActor
enum DashScreenScrollLocator {
  /// Nearest non-container view controller hosting `view`. `UINavigationController`
  /// and `UITabBarController` are skipped so each content screen resolves itself.
  static func enclosingViewController(from view: UIView) -> UIViewController? {
    var node: UIView? = view
    while let current = node {
      var responder: UIResponder? = current
      while let next = responder {
        if let controller = next as? UIViewController,
          !(controller is UINavigationController),
          !(controller is UITabBarController),
          let root = controller.viewIfLoaded,
          current === root || current.isDescendant(of: root)
        {
          return controller
        }
        responder = next.next
      }
      node = current.superview
    }
    return nil
  }

  /// Root view of that content view controller.
  static func enclosingContentView(from view: UIView) -> UIView? {
    enclosingViewController(from: view)?.viewIfLoaded
  }

  /// The screen's primary scroll view: the outermost scroll inside its content
  /// view that is neither the three-tab pager nor a small nested region (tray
  /// bodies, the Domains viewport, a build log) — those sit deeper and shorter.
  static func contentScrollView(
    from view: UIView,
    minimumHeight: CGFloat = 80
  ) -> UIScrollView? {
    let root = enclosingContentView(from: view) ?? view.superview ?? view
    var found: UIScrollView?
    func walk(_ node: UIView) {
      guard found == nil else { return }
      if let scroll = node as? UIScrollView,
        !DashScrollViewConfigurator.isTabPager(scroll),
        scroll.bounds.height > minimumHeight
      {
        found = scroll
        return
      }
      for child in node.subviews { walk(child) }
    }
    walk(root)
    return found
  }
}

enum DashCanvasPlateRules {
  static func isSystemPlate(_ color: UIColor?) -> Bool {
    guard let color else { return false }
    var white: CGFloat = 0
    var alpha: CGFloat = 0
    guard color.getWhite(&white, alpha: &alpha), alpha > 0.9 else { return false }
    return white > 0.96 || white < 0.06
  }
}

/// Clears UIScrollView's opaque fill and hides iOS 26 edge pockets. SwiftUI's
/// `scrollEdgeEffectHidden` alone was still leaving a fixed white slab that
/// content scrolled underneath.
///
/// Note: a `.background` representable is a *sibling* of the UIScrollView, not
/// a descendant — walk up, then search the subtree for scroll views.
struct DashScrollViewConfigurator: UIViewRepresentable {
  enum Fill {
    /// Matches `DashTheme.canvas` — kills the system white slab on ordinary roots.
    case canvas
    /// Home: let the page's own canvas + top wash show through scroll chrome.
    case clear
  }

  var fill: Fill = .canvas

  func makeUIView(context: Context) -> UIView {
    let view = UIView()
    view.isUserInteractionEnabled = false
    view.backgroundColor = .clear
    view.isOpaque = false
    return view
  }

  func updateUIView(_ uiView: UIView, context: Context) {
    let fill = fill
    DispatchQueue.main.async {
      Self.configureNearbyScrollViews(from: uiView, fill: fill)
      DispatchQueue.main.async {
        Self.configureNearbyScrollViews(from: uiView, fill: fill)
      }
    }
  }

  private static func configureNearbyScrollViews(from view: UIView, fill: Fill) {
    // Keep the three-tab pager clear so the shared wash / per-screen plates
    // show through without applying one screen's fill to neighboring content.
    var node: UIView? = view.superview
    while let current = node {
      if let pager = tabPager(in: current) {
        paint(pager, fill: .clear)
        break
      }
      // A `.clear` screen is a tab root: the workspace canvas + top wash live
      // behind the pager, so every default UIKit plate *above* the content
      // view controller (hosting wrappers, the navigation controller's view,
      // the page cell) has to be punched through too — `apply(in:)` only walks
      // downward from the content VC and never reaches them. Only system
      // chrome is cleared; real content plates are left alone.
      if fill == .clear, DashCanvasPlateRules.isSystemPlate(current.backgroundColor) {
        current.backgroundColor = .clear
      }
      node = current.superview
    }

    // Scope fill to this content VC only (root or pushed destination).
    let screen = DashScreenScrollLocator.enclosingContentView(from: view) ?? view.superview ?? view
    // UIKit's slide animates the VC's view — paint it so the plate is opaque
    // (canvas) or wash-through (clear) for the whole transition, not only
    // after SwiftUI commits its `.background`.
    screen.backgroundColor = fill == .clear ? .clear : canvasFill
    apply(in: screen, fill: fill)
  }

  /// Same geometry heuristic as `TabPagerScrollLock` — shared so Home's page
  /// fill and the pager lock agree on which scroll is the three-tab pager.
  static func isTabPager(_ scroll: UIScrollView) -> Bool {
    if scroll.isPagingEnabled { return true }
    guard scroll is UICollectionView else { return false }
    let width = scroll.bounds.width
    guard width > 100 else { return false }
    let pages = scroll.contentSize.width / width
    let mostlyHorizontal = scroll.contentSize.height <= scroll.bounds.height + 2
    return mostlyHorizontal && pages >= 1.8 && pages <= 4.5
  }

  private static func tabPager(in view: UIView) -> UIScrollView? {
    if let scroll = view as? UIScrollView, isTabPager(scroll) {
      return scroll
    }
    for child in view.subviews {
      if let scroll = child as? UIScrollView, isTabPager(scroll) {
        return scroll
      }
      for grand in child.subviews {
        if let scroll = grand as? UIScrollView, isTabPager(scroll) {
          return scroll
        }
      }
    }
    return nil
  }

  private static let canvasFill = UIColor { traits in
    if traits.userInterfaceStyle == .dark {
      // Matches `DashTheme.canvas` / `color-kumo-canvas` dark: 0x030303
      UIColor(red: 0x03 / 255, green: 0x03 / 255, blue: 0x03 / 255, alpha: 1)
    } else {
      // Matches `DashTheme.canvas` / `color-kumo-canvas` light: 0xFBFBFB
      UIColor(red: 0xFB / 255, green: 0xFB / 255, blue: 0xFB / 255, alpha: 1)
    }
  }

  private static func paint(_ scroll: UIScrollView, fill: Fill) {
    // Do NOT also force `isOpaque = true`: under nested hosting views it makes
    // CoreAnimation skip compositing the HostingScrollView's content, blanking
    // the whole screen.
    scroll.backgroundColor = fill == .clear ? .clear : canvasFill
    if #available(iOS 26.0, *) {
      scroll.topEdgeEffect.isHidden = true
      scroll.bottomEdgeEffect.isHidden = true
      scroll.leftEdgeEffect.isHidden = true
      scroll.rightEdgeEffect.isHidden = true
    }
  }

  private static func apply(in view: UIView, fill: Fill) {
    if let scroll = view as? UIScrollView {
      // Tab pager stays clear; content scrolls take the caller's fill.
      paint(scroll, fill: isTabPager(scroll) ? .clear : fill)
    }

    // Hosting/nav containers default to system white above the scroll view.
    // Home (`.clear`) must punch that out so the wash shows through — but
    // never do that on a `.canvas` screen: light canvas (0xFBFBFB) is itself
    // "near white", and clearing it leaves the UIKit push plate transparent.
    let name = NSStringFromClass(type(of: view))
    if name.contains("HostingView") || name.contains("NavigationController") {
      let unset =
        view.backgroundColor == nil
        || view.backgroundColor == .systemBackground
        // A transparent root must also punch through dark-mode system chrome
        // (near-black), which `isNearWhite` cannot see.
        || (fill == .clear
          ? DashCanvasPlateRules.isSystemPlate(view.backgroundColor)
          : isNearWhite(view.backgroundColor))
      if unset {
        view.backgroundColor = fill == .clear ? .clear : canvasFill
      }
    }

    for child in view.subviews {
      apply(in: child, fill: fill)
    }
  }

  private static func isNearWhite(_ color: UIColor?) -> Bool {
    guard let color else { return false }
    var white: CGFloat = 0
    var alpha: CGFloat = 0
    return color.getWhite(&white, alpha: &alpha) && white > 0.96 && alpha > 0.9
  }
}
