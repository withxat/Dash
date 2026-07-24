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

/// Watchtower root action that enters chart customization. It uses the same
/// floated 44pt circle as the profile and inbox controls so adding a second
/// trailing action does not let the navigation bar clamp either button.
struct HeaderWatchtowerCustomizeButton: View {
  let action: @MainActor () -> Void

  var body: some View {
    Group {
      if #available(iOS 26.0, *) {
        Button {
          DashDelight.lightImpact()
          action()
        } label: {
          SolarIcon(asset: SolarAsset.slider, size: 24, color: DashTheme.strong)
            .frame(width: AvatarHeaderMetrics.barSize, height: AvatarHeaderMetrics.barSize)
            .padding(-7)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
      } else {
        Button {
          DashDelight.lightImpact()
          action()
        } label: {
          SolarIcon(asset: SolarAsset.slider, size: 24, color: DashTheme.strong)
            .frame(width: AvatarHeaderMetrics.barSize, height: AvatarHeaderMetrics.barSize)
            .background(DashTheme.elevated, in: Circle())
            .overlay { Circle().stroke(DashTheme.line, lineWidth: 0.5) }
        }
        .buttonStyle(DashPressButtonStyle())
      }
    }
    .frame(width: AvatarHeaderMetrics.barSize, height: AvatarHeaderMetrics.barSize)
    .accessibilityLabel(DashL10n.string("Adjust view"))
    .accessibilityIdentifier("watchtower-customize-button")
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
  /// Canvas chrome for a tab-root screen: canvas background and every fix
  /// needed to keep the system's white slabs from painting over it (UIKit
  /// scroll fill, iOS 26 edge pockets, nav-bar background).
  ///
  /// The root shows a REAL navigation bar — no title, no items. Keeping the
  /// bar mounted is what makes a push seamless: the bar's height never
  /// changes (no content shift), and the back control lands in the leading
  /// slot where the shared floating avatar sits (`MainTabView` renders that
  /// avatar once, above the pager, so it doesn't ride along on tab swipes;
  /// seating it as a toolbar item would also squash it against the bar's
  /// item-height clamp). `topBand` is a zero-height hook at the content's
  /// rest line — Home hangs its scroll probe there.
  ///
  /// `scrollFill: .clear` is for Home: its in-page canvas + top wash must
  /// show through the content scroll. Other roots keep `.canvas` so the
  /// system white slab stays dead.
  func dashCatalogScreen(
    @ViewBuilder background: () -> some View = { DashTheme.canvas.ignoresSafeArea() },
    scrollFill: DashScrollViewConfigurator.Fill = .canvas,
    @ViewBuilder topBand: () -> some View = { Color.clear }
  ) -> some View {
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
      // The bar itself stays fully transparent so the canvas (and Home's
      // wash) shows through; scrolled content frosts under the status bar
      // only via the shared appearance, never a slab.
      .toolbarBackground(.hidden, for: .navigationBar)
      .safeAreaInset(edge: .top, spacing: 0) {
        Color.clear
          .frame(height: 0)
          .background { topBand() }
      }
      .scrollContentBackground(.hidden)
      .modifier(DashScrollEdgeEffectsHidden())
      // UIKit scroll/hosting chrome → canvas grey (kills the system white slab),
      // or clear on Home so the page's own canvas + wash show through.
      .background { DashScrollViewConfigurator(fill: scrollFill) }
      .background { background() }
  }

  /// Canvas scroll chrome for pushed feature/detail screens. Tab roots use
  /// `dashCatalogScreen`; destinations need the same edge-pocket kill so iOS
  /// 26 doesn't leave a white slab under the (now hidden) dock.
  func dashDetailCanvasChrome() -> some View {
    modifier(DashScrollEdgeEffectsHidden())
      .background { DashScrollViewConfigurator(fill: .canvas) }
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
    // Keep the three-tab pager clear so Home's wash / per-tab plates show
    // through without applying one screen's fill to neighboring content.
    var node: UIView? = view.superview
    while let current = node {
      if let pager = tabPager(in: current) {
        paint(pager, fill: .clear)
        break
      }
      node = current.superview
    }

    // Scope fill to this content VC only (root or pushed destination).
    let screen = enclosingContentView(from: view) ?? view.superview ?? view
    // UIKit's slide animates the VC's view — paint it so the plate is opaque
    // (canvas) or wash-through (clear) for the whole transition, not only
    // after SwiftUI commits its `.background`.
    screen.backgroundColor = fill == .clear ? .clear : canvasFill
    apply(in: screen, fill: fill)
  }

  /// Nearest non-container view controller that hosts `view`. Skips
  /// `UINavigationController` so a pushed destination and the tab root each
  /// configure only their own plate.
  private static func enclosingContentView(from view: UIView) -> UIView? {
    var node: UIView? = view
    while let current = node {
      var responder: UIResponder? = current
      while let next = responder {
        if let viewController = next as? UIViewController,
          !(viewController is UINavigationController),
          !(viewController is UITabBarController),
          let root = viewController.viewIfLoaded,
          current === root || current.isDescendant(of: root)
        {
          return root
        }
        responder = next.next
      }
      node = current.superview
    }
    return nil
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
        || isNearWhite(view.backgroundColor)
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
