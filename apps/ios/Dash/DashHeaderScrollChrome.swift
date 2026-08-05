import SwiftUI
import UIKit
import VariableBlur

// MARK: - Root chrome

/// Shared profile avatar control: ONE instance, floated by `MainTabView`
/// above the pager so it doesn't ride along on tab swipes. It is positioned
/// over the custom page bar's leading slot, so a workspace presentation fades
/// its Close control into the same spot and glass circle.
///
/// Tap opens Settings; long-press opens the account switcher tray, matching
/// the inbox's long-press pattern.
struct HeaderProfileButton: View {
  @Environment(AppModel.self) private var model
  /// Workspace present publishes its source anchor onto the avatar circle so
  /// the morph captures the face, not the glass plate around it.
  @Environment(\.dashNavigationEmbeddedAnchorID) private var embeddedAnchorID
  let action: @MainActor () -> Void
  /// Long-press opens the account switcher tray when provided.
  var onLongPress: (@MainActor () -> Void)? = nil
  /// Long-press and Button both see the same touch up; once the hold has
  /// opened the tray, swallow the click that would otherwise push Settings
  /// underneath it.
  @State private var suppressNextTap = false

  private var accountLabel: String {
    model.activeAccount?.name ?? model.profileTitle
  }

  /// Circular glass matching the custom page controls. Without
  /// `buttonBorderShape(.circle)`, iOS 26 paints a square glass plate around
  /// the 44×44 avatar bounds and flashes its white corner during push morph.
  /// The negative padding pulls the glass in so the ring hugs the avatar
  /// instead of leaving a gap around it.
  var body: some View {
    let email = model.user?.email ?? ""
    Group {
      if #available(iOS 26.0, *) {
        Button {
          performTap()
        } label: {
          avatar(email: email)
            .frame(width: AvatarHeaderMetrics.barSize, height: AvatarHeaderMetrics.barSize)
            .padding(-7)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
      } else {
        Button(action: performTap) {
          avatar(email: email)
        }
        .buttonStyle(DashPressButtonStyle())
      }
    }
    .simultaneousGesture(
      LongPressGesture(minimumDuration: 0.35).onEnded { _ in
        guard let onLongPress else { return }
        suppressNextTap = true
        DashDelight.lightImpact()
        onLongPress()
      }
    )
    .accessibilityLabel("Profile, \(accountLabel)")
    .accessibilityIdentifier("header-profile-button")
    .accessibilityHint(
      onLongPress != nil
        ? DashL10n.string("Long press for account menu") : ""
    )
    .accessibilityAction(named: DashL10n.string("Switch account")) {
      onLongPress?()
    }
  }

  private func performTap() {
    if suppressNextTap {
      suppressNextTap = false
      return
    }
    DashDelight.lightImpact()
    action()
  }

  @ViewBuilder
  private func avatar(email: String) -> some View {
    let mark = HeaderProfileAvatar(email: email)
    if let embeddedAnchorID {
      mark.dashNavigationAnchor(instanceID: embeddedAnchorID)
    } else {
      mark
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
  @State private var suppressNextTap = false

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
          suppressNextTap = true
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
        performTap()
      } label: {
        SolarIcon(asset: SolarAsset.inbox, size: 24, color: DashTheme.strong)
          .frame(width: AvatarHeaderMetrics.barSize, height: AvatarHeaderMetrics.barSize)
          .padding(-7)
      }
      .buttonStyle(.glass)
      .buttonBorderShape(.circle)
      .accessibilityLabel(accessibilityLabel)
    } else {
      Button(action: performTap) {
        SolarIcon(asset: SolarAsset.inbox, size: 24, color: DashTheme.strong)
          .frame(width: AvatarHeaderMetrics.barSize, height: AvatarHeaderMetrics.barSize)
          .background(DashTheme.elevated, in: Circle())
          .overlay { Circle().stroke(DashTheme.line, lineWidth: 0.5) }
      }
      .buttonStyle(DashPressButtonStyle())
      .accessibilityLabel(accessibilityLabel)
    }
  }

  private func performTap() {
    if suppressNextTap {
      suppressNextTap = false
      return
    }
    DashDelight.lightImpact()
    action()
  }
}

