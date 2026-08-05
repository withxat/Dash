import CloudflareAPI
import GradientAvatars
import SwiftDitherKit
import SwiftUI
import UIKit

enum DashTheme {
  enum Layout {
    static let emptyStateMinHeight: CGFloat = 420
    static let minimumHitTarget: CGFloat = 44
    /// Title + subtitle list row. Resources `FeatureRow` usually settles on two
    /// subtitle lines; detail Actions with short blurbs reserve the same slot
    /// so they don't stack denser than the catalog.
    static let subtitledListRow: CGFloat = 72
    /// Fixed height for every primary / secondary tray pill. Never `minHeight`
    /// alone — pills must not grow with Dynamic Type or leftover tray space.
    static let actionPillHeight: CGFloat = 48
  }

  enum DitherChart {
    /// Byte-formatted axes need a wider gutter than `1.2K` does — "17.4 MB"
    /// clips against the default leading margin.
    static func options(
      showsLegend: Bool,
      accessibility: DitherAccessibility,
      valueFormat: DitherValueFormat = .compact,
      leadingMargin: CGFloat = 42
    ) -> DitherCartesianOptions {
      DitherCartesianOptions(
        stacking: .overlaid,
        margins: DitherMargins(top: 8, trailing: 8, bottom: 24, leading: leadingMargin),
        bloom: .off,
        interactive: true,
        showsAxes: true,
        showsLegend: showsLegend,
        showsTooltip: true,
        valueFormat: valueFormat,
        accessibility: accessibility)
    }

    /// Plot-only chart: no axes, labels, scrubbing, or tooltip — flush margins
    /// so the sparkline can sit on a metric panel edge.
    static func sparklineOptions(
      accessibility: DitherAccessibility,
      valueCeiling: Double? = nil
    ) -> DitherCartesianOptions {
      DitherCartesianOptions(
        stacking: .overlaid,
        margins: .sparkline,
        bloom: .off,
        interactive: false,
        showsAxes: false,
        showsLegend: false,
        showsTooltip: false,
        valueFormat: .compact,
        accessibility: accessibility,
        valueCeiling: valueCeiling)
    }

    static func polarOptions(
      showsLegend: Bool = true,
      accessibility: DitherAccessibility
    ) -> DitherPolarOptions {
      DitherPolarOptions(
        bloom: .off,
        interactive: true,
        showsLegend: showsLegend,
        showsTooltip: true,
        valueFormat: .compact,
        accessibility: accessibility)
    }

    static func height(
      dynamicTypeSize: DynamicTypeSize,
      showsLegend: Bool = false
    ) -> CGFloat {
      if dynamicTypeSize.isAccessibilitySize {
        return showsLegend ? 260 : 240
      }
      return showsLegend ? 214 : 190
    }

    /// Half-row collapsed Watchtower metric charts.
    static func collapsedHeight(dynamicTypeSize: DynamicTypeSize) -> CGFloat {
      dynamicTypeSize.isAccessibilitySize ? 120 : 88
    }

    static func brand(
      colorScheme: ColorScheme,
      contrast: ColorSchemeContrast
    ) -> DitherColor {
      // `color-kumo-brand` / `text-kumo-link` (high-contrast).
      adaptive(
        colorScheme: colorScheme,
        contrast: contrast,
        light: 0x056DFF,
        dark: 0x045EDE,
        highLight: 0x1447E6,
        highDark: 0x51A2FF)
    }

    static func warning(
      colorScheme: ColorScheme,
      contrast: ColorSchemeContrast
    ) -> DitherColor {
      // `text-kumo-warning` / `color-kumo-warning`.
      adaptive(
        colorScheme: colorScheme,
        contrast: contrast,
        light: 0xBD6500,
        dark: 0xFF8904,
        highLight: 0x9F2D00,
        highDark: 0xFFD6A7)
    }

    static func positive(
      colorScheme: ColorScheme,
      contrast: ColorSchemeContrast
    ) -> DitherColor {
      // Green fill for healthy slices/series; same family as `DashTheme.success`.
      adaptive(
        colorScheme: colorScheme,
        contrast: contrast,
        light: 0x00A63E,
        dark: 0x00C950,
        highLight: 0x008236,
        highDark: 0x7BF1A8)
    }

    static func negative(
      colorScheme: ColorScheme,
      contrast: ColorSchemeContrast
    ) -> DitherColor {
      // Red fill for failed slices/series; same family as `DashTheme.danger`.
      adaptive(
        colorScheme: colorScheme,
        contrast: contrast,
        light: 0xE7000B,
        dark: 0xFF6467,
        highLight: 0xC10007,
        highDark: 0xFFA2A2)
    }

    static func neutral(
      colorScheme: ColorScheme,
      contrast: ColorSchemeContrast
    ) -> DitherColor {
      // Grey fill for canceled/other buckets; sits between `subtle` and `faint`.
      adaptive(
        colorScheme: colorScheme,
        contrast: contrast,
        light: 0x6A7282,
        dark: 0x6A7282,
        highLight: 0x4A5565,
        highDark: 0x99A1AF)
    }

