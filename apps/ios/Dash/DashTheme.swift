import CloudflareAPI
import GradientAvatars
import SwiftDitherKit
import SwiftUI
import UIKit

enum DashTheme {
  enum Layout {
    static let emptyStateMinHeight: CGFloat = 420
    static let minimumHitTarget: CGFloat = 44
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
    /// Loading ring ↔ success glyph: mirrors the shared Transitions.dev icon
    /// swap instead of borrowing the springier tray morph.
    static let iconSwap = Animation.easeInOut(duration: 0.25)
    /// Staggered text entrance: Transitions.dev's 12pt / 3pt-blur reveal.
    static let textReveal = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.5)
    /// Failure-reveal exit is deliberately independent: one quiet, synchronous
    /// CSS `ease` fade with no stagger, offset, or blur played backwards.
    static let failureDismiss = Animation.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.2)
    /// Correctness fallback when the initiating button is dismissed before its
    /// animation completion can report back.
    @MainActor static var iconSwapFallbackDelay: Duration {
      UIAccessibility.isReduceMotionEnabled ? .zero : .milliseconds(350)
    }

    /// Reduce-motion fallback: position/scale drop out, a short opacity ease stays.
    static let reduced = Animation.easeOut(duration: 0.12)

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

    // MARK: Floating surfaces — trays and toasts share one present / release /
    // dismiss set (aliased by `DashTrayMotion` and `DashToastMotion`). `dismiss`
    // is the fast exit. Raw springs: call sites gate reduce-motion, and some
    // deliberately skip the gate to keep a drag-release physical.
    static let present = Animation.spring(
      response: 0.35, dampingFraction: 0.88, blendDuration: 0.12)
    static let release = Animation.spring(
      response: 0.34, dampingFraction: 0.82, blendDuration: 0.14)
    static let dismiss = Animation.spring(
      response: 0.28, dampingFraction: 0.94, blendDuration: 0.08)
  }

  enum Sheet {
    static let content: CGFloat = Spacing.panel
    static let headerTop: CGFloat = Spacing.panel
    static let headerBottom: CGFloat = Spacing.comfortable
    static let bodyVertical: CGFloat = 16
    static let bodyBottom: CGFloat = 32
    /// `color-kumo-base`
    static let background = adaptive(light: 0xFFFFFF, dark: 0x0F0F0F)
    static let grabBarWidth: CGFloat = 36
    static let grabBarHeight: CGFloat = 5
    static let grabBarTop: CGFloat = Spacing.compact
    static let grabBarBottom: CGFloat = 8
    /// `text-kumo-placeholder`
    static let closeIcon = adaptive(light: 0xA1A1A1, dark: 0x737373)
    /// `color-kumo-tint`
    static let headerBorder = adaptive(light: 0xF5F5F5, dark: 0x262626)
    /// `color-kumo-tint`
    static let shortcutItem = adaptive(light: 0xF5F5F5, dark: 0x262626)
    static let scrimOpacity: CGFloat = 0.35
    /// Gap between a floating tray and the screen edges.
    static let floatingMargin: CGFloat = 12
    /// Lets floating trays sit slightly inside the home-indicator safe area.
    static let floatingBottomTuck: CGFloat = 6
    /// Native-sheet-like top corners while an expandable tray is expanded.
    static let expandedTopRadius: CGFloat = 12
    /// Gap kept below the top safe area while expanded.
    static let expandedTopGap: CGFloat = Spacing.compact
    /// Share of the screen an expandable tray keeps when collapsed to its
    /// floating detent.
    static let floatingDetentFraction: CGFloat = 0.62
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
  /// tone. The two tokens stay separate because this one also fills the
  /// expanded zone rows and backs the avatar-overlap ring — move that value
  /// and look at this one in the same pass.
  static let homeDomainsSurface = adaptive(light: 0xEDEDED, dark: 0x262626)
  /// Header band across a two-tone list group — elevated dark step so the band
  /// stays visible above the card fill.
  ///
  /// The light value is deliberately off the neutral ramp, between
  /// `color-kumo-tint` and `color-kumo-fill`, because it does two jobs at once
  /// in `DashTwoToneListGroup`: it fills the header band *and* it is the 2pt
  /// border showing through around the rows card. Tint (`#F5F5F5`) left a 4%
  /// edge nobody could see; fill (`#E5E5E5`) drew the edge but turned the band
  /// into a heavy grey block. Do not "correct" this back onto the ramp without
  /// looking at both at once.
  static let listGroupHeaderSurface = adaptive(light: 0xEDEDED, dark: 0x333333)
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
  /// field (`DashWorkspaceTopWash`, shared by all three tab roots), plus the
  /// fixed About halo. Same adaptive stop as `accent`; call sites apply
  /// opacity so it washes into `canvas`.
  static let wash = accent

  /// Decorative workspace pigments. They retain the existing Kumo four-stop
  /// adaptation instead of borrowing info/success/danger status roles. Purple
  /// and teal match the app's categorical chart families.
  static func workspaceWash(for preset: DashWorkspaceWashPreset) -> Color {
    switch preset {
    case .cloudflare:
      wash
    case .blue:
      adaptive(
        light: 0x2B7FFF, dark: 0x51A2FF, highLight: 0x1447E6, highDark: 0x8EC5FF)
    case .purple:
      adaptive(
        light: 0x8E51FF, dark: 0x8E51FF, highLight: 0x6E11B0, highDark: 0xC4B4FF)
    case .teal:
      adaptive(
        light: 0x009689, dark: 0x00BBA7, highLight: 0x00786F, highDark: 0x46ECD5)
    }
  }

  /// `color-kumo-brand` / `color-kumo-brand-hover` (high light) /
  /// `text-kumo-link` (high dark). Reserved for focus rings, primary CTAs,
  /// and rare accents — not catalog decoration.
  static let brand = adaptive(
    light: 0x056DFF, dark: 0x045EDE, highLight: 0x1447E6, highDark: 0x51A2FF)
  /// `color-kumo-line` (light composited over white; dark solid).
  static let line = adaptive(light: 0xE7E7E7, dark: 0x333333)
  /// `color-kumo-hairline`
  static let hairline = adaptive(light: 0xE9E9E9, dark: 0x262626)
  /// Row separators on `recessed` panels — `color-kumo-line`.
  static let panelLine = adaptive(light: 0xE7E7E7, dark: 0x333333)
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

  /// Sign-in backdrop palettes: 3×3 mesh vertex colors (row-major) and the
  /// three-stop still wash used on iOS 17 and under Reduce Motion.
  ///
  /// Built only from Kumo surface / warning-tint / brand-orange stops so the
  /// mesh stays inside the token system. Two keyframe palettes per scheme —
  /// airy and deep — crossfade per vertex so the backdrop breathes.
  enum LoginBackdrop {
    // `color-kumo-base` / `color-kumo-canvas` / `color-kumo-elevated` /
    // `color-kumo-warning-tint` (composited) / soft `text-kumo-brand` washes.
    private static let meshLightAiry: [UInt32] = [
      0xFFFFFF, 0xFFFAEA, 0xFBFBFB,
      0xF8F8F8, 0xFFFFFF, 0xFFFAEA,
      0xFBFBFB, 0xFFFAEA, 0xFFFFFF,
    ]
    // Deep extreme uses `color-kumo-banner-warning` / warning-tint so
    // `text-kumo-subtle` stays near ≥4.5:1.
    private static let meshLightDeep: [UInt32] = [
      0xFFFAEA, 0xFEF9C2, 0xFFFAEA,
      0xFEF9C2, 0xFFFAEA, 0xFEF9C2,
      0xFFFAEA, 0xFEF9C2, 0xFFFAEA,
    ]
    private static let meshDarkAiry: [UInt32] = [
      0x030303, 0x2A1C0A, 0x0F0F0F,
      0x18181B, 0x0B0B0B, 0x2A1C0A,
      0x0F0F0F, 0x18181B, 0x030303,
    ]
    // Deep extreme stays on `color-kumo-warning-tint` / base so
    // `text-kumo-subtle` keeps ≥4.5:1 on the hottest stop.
    private static let meshDarkDeep: [UInt32] = [
      0x0F0F0F, 0x2A1C0A, 0x18181B,
      0x2A1C0A, 0x0B0B0B, 0x2A1C0A,
      0x18181B, 0x2A1C0A, 0x0F0F0F,
    ]
    static let stillLight: [Color] = [
      Color(hex: 0xFFFAEA), Color(hex: 0xFFFFFF), Color(hex: 0xFBFBFB),
    ]
    static let stillDark: [Color] = [
      Color(hex: 0x2A1C0A), Color(hex: 0x030303), Color(hex: 0x18181B),
    ]

    /// Vertex colors for the sign-in mesh. `blend` maps a vertex index to a
    /// 0…1 mix between the airy and deep keyframes for that vertex.
    static func meshColors(dark: Bool, blend: (Int) -> Double) -> [Color] {
      let airy = dark ? meshDarkAiry : meshLightAiry
      let deep = dark ? meshDarkDeep : meshLightDeep
      return airy.indices.map { mixed(airy[$0], deep[$0], unit: blend($0)) }
    }

    private static func mixed(_ from: UInt32, _ to: UInt32, unit: Double) -> Color {
      let unit = min(max(unit, 0), 1)
      func channel(_ shift: UInt32) -> Double {
        let start = Double((from >> shift) & 0xFF)
        let end = Double((to >> shift) & 0xFF)
        return (start + (end - start) * unit) / 255
      }
      return Color(red: channel(16), green: channel(8), blue: channel(0))
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

  static func hex(from color: Color) -> UInt32 {
    let ui = UIColor(color)
    var r: CGFloat = 0
    var g: CGFloat = 0
    var b: CGFloat = 0
    var a: CGFloat = 0
    guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else {
      // Fallback for grayscale / non-RGB spaces.
      var white: CGFloat = 0
      ui.getWhite(&white, alpha: &a)
      let v = UInt32((white * 255).rounded())
      return (v << 16) | (v << 8) | v
    }
    let red = UInt32((r * 255).rounded())
    let green = UInt32((g * 255).rounded())
    let blue = UInt32((b * 255).rounded())
    return (red << 16) | (green << 8) | blue
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
    case .sectionTitle: (18, .semibold, .default, .headline)
    case .body: (16, .regular, .default, .body)
    case .bodyMedium: (16, .medium, .default, .body)
    case .bodySemibold: (16, .semibold, .default, .body)
    case .bodyBold: (16, .bold, .default, .body)
    case .button: (17, .semibold, .default, .body)
    case .buttonMedium: (17, .medium, .default, .body)
    case .buttonBold: (17, .bold, .default, .body)
    case .supporting: (15, .regular, .default, .subheadline)
    case .supportingMedium: (14, .medium, .default, .subheadline)
    case .supportingSemibold: (15, .semibold, .default, .subheadline)
    case .footnote: (13, .regular, .default, .footnote)
    case .footnoteSemibold: (13, .semibold, .default, .footnote)
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

  var muted: Color {
    switch self {
    case .soft: DashTheme.iconMuted
    case .brand: DashTheme.brand.opacity(0.85)
    case .success: DashTheme.success.opacity(0.85)
    case .warning: DashTheme.warning.opacity(0.9)
    case .accent: DashTheme.accent.opacity(0.9)
    case .danger: DashTheme.danger.opacity(0.85)
    case .info: DashTheme.info.opacity(0.85)
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
    default: .soft
    }
  }

  /// One distinct tone per catalog feature so Resources rows stay scannable.
  static func tone(for feature: FeatureID) -> FeatureVisualTone {
    switch feature {
    case .zones: .success
    case .workers: .brand
    case .pages: .info
    case .r2: .accent
    case .kv: .warning
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
    // Mirrors `DashTextStyle.footnote` (13pt regular, scaling with .footnote).
    label.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .systemFont(ofSize: 13))
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