extension View {
  /// Chrome for a tab-root screen: a transparent page plus every fix needed to
  /// keep the system's white slabs from painting over the workspace canvas
  /// (UIKit scroll fill and iOS 26 edge pockets).
  ///
  /// `DashRoutePageChromeHost` reserves the same header height on roots and
  /// destinations, so changing pages never shifts the content rest line. The
  /// shared floating avatar sits above the pager in that leading slot.
  ///
  /// Roots paint NO background of their own. The canvas and the single
  /// `DashWorkspaceTopWash` live behind the pager in `MainTabView`, so all
  /// three tabs share one light field: the glow holds still while pages slide
  /// across it. Give a root an opaque plate again and it goes dark on that tab.
  func dashCatalogScreen() -> some View {
    modifier(DashCatalogScreenModifier())
  }

  /// Canvas scroll chrome for pushed feature/detail screens. Tab roots use
  /// `dashCatalogScreen`; destinations need the same edge-pocket kill so iOS
  /// 26 doesn't leave a white slab under the (now hidden) dock — and the same
  /// header frost, so a pushed screen frosts its bar exactly like a root.
  func dashDetailCanvasChrome() -> some View {
    modifier(DashScrollEdgeEffectsHidden())
      .background { DashScrollViewConfigurator(fill: .canvas) }
      .dashHeaderScrim()
  }

  /// The header frost, as a layer INSIDE the screen: above the scrolling
  /// content, below the page-owned navigation chrome. That z-order keeps the
  /// title and controls crisp on top of the blur.
  ///
  /// Screens that host fixed page chrome (`DashPageChromeHost` / text tabs)
  /// install their own frost under that chrome and set
  /// `DashHeaderScrimHandledKey`, so this wrapper skips and does not smear
  /// the tabs.
  func dashHeaderScrim() -> some View {
    modifier(DashHeaderScrimModifier())
  }
}

private struct DashCatalogScreenModifier: ViewModifier {
  @Environment(\.dashUsesCustomPageStack) private var usesCustomPageStack

  @ViewBuilder
  func body(content: Content) -> some View {
    if usesCustomPageStack {
      content
        .scrollContentBackground(.hidden)
        .modifier(DashScrollEdgeEffectsHidden())
        // The custom route host owns the header reservation and frost. This
        // modifier keeps only the root's transparent UIKit plates.
        .background { DashScrollViewConfigurator(fill: .clear) }
    } else {
      content
        .navigationTitle(Text(verbatim: ""))
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
        .background { DashScrollViewConfigurator(fill: .clear) }
        .dashHeaderScrim()
    }
  }
}

/// Preference set by `DashPageChromeHost` so the destination/root
/// `dashHeaderScrim()` wrapper does not paint a second band on top of the
/// page chrome (text tabs) that must stay as crisp as the nav title.
enum DashHeaderScrimHandledKey: PreferenceKey {
  static let defaultValue = false

  static func reduce(value: inout Bool, nextValue: () -> Bool) {
    value = value || nextValue()
  }
}

private enum DashPageChromeHeightKey: PreferenceKey {
  static let defaultValue: CGFloat = 0

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

/// Fixed page chrome (text tabs) above the header frost, same stacking as the
/// page bar's title and controls: no fill of its own, never softened
/// by the blur tail. Owns the frost for this screen so the outer
/// `dashHeaderScrim()` wrapper can stand down.
///
/// `isChromeVisible` hides chrome without unmounting its measured subtree, so a
/// caller can animate the reserved inset away in the same transaction as the
/// content below it.
struct DashPageChromeHost<Chrome: View, Content: View>: View {
  let isChromeVisible: Bool
  @ViewBuilder var chrome: () -> Chrome
  @ViewBuilder var content: () -> Content
  /// Watchtower's root hosts its range tabs through here, so this probe is the
  /// one driving the workspace glow on that tab (see `dashWorkspaceWashScroll`).
  @Environment(\.dashWorkspaceWashScroll) private var washScroll
  @State private var scroll = DashHeaderScrollState()
  @State private var chromeHeight: CGFloat = 0

  init(
    isChromeVisible: Bool = true,
    @ViewBuilder chrome: @escaping () -> Chrome,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.isChromeVisible = isChromeVisible
    self.chrome = chrome
    self.content = content
  }