    static func accentPurple(
      colorScheme: ColorScheme,
      contrast: ColorSchemeContrast
    ) -> DitherColor {
      // Categorical violet for multi-slice donuts (DNS record types).
      adaptive(
        colorScheme: colorScheme,
        contrast: contrast,
        light: 0x8E51FF,
        dark: 0x8E51FF,
        highLight: 0x6E11B0,
        highDark: 0xC4B4FF)
    }

    static func accentTeal(
      colorScheme: ColorScheme,
      contrast: ColorSchemeContrast
    ) -> DitherColor {
      // Categorical teal for multi-slice donuts (DNS record types).
      adaptive(
        colorScheme: colorScheme,
        contrast: contrast,
        light: 0x009689,
        dark: 0x00BBA7,
        highLight: 0x00786F,
        highDark: 0x46ECD5)
    }

    static func accentBlue(
      colorScheme: ColorScheme,
      contrast: ColorSchemeContrast
    ) -> DitherColor {
      // Categorical blue — matches the Web Analytics dashboard sparklines.
      adaptive(
        colorScheme: colorScheme,
        contrast: contrast,
        light: 0x2B7FFF,
        dark: 0x51A2FF,
        highLight: 0x1447E6,
        highDark: 0x8EC5FF)
    }

    private static func adaptive(
      colorScheme: ColorScheme,
      contrast: ColorSchemeContrast,
      light: UInt32,
      dark: UInt32,
      highLight: UInt32,
      highDark: UInt32
    ) -> DitherColor {
      switch (colorScheme, contrast) {
      case (.dark, .increased):
        DitherColor(hex: highDark)
      case (.dark, _):
        DitherColor(hex: dark)
      case (_, .increased):
        DitherColor(hex: highLight)
      default:
        DitherColor(hex: light)
      }
    }
  }

  enum Radius {
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let button: CGFloat = 18
    static let card: CGFloat = 24
    static let sheet: CGFloat = 36
  }