  var body: some View {
    content()
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .padding(.top, isChromeVisible ? chromeHeight : 0)
      // Frost first, chrome second: the band still reaches the status bar, but
      // the tabs paint above it like UIKit's bar items.
      .overlay(alignment: .top) { DashHeaderScrim(scroll: scroll) }
      .overlay(alignment: .top) {
        // Keep the fixed-size chrome mounted while it is visually hidden: its
        // measured height then stays stable while the caller animates the
        // content inset to zero instead of snapping through a later preference.
        ZStack(alignment: .top) {
          chrome()
            .padding(.horizontal, DashTheme.Spacing.screen)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .top)
        .background {
          GeometryReader { geo in
            Color.clear.preference(
              key: DashPageChromeHeightKey.self,
              value: geo.size.height
            )
          }
        }
        .opacity(isChromeVisible ? 1 : 0)
        .allowsHitTesting(isChromeVisible)
        .accessibilityHidden(!isChromeVisible)
      }
      .onPreferenceChange(DashPageChromeHeightKey.self) { chromeHeight = $0 }
      .background {
        DashHeaderScrollProbe(scroll: scroll, wash: washScroll)
        DashScreenClipLift()
      }
      .preference(key: DashHeaderScrimHandledKey.self, value: true)
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

/// Geometry of the header frost. The band is pinned to the physical top edge
/// and extends beyond the navigation region so the progressive blur and tint can
/// ease to nothing before their lower edge reaches scrolling content.
enum DashHeaderScrimMetrics {
  /// Floor for the safe-area top inset, in case a screen reports one without
  /// its page chrome. Never a substitute for the measured inset.
  static let minimumTop: CGFloat = 44
  /// ProgressiveBlurHeader's fade length below the navigation inset. Kept
  /// shorter than the old 64pt so the frost clears sooner into content; the
  /// workspace glow (`DashWorkspaceTopWash`) is a separate layer and untouched.
  static let tail: CGFloat = 40
  /// ProgressiveBlurHeader's restrained optical tuning.
  static let maxBlurRadius: CGFloat = 5
  static let startOffset: CGFloat = 0
  static let tintOpacityTop = 0.7
  static let tintOpacityMiddle = 0.5
  /// Absolute Y of the mid tint stop inside the band — scaled with `tail` so
  /// the ramp still eases out before the lower edge.
  static let tintMiddleY: CGFloat = 56
  /// Scroll depth that brings the frost in. The band is not scrubbed by the
  /// finger — crossing this line starts its own short entrance, so a nudge or
  /// rubber-band settle never leaves a half-painted header tracking the touch.
  static let enter: CGFloat = 20
  /// The shallower depth it leaves at. Two thresholds, not one: a single line
  /// makes the band chatter on and off while a finger rests on it.
  static let exit: CGFloat = 6
}

/// The backdrop filter is created only after the scroll threshold is crossed.
/// Give that first composited frame a short entrance so the filter never lands
/// as a fully opaque flash. Exit uses the same calm timing with a smaller lift,
/// so returning to the top does not snap the atmosphere away.
enum DashHeaderScrimMotion {
  static let insertionOffsetY: CGFloat = -8
  static let removalOffsetY: CGFloat = -3
  static let insertionDuration = 0.36
  static let removalDuration = insertionDuration

  static let insertion = Animation.timingCurve(
    0.25,
    0.1,
    0.25,
    1,
    duration: insertionDuration
  )
  static let removal = Animation.timingCurve(
    0.25,
    0.1,
    0.25,
    1,
    duration: removalDuration
  )
}

enum DashHeaderScrimRules {
  /// Whether a screen at this scroll `distance` wants the frost, given what it
  /// wanted a frame ago. The hysteresis is the point: crossing `enter` arms it,
  /// and only falling back under `exit` disarms it.
  static func isScrolled(distance: CGFloat, wasScrolled: Bool) -> Bool {
    wasScrolled
      ? distance > DashHeaderScrimMetrics.exit
      : distance > DashHeaderScrimMetrics.enter
  }

  /// Resolution of the falloff. Enough stops that the linear interpolation
  /// between them reads as a curve rather than a chain of facets.
  static let rampSteps = 8

  /// Accessibility-canvas mask: full strength down to `solidFraction`, then a
  /// smoothstep falloff reaching fully clear at `extent`, and nothing below.
  ///
  /// Smoothstep on purpose — it leaves the plateau and arrives at zero with
  /// zero slope, so neither end of the falloff shows a corner. A linear ramp
  /// puts a visible crease at both.
  static func maskStops(
    solidFraction: CGFloat,
    extent: CGFloat = 1
  ) -> [(opacity: CGFloat, location: CGFloat)] {
    let end = min(max(extent, 0), 1)
    let solid = min(max(solidFraction, 0), end)
    var stops: [(opacity: CGFloat, location: CGFloat)] = [(opacity: 1, location: 0)]
    if solid > 0 {
      stops.append((opacity: 1, location: solid))
    }
    let ramp = end - solid
    if ramp > 0 {
      for step in 1...rampSteps {
        let t = CGFloat(step) / CGFloat(rampSteps)
        stops.append((opacity: 1 - t * t * (3 - 2 * t), location: solid + ramp * t))
      }
    } else {
      stops.append((opacity: 0, location: end))
    }
    if end < 1 {
      stops.append((opacity: 0, location: 1))
    }
    return stops
  }
}

/// Whether this screen wants its header frosted. Written by
/// `DashHeaderScrollProbe`, read ONLY by `DashHeaderScrim`.
///
/// One per screen, and deliberately not the screen's own `@State` value: the
/// probe reports from a scroll callback, and a scroll-driven value the screen
/// body reads would refresh the page host on every frame while its explicit
/// transition is still settling.
@MainActor
@Observable
final class DashHeaderScrollState {
  /// Mounts and unmounts the band as a discrete state. It is never scrubbed by
  /// the finger; the transition owns the short entrance after the threshold is
  /// crossed. The value also doubles as the hysteresis memory.
  private(set) var isFrosted = false

  func report(distance: CGFloat) {
    apply(DashHeaderScrimRules.isScrolled(distance: distance, wasScrolled: isFrosted))
  }

  /// A screen with no scroll view of its own never frosts.
  func clear() {
    apply(false)
  }

  private func apply(_ value: Bool) {
    guard value != isFrosted else { return }
    isFrosted = value
  }
}

// MARK: - Workspace wash

/// How the shared workspace glow answers the active root's scroll.
///
/// The frost and the glow are different kinds of layer and now behave like it:
/// the frost is chrome, pinned to the physical top edge for as long as the
/// screen is scrolled, while the glow belongs to the *top of the content* and
/// leaves with it. Riding 1:1 is what makes it read as light lying on the page
/// instead of a fixture of the window — pinning both is what made the glow look
/// stuck to the blur.
enum DashWorkspaceWashRules {
  /// Fall-off distance from the physical top edge — also exactly how far the
  /// field has to travel before none of it is left on screen.
  static let depth: CGFloat = 300

  /// Clamped at both ends. A rubber-band pull past the top must not push the
  /// light *down* off its own edge and expose bare canvas above it, and once
  /// the field has cleared `depth` there is nothing left to move.
  static func lift(for distance: CGFloat) -> CGFloat {
    min(max(distance, 0), depth)
  }

  static func blendedDistance(
    from source: CGFloat,
    to target: CGFloat,
    progress rawProgress: CGFloat
  ) -> CGFloat {
    let progress = min(max(rawProgress, 0), 1)
    return source + ((target - source) * progress)
  }
}

/// One tab root's private workspace-scroll snapshot. Written by that root's
/// `DashHeaderScrollProbe`, read ONLY by the single `DashWorkspaceTopWash`.
///
/// Same rule as `DashHeaderScrollState`, and for the same reason: this value
/// moves on every scrolled frame, so it must never become `MainTabView` state.
/// `MainTabView` only hands these references to the wash; reading a distance in
/// that body would refresh every cached page host while a root is moving.
@MainActor
@Observable
final class DashWorkspaceWashScroll {
  private(set) var distance: CGFloat = 0

  func report(distance: CGFloat) {
    guard distance != self.distance else { return }
    self.distance = distance
  }

  /// A root with no scroll view of its own leaves the glow at rest.
  func clear() {
    report(distance: 0)
  }
}

private struct DashWorkspaceWashScrollKey: EnvironmentKey {
  static let defaultValue: DashWorkspaceWashScroll? = nil
}

extension EnvironmentValues {
  /// Each cached tab root receives its own snapshot store from `MainTabView`;
  /// pushed destinations clear it in `DestinationStackHost`. The single wash
  /// blends only the outgoing and selected snapshots during a tab handoff.
  var dashWorkspaceWashScroll: DashWorkspaceWashScroll? {
    get { self[DashWorkspaceWashScrollKey.self] }
    set { self[DashWorkspaceWashScrollKey.self] = newValue }
  }
}

/// Installs the frost on one screen: the band as an overlay (above content,
/// below the bar), the probe that drives it, and the clip lift that lets the
/// band reach the status bar.
///
/// When a descendant `DashPageChromeHost` already owns the frost (so its text
/// tabs can sit above the band), this modifier stands down — otherwise the
/// wrapper overlay would cover those tabs again.
struct DashHeaderScrimModifier: ViewModifier {
  /// Non-nil only on the active tab root; the same probe then feeds this
  /// screen's frost and the workspace glow from one observation.
  @Environment(\.dashWorkspaceWashScroll) private var washScroll
  @Environment(\.dashUsesCustomPageStack) private var usesCustomPageStack
  @State private var scroll = DashHeaderScrollState()

  @ViewBuilder
  func body(content: Content) -> some View {
    if usesCustomPageStack {
      // `DashRoutePageChromeHost` owns the page-level band and probe. Fixed
      // in-page chrome can still publish `DashHeaderScrimHandledKey` and keep
      // its more local ownership without this wrapper painting a duplicate.
      content
    } else {
      content
        .overlayPreferenceValue(DashHeaderScrimHandledKey.self) { handled in
          if !handled {
            DashHeaderScrim(scroll: scroll)
              .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
              .allowsHitTesting(false)
          }
        }
        .backgroundPreferenceValue(DashHeaderScrimHandledKey.self) { handled in
          if !handled {
            DashHeaderScrollProbe(scroll: scroll, wash: washScroll)
            // The band draws above its own layout box to cover the status bar;
            // SwiftUI's hosting wrappers shear it there unless they are unclipped.
            DashScreenClipLift()
          }
        }
    }
  }
}

/// The screen's header frost: a variable-radius backdrop strongest at the
/// physical top edge, with an adaptive tint eased to fully clear below the
/// navigation region so its lower edge never lands as a line on the content.
///
/// It lives inside the page on purpose. The page-owned navigation chrome is
/// layered above it, so the title and controls stay crisp; a band floated over
/// the pager (where the profile avatar lives) would cover them instead.
struct DashHeaderScrim: View {
  let scroll: DashHeaderScrollState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    GeometryReader { proxy in
      // Mounted only while it shows: even an invisible backdrop filter still
      // participates in compositing.
      if scroll.isFrosted {
        // The reader sits in the content's safe area, whose top inset already
        // covers the status bar and page navigation region. The tail gives the blur and
        // tint room to disappear.
        let top = max(proxy.safeAreaInsets.top, DashHeaderScrimMetrics.minimumTop)
        let height = top + DashHeaderScrimMetrics.tail
        band(
          opaqueSolidFraction: top / height,
          height: height
        )
        .frame(width: proxy.size.width, height: height)
        .offset(y: -top)
        .transition(scrimTransition)
      }
    }
    .animation(scrimAnimation, value: scroll.isFrosted)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private var scrimAnimation: Animation {
    guard !reduceMotion else { return DashTheme.Motion.reduced }
    return scroll.isFrosted
      ? DashHeaderScrimMotion.insertion
      : DashHeaderScrimMotion.removal
  }

  private var scrimTransition: AnyTransition {
    guard !reduceMotion else { return .opacity }
    return .asymmetric(
      insertion: .opacity.combined(
        with: .offset(y: DashHeaderScrimMotion.insertionOffsetY)
      ),
      removal: .opacity.combined(
        with: .offset(y: DashHeaderScrimMotion.removalOffsetY)
      )
    )
  }

  /// The optical path follows ProgressiveBlurHeader: one variable-radius
  /// backdrop plus an adaptive white/black tint ramp.
  ///
  /// Reduce Transparency drops to one flat canvas layer. Its plateau spans the
  /// complete measured top inset, keeping the status and navigation regions
  /// opaque before the same smooth tail begins.
  @ViewBuilder
  private func band(
    opaqueSolidFraction: CGFloat,
    height: CGFloat
  ) -> some View {
    if reduceTransparency {
      DashTheme.canvas
        .mask { ramp(solidFraction: opaqueSolidFraction, extent: 1) }
    } else {
      ZStack {
        VariableBlurView(
          maxBlurRadius: DashHeaderScrimMetrics.maxBlurRadius,
          direction: .blurredTopClearBottom,
          startOffset: DashHeaderScrimMetrics.startOffset
        )
        tintRamp(height: height)
      }
    }
  }

  private func tintRamp(height: CGFloat) -> LinearGradient {
    let middle = min(max(DashHeaderScrimMetrics.tintMiddleY / height, 0), 1)
    let tint: Color = colorScheme == .dark ? .black : .white
    return LinearGradient(
      stops: [
        Gradient.Stop(color: tint.opacity(DashHeaderScrimMetrics.tintOpacityTop), location: 0),
        Gradient.Stop(
          color: tint.opacity(DashHeaderScrimMetrics.tintOpacityMiddle),
          location: middle
        ),
        Gradient.Stop(color: tint.opacity(0), location: 1),
      ],
      startPoint: .top,
      endPoint: .bottom
    )
  }

  private func ramp(solidFraction: CGFloat, extent: CGFloat) -> LinearGradient {
    LinearGradient(
      stops:
        DashHeaderScrimRules
        .maskStops(solidFraction: solidFraction, extent: extent)
        .map { Gradient.Stop(color: .white.opacity($0.opacity), location: $0.location) },
      startPoint: .top,
      endPoint: .bottom
    )
  }
}

/// Re-resolution window after a screen mounts, in milliseconds from the mount.
/// Same shape as `TabPagerLockRetrySchedule`, stretched: a pushed screen's
/// scroll view can arrive well after the transition starts.
enum DashHeaderScrollProbeSchedule {
  static let offsetsMS: [Int64] = [0, 32, 120, 320, 700]
}

/// Reports this screen's scroll position to its `DashHeaderScrollState`.
/// Installed by `dashHeaderScrim()`, so every tab root and every pushed
/// destination feeds its own frost without a feature screen knowing it exists.
struct DashHeaderScrollProbe: UIViewRepresentable {
  let scroll: DashHeaderScrollState
  /// This root's private workspace snapshot — nil on pushed destinations. One
  /// observation feeds both: the frost wants a threshold off this distance,
  /// the glow wants the distance itself.
  var wash: DashWorkspaceWashScroll?

  func makeUIView(context: Context) -> DashHeaderScrollProbeView {
    DashHeaderScrollProbeView()
  }

  func updateUIView(_ uiView: DashHeaderScrollProbeView, context: Context) {
    uiView.configure(scroll: scroll, wash: wash)
  }

  static func dismantleUIView(_ uiView: DashHeaderScrollProbeView, coordinator: ()) {
    uiView.tearDown()
  }
}

/// KVO on the screen's own scroll view — not a SwiftUI preference. Global-frame
/// probes bubbling up through the pager re-evaluate the tab container on every
/// scrolled frame, which cancels a running push; an observation writing into an
/// `@Observable` store re-renders only the band that reads it.
final class DashHeaderScrollProbeView: UIView {
  private weak var scroll: DashHeaderScrollState?
  private weak var wash: DashWorkspaceWashScroll?
  private weak var scrollView: UIScrollView?
  private var offsetObservation: NSKeyValueObservation?
  private var retryTask: Task<Void, Never>?

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    isHidden = true
    backgroundColor = .clear
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  func configure(scroll: DashHeaderScrollState, wash: DashWorkspaceWashScroll?) {
    self.scroll = scroll
    // Reassigned rather than merged: each cached root owns one stable snapshot,
    // while pushed destinations receive nil. The one visible wash decides which
    // two root snapshots participate in a tab handoff.
    self.wash = wash
    attachIfNeeded()
    report()
    scheduleAttachRetries()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    guard window != nil else { return }
    attachIfNeeded()
    report()
    scheduleAttachRetries()
  }

  override func willMove(toWindow newWindow: UIWindow?) {
    if newWindow == nil { detach() }
    super.willMove(toWindow: newWindow)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    attachIfNeeded()
    report()
  }

  func tearDown() {
    detach()
    scroll = nil
    // Deliberately not cleared to zero: a teardown is a rebuild as often as a
    // departure, and snapping the glow back down would flash it under whatever
    // replaces this screen. The next owner reports its own position on mount.
    wash = nil
  }

  private func detach() {
    retryTask?.cancel()
    retryTask = nil
    offsetObservation = nil
    scrollView = nil
  }

  /// A screen's scroll view is rarely laid out by the time its chrome mounts —
  /// on a push it appears a few frames into the transition. `layoutSubviews`
  /// alone fires too early and may never fire again, which is how a screen ends
  /// up permanently without a frost. Re-resolve across a short window instead.
  private func scheduleAttachRetries() {
    retryTask?.cancel()
    guard window != nil else {
      retryTask = nil
      return
    }
    retryTask = Task { @MainActor [weak self] in
      var previousMS: Int64 = 0
      for offsetMS in DashHeaderScrollProbeSchedule.offsetsMS {
        let delayMS = offsetMS - previousMS
        previousMS = offsetMS
        if delayMS > 0 {
          do {
            try await Task.sleep(for: .milliseconds(delayMS))
          } catch {
            return
          }
        }
        guard !Task.isCancelled, let self, self.window != nil else { return }
        self.attachIfNeeded()
        self.report()
      }
      self?.retryTask = nil
    }
  }

  private func attachIfNeeded() {
    guard let window else { return }
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

  private func report() {
    guard let scroll, window != nil else { return }
    guard let scrollView, scrollView.window != nil else {
      scroll.clear()
      wash?.clear()
      return
    }
    let distance = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
    scroll.report(distance: distance)
    wash?.report(distance: distance)
  }
}

/// Unclips SwiftUI's hosting wrappers between this view and its screen's view
/// controller, so a layer inside the page can paint into the status-bar band.
/// The content view controller itself and every navigation / page transition
/// ancestor above it stay clipped — unclipping those lets one screen's chrome
/// spill over an incoming push.
struct DashScreenClipLift: UIViewRepresentable {
  func makeUIView(context: Context) -> DashScreenClipLiftView {
    DashScreenClipLiftView()
  }

  func updateUIView(_ uiView: DashScreenClipLiftView, context: Context) {
    uiView.scheduleLift()
  }
}

final class DashScreenClipLiftView: UIView {
  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    backgroundColor = .clear
    isHidden = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil { scheduleLift() }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    DashScreenClipScope.lift(from: self)
  }

  func scheduleLift() {
    DispatchQueue.main.async { [weak self] in
      self?.lift()
      // SwiftUI rebuilds often re-enable clipping; one follow-up pass catches that.
      DispatchQueue.main.async { [weak self] in
        self?.lift()
      }
    }
  }

  private func lift() {
    DashScreenClipScope.lift(from: self)
  }
}

/// Testable boundary for the UIKit mutation above.
@MainActor
enum DashScreenClipScope {
  static func lift(from view: UIView) {
    guard let contentRoot = DashScreenScrollLocator.enclosingContentView(from: view) else {
      return
    }
    var node = view.superview
    while let current = node, current !== contentRoot {
      current.clipsToBounds = false
      node = current.superview
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
protocol DashScreenContainerController: AnyObject {}

@MainActor
enum DashScreenScrollLocator {
  /// Nearest non-container view controller hosting `view`. Navigation, tab and
  /// page containers are skipped so each content screen resolves itself — the
  /// page container especially: its root view holds all three tab pages, and a
  /// screen that resolved to it would search its neighbours' content.
  static func enclosingViewController(from view: UIView) -> UIViewController? {
    var node: UIView? = view
    while let current = node {
      var responder: UIResponder? = current
      while let next = responder {
        if let controller = next as? UIViewController,
          !(controller is UINavigationController),
          !(controller is UITabBarController),
          !(controller is UIPageViewController),
          !(controller is DashScreenContainerController),
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

  /// The screen's primary scroll view: the tallest outermost scroll inside its
  /// content view that is not the three-tab pager. Nested regions (tray bodies,
  /// the Domains viewport, a build log) are height-capped and lose; the walk
  /// stops at each scroll rather than descending, so a page scroll's own
  /// children never compete with it.
  ///
  /// Tallest, not first-found: a screen with header chrome (`DashFeatureList`'s
  /// `header:`) puts that chrome ahead of the page scroll in subview order, and
  /// picking by document order would hand the screen to whatever the chrome
  /// happens to contain.
  static func contentScrollView(
    from view: UIView,
    minimumHeight: CGFloat = 80
  ) -> UIScrollView? {
    let root = enclosingContentView(from: view) ?? view.superview ?? view
    var best: UIScrollView?
    func walk(_ node: UIView) {
      if let scroll = node as? UIScrollView,
        !DashScrollViewConfigurator.isTabPager(scroll),
        scroll.bounds.height > minimumHeight
      {
        if scroll.bounds.height > (best?.bounds.height ?? 0) { best = scroll }
        return
      }
      for child in node.subviews { walk(child) }
    }
    walk(root)
    return best
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
    // "near white", and clearing it leaves the page-host plate transparent.
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