  static var buttonShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
  }

  /// Rounded-full pill used by every primary action button.
  static var pillShape: Capsule {
    Capsule(style: .continuous)
  }

  enum Spacing {
    static let screen: CGFloat = 16
    static let section: CGFloat = 20
    static let card: CGFloat = 16
    /// Gap between tiles in home shortcut grids and similar 2-up layouts.
    static let itemGap: CGFloat = 12
    /// Optical inset for bare list rows, matching the group title above them.
    static let rowInset: CGFloat = 4
    /// Tight inline rhythm — search rows, tool-tile stacks, banner internals.
    static let compact: CGFloat = 10
    /// Comfortable stack and row padding — empty states, value rows, sheet headers.
    static let comfortable: CGFloat = 14
    /// Inner horizontal padding of a single item card (tiles, vivid hero cards).
    static let itemCardInset: CGFloat = comfortable
    /// Generous outer padding — empty-state panels, text-tab tracks, sheet insets.
    static let panel: CGFloat = 28
    /// Extra scroll padding above the floating tab bar / home indicator.
    static let scrollBottomInset: CGFloat = 80
    /// Air above the Home greeting under the nav bar.
    static let homeGreetingTop: CGFloat = section
    /// Air under the Home greeting before quick actions.
    static let homeGreetingBottom: CGFloat = panel
  }

  /// Trailing chevron glyph sizes — row disclosure vs compact inline menus.
  enum Chevron {
    static let row: CGFloat = 16
    static let compact: CGFloat = 14
  }

  /// Edge tokens for cards, tiles, and floating chrome — a flat 1pt ring, no
  /// drop shadow. Both cases now render the same ring (shadows removed
  /// project-wide); kept as two cases only for call-site readability.
  enum Shadow {
    /// Cards and containers — the default elevated surface treatment.
    case border
    /// Floating chrome (tab bar).
    case raised
  }

  /// The app's single motion vocabulary. Nothing outside this enum should mint
  /// its own duration or spring — a screen you never thought about beside another
  /// still moves at the same pace because both pull their timing from here.
  ///
  /// Slow in, faster out: a surface enters on its base token and leaves on the
  /// matching faster, more-damped exit (`morph` → `morphExit`, `present` →
  /// `dismiss`). The exit is where the user has already decided — get out of the
  /// way instead of dragging the affordance off screen.
  ///
  /// The reduce-motion-aware tokens (`@MainActor var`) self-resolve: movement
  /// collapses to a short opacity ease. The raw `static let` springs are gated by
  /// their call sites, which sometimes want `nil` (instant) instead of `reduced`.
  enum Motion {
    @MainActor private static var isReduced: Bool { UIAccessibility.isReduceMotionEnabled }

    // MARK: Micro — frequent, symmetric feedback. Un-gated: call sites choose
    // `nil` (instant) vs `reduced` for their reduce-motion branch.
    static let quick = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.12)
    static let press = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.15)
    /// Loading ring ↔ success glyph. The swap is the last thing between a
    /// finished write and the tray leaving, so it eases out rather than in and
    /// out: the arriving glyph is already legible in the first third instead of
    /// crossing a half-faded midpoint the user waits through.
    static let iconSwap = Animation.easeOut(duration: 0.16)
    /// Staggered text entrance: Transitions.dev's 12pt / 3pt-blur reveal.
    static let textReveal = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.5)
    /// Failure-reveal exit is deliberately independent: one quiet, synchronous
    /// CSS `ease` fade with no stagger, offset, or blur played backwards.
    static let failureDismiss = Animation.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.2)
    /// Correctness fallback when the initiating button is dismissed before its
    /// animation completion can report back.
    @MainActor static var iconSwapFallbackDelay: Duration {
      // `iconSwap` plus a frame of slack — it must outlast the real completion
      // callback, not become a second dwell the user sits through.
      UIAccessibility.isReduceMotionEnabled ? .zero : .milliseconds(260)
    }

    /// Reduce-motion fallback: position/scale drop out, a short opacity ease stays.
    static let reduced = Animation.easeOut(duration: 0.12)

    /// UIKit timings for Dash's page compositor. Detail drills share the tab
    /// handoff settle window; workspace overlays keep a distinct vertical train;
    /// exits finish sooner than their matching entrances.
    enum Page {
      static let reducedDuration: TimeInterval = 0.12
      static let flowEnterDuration: TimeInterval = 0.3
      static let flowExitDuration: TimeInterval = 0.3
      static let entityEnterDuration: TimeInterval = 0.29
      static let entityExitDuration: TimeInterval = 0.23
      /// Family's wallet-card pattern: geometry settles first, with destination
      /// chrome resolving during the latter half. Collapse is a firmer inverse.
      static let cardEnterDuration: TimeInterval = 0.38
      static let cardExitDuration: TimeInterval = 0.34
      static let cardDampingRatio: CGFloat = 1
      // The full-height workspace train stays close to the flow handoff pace.
      static let workspaceEnterDuration: TimeInterval = 0.28
      static let workspaceExitDuration: TimeInterval = 0.22
      static let dampingRatio: CGFloat = 0.9
      /// Flow drills use the tab settle spring so push and tab swipe read as
      /// one horizontal language (`tabStepSettleDampingRatio`).
      static let flowDampingRatio: CGFloat = 0.68
      /// Slightly underdamped on entrance; exit stays firmer so Close leaves cleanly.
      static let workspaceEnterDampingRatio: CGFloat = 0.84
      static let workspaceExitDampingRatio: CGFloat = 0.9
    }

    /// Skeleton → loaded content: long enough for blur to read.
    @MainActor static var content: Animation {
      isReduced ? reduced : Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.3)
    }

    /// Hero morph for matchedGeometryEffect trays and the shared confirm
    /// affordances — springy and slower than the micro tokens so the shape
    /// change reads. Enter / expand.
    @MainActor static var morph: Animation {
      isReduced ? reduced : Animation.spring(response: 0.28, dampingFraction: 0.82)
    }
    /// The exit half of `morph`: a collapse / cancel / close leaves quicker and
    /// more damped, so a dismissed affordance never drags on the way out.
    @MainActor static var morphExit: Animation {
      isReduced ? reduced : Animation.spring(response: 0.22, dampingFraction: 0.92)
    }

    /// A small threshold-crossing pop for pull affordances and the tab icon —
    /// enough overshoot to snap without wobbling.
    @MainActor static var pop: Animation {
      isReduced ? reduced : Animation.spring(response: 0.3, dampingFraction: 0.6)
    }

    /// Firm chrome arrival that lands without bounce — keyboard lift, the
    /// floating tab bar showing/hiding, and switching tabs. Critically damped:
    /// it settles exactly, so unrelated chrome shares one calm pace.
    @MainActor static var settle: Animation {
      isReduced ? reduced : Animation.spring(response: 0.32, dampingFraction: 0.9)
    }

    /// Family-style tab handoff: a short directional flight between two content
    /// identities while the workspace wash, root header, and dock stay fixed.
    /// The two page timelines are deliberately asymmetric (measured from
    /// Family's own switches at 60fps): the outgoing page clears FIRST — a
    /// front-loaded fade over a near-constant glide, still travelling when it
    /// vanishes — and the incoming page lands just after it, a lagged S-curve
    /// fade riding a soft spring settle with ~1pt of overshoot. The opacities
    /// are not complementary: at the crossover both sit near 30%, so the swap
    /// briefly breathes toward the canvas instead of double-exposing two pages.
    static let tabStepSlide: CGFloat = 24
    static let tabStepOutgoingFadeDuration: TimeInterval = 0.12
    static let tabStepOutgoingFadeControlPoint1 = CGPoint(x: 0.2, y: 0.7)
    static let tabStepOutgoingFadeControlPoint2 = CGPoint(x: 0.4, y: 1)
    static let tabStepOutgoingSlideDuration: TimeInterval = 0.15
    static let tabStepIncomingFadeDuration: TimeInterval = 0.14
    static let tabStepSettleDuration: TimeInterval = 0.3
    static let tabStepSettleDampingRatio: CGFloat = 0.68
    /// The ONE workspace wash blends the two tabs' scroll lifts across the same
    /// handoff. It is shared chrome behind both pages, so it keeps a single
    /// calm complementary curve that finishes inside the settle window.
    static let tabStepDuration: TimeInterval = 0.26
    static let tabStepControlPoint1 = CGPoint(x: 0.22, y: 1)
    static let tabStepControlPoint2 = CGPoint(x: 0.36, y: 1)
    static let tabStep = Animation.timingCurve(
      Double(tabStepControlPoint1.x),
      Double(tabStepControlPoint1.y),
      Double(tabStepControlPoint2.x),
      Double(tabStepControlPoint2.y),
      duration: tabStepDuration)

    // MARK: Tray

    /// During an internal route replacement, the compact card follows the active
    /// step's measured height independently of the content crossfade.
    static let trayResize = Animation.timingCurve(0.25, 1, 0.5, 1, duration: 0.27)
    /// Step replacement paces. Returning to a root menu is a little quicker;
    /// destructive confirmations arrive fastest so the warning reads promptly
    /// while the shell continues its own 270ms settle.
    static let trayStep = Animation.timingCurve(0.26, 0.08, 0.25, 1, duration: 0.27)
    static let trayStepReturn = Animation.timingCurve(0.26, 0.08, 0.25, 1, duration: 0.22)
    static let trayStepDestructive = Animation.timingCurve(
      0.26, 0.08, 0.25, 1, duration: 0.15)
    /// Horizontal travel of a stack-driven tray step: fly instead of teleport.
    /// Forward pushes enter from the trailing side and exit leading; a pop
    /// mirrors both. Small on purpose — a directional flash, not a page slide.
    static let trayStepSlide: CGFloat = 24
    // MARK: Floating surfaces — Toast and free-moving interaction vocabulary.
    // Raw springs: call sites gate reduce-motion, and some deliberately skip the
    // gate to keep a drag-release physical.
    static let present = Animation.spring(
      response: 0.35, dampingFraction: 0.88, blendDuration: 0.12)
    static let release = Animation.spring(
      response: 0.34, dampingFraction: 0.82, blendDuration: 0.14)
    static let dismiss = Animation.spring(
      response: 0.28, dampingFraction: 0.94, blendDuration: 0.08)
    /// Tray scrim opacity fades in/out in place while the card rides its own
    /// spring. Opacity carries no physics, so a timing curve reads cleaner than
    /// a spring and stays in step with the card's settle: present eases out so
    /// the scrim arrives and holds, dismiss eases in so it lingers then drops.
    static let scrimPresent = Animation.easeOut(duration: 0.3)
    static let scrimDismiss = Animation.easeIn(duration: 0.22)
  }

  enum Sheet {
    /// Body and footer inset inside a floating content tray.
    static let content: CGFloat = 24
    /// Header chrome is optically wider than the body. A 44pt close target has
    /// a 32pt visible face, so these values put that face at 28pt on a root step
    /// and 32pt on a detail step.
    static let headerHorizontal: CGFloat = 28
    static let headerTop: CGFloat = 22
    static let detailHeaderTop: CGFloat = 26
    static let headerBottom: CGFloat = 6
    static let descriptionBottom: CGFloat = Spacing.comfortable
    static let bodyVertical: CGFloat = 16
    static let bodyBottom: CGFloat = 24
    static let actionGap: CGFloat = 16
    /// Near-white keeps the floating face distinct from a pure-white canvas;
    /// Dark Mode retains Dash's established surface instead of copying a
    /// light-only web demo.
    static let background = adaptive(light: 0xFEFFFE, dark: 0x0F0F0F)
    /// `text-kumo-placeholder`
    static let closeIcon = adaptive(light: 0xA1A1A1, dark: 0x737373)
    /// 1pt rule under tray titles — same adaptive edge as `DashTheme.separator`.
    static var headerBorder: Color { DashTheme.separator }
    /// `color-kumo-tint`
    static let shortcutItem = adaptive(light: 0xF5F5F5, dark: 0x262626)
    static let scrimOpacity: CGFloat = 0.35
    /// Gap between a floating tray and the screen edges.
    static let floatingMargin: CGFloat = 12
    /// Lets the compact tray sit slightly inside the home-indicator safe area.
    static let floatingBottomTuck: CGFloat = 6
  }

  enum Toast {
    /// Toasts and trays share the established floating-chrome edge margin.
    static let horizontalMargin: CGFloat = 12
  }

  // Palette mirrors https://kumo-ui.com/colors/ token reference (sRGB hex
  // baked from the documented oklch / Tailwind stops). Prefer these roles
  // over raw hex at call sites — domain card customization is the exception.

  /// `color-kumo-canvas`
  static let canvas = adaptive(light: 0xFBFBFB, dark: 0x030303)
  /// `color-kumo-elevated`
  static let elevated = adaptive(light: 0xF8F8F8, dark: 0x060606)
  /// `color-kumo-recessed`
  static let recessed = adaptive(light: 0xF2F2F2, dark: 0x0B0B0B)
  /// Home Domains card.
  ///
  /// The light value tracks `listGroupHeaderSurface` on purpose, not by
  /// derivation: Domains, Shortcuts, and Recently used are three sibling
  /// groups stacked on one screen, and their outer plates have to be one
  /// tone (`#F6F6F6`). The two tokens stay separate because this one also
  /// fills the expanded zone rows and backs the avatar-overlap ring — move
  /// that value and look at this one in the same pass.
  static let homeDomainsSurface = adaptive(light: 0xF6F6F6, dark: 0x262626)
  /// Header band across a two-tone list group — elevated dark step so the band
  /// stays visible above the card fill.
  ///
  /// Light `#F6F6F6` matches `homeDomainsSurface` so Home's sibling groups and
  /// every `DashInfoGroup` / `DashTwoToneListGroup` share one outer plate. It
  /// also paints the 2pt border showing through around the rows card, so keep
  /// it a step off `homeCardSurface` white in both appearances.
  static let listGroupHeaderSurface = adaptive(light: 0xF6F6F6, dark: 0x333333)
  /// Home's cards (Shortcuts / Recently used / quick actions) — `color-kumo-base`
  /// in light; `color-kumo-tint` in dark. These groups carry no ring, so this
  /// fill is the only thing that separates the rows from the header band above
  /// them — it has to stay a step away from `listGroupHeaderSurface` in both
  /// appearances.
  static let homeCardSurface = adaptive(light: 0xFFFFFF, dark: 0x262626)
  /// Quiet glyph on a quick-action tile — `text-kumo-inactive`.
  static let homeCardGlyph = adaptive(light: 0xD4D4D4, dark: 0x525252)
  /// Neutral capsule behind a small metadata badge (`DashMetaBadge`) — a
  /// license identifier, a section's freshness. It carries no tone on purpose;
  /// anything reporting state belongs to `StatusBadge` and its tinted fills.
  static let metaBadgeSurface = adaptive(light: 0xF5F5F5, dark: 0x262626)
  /// Floating tab bar — `color-kumo-control`.
  static let tabBarSurface = adaptive(light: 0xFFFFFF, dark: 0x18181B)
  /// `color-kumo-tint` / control dark — soft fills behind controls.
  static let base = adaptive(light: 0xF5F5F5, dark: 0x18181B)
  /// `color-kumo-fill` / `color-kumo-interact` (dark).
  static let fill = adaptive(light: 0xE5E5E5, dark: 0x404040)
  /// `text-kumo-default`
  static let text = adaptive(light: 0x18181B, dark: 0xF5F5F5)
  /// `text-kumo-strong`
  static let strong = adaptive(light: 0x0A0A0A, dark: 0xFAFAFA)
  /// List-group section labels (Shortcuts, Deployments, …) — same quiet ink
  /// as supporting metric labels ("Requests" on analytics cards).
  static let listGroupTitle = subtle
  /// `text-kumo-subtle` — Increased Contrast steps toward strong / inactive.
  static let subtle = adaptive(
    light: 0x737373, dark: 0xA1A1A1, highLight: 0x525252, highDark: 0xD4D4D4)
  /// List-row descriptions — `text-kumo-placeholder`; Increased Contrast
  /// promotes back to `subtle`.
  static let rowSubtitle = adaptive(
    light: 0xA1A1A1, dark: 0xA1A1A1, highLight: 0x737373, highDark: 0xD4D4D4)
  /// Quiet icon actions — between `subtle` and `inactive`.
  static let faint = adaptive(
    light: 0xA1A1A1, dark: 0x737373, highLight: 0x737373, highDark: 0xA1A1A1)
  /// Leading icons on neutral tray menu rows — `text-kumo-subtle`.
  static let iconMuted = adaptive(
    light: 0x737373, dark: 0xA1A1A1, highLight: 0x525252, highDark: 0xD4D4D4)
  /// `text-kumo-placeholder`
  static let placeholder = adaptive(
    light: 0xA1A1A1, dark: 0x737373, highLight: 0x737373, highDark: 0xA1A1A1)
  /// `text-kumo-inverse`
  static let inverse = adaptive(light: 0xF5F5F5, dark: 0x171717)

  /// Cloudflare brand orange — canonical `#F6821F` in light, lifted in dark and
  /// under Increased Contrast so storage accents and proxied-DNS badges stay
  /// recognizable. Not the catalog blue (`brand`).
  static let accent = adaptive(
    light: 0xF6821F, dark: 0xFF9838, highLight: 0xC45A00, highDark: 0xFFB366)
  /// Soft brand-orange default for the workspace's configurable top light
  /// field (`DashWorkspaceTopWash`, shared by all three tab roots). Same
  /// adaptive stop as `accent`; call sites apply opacity so it washes into
  /// `canvas`.
  static let wash = accent

  /// Decorative workspace pigments. They retain the existing Kumo four-stop
  /// adaptation instead of borrowing info/success/danger status roles. Purple
  /// and teal match the app's categorical chart families.
  static func workspaceWash(for preset: DashWorkspaceWashPreset) -> Color {
    switch preset {
    case .none:
      .clear
    case .cloudflare:
      wash
    case .blue:
      adaptive(
        light: 0x2B7FFF, dark: 0x51A2FF, highLight: 0x1447E6, highDark: 0x8EC5FF)
    case .purple:
      adaptive(
        light: 0x8E51FF, dark: 0x8E51FF, highLight: 0x6E11B0, highDark: 0xC4B4FF)
    case .teal:
      teal
    }
  }

  /// Categorical teal — the same stop the dither charts use for a third series.
  /// Shared with the `.teal` workspace wash and the registrar detail header.
  static let teal = adaptive(
    light: 0x009689, dark: 0x00BBA7, highLight: 0x00786F, highDark: 0x46ECD5)

  /// `color-kumo-brand` / `color-kumo-brand-hover` (high light) /
  /// `text-kumo-link` (high dark). Reserved for focus rings, primary CTAs,
  /// and rare accents — not catalog decoration.
  static let brand = adaptive(
    light: 0x056DFF, dark: 0x045EDE, highLight: 0x1447E6, highDark: 0x51A2FF)
  static let violet = adaptive(
    light: 0x8E51FF, dark: 0x8E51FF, highLight: 0x6E11B0, highDark: 0xC4B4FF)
  /// Interactive text on Liquid Glass. Keep the regular brand blue in light
  /// mode, but lift dark appearances so small labels stay legible when the
  /// material samples and darkens pigmented content beneath it.
  static let glassActionForeground = adaptive(
    light: 0x056DFF, dark: 0x51A2FF, highLight: 0x1447E6, highDark: 0x8EC5FF)
  /// Shared edge for strokes, 1pt rules, and card rings — pure black/white at
  /// token opacity so the line reads on canvas, wash, elevated, and tinted fills.
  /// Prefer this over solid gray hexes for any border or separator.
  static let separator = Color(
    uiColor: UIColor { traits in
      traits.userInterfaceStyle == .dark
        ? UIColor.white.withAlphaComponent(0.045)
        : UIColor.black.withAlphaComponent(0.055)
    })
  /// Alias of `separator` — kept for older stroke call sites.
  static var line: Color { separator }
  /// Soft solid gray for non-edge uses (globe glow). Not a border token.
  static let hairline = adaptive(light: 0xE9E9E9, dark: 0x262626)
  /// Alias of `separator` — row rules on recessed panels.
  static var panelLine: Color { separator }
  /// Status foregrounds — `text-kumo-*` for readable copy on matching tints.
  /// Increased Contrast lifts dark-mode stops toward `text-kumo-strong`.
  static let danger = adaptive(
    light: 0xC10007, dark: 0xFF6467, highLight: 0xC10007, highDark: 0xFAFAFA)
  /// `color-kumo-danger-tint` composited over `color-kumo-base`.
  static let dangerTint = adaptive(light: 0xFFF3F3, dark: 0x260C0D)
  static let success = adaptive(
    light: 0x006045, dark: 0xA4F4CF, highLight: 0x006045, highDark: 0xFAFAFA)
  /// `color-kumo-success-tint` composited over `color-kumo-base`.
  static let successTint = adaptive(light: 0xEBFDF1, dark: 0x0E1D15)
  /// Locale-aware chart directions need vivid red / green without borrowing
  /// status semantics. The light green keeps 4.95:1 on `homeCardSurface`;
  /// Increased Contrast deepens it further instead of turning both hues white.
  static let chartTrendGreen = adaptive(
    light: DashChartTrendColorTokens.green.light,
    dark: DashChartTrendColorTokens.green.dark,
    highLight: DashChartTrendColorTokens.green.highLight,
    highDark: DashChartTrendColorTokens.green.highDark)
  static let chartTrendRed = adaptive(
    light: DashChartTrendColorTokens.red.light,
    dark: DashChartTrendColorTokens.red.dark,
    highLight: DashChartTrendColorTokens.red.highLight,
    highDark: DashChartTrendColorTokens.red.highDark)
  /// `text-kumo-warning`; high stops use `text-kumo-badge-orange-subtle`.
  /// Light diverges from the Kumo stop (`0xBD6500`, 4.0:1 on `warningTint`):
  /// darkened so 12–13pt badge copy clears WCAG AA 4.5:1 (now 4.9:1).
  static let warning = adaptive(
    light: 0xA85A00, dark: 0xFF8904, highLight: 0x9F2D00, highDark: 0xFFD6A7)
  /// `color-kumo-warning-tint` composited over `color-kumo-base`.
  static let warningTint = adaptive(light: 0xFFFAEA, dark: 0x2A1C0A)
  /// `text-kumo-info` / `text-kumo-link`.
  static let info = adaptive(
    light: 0x193CB8, dark: 0x51A2FF, highLight: 0x193CB8, highDark: 0xFAFAFA)
  /// `color-kumo-info-tint` composited over `color-kumo-base`.
  static let infoTint = adaptive(light: 0xEFF6FF, dark: 0x12182B)

  /// Resolves light/dark, and swaps to higher-contrast stops when Increased Contrast is on.
  private static func adaptive(
    light: UInt32,
    dark: UInt32,
    highLight: UInt32? = nil,
    highDark: UInt32? = nil
  ) -> Color {
    Color(
      uiColor: UIColor { traits in
        let high = traits.accessibilityContrast == .high
        let useDark = traits.userInterfaceStyle == .dark
        let hex: UInt32
        if useDark {
          hex = high ? (highDark ?? dark) : dark
        } else {
          hex = high ? (highLight ?? light) : light
        }
        return UIColor(hex: hex)
      })
  }

  /// Sign-in backdrop palettes: four Paper mesh-gradient spots (orange / white
  /// derived) and the three-stop still wash used under Reduce Motion.
  enum LoginBackdrop {
    /// Spot colors for `loginMeshGradient` — white / cream / soft yellow /
    /// brand-orange wash in light; near-black / base / warning-tint / warm
    /// umber in dark. The orange stop needs enough chroma that moving spots
    /// read as a mesh, not a flat wash.
    static func meshSpots(dark: Bool) -> [SIMD4<Float>] {
      let hexes: [UInt32] =
        dark
        ? [0x030303, 0x18181B, 0x2A1C0A, 0x7A4A12]
        : [0xFFFFFF, 0xFFFAEA, 0xFEF9C2, 0xF6A85C]
      return hexes.map(rgba)
    }

    static let stillLight: [Color] = [
      Color(hex: 0xFFFAEA), Color(hex: 0xFFFFFF), Color(hex: 0xFBFBFB),
    ]
    static let stillDark: [Color] = [
      Color(hex: 0x2A1C0A), Color(hex: 0x030303), Color(hex: 0x18181B),
    ]

    private static func rgba(_ hex: UInt32) -> SIMD4<Float> {
      SIMD4(
        Float((hex >> 16) & 0xFF) / 255,
        Float((hex >> 8) & 0xFF) / 255,
        Float(hex & 0xFF) / 255,
        1)
    }
  }
}

extension UIColor {
  fileprivate convenience init(hex: UInt32) {
    self.init(
      red: CGFloat((hex >> 16) & 0xFF) / 255,
      green: CGFloat((hex >> 8) & 0xFF) / 255,
      blue: CGFloat(hex & 0xFF) / 255,
      alpha: 1)
  }
}

extension UIFont {
  static func dashTitle(size: CGFloat, weight: UIFont.Weight = .bold) -> UIFont {
    .systemFont(ofSize: size, weight: weight)
  }
}

extension Color {
  init(hex: UInt32) {
    self.init(uiColor: UIColor(hex: hex))
  }
}

extension DomainCardColors {
  static func fill(_ hex: UInt32) -> Color { Color(hex: hex) }

  static func foreground(_ hex: UInt32) -> Color {
    prefersLightContent(hex) ? .white : Color(hex: 0x0A0A0A)
  }

  static func secondaryForeground(_ hex: UInt32) -> Color {
    foreground(hex).opacity(0.74)
  }
}

extension Font {
  static func dashTitle(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
    .system(size: size, weight: weight)
  }
}

/// Scalable counterparts to the app's established fixed-size hierarchy. Base
/// sizes intentionally match the existing UI while Dynamic Type supplies the
/// user-selected scale.
enum DashTextStyle {
  case emptyTitle
  case sheetTitle
  case trayTitle
  case sectionTitle
  case body
  case bodyMedium
  case bodySemibold
  case bodyBold
  case button
  case buttonMedium
  case buttonBold
  case supporting
  case supportingMedium
  case supportingSemibold
  case footnote
  case footnoteSemibold
  case caption
  case captionSemibold
  case micro
  case code
  case codeBody

  fileprivate var metrics:
    (
      size: CGFloat, weight: Font.Weight, design: Font.Design, relativeTo: Font.TextStyle
    )
  {
    switch self {
    case .emptyTitle: (24, .bold, .default, .title2)
    case .sheetTitle: (20, .bold, .default, .title3)
    case .trayTitle: (22, .bold, .default, .title3)
    case .sectionTitle: (20, .semibold, .default, .headline)
    case .body: (18, .regular, .default, .body)
    case .bodyMedium: (18, .medium, .default, .body)
    case .bodySemibold: (18, .semibold, .default, .body)
    case .bodyBold: (18, .bold, .default, .body)
    case .button: (18, .semibold, .default, .body)
    case .buttonMedium: (18, .medium, .default, .body)
    case .buttonBold: (18, .bold, .default, .body)
    case .supporting: (17, .regular, .default, .subheadline)
    case .supportingMedium: (16, .medium, .default, .subheadline)
    case .supportingSemibold: (17, .semibold, .default, .subheadline)
    case .footnote: (15, .regular, .default, .footnote)
    case .footnoteSemibold: (15, .semibold, .default, .footnote)
    case .caption: (12, .regular, .default, .caption)
    case .captionSemibold: (12, .semibold, .default, .caption)
    case .micro: (11, .regular, .default, .caption2)
    case .code: (13, .regular, .monospaced, .footnote)
    case .codeBody: (14, .regular, .monospaced, .subheadline)
    }
  }
}

/// Stable product color family for icons and hero moments. Catalog lists use
/// the muted tone; hero/pinned/exception surfaces may use the vivid tone.
enum FeatureVisualTone: Hashable, Sendable {
  case soft
  case brand
  case success
  case warning
  case accent
  case danger
  case info
  case violet
  case teal

  var muted: Color {
    switch self {
    case .soft: DashTheme.iconMuted
    case .brand: DashTheme.brand.opacity(0.85)
    case .success: DashTheme.success.opacity(0.85)
    case .warning: DashTheme.warning.opacity(0.9)
    case .accent: DashTheme.accent.opacity(0.9)
    case .danger: DashTheme.danger.opacity(0.85)
    case .info: DashTheme.info.opacity(0.85)
    case .violet: DashTheme.violet.opacity(0.85)
    case .teal: DashTheme.teal.opacity(0.85)
    }
  }

  var vivid: Color {
    switch self {
    case .soft: DashTheme.strong
    case .brand: DashTheme.brand
    case .success: DashTheme.success
    case .warning: DashTheme.warning
    case .accent: DashTheme.accent
    case .danger: DashTheme.danger
    case .info: DashTheme.info
    case .violet: DashTheme.violet
    case .teal: DashTheme.teal
    }
  }

  /// Label ink for text set on the `vivid` fill (toned tray submit pills).
  /// Most vivid stops are deep in light mode and pale in dark, so adaptive
  /// `inverse` reads on both. Brand orange (`accent`) is mid-luminance in
  /// *both* appearances — near-white `inverse` text lands at ~2.4:1 on
  /// `#F6821F` in light mode — so its label stays fixed near-black
  /// (6.9:1 light, 8.4:1 dark).
  var vividLabel: Color {
    switch self {
    case .accent: Color(hex: 0x171717)
    default: DashTheme.inverse
    }
  }

}

enum FeatureVisualIdentity {
  /// Fallback when only a section title is known (no feature id).
  static func tone(forCategory category: String) -> FeatureVisualTone {
    switch category {
    case "Domains & DNS": .success
    case "Compute": .brand
    case "Storage & Data": .accent
    case "Networks": .violet
    default: .soft
    }
  }

  /// One distinct tone per catalog feature so Resources rows stay scannable.
  static func tone(for feature: FeatureID) -> FeatureVisualTone {
    switch feature {
    case .zones: .success
    case .emailRouting: .danger
    case .workers: .brand
    case .pages: .info
    case .r2: .accent
    case .kv: .warning
    case .tunnels: .violet
    }
  }

  static func catalogColor(for feature: FeatureID) -> Color {
    tone(for: feature).muted
  }

  static func heroColor(for feature: FeatureID) -> Color {
    tone(for: feature).vivid
  }

  /// Saturated fill for rare vivid feature cards.
  static func cardColor(for feature: FeatureID) -> Color {
    tone(for: feature).vivid
  }

  /// Text/icon color on a vivid feature card.
  static func onCardColor(for feature: FeatureID) -> Color {
    DashTheme.inverse
  }
}

/// UILabel-backed footnote text that fills each line to the full proposed width
/// before wrapping. SwiftUI's `Text` breaks with the system "balanced" strategy
/// — it shortens the first line rather than leave a lone word on the last —
/// which reads as wasted width in a list row with a trailing chevron. UILabel
/// with an empty `lineBreakStrategy` wraps greedily; SwiftUI has no API for it.
struct DashGreedyWrapText: UIViewRepresentable {
  let text: String
  var color: Color = DashTheme.rowSubtitle
  var lines: Int = 2

  func makeUIView(context: Context) -> UILabel {
    let label = UILabel()
    label.lineBreakStrategy = []
    label.lineBreakMode = .byTruncatingTail
    // Mirrors `DashTextStyle.footnote` (15pt regular, scaling with .footnote).
    label.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .systemFont(ofSize: 15))
    label.adjustsFontForContentSizeCategory = true
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
  }

  func updateUIView(_ label: UILabel, context: Context) {
    label.text = text
    label.numberOfLines = lines
    label.textColor = UIColor(color)
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize, uiView label: UILabel, context: Context
  ) -> CGSize? {
    let width = proposal.width ?? UIView.layoutFittingExpandedSize.width
    return label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
  }
}

private struct DashTypographyModifier: ViewModifier {
  let style: DashTextStyle
  @ScaledMetric private var size: CGFloat

  init(style: DashTextStyle) {
    self.style = style
    let metrics = style.metrics
    _size = ScaledMetric(wrappedValue: metrics.size, relativeTo: metrics.relativeTo)
  }

  func body(content: Content) -> some View {
    let metrics = style.metrics
    content.font(.system(size: size, weight: metrics.weight, design: metrics.design))
  }
}

extension View {
  func dashTextStyle(_ style: DashTextStyle) -> some View {
    modifier(DashTypographyModifier(style: style))
  }
}
