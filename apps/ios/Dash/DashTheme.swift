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
    static let listInset: CGFloat = 0
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

  /// Strong ease-out motion tokens — built-in easings feel soft, and frequent
  /// state flips stay the shortest.
  enum Motion {
    static let quick = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.12)
    static let press = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.15)
    static let reduced = Animation.easeOut(duration: 0.12)
    /// Skeleton → loaded content: long enough for blur to read.
    @MainActor static var content: Animation {
      UIAccessibility.isReduceMotionEnabled
        ? reduced : Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.3)
    }
    /// Deliberate hero morph for matchedGeometryEffect tray transitions — springy
    /// and slower than the micro-interaction tokens so the shape change reads.
    @MainActor static var morph: Animation {
      UIAccessibility.isReduceMotionEnabled
        ? reduced : Animation.spring(response: 0.28, dampingFraction: 0.82)
    }
    /// A small threshold-crossing pop for pull affordances — enough overshoot to
    /// snap without wobbling.
    @MainActor static var pop: Animation {
      UIAccessibility.isReduceMotionEnabled
        ? reduced : Animation.spring(response: 0.3, dampingFraction: 0.6)
    }
    /// Modal sheet present/dismiss — the card slide and dim fade. A firmly
    /// damped spring: settles fast with a physical arrival, no visible bounce.
    /// Floating-tray springs live in `DashTrayMotion` (DashChrome.swift).
    @MainActor static var sheet: Animation {
      UIAccessibility.isReduceMotionEnabled
        ? reduced : Animation.spring(response: 0.32, dampingFraction: 0.9)
    }
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
  /// Home Domains card — `color-kumo-tint`.
  static let homeDomainsSurface = adaptive(light: 0xF5F5F5, dark: 0x262626)
  /// Header band across a bordered list group — `color-kumo-tint` / elevated
  /// dark step so the band stays visible above the card fill.
  static let listGroupHeaderSurface = adaptive(light: 0xF5F5F5, dark: 0x333333)
  /// Home's cards (Shortcuts / Recently used / quick actions) — `color-kumo-base`
  /// in light; `color-kumo-tint` in dark so the hairline ring still separates.
  static let homeCardSurface = adaptive(light: 0xFFFFFF, dark: 0x262626)
  /// Quiet glyph on a quick-action tile — `text-kumo-inactive`.
  static let homeCardGlyph = adaptive(light: 0xD4D4D4, dark: 0x525252)
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
  /// Soft brand-orange glow for Home's top light field and the About halo —
  /// same adaptive stop as `accent`; call sites apply opacity so it washes into `canvas`.
  static let homeWash = accent
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
  /// Gives a single item its own card. Catalog lists deliberately do NOT use
  /// this — they stay bare rows on the canvas, with colour living on the icon
  /// tile. Reserved for tiles and the rare vivid hero card.
  func dashListItemCard(fill: Color = DashTheme.recessed) -> some View {
    padding(.horizontal, DashTheme.Spacing.itemCardInset)
      .background(
        fill,
        in: RoundedRectangle(cornerRadius: DashTheme.Radius.button, style: .continuous))
  }

  func dashTextStyle(_ style: DashTextStyle) -> some View {
    modifier(DashTypographyModifier(style: style))
  }

  func dashCompactHitTarget() -> some View {
    frame(
      minWidth: DashTheme.Layout.minimumHitTarget,
      minHeight: DashTheme.Layout.minimumHitTarget
    )
    .contentShape(Rectangle())
  }

  /// Widens the tappable area without forcing a 44pt height — section-header
  /// actions must stay as tall as the title line (unlike `dashCompactHitTarget`,
  /// which stretches Home Shortcuts above Recently used).
  func dashHeaderActionHitTarget() -> some View {
    frame(minWidth: DashTheme.Layout.minimumHitTarget, alignment: .trailing)
      .contentShape(Rectangle())
  }

  /// Applies a shared shadow-as-border treatment. Prefer this over ad-hoc
  /// `.shadow` stacks or `DashTheme.line` strokes on elevated surfaces.
  func dashShadow(
    _ style: DashTheme.Shadow = .border,
    cornerRadius: CGFloat = DashTheme.Radius.card
  ) -> some View {
    modifier(
      DashShadowModifier(
        style: style,
        shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
      )
    )
  }

  func dashShadow<S: InsettableShape>(
    _ style: DashTheme.Shadow,
    in shape: S
  ) -> some View {
    modifier(DashShadowModifier(style: style, shape: shape))
  }
}

/// A flat 1pt ring that defines an elevated surface's edge — `color-kumo-shadow-edge`
/// (pure black/white at token opacity), never a tinted hairline. Drop shadows
/// were removed project-wide, so `.border` and `.raised` render identically.
private struct DashShadowModifier<S: InsettableShape>: ViewModifier {
  let style: DashTheme.Shadow
  let shape: S
  @Environment(\.colorScheme) private var colorScheme

  func body(content: Content) -> some View {
    content.overlay {
      shape.strokeBorder(
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.12),
        lineWidth: 1)
    }
  }
}

extension View {
  /// Tactile tile treatment — the sanctioned exception to the flat system,
  /// used by Home quick-action tiles and Domain color cards. Light-from-above
  /// modeling with neutral overlays only, so the surface's own color never
  /// shifts hue: a bevel ring (lit top edge, weighted bottom), a whisper of
  /// face sheen, and a soft two-layer drop shadow. Dark mode leans on the
  /// rim light instead — shadows can't read against the near-black canvas.
  ///
  /// Pass `.pigmented` for saturated fills (Domain cards): the face needs a
  /// soft top specular so the enamel reads on dark greens/indigos where a
  /// black-only bevel would disappear.
  ///
  /// Press sink (`dashSurfacePressed`) offsets the **visual** stack 1pt down
  /// while the layout/hit target stays fixed — translating the Button label
  /// under the finger cancels quick taps. Implemented as a `View` (not a
  /// `ViewModifier` that reuses `Content` twice) so press-driven invalidation
  /// actually rebuilds the sinking face. The sink only engages under a
  /// `DashSurfaceButtonStyle` host (Domain cards); Home quick-action tiles
  /// press with the whole-tile `DashPressButtonStyle` shrink instead.
  func dashEmbossed(
    _ style: DashEmbossStyle = .tile,
    cornerRadius: CGFloat = DashTheme.Radius.card
  ) -> some View {
    DashEmbossedContainer(
      style: style,
      shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    ) { self }
  }

  /// Capsule emboss for primary action pills — same enamel as Domain cards.
  func dashEmbossedPill(_ style: DashEmbossStyle = .pigmented) -> some View {
    DashEmbossedContainer(
      style: style,
      shape: Capsule(style: .continuous)
    ) { self }
  }

  /// Bevel / sheen / drop shadow only — no press-sink duplicate. Use when the
  /// view already owns its hit target (`DashPressButtonStyle`, hold gesture)
  /// or carries a `matchedGeometryEffect` that must stay single-instance.
  func dashEmbossChrome<S: InsettableShape>(
    _ style: DashEmbossStyle = .tile,
    shape: S
  ) -> some View {
    modifier(DashEmbossChromeModifier(style: style, shape: shape))
  }
}

enum DashEmbossStyle: Hashable, Sendable {
  /// Neutral Home tool tiles.
  case tile
  /// Saturated Domain color cards — stronger top light, softer bottom weight.
  case pigmented
}

/// Shared enamel stops for `dashEmbossed` / `dashEmbossChrome`.
private enum DashEmbossPalette {
  static func sinkDimOpacity(dark: Bool, pigmented: Bool) -> Double {
    if pigmented { return dark ? 0.12 : 0.06 }
    return dark ? 0.18 : 0.08
  }

  static func faceSheenColors(dark: Bool, pigmented: Bool) -> [Color] {
    if pigmented {
      return dark
        ? [Color.white.opacity(0.12), Color.white.opacity(0.02), Color.black.opacity(0.10)]
        : [Color.white.opacity(0.18), Color.white.opacity(0.04), Color.black.opacity(0.08)]
    }
    return dark
      ? [Color.white.opacity(0.06), Color.white.opacity(0)]
      : [Color.white.opacity(0), Color.black.opacity(0.03)]
  }

  static func bevelColors(dark: Bool, pigmented: Bool) -> [Color] {
    if pigmented {
      // White rim on top so dark fills still catch a lit edge; bottom stays
      // grounded with a deeper neutral stroke.
      return dark
        ? [Color.white.opacity(0.28), Color.white.opacity(0.06)]
        : [Color.white.opacity(0.28), Color.black.opacity(0.18)]
    }
    return dark
      ? [Color.white.opacity(0.22), Color.white.opacity(0.05)]
      : [Color.black.opacity(0.05), Color.black.opacity(0.16)]
  }
}

/// Emboss + press sink. Built as a `View` so the content closure is invoked
/// fresh for the hit plate and the visual face — reusing a `ViewModifier`'s
/// `Content` value twice left the sinking copy stale when
/// `dashSurfacePressed` flipped (tray still opened; press looked dead).
private struct DashEmbossedContainer<Content: View, S: InsettableShape>: View {
  let style: DashEmbossStyle
  let shape: S
  @ViewBuilder var content: () -> Content

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.dashSurfacePressed) private var pressed
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let dark = colorScheme == .dark
    let pigmented = style == .pigmented
    let sink = pressed && !reduceMotion ? CGFloat(1) : 0

    // Unmoved layout + hit target; only the visual copy sinks on press.
    ZStack {
      content()
        .opacity(0)

      embossedFace(dark: dark, pigmented: pigmented)
        .offset(y: sink)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
    .contentShape(shape)
    .animation(reduceMotion ? nil : DashTheme.Motion.press, value: pressed)
    .onChange(of: pressed) { _, isPressed in
      if isPressed { DashDelight.lightImpact() }
    }
  }

  @ViewBuilder
  private func embossedFace(dark: Bool, pigmented: Bool) -> some View {
    content()
      .overlay {
        // Face sheen: light grazes the top. Pigmented cards add a soft
        // enamel specular; neutral tiles keep the quieter bottom weight.
        shape
          .fill(
            LinearGradient(
              colors: DashEmbossPalette.faceSheenColors(dark: dark, pigmented: pigmented),
              startPoint: .top, endPoint: .bottom)
          )
          .allowsHitTesting(false)
      }
      .overlay {
        // Sink dim: less light reaches a pressed face. Tiles need a stronger
        // dim than pigmented cards — white Home chrome eats a 4% wash.
        shape
          .fill(
            Color.black.opacity(
              pressed ? DashEmbossPalette.sinkDimOpacity(dark: dark, pigmented: pigmented) : 0)
          )
          .allowsHitTesting(false)
      }
      .overlay {
        // Bevel ring: same neutral ink as `dashShadow`, redistributed so the
        // top edge reads lit and the bottom edge grounded.
        shape.strokeBorder(
          LinearGradient(
            colors: DashEmbossPalette.bevelColors(dark: dark, pigmented: pigmented),
            startPoint: .top, endPoint: .bottom),
          lineWidth: 1)
      }
      .shadow(color: .black.opacity(dark ? 0.4 : 0.05), radius: 1, y: 1)
      // Pressing sinks optically: 1pt downward shift (visual layer only),
      // tighter ambient shadow, and face dim — see `body` for hit testing.
      .shadow(
        color: .black.opacity(dark ? 0.3 : (pigmented ? 0.10 : 0.07)),
        radius: pressed ? 3 : (pigmented ? 10 : 8),
        y: pressed ? 1 : (pigmented ? 5 : 4)
      )
  }
}

/// Static enamel chrome (sheen + bevel + shadows) without duplicating content.
private struct DashEmbossChromeModifier<S: InsettableShape>: ViewModifier {
  let style: DashEmbossStyle
  let shape: S
  @Environment(\.colorScheme) private var colorScheme

  func body(content: Content) -> some View {
    let dark = colorScheme == .dark
    let pigmented = style == .pigmented
    content
      .overlay {
        shape
          .fill(
            LinearGradient(
              colors: DashEmbossPalette.faceSheenColors(dark: dark, pigmented: pigmented),
              startPoint: .top, endPoint: .bottom)
          )
          .allowsHitTesting(false)
      }
      .overlay {
        shape.strokeBorder(
          LinearGradient(
            colors: DashEmbossPalette.bevelColors(dark: dark, pigmented: pigmented),
            startPoint: .top, endPoint: .bottom),
          lineWidth: 1)
      }
      .shadow(color: .black.opacity(dark ? 0.4 : 0.05), radius: 1, y: 1)
      .shadow(
        color: .black.opacity(dark ? 0.3 : (pigmented ? 0.10 : 0.07)),
        radius: pigmented ? 10 : 8,
        y: pigmented ? 5 : 4
      )
  }
}

struct DashCard<Content: View>: View {
  private let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) { content }
      .padding(DashTheme.Spacing.card)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        DashTheme.recessed,
        in: RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous)
      )
      .dashShadow(.border)
  }
}

/// Stats / analytics surface — same embossed `homeCardSurface` enamel as Home
/// quick-action tiles (not Liquid Glass).
///
/// Use for metric tiles and chart cards only. Keep ordinary content cards on
/// `DashCard` so the rest of the app stays an opaque recessed system.
struct DashGlassCard<Content: View>: View {
  private let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) { content }
      .padding(DashTheme.Spacing.card)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(DashTheme.homeCardSurface, in: shape)
      .dashEmbossChrome(shape: shape)
  }
}

/// A small, bounded stack of independent cards, controls, or notices.
///
/// `DashFeatureList` keeps its outer lazy stack at zero spacing so large
/// `ForEach` row collections stay virtualized. Use this wrapper for page chrome
/// that should read as separate surfaces instead of adding one-off padding to
/// every child. Never wrap an unbounded resource list here.
struct DashSurfaceStack<Content: View>: View {
  private let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DashTheme.Spacing.itemGap) {
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A colored surface with the app's static Metal grain. Keeping the shader on
/// the background prevents it from changing text and icon rendering.
struct DashGrainSurface: View {
  enum ShapeStyle: Hashable, Sendable {
    case rounded(CGFloat)
    case capsule
  }

  let color: Color
  var shape: ShapeStyle
  var intensity: Float = 0.04

  init(color: Color, cornerRadius: CGFloat, intensity: Float = 0.04) {
    self.color = color
    self.shape = .rounded(cornerRadius)
    self.intensity = intensity
  }

  init(color: Color, shape: ShapeStyle, intensity: Float = 0.04) {
    self.color = color
    self.shape = shape
    self.intensity = intensity
  }

  var body: some View {
    switch shape {
    case .rounded(let cornerRadius):
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .fill(color)
        .colorEffect(ShaderLibrary.surfaceGrain(.float(intensity)))
    case .capsule:
      Capsule(style: .continuous)
        .fill(color)
        .colorEffect(ShaderLibrary.surfaceGrain(.float(intensity)))
    }
  }
}

/// Home quick action card: a card-surface rounded rect with a faint fill icon
/// and a quiet caption below — no badge circle around the glyph.
struct DashToolTile: View {
  let title: String
  let icon: String

  var body: some View {
    VStack(spacing: DashTheme.Spacing.compact) {
      SolarIcon(asset: icon, size: 24, color: DashTheme.homeCardGlyph)
      Text(title)
        .dashTextStyle(.supportingMedium)
        .foregroundStyle(DashTheme.text)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
    .padding(DashTheme.Spacing.card)
    .frame(maxWidth: .infinity, minHeight: 96)
    .background(
      DashTheme.homeCardSurface,
      in: RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous)
    )
    .dashEmbossed()
  }
}

/// Tool-tile grid that reflows with available width — typically two-up on
/// iPhone, kept usable down to 320pt Display Zoom windows.
struct DashTileGrid<Content: View>: View {
  @ViewBuilder let content: () -> Content

  var body: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 136), spacing: 12)], spacing: 12) {
      content()
    }
  }
}

/// Opens a destination on the enclosing tab's navigation stack.
struct DashListGroupLink<Label: View>: View {
  let value: Destination
  var onNavigate: (() -> Void)?
  @ViewBuilder let label: () -> Label

  var body: some View {
    DestinationLink(destination: value, onNavigate: onNavigate, label: label)
  }
}

/// Routes `Destination` values through the tab navigation stack.
struct DashDestinationLink<Label: View>: View {
  let destination: Destination
  @ViewBuilder let label: () -> Label

  var body: some View {
    DestinationLink(destination: destination, label: label)
      .listRowSeparator(.hidden)
      .listSectionSeparator(.hidden)
  }
}

struct DashListGroupDivider: View {
  var body: some View {
    Divider().overlay(DashTheme.panelLine)
  }
}

/// Horizontal inset for a single feature-list row. Applied per row (or to a
/// single `ForEach`) so an outer `LazyVStack` can still virtualize.
/// `nonisolated` like SwiftUI's own modifiers so nonisolated `@ViewBuilder`
/// helpers (`dashListCardRows`) can apply it inside their `ForEach` closure.
extension View {
  nonisolated func dashListCardInset() -> some View {
    padding(.horizontal, DashTheme.Spacing.rowInset)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// Separates a new titled section from the card, control, or list above it.
  /// `DashFeatureList` keeps its outer lazy stack at zero spacing so bare
  /// `ForEach` rows remain virtualized; section boundaries opt into rhythm
  /// explicitly instead of accidentally gapping every row.
  nonisolated func dashSectionBoundary(_ isEnabled: Bool = true) -> some View {
    padding(.top, isEnabled ? DashTheme.Spacing.section : 0)
  }

  /// Separates adjacent independent surfaces inside a section. Use the larger
  /// `dashSectionBoundary` when the following view starts a titled section.
  nonisolated func dashItemBoundary(_ isEnabled: Bool = true) -> some View {
    padding(.top, isEnabled ? DashTheme.Spacing.itemGap : 0)
  }
}

/// Home/Resources-style list group without a section title. Bare rows on the
/// canvas — no fill, no separators; the row's own padding carries the rhythm.
///
/// A `@ViewBuilder` passthrough — not a `View` wrapping `VStack` — so `ForEach`
/// children stay `LazyVStack`-virtualizable. The old eager stack mounted every
/// DNS/KV/R2 row at once and stampeded row work (including R2 thumbnails).
/// Row inset lives on each row (`dashListCardRows` / `dashListCardInset`), never
/// on this wrapper: padding a `TupleView` would re-eagerize the list.
@ViewBuilder
func dashListCard<Content: View>(
  @ViewBuilder content: () -> Content
) -> some View {
  content()
}

/// Emits a `ForEach` of rows directly (a function, not an opaque `View`
/// wrapper) so feature lists inside `DashFeatureList`'s `LazyVStack` only build
/// onscreen rows. Defaults to the card row inset; pass `inset: false` when the
/// parent (`DashListGroup`) already supplies it.
@ViewBuilder
func dashListCardRows<Item: Identifiable, Row: View>(
  items: [Item],
  inset: Bool = true,
  @ViewBuilder row: @escaping (Item) -> Row
) -> some View {
  ForEach(Array(items.enumerated()), id: \.element.id) { _, item in
    if inset {
      row(item)
        .dashListCardInset()
    } else {
      row(item)
    }
  }
}

/// Feature drill-down shell: fixed chrome above scrollable content.
struct DashFeatureScreen<Chrome: View, Content: View>: View {
  @ViewBuilder var chrome: () -> Chrome
  @ViewBuilder var content: () -> Content

  init(
    @ViewBuilder chrome: @escaping () -> Chrome,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.chrome = chrome
    self.content = content
  }

  var body: some View {
    VStack(spacing: 0) {
      chrome()
        .padding(.horizontal, DashTheme.Spacing.screen)
      // Bound the scroll slot to the remaining height. Without this, ScrollView
      // reports its full content height inside the VStack, the stack grows past
      // the screen, and the list clips instead of scrolling.
      content()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(DashTheme.canvas)
  }
}

extension DashFeatureScreen where Chrome == EmptyView {
  init(@ViewBuilder content: @escaping () -> Content) {
    self.init(chrome: { EmptyView() }, content: content)
  }
}

/// What a feature list should render for a given load/error/content state.
///
/// Loading contract (lists):
/// - **Cold** (`loading`): no cached primary payload → `DashListSkeleton` only.
///   Never paint an empty shell with “Updating…”.
/// - **Warm** (`content` + `refreshing`): rows/shell already visible → keep
///   content and show the inline “Updating…” strip (and optional error banner).
/// - **Empty settled** (`content`, not refreshing, zero items): `DashEmptyState`
///   inside `content`, not a separate phase.
/// - **Section cold** (not this enum): secondary fetches inside an already-loaded
///   detail (build log, traffic chart, preview) may use a local ring + short copy.
///
/// Cache-first: when `hasContent` is true, refresh never returns to Cold.
enum DashListPhase: Equatable {
  case loading
  case fullScreenError(String)
  case content(banner: String?, refreshing: Bool)

  static func resolve(isLoading: Bool, error: String?, hasContent: Bool) -> DashListPhase {
    if hasContent {
      return .content(banner: error, refreshing: isLoading)
    }
    if isLoading { return .loading }
    if let error { return .fullScreenError(error) }
    return .content(banner: nil, refreshing: false)
  }
}

/// Shared feature list: loading/error slots, grouped list chrome.
struct DashFeatureList<Header: View, Content: View>: View {
  var isLoading: Bool = false
  var error: String?
  var hasContent: Bool = false
  var retry: () -> Void
  @ViewBuilder var header: () -> Header
  @ViewBuilder var content: () -> Content
  @Environment(AppModel.self) private var model
  @Environment(\.featureRequiredScopes) private var featureRequiredScopes

  init(
    isLoading: Bool = false,
    error: String? = nil,
    hasContent: Bool = false,
    retry: @escaping () -> Void = {},
    @ViewBuilder header: @escaping () -> Header,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.isLoading = isLoading
    self.error = error
    self.hasContent = hasContent
    self.retry = retry
    self.header = header
    self.content = content
  }

  var body: some View {
    DashFeatureScreen(chrome: header) {
      ScrollView {
        // Spacing must stay 0: `dashListCardRows` flattens its ForEach into this
        // stack so rows stay lazy. Section spacing here would gap every row
        // (Workers/Pages looked sparse vs Resources' DashListGroup VStack(0)).
        // Pad chrome blocks (Updating… / error banner) explicitly instead.
        LazyVStack(spacing: 0) {
          switch DashListPhase.resolve(isLoading: isLoading, error: error, hasContent: hasContent) {
          case .loading:
            DashListSkeleton()
          case .fullScreenError(let message):
            ErrorStateView(message: message, retry: retry)
          case .content(let banner, let refreshing):
            if refreshing {
              HStack(spacing: DashTheme.Spacing.compact) {
                DashLoadingRing(color: DashTheme.brand, size: 16, lineWidth: 2.5)
                Text("Updating…")
                  .dashTextStyle(.footnote)
                  .foregroundStyle(DashTheme.subtle)
                Spacer(minLength: 0)
              }
              .accessibilityElement(children: .combine)
              .accessibilityLabel("Updating")
              .padding(.bottom, DashTheme.Spacing.itemGap)
            }
            if let banner {
              failureBanner(banner)
                .padding(.bottom, DashTheme.Spacing.itemGap)
            }
            // No entrance reveal here: pushed feature screens arrive via the
            // navigation transition; content should simply be there.
            content()
          }
        }
        .padding(.horizontal, DashTheme.Spacing.screen)
        // This gap belongs to the scroll content. Putting it on
        // DashFeatureScreen turns it into fixed header chrome.
        .padding(.top, DashTheme.Spacing.section)
        .padding(.bottom, DashTheme.Spacing.scrollBottomInset)
      }
      .scrollDismissesKeyboard(.interactively)
      .modifier(DashScrollEdgeEffectsHidden())
    }
  }

  @ViewBuilder
  private func failureBanner(_ message: String) -> some View {
    let presentation = DashFailurePresentation.from(message: message)
    VStack(alignment: .leading, spacing: DashTheme.Spacing.compact) {
      DashNotice(kind: .error, message: presentation.message)
      DashSecondaryPillButton(title: presentation.action.title) {
        switch presentation.action {
        case .signInAgain:
          Task { await model.signOut() }
        case .grantAccess:
          model.requestAccess(
            to: featureRequiredScopes.isEmpty
              ? DashAuthorizationScopes.core : featureRequiredScopes)
        case .tryAgain:
          retry()
        }
      }
    }
  }
}

extension DashFeatureList where Header == EmptyView {
  init(
    isLoading: Bool = false,
    error: String? = nil,
    hasContent: Bool = false,
    retry: @escaping () -> Void = {},
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.init(
      isLoading: isLoading,
      error: error,
      hasContent: hasContent,
      retry: retry,
      header: { EmptyView() },
      content: content
    )
  }
}

struct DashListGroup<Content: View>: View {
  let title: String
  var actionTitle: String?
  var actionIcon: String?
  var action: (() -> Void)?
  private let content: Content

  init(
    title: String, actionTitle: String? = nil, actionIcon: String? = nil,
    action: (() -> Void)? = nil,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.actionTitle = actionTitle
    self.actionIcon = actionIcon
    self.action = action
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      DashListGroupHeader(
        title: DashL10n.ui(title),
        actionTitle: DashL10n.ui(actionTitle),
        actionIcon: actionIcon,
        action: action
      )
      .padding(.horizontal, 4)

      // Bare rows on the canvas — no fill, no separators. Rows inset to match
      // the title above them, so the group reads as one column.
      VStack(alignment: .leading, spacing: 0) { content }
        .padding(.horizontal, DashTheme.Spacing.rowInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

/// The title row of a `DashListGroup`. Shared so cards that paint their own
/// header band (Home Shortcuts) keep the exact title and action styling.
struct DashListGroupHeader: View {
  let title: String
  var actionTitle: String?
  var actionIcon: String?
  var action: (() -> Void)?

  var body: some View {
    HStack(spacing: 12) {
      Text(title)
        .dashTextStyle(.supportingMedium)
        .foregroundStyle(DashTheme.listGroupTitle)
      Spacer(minLength: 0)
      if let action {
        Group {
          if let actionIcon {
            Button(action: action) {
              SolarIcon(asset: actionIcon, size: 16, color: DashTheme.brand)
            }
            .buttonStyle(DashPressButtonStyle())
            .accessibilityLabel(actionTitle ?? DashL10n.ui("Edit"))
            // Expand the tap target without `dashCompactHitTarget()`'s
            // minHeight: 44 — that stretched this header past title-only
            // groups (e.g. Home Shortcuts vs Recently used).
            .dashHeaderActionHitTarget()
          } else if let actionTitle {
            Button(actionTitle, action: action)
              .dashTextStyle(.supportingMedium)
              .foregroundStyle(DashTheme.brand)
              .buttonStyle(DashPressButtonStyle())
              .dashHeaderActionHitTarget()
          }
        }
      }
    }
  }
}

/// Two-tone bordered group (the short-lived `WatchtowerListGroup` framing):
/// the title rides an elevated plate, and the rows sit in their own rounded,
/// ring-edged card seated flush inside it — the inner card's top ring is the
/// hairline under the header, so its rounded corners peek out of the band.
/// The inner card overhangs the plate's clip by 1pt on the sides and bottom,
/// trimming its ring there so the plate's own ring edges the group. Reserved
/// for Home's Shortcuts and Recently used cards; plain `DashListGroup` stays
/// bandless.
struct DashBorderedListGroup<Content: View>: View {
  let title: String
  var actionTitle: String?
  var actionIcon: String?
  var action: (() -> Void)?
  private let content: Content

  init(
    title: String, actionTitle: String? = nil, actionIcon: String? = nil,
    action: (() -> Void)? = nil,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.actionTitle = actionTitle
    self.actionIcon = actionIcon
    self.action = action
    self.content = content()
  }

  var body: some View {
    VStack(spacing: 0) {
      DashListGroupHeader(
        title: DashL10n.ui(title),
        actionTitle: DashL10n.ui(actionTitle),
        actionIcon: actionIcon,
        action: action
      )
      .padding(.horizontal, 16)
      .padding(.vertical, 12)

      VStack(alignment: .leading, spacing: 0) { content }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DashTheme.homeCardSurface)
        .clipShape(RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous))
        .dashShadow(.border)
        .padding(.horizontal, -1)
        .padding(.bottom, -1)
    }
    .background(DashTheme.listGroupHeaderSurface)
    .clipShape(RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous))
    .dashShadow(.border)
  }
}

struct CatalogFeatureIcon: View {
  enum Style {
    case fill
    case outline
  }

  enum Size {
    case list
    case shortcut
    case compact
    case hero
  }

  let feature: FeatureID
  var style: Style = .fill
  var size: Size = .list
  /// When true, uses vivid tone (pinned/hero). Catalog lists stay muted.
  var emphasized: Bool = false
  /// Sitting on a card already filled with the feature's tone: the glyph flips
  /// to the on-card color and drops its background.
  var onColor: Bool = false
  @ScaledMetric(relativeTo: .body) private var listGlyphScale: CGFloat = 1
  @ScaledMetric(relativeTo: .body) private var listTileScale: CGFloat = 1

  private var tone: Color {
    let identity = FeatureVisualIdentity.tone(for: feature)
    if onColor {
      return FeatureVisualIdentity.onCardColor(for: feature)
    }
    if emphasized || size == .hero {
      return identity.vivid
    }
    return identity.muted
  }

  private var assetName: String {
    switch style {
    case .fill: feature.solarFillAssetName
    case .outline: feature.solarOutlineAssetName
    }
  }

  private var scaleClamp: CGFloat {
    min(max(listGlyphScale, 1), 1.3)
  }

  private var glyphSize: CGFloat {
    let base: CGFloat =
      switch size {
      case .list: 24
      case .shortcut: 20
      // Matches bare `SolarIcon` glyphs in `DetailIconView`.
      case .compact: 20
      case .hero: 36
      }
    return size == .list || size == .shortcut ? base * scaleClamp : base
  }

  private var tileSize: CGFloat {
    let base: CGFloat =
      switch size {
      // Shared catalog tile: tighter circle, glyph size unchanged (24 for
      // `.list`, 20 for `.shortcut`). Applies everywhere this size is used —
      // Home Shortcuts, Resources, feature rows, workspace heroes.
      case .list: 36
      case .shortcut: 32
      // Detail-header glyphs stay bare — no plate behind them.
      case .compact: 20
      case .hero: 56
      }
    return size == .list || size == .shortcut
      ? base * min(max(listTileScale, 1), 1.3) : base
  }

  /// List/shortcut/hero tiles keep the soft tone circle; detail headers
  /// (`.compact`) and on-card glyphs stay bare.
  private var showsPlate: Bool {
    !onColor && size != .compact
  }

  var body: some View {
    Image(assetName)
      .resizable()
      .renderingMode(.template)
      .scaledToFit()
      .foregroundStyle(tone)
      .frame(width: glyphSize, height: glyphSize)
      .frame(
        width: tileSize, height: tileSize,
        alignment: showsPlate ? .center : .leading
      )
      .background(
        showsPlate
          ? tone.opacity(emphasized || size == .hero ? 0.16 : 0.1)
          : Color.clear,
        in: Circle()
      )
      .accessibilityHidden(true)
  }
}

struct StatusBadge: View {
  let text: String

  enum Presentation: Equatable {
    /// Quiet trailing label or check — never a colored capsule.
    case quiet
    /// Capsule reserved for warnings, critical states, and access limits.
    case capsule
  }

  static func presentation(for text: String) -> Presentation {
    let value = text.lowercased()
    if ["active", "ok", "healthy", "success"].contains(value) {
      return .quiet
    }
    return .capsule
  }

  private var colors: (foreground: Color, background: Color) {
    let value = text.lowercased()
    if ["active", "ok", "healthy", "success"].contains(value) {
      return (DashTheme.success, DashTheme.successTint)
    }
    if ["warning", "pending", "degraded", "read-only", "locked"].contains(value) {
      return (DashTheme.warning, DashTheme.warningTint)
    }
    if ["error", "failed", "critical", "inactive"].contains(value) {
      return (DashTheme.danger, DashTheme.dangerTint)
    }
    return (DashTheme.brand, DashTheme.infoTint)
  }

  var body: some View {
    Group {
      switch Self.presentation(for: text) {
      case .quiet:
        HStack(spacing: 4) {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(colors.foreground)
          Text(displayedText)
            .dashTextStyle(.captionSemibold)
            .foregroundStyle(colors.foreground)
            .lineLimit(1)
        }
      case .capsule:
        Text(displayedText)
          .dashTextStyle(.captionSemibold)
          .foregroundStyle(colors.foreground)
          .lineLimit(1)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(colors.background, in: Capsule())
      }
    }
    .fixedSize(horizontal: true, vertical: false)
    .layoutPriority(1)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(StatusBadge.accessibilityText(for: text))
  }

  /// Color logic stays on the English source token; only the label is localized.
  private var displayedText: String { DashL10n.ui(text.capitalized) }

  static func accessibilityText(for text: String) -> String {
    DashL10n.string("Status, \(DashL10n.ui(text))")
  }
}

/// Sparse delight for rare, high-value moments — not for list filters or typing.
/// All generators no-op when Settings → Haptic feedback is off.
@MainActor
enum DashDelight {
  /// A meaningful action completed (zone created, upload finished).
  static func celebrateSuccess() {
    guard DashInteractionPreferences.hapticsEnabled else { return }
    UINotificationFeedbackGenerator().notificationOccurred(.success)
  }

  /// Recovered from a transient failure (Watchtower refresh after an error).
  static func recoverFromIssue() {
    guard DashInteractionPreferences.hapticsEnabled else { return }
    UINotificationFeedbackGenerator().notificationOccurred(.success)
  }

  /// Destructive or irreversible action is about to happen.
  static func warnImpact() {
    guard DashInteractionPreferences.hapticsEnabled else { return }
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
  }

  /// Operation failed or was rejected.
  static func failError() {
    guard DashInteractionPreferences.hapticsEnabled else { return }
    UINotificationFeedbackGenerator().notificationOccurred(.error)
  }

  /// Lightweight tap on a secondary control (copy, chip toggle).
  static func lightImpact() {
    guard DashInteractionPreferences.hapticsEnabled else { return }
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
  }

  /// Picker, tab, or segment selection changed.
  static func selectionChanged() {
    guard DashInteractionPreferences.hapticsEnabled else { return }
    UISelectionFeedbackGenerator().selectionChanged()
  }

  /// Soft generator for a hold-to-confirm ramp. Call `prepare` then
  /// `holdRampImpact` with rising intensity; finish with `warnImpact`.
  static func makeHoldRampGenerator() -> UIImpactFeedbackGenerator? {
    guard DashInteractionPreferences.hapticsEnabled else { return nil }
    let generator = UIImpactFeedbackGenerator(style: .soft)
    generator.prepare()
    return generator
  }

  /// One tick in a hold ramp. `intensity` is clamped to 0…1.
  static func holdRampImpact(
    _ generator: UIImpactFeedbackGenerator?,
    intensity: CGFloat
  ) {
    guard DashInteractionPreferences.hapticsEnabled, let generator else { return }
    let clamped = min(max(intensity, 0), 1)
    generator.impactOccurred(intensity: clamped)
    generator.prepare()
  }
}

/// Placeholder rows that match `DashListRow` / recessed card geometry so first
/// paint keeps catalog structure instead of a blank 420pt spinner. Cold list
/// loads go through `DashFeatureList` → `DashListPhase.loading` → this view.
struct DashListSkeleton: View {
  var rows: Int = 4

  var body: some View {
    DashListGroup(title: " ") {
      ForEach(0..<rows, id: \.self) { index in
        HStack(spacing: 12) {
          Circle()
            .fill(DashTheme.fill.opacity(0.55))
            .frame(width: 44, height: 44)
          VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
              .fill(DashTheme.fill.opacity(0.55))
              .frame(height: 14)
              .frame(maxWidth: 160)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
              .fill(DashTheme.fill.opacity(0.4))
              .frame(height: 11)
              .frame(maxWidth: 220)
          }
          Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .frame(minHeight: DashTheme.Layout.minimumHitTarget)
        .accessibilityHidden(true)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Loading")
  }
}

struct ErrorStateView: View {
  let message: String
  let retry: () -> Void
  @Environment(AppModel.self) private var model
  @Environment(\.featureRequiredScopes) private var featureRequiredScopes

  private var presentation: DashFailurePresentation {
    DashFailurePresentation.from(message: message)
  }

  var body: some View {
    DashEmptyState(
      icon: SolarAsset.Content.danger,
      title: "Couldn’t load",
      message: presentation.message,
      actionTitle: presentation.action.title,
      action: {
        switch presentation.action {
        case .signInAgain:
          Task { await model.signOut() }
        case .grantAccess:
          model.requestAccess(
            to: featureRequiredScopes.isEmpty
              ? DashAuthorizationScopes.core : featureRequiredScopes)
        case .tryAgain:
          retry()
        }
      })
  }
}

/// Press feedback for genuine *button* controls: pills, circular icon buttons,
/// toolbar/back/close actions, small text actions (Cancel, Back, Save, Show
/// more…), and tab labels. The 0.97 shrink is the app's single "this is a
/// button" cue; a light haptic fires on press-down so every button operation
/// feels tactile.
///
/// Do NOT apply this to rows, list items, cards, or tiles — those are tappable
/// *surfaces*, not buttons, and must not shrink. Use `DashSurfaceButtonStyle`
/// for them (and `DestinationLink`, which already does). See "Press feedback"
/// in AGENTS.md. Sanctioned exception: the Home Quick-actions tool tiles are
/// launcher buttons and take this style — the shrink is their press cue.
struct DashPressButtonStyle: ButtonStyle {
  /// How long the pressed pose stays on screen before springing back — long
  /// enough for `Motion.press` (0.15s ease-out) to reach the dip. Kept on the
  /// non-generic style because Swift disallows static stored properties on
  /// generic types (`DashPressFeedback`).
  fileprivate static let minimumDwell: Duration = .milliseconds(120)

  /// Total time for a quick tap's pulse to play out: `minimumDwell` plus the
  /// 0.15s `Motion.press` spring-back. Heavyweight main-thread work triggered
  /// by a tap (system sheet presentations like `ASWebAuthenticationSession.start()`)
  /// should wait this long so the stall doesn't eat the pulse's frames.
  static let pulseSettle: Duration = .milliseconds(270)

  func makeBody(configuration: Configuration) -> some View {
    DashPressFeedback(isPressed: configuration.isPressed) {
      configuration.label
    }
  }
}

/// Renders the 0.97 shrink with a minimum visible dwell. On a quick tap —
/// especially inside a ScrollView, which delivers press and release nearly
/// simultaneously — animating `isPressed` directly starts the shrink and
/// immediately retargets it back, so nothing reads on screen and the button
/// looks dead even though the action fires. Holding the pressed pose for a
/// short floor turns a quick tap into a full dip-and-spring pulse; real
/// holds still release the moment the finger lifts.
private struct DashPressFeedback<Label: View>: View {
  let isPressed: Bool
  @ViewBuilder var label: () -> Label

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var visuallyPressed = false
  @State private var pressedAt: ContinuousClock.Instant?
  @State private var release: Task<Void, Never>?

  var body: some View {
    label()
      .scaleEffect(visuallyPressed && !reduceMotion ? 0.97 : 1)
      .animation(reduceMotion ? nil : DashTheme.Motion.press, value: visuallyPressed)
      .onChange(of: isPressed) { _, pressed in
        if pressed {
          DashDelight.lightImpact()
          release?.cancel()
          release = nil
          pressedAt = .now
          visuallyPressed = true
        } else {
          let held: Duration = pressedAt.map { .now - $0 } ?? .zero
          pressedAt = nil
          let dwell = DashPressButtonStyle.minimumDwell
          if held >= dwell {
            visuallyPressed = false
          } else {
            release = Task {
              try? await Task.sleep(for: dwell - held)
              guard !Task.isCancelled else { return }
              visuallyPressed = false
            }
          }
        }
      }
  }
}

/// Press state a `DashSurfaceButtonStyle` button exposes to its label. The
/// surface hit target stays put by contract (no scale — shrink would read as a
/// button, not a surface). Embossed tiles (`dashEmbossed()`) read this for
/// optical sink: shadow, dim, and a 1pt visual-only offset on a non-interactive
/// copy so the stable label geometry still receives the tap.
private struct DashSurfacePressedKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  var dashSurfacePressed: Bool {
    get { self[DashSurfacePressedKey.self] }
    set { self[DashSurfacePressedKey.self] = newValue }
  }
}

/// Press style for tappable *surfaces* — full-width rows, list items, cards, and
/// tiles. These are not buttons: they carry no shrink and no press animation, so
/// the surface stays put while the tap routes (a push, a sheet, a toggle). Only
/// discrete button controls scale (`DashPressButtonStyle`). See "Press feedback"
/// in AGENTS.md. The style does publish `dashSurfacePressed` so opted-in
/// descendants (the embossed Home tiles) can render their own in-place feedback.
struct DashSurfaceButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    // Bridge through a real `View` ancestor — applying `.environment` directly
    // onto `configuration.label` can leave `@Environment` readers inside the
    // label stale for the whole press.
    DashSurfacePressedHost(isPressed: configuration.isPressed) {
      configuration.label
    }
  }
}

/// Publishes `dashSurfacePressed` for embossed tiles / domain cards.
private struct DashSurfacePressedHost<Content: View>: View {
  let isPressed: Bool
  @ViewBuilder var content: () -> Content

  var body: some View {
    content()
      .environment(\.dashSurfacePressed, isPressed)
  }
}

struct DashEmptyState: View {
  let icon: String
  let title: String
  let message: String
  var actionTitle: String?
  var action: (() -> Void)?

  var body: some View {
    VStack(spacing: DashTheme.Spacing.comfortable) {
      SolarIcon(asset: icon, size: 34, color: DashTheme.strong)
        .frame(width: 72, height: 72)
        .background(DashTheme.recessed, in: Circle())
      Text(DashL10n.ui(title))
        .dashTextStyle(.emptyTitle)
        .foregroundStyle(DashTheme.strong)
        .multilineTextAlignment(.center)
      Text(DashL10n.ui(message))
        .dashTextStyle(.supporting)
        .foregroundStyle(DashTheme.subtle)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      if let actionTitle, let action {
        DashSecondaryPillButton(title: DashL10n.ui(actionTitle), action: action)
          .padding(.top, 6)
      }
    }
    .frame(maxWidth: 440)
    .padding(DashTheme.Spacing.panel)
    .frame(maxWidth: .infinity, minHeight: DashTheme.Layout.emptyStateMinHeight)
    .listRowInsets(EdgeInsets())
    .listRowSeparator(.hidden)
    .listSectionSeparator(.hidden)
    .listRowBackground(Color.clear)
  }
}

extension View {
  func dashScreen() -> some View {
    scrollContentBackground(.hidden)
      .background(DashTheme.canvas)
      .foregroundStyle(DashTheme.text)
  }

  func dashGroupedList() -> some View {
    modifier(DashGroupedListModifier())
  }
}

struct DashListRow<Accessory: View>: View {
  let title: String
  var subtitle: String?
  var icon: String?
  /// Explicit override; when nil, uses the owning feature accent from the
  /// environment (catalog muted tone), then falls back to brand.
  var iconColor: Color?
  /// Deterministic domain dither avatar — takes precedence over `icon`.
  var avatarSeed: String?
  /// Replaces the icon circle with a rounded image thumbnail when set; the
  /// row falls back to `icon` while the image is nil (loading, non-image).
  var thumbnail: UIImage?
  var trailing: String?
  var showsChevron = true
  @ViewBuilder var accessory: () -> Accessory
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.featureIdentity) private var featureIdentity
  @ScaledMetric(relativeTo: .body) private var iconScale: CGFloat = 1

  init(
    title: String,
    subtitle: String? = nil,
    icon: String? = nil,
    iconColor: Color? = nil,
    avatarSeed: String? = nil,
    thumbnail: UIImage? = nil,
    trailing: String? = nil,
    showsChevron: Bool = true,
    @ViewBuilder accessory: @escaping () -> Accessory
  ) {
    self.title = title
    self.subtitle = subtitle
    self.icon = icon
    self.iconColor = iconColor
    self.avatarSeed = avatarSeed
    self.thumbnail = thumbnail
    self.trailing = trailing
    self.showsChevron = showsChevron
    self.accessory = accessory
  }

  private var isAccessibilitySize: Bool { dynamicTypeSize.isAccessibilitySize }
  /// Match `CatalogFeatureIcon` `.list` (Home Shortcuts / Resources): 24pt
  /// glyph in a 36pt tone circle — content rows used to lag at 22/40.
  private var iconPointSize: CGFloat { 24 * min(max(iconScale, 1), 1.3) }
  private var iconFrame: CGFloat { 36 * min(max(iconScale, 1), 1.3) }
  /// Optically matched, not frame-matched: a full-bleed saturated avatar at
  /// the icon circle's 36pt reads a size class heavier than a 24pt glyph on a
  /// 10% tint halo, so the disc renders at 30pt inside the same 36pt slot.
  private var avatarSize: CGFloat { 30 * min(max(iconScale, 1), 1.3) }
  private var resolvedIconColor: Color {
    if let iconColor { return iconColor }
    if let feature = featureIdentity {
      return FeatureVisualIdentity.catalogColor(for: feature)
    }
    return DashTheme.brand
  }

  var body: some View {
    Group {
      if isAccessibilitySize {
        VStack(alignment: .leading, spacing: 8) {
          labelStack
          HStack(spacing: 8) {
            accessory()
            if let trailing {
              Text(trailing)
                .dashTextStyle(.supporting)
                .foregroundStyle(DashTheme.subtle)
            }
            Spacer(minLength: 0)
            if showsChevron {
              SolarIcon(
                asset: SolarAsset.chevronRight, size: DashTheme.Chevron.row,
                color: DashTheme.placeholder)
            }
          }
        }
      } else {
        // labelStack's greedy frame fills the row and pushes the trailing
        // accessory/chevron to the edge; no Spacer needed.
        HStack(spacing: 12) {
          leadingIcon
          labelStack
          accessory()
          if let trailing {
            Text(trailing)
              .dashTextStyle(.supporting)
              .foregroundStyle(DashTheme.subtle)
          }
          if showsChevron {
            SolarIcon(
              asset: SolarAsset.chevronRight, size: DashTheme.Chevron.row,
              color: DashTheme.placeholder)
          }
        }
      }
    }
    .padding(.vertical, 12)
    .frame(minHeight: DashTheme.Layout.minimumHitTarget)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private var leadingIcon: some View {
    Group {
      if let thumbnail {
        Image(uiImage: thumbnail)
          .resizable()
          .scaledToFill()
          .frame(width: iconFrame, height: iconFrame)
          .clipShape(RoundedRectangle(cornerRadius: iconFrame * 0.3, style: .continuous))
      } else if let avatarSeed {
        GradientAvatar(seed: avatarSeed, size: avatarSize, pattern: .dither, contentScale: 1.8)
          // Keep the full icon slot so the label column stays aligned.
          .frame(width: iconFrame, height: iconFrame)
          .accessibilityHidden(true)
      } else if let icon {
        SolarIcon(asset: icon, size: iconPointSize, color: resolvedIconColor)
          .frame(width: iconFrame, height: iconFrame)
          .background(resolvedIconColor.opacity(0.1), in: Circle())
      }
    }
  }

  private var labelStack: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .dashTextStyle(.bodyMedium)
        .foregroundStyle(DashTheme.text)
        .lineLimit(isAccessibilitySize ? nil : 1)
      if let subtitle {
        Text(subtitle)
          .dashTextStyle(.footnote)
          .foregroundStyle(DashTheme.rowSubtitle)
          .lineLimit(isAccessibilitySize ? nil : 1)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

extension DashListRow where Accessory == EmptyView {
  init(
    title: String,
    subtitle: String? = nil,
    icon: String? = nil,
    iconColor: Color? = nil,
    avatarSeed: String? = nil,
    trailing: String? = nil,
    showsChevron: Bool = true
  ) {
    self.init(
      title: title,
      subtitle: subtitle,
      icon: icon,
      iconColor: iconColor,
      avatarSeed: avatarSeed,
      trailing: trailing,
      showsChevron: showsChevron,
      accessory: { EmptyView() })
  }
}

struct DashValueRow: View {
  let title: String
  let value: String
  var subtitle: String?
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  private var isAccessibilitySize: Bool { dynamicTypeSize.isAccessibilitySize }

  var body: some View {
    Group {
      if isAccessibilitySize {
        VStack(alignment: .leading, spacing: 6) {
          titleBlock
          Text(value)
            .dashTextStyle(.supportingMedium)
            .monospacedDigit()
            .foregroundStyle(DashTheme.subtle)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      } else {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
          titleBlock
          Spacer(minLength: 12)
          Text(value)
            .dashTextStyle(.supportingMedium)
            .monospacedDigit()
            .foregroundStyle(DashTheme.subtle)
            .multilineTextAlignment(.trailing)
            .lineLimit(2)
        }
      }
    }
    .padding(.vertical, DashTheme.Spacing.comfortable)
    .frame(minHeight: DashTheme.Layout.minimumHitTarget)
    .accessibilityElement(children: .combine)
  }

  private var titleBlock: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .dashTextStyle(.bodyMedium)
        .foregroundStyle(DashTheme.text)
      if let subtitle {
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(DashTheme.subtle)
      }
    }
  }
}

// MARK: - Control cards

/// The face of one setting control: its own recessed rounded card with a bold
/// title on the left and the control on the right. Captions render below the
/// card (see `dashControlCaption`), never inside it.
private struct DashControlSurface<Trailing: View>: View {
  let title: String
  @ViewBuilder let trailing: () -> Trailing

  var body: some View {
    HStack(spacing: 16) {
      Text(DashL10n.ui(title))
        .dashTextStyle(.bodySemibold)
        .foregroundStyle(DashTheme.strong)
        .multilineTextAlignment(.leading)
      Spacer(minLength: 12)
      trailing()
    }
    // DashSwitch stands 31pt; every card matches it so toggle, menu, and value
    // rows share one height.
    .frame(minHeight: 31)
    .padding(.horizontal, 16)
    .padding(.vertical, DashTheme.Spacing.comfortable)
    .frame(maxWidth: .infinity)
    .background(
      DashTheme.recessed,
      in: RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous))
  }
}

extension View {
  /// Lays the supporting text of a control card beneath it, aligned with the
  /// card's inner content.
  fileprivate func dashControlCaption(_ caption: String?) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      self
      if let caption {
        Text(DashL10n.ui(caption))
          .dashTextStyle(.supporting)
          .foregroundStyle(DashTheme.subtle)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 16)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// Custom on/off indicator — display-only; the enclosing control flips the
/// binding. Capsule track with a pure circular thumb (no `UISwitch` chrome).
struct DashSwitch: View {
  var isOn: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private enum Metrics {
    static let width: CGFloat = 51
    static let height: CGFloat = 31
    static let inset: CGFloat = 2
    static var thumb: CGFloat { height - inset * 2 }
  }

  var body: some View {
    ZStack {
      Capsule(style: .continuous)
        .fill(isOn ? DashTheme.brand : DashTheme.fill)
      HStack(spacing: 0) {
        if isOn { Spacer(minLength: 0) }
        Circle()
          .fill(Color.white)
          .frame(width: Metrics.thumb, height: Metrics.thumb)
        if !isOn { Spacer(minLength: 0) }
      }
      .padding(Metrics.inset)
    }
    .frame(width: Metrics.width, height: Metrics.height)
    .animation(
      reduceMotion ? DashTheme.Motion.reduced : DashTheme.Motion.quick,
      value: isOn
    )
    .accessibilityHidden(true)
  }
}

/// A switch in a control card. The whole card is the toggle target — a full
/// card is the friendlier hit target — so the switch is display-only and the
/// card button flips the binding.
///
/// Optimistic: callers flip `isOn` immediately. `isLoading` means in-flight —
/// keep the switch visible and disable interaction; never replace it with a
/// spinner. On failure, the caller reverts `isOn` and warns with
/// `model.toasts.error(...)` — never an inline banner under the switch.
struct DashToggleRow: View {
  let title: String
  var subtitle: String?
  @Binding var isOn: Bool
  var isEnabled = true
  /// Request in flight — disables the row; switch stays on the optimistic value.
  var isLoading = false

  var body: some View {
    Button {
      isOn.toggle()
    } label: {
      DashControlSurface(title: title) {
        DashSwitch(isOn: isOn)
          .opacity(isLoading ? 0.72 : 1)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(DashSurfaceButtonStyle())
    .disabled(!isEnabled || isLoading)
    .opacity(isEnabled ? 1 : 0.55)
    .accessibilityElement(children: .combine)
    .accessibilityValue(isOn ? "On" : "Off")
    .accessibilityAddTraits(.isToggle)
    .dashControlCaption(subtitle)
  }
}

/// An enum setting in a control card: the current value and a disclosure sit
/// where the switch would, and only that trailing part triggers the menu — the
/// card itself stays put.
///
/// Optimistic: callers update `value` immediately (or accept the selection in
/// `onSelect` and patch local state). `isLoading` disables the menu; never
/// replace the value/chevron with a spinner. On failure, revert `value` and
/// warn with `model.toasts.error(...)`.
struct DashMenuRow: View {
  let title: String
  let value: String
  var caption: String?
  let options: [String]
  var isEnabled = true
  /// Request in flight — disables the menu; current value stays visible.
  var isLoading = false
  let onSelect: (String) -> Void
  /// Local mirror of `value` so the picker gets a native binding. Building a
  /// `Binding(get:set:)` from `onSelect` needs a Sendable conversion that
  /// warns, and isolating the setter crashes the Xcode 26.4.1 frontend.
  @State private var selection = ""

  var body: some View {
    DashControlSurface(title: title) {
      Menu {
        Picker(title, selection: $selection) {
          ForEach(options, id: \.self) {
            Text(DashL10n.ui($0.replacingOccurrences(of: "_", with: " ")))
          }
        }
      } label: {
        HStack(spacing: 6) {
          Text(DashL10n.ui(value.replacingOccurrences(of: "_", with: " ")))
            .dashTextStyle(.bodyMedium)
            .foregroundStyle(DashTheme.subtle)
            .lineLimit(1)
            .opacity(isLoading ? 0.72 : 1)
          SolarIcon(
            asset: SolarAsset.chevronRight, size: DashTheme.Chevron.compact,
            color: DashTheme.placeholder
          )
          .rotationEffect(.degrees(90))
          .opacity(isLoading ? 0.72 : 1)
        }
        .frame(minHeight: 31)
        .contentShape(Rectangle())
      }
      .buttonStyle(DashPressButtonStyle())
    }
    .disabled(!isEnabled || isLoading)
    .opacity(isEnabled ? 1 : 0.55)
    .dashControlCaption(caption)
    .onAppear { selection = value }
    .onChange(of: value) { _, newValue in selection = newValue }
    .onChange(of: selection) { _, chosen in
      guard chosen != value else { return }
      onSelect(chosen)
      // Keep the optimistic pick; `onChange(of: value)` re-syncs on success or
      // when the caller reverts after failure.
      selection = chosen
    }
  }
}

/// A read-only value in a control card, for settings that can't be edited here.
struct DashValueCard: View {
  let title: String
  let value: String
  var caption: String?

  var body: some View {
    DashControlSurface(title: title) {
      Text(value)
        .dashTextStyle(.bodyMedium)
        .foregroundStyle(DashTheme.subtle)
        .multilineTextAlignment(.trailing)
        .lineLimit(2)
    }
    .dashControlCaption(caption)
  }
}

/// A screen's inherently read-only settings, gathered into one white card at
/// the top of the page — label/value rows with dividers — instead of dead
/// controls scattered through the editable flow.
struct DashReadOnlySettingsCard: View {
  let rows: [(String, String)]

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Read only")
        .dashTextStyle(.bodyMedium)
        .foregroundStyle(DashTheme.subtle)
        .padding(.horizontal, 16)
      dashListCard {
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
          DashValueRow(title: row.0, value: row.1)
            .dashListCardInset()
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct DashCodePanel: View {
  let title: String
  var message: String?
  @Binding var text: String
  var isEditable = true
  var minHeight: CGFloat = 160

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .dashTextStyle(.sectionTitle)
          .foregroundStyle(DashTheme.strong)
        if let message {
          Text(message)
            .font(.caption)
            .foregroundStyle(DashTheme.subtle)
        }
      }

      TextEditor(text: $text)
        .dashTextStyle(.code)
        .foregroundStyle(DashTheme.text)
        .scrollContentBackground(.hidden)
        .disabled(!isEditable)
        .frame(minHeight: minHeight)
        .padding(12)
        .background(DashTheme.base)
        .clipShape(RoundedRectangle(cornerRadius: DashTheme.Radius.medium, style: .continuous))
    }
    .padding(DashTheme.Spacing.card)
    .background(
      DashTheme.recessed,
      in: RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous))
  }
}

/// Read-only companion to DashCodePanel for command output and source code.
struct DashCodeBlock: View {
  var title: String?
  let text: String
  var placeholder: String?
  var minHeight: CGFloat = 120

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let title {
        Text(title)
          .dashTextStyle(.sectionTitle)
          .foregroundStyle(DashTheme.strong)
      }
      ScrollView(.horizontal, showsIndicators: false) {
        Text(text.isEmpty ? (placeholder ?? "") : text)
          .dashTextStyle(.code)
          .foregroundStyle(text.isEmpty ? DashTheme.subtle : DashTheme.text)
          .textSelection(.enabled)
          .padding(12)
      }
      .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
      .background(DashTheme.base)
      .clipShape(RoundedRectangle(cornerRadius: DashTheme.Radius.medium, style: .continuous))
    }
    .padding(DashTheme.Spacing.card)
    .background(
      DashTheme.recessed,
      in: RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous))
  }
}

struct DashNotice: View {
  enum Kind {
    case success, error, warning

    var defaultTitle: String {
      switch self {
      case .success: DashL10n.ui("Success")
      case .error: DashL10n.ui("Error")
      case .warning: DashL10n.ui("Warning")
      }
    }
  }

  let kind: Kind
  /// Defaults to the kind label (`Warning` / `Error` / `Success`).
  var title: String?
  let message: String

  private var resolvedTitle: String { DashL10n.ui(title) ?? kind.defaultTitle }
  private var resolvedMessage: String { DashL10n.ui(message) }

  private var colors: (foreground: Color, background: Color, icon: String) {
    switch kind {
    case .success: (DashTheme.success, DashTheme.successTint, SolarAsset.Content.checkCircle)
    case .error: (DashTheme.danger, DashTheme.dangerTint, SolarAsset.Content.danger)
    case .warning: (DashTheme.warning, DashTheme.warningTint, SolarAsset.Content.danger)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      SolarIcon(asset: colors.icon, size: 28, color: colors.foreground)
      Text(resolvedTitle)
        .dashTextStyle(.bodySemibold)
        .foregroundStyle(colors.foreground)
      Text(resolvedMessage)
        .dashTextStyle(.supporting)
        .foregroundStyle(colors.foreground)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(DashTheme.Spacing.card)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(colors.background)
    .clipShape(RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous))
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      DashNotice.accessibilityText(
        kind: kind, title: resolvedTitle, message: resolvedMessage))
  }

  static func accessibilityText(kind: Kind, message: String) -> String {
    accessibilityText(kind: kind, title: kind.defaultTitle, message: message)
  }

  static func accessibilityText(kind: Kind, title: String, message: String) -> String {
    "\(title): \(message)"
  }
}

struct DashListButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .opacity(configuration.isPressed ? 0.58 : 1)
      .animation(
        reduceMotion ? DashTheme.Motion.reduced : DashTheme.Motion.quick,
        value: configuration.isPressed
      )
  }
}

struct DashSectionHeader: View {
  let title: String

  init(_ title: String) {
    self.title = title
  }

  var body: some View {
    Text(title)
      .dashTextStyle(.sectionTitle)
      .foregroundStyle(DashTheme.strong)
      .textCase(nil)
      .padding(.top, 12)
      .padding(.bottom, 6)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct DashToolbarActionIcon: View {
  let asset: String

  var body: some View {
    // Keep the glyph square so Liquid Glass morphs to a circle, not a capsule.
    // 24pt matches the system back chevron, which renders its 24×24 Solar
    // asset at natural size.
    SolarIcon(asset: asset, size: 24, color: DashTheme.strong)
      .frame(width: 24, height: 24)
      .accessibilityHidden(true)
  }
}

/// Keeps adjacent nav-bar actions visually grouped without shrinking their
/// 44pt touch targets. Native spacing between separate `ToolbarItem`s is too
/// loose for a compact pair, so paired actions share one item with a short
/// gap while retaining their own circular glass.
struct DashToolbarActionGroup<Content: View>: View {
  @ViewBuilder let content: () -> Content

  var body: some View {
    HStack(spacing: 8) {
      content()
    }
  }
}

/// Trailing nav-bar icon action. Forces a circle on iOS 26 Liquid Glass
/// (system default is a capsule whenever the label isn't treated as square).
struct DashToolbarIconButton: View {
  let asset: String
  var accessibilityLabel: String
  let action: () -> Void

  var body: some View {
    Group {
      if #available(iOS 26.0, *) {
        // Do NOT use `.buttonStyle(.glass)` here. After
        // `sharedBackgroundVisibility(.hidden)`, that style paints a circle a
        // few points smaller than the system back control, and the nav-bar
        // item-height clamp shrinks it further. An explicit 44pt `glassEffect`
        // matches the leading back button / floated profile avatar.
        Button(action: action) {
          DashToolbarActionIcon(asset: asset)
            .frame(
              width: AvatarHeaderMetrics.barSize,
              height: AvatarHeaderMetrics.barSize
            )
            .contentShape(Circle())
            .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(DashPressButtonStyle())
        .accessibilityLabel(DashL10n.ui(accessibilityLabel))
      } else {
        Button(action: action) {
          DashToolbarActionIcon(asset: asset)
            .dashCompactHitTarget()
        }
        .buttonStyle(DashPressButtonStyle())
        .accessibilityLabel(DashL10n.ui(accessibilityLabel))
      }
    }
  }
}

/// Trailing nav-bar text action. Paints its own glass capsule so it matches
/// `DashToolbarIconButton` after `sharedBackgroundVisibility(.hidden)` — without
/// this, text actions render as bare labels while icon buttons keep their glass.
struct DashToolbarTextButton: View {
  let title: String
  let action: () -> Void

  private var label: some View {
    Text(DashL10n.ui(title))
      .dashTextStyle(.supportingSemibold)
      .foregroundStyle(DashTheme.strong)
      .padding(.horizontal, 14)
      .frame(height: AvatarHeaderMetrics.barSize)
      .contentShape(Capsule(style: .continuous))
  }

  var body: some View {
    Group {
      if #available(iOS 26.0, *) {
        Button(action: action) {
          label.glassEffect(
            .regular.interactive(), in: Capsule(style: .continuous))
        }
        .buttonStyle(DashPressButtonStyle())
      } else {
        Button(action: action) {
          label
            .background(DashTheme.elevated, in: Capsule(style: .continuous))
            .overlay {
              Capsule(style: .continuous).stroke(DashTheme.line, lineWidth: 0.5)
            }
        }
        .buttonStyle(DashPressButtonStyle())
      }
    }
  }
}

extension ToolbarContent {
  /// Hides the nav bar's shared Liquid Glass plate behind trailing actions.
  /// Required whenever the item already paints its own glass
  /// (`DashToolbarIconButton`, `DashToolbarTextButton`, profile-style
  /// controls): without this, iOS 26 stacks a second capsule/circle under the
  /// button. Also keeps adjacent icons from merging into one shared capsule.
  @ToolbarContentBuilder
  func dashSeparateToolbarBackground() -> some ToolbarContent {
    if #available(iOS 26.0, *) {
      sharedBackgroundVisibility(.hidden)
    } else {
      self
    }
  }
}

struct DashTextTabs<Selection: Hashable>: View {
  let items: [(title: String, value: Selection)]
  @Binding var selection: Selection
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(spacing: 0) {
      // A plain HStack, deliberately not a horizontal ScrollView: a scroll view
      // delays touch-down (killing the press animation) and picks up the
      // enclosing `refreshable`, letting a vertical pull on the tabs trigger a
      // refresh. Tab sets are 2–3 items and always fit.
      HStack(spacing: DashTheme.Spacing.panel) {
        ForEach(items.indices, id: \.self) { index in
          let item = items[index]
          Button {
            withAnimation(reduceMotion ? DashTheme.Motion.reduced : DashTheme.Motion.quick) {
              selection = item.value
            }
          } label: {
            Text(DashL10n.ui(item.title))
              .dashTextStyle(.sectionTitle)
              .foregroundStyle(
                selection == item.value ? DashTheme.strong : DashTheme.placeholder
              )
              .contentTransition(reduceMotion ? .opacity : .interpolate)
              // Press the whole tab (incl. its padding), not just the glyph, so
              // the shrink reads on the small label.
              .dashCompactHitTarget()
              .contentShape(Rectangle())
          }
          .buttonStyle(DashPressButtonStyle())
          .accessibilityAddTraits(selection == item.value ? .isSelected : [])
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.bottom, DashTheme.Spacing.compact)

      // Same hairline the tray header carries, so tabs read as header chrome.
      Rectangle()
        .fill(DashTheme.Sheet.headerBorder)
        .frame(height: 1)
    }
  }
}

private struct DashGroupedListModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
      .listStyle(.insetGrouped)
      .contentMargins(.horizontal, DashTheme.Spacing.screen, for: .scrollContent)
      .contentMargins(.top, 0, for: .scrollContent)
      .contentMargins(.bottom, DashTheme.Spacing.scrollBottomInset, for: .scrollContent)
      .listSectionSpacing(DashTheme.Spacing.section)
      .listRowSpacing(0)
      .listRowSeparator(.hidden)
      .listSectionSeparator(.hidden)
      .listRowBackground(DashTheme.base)
      .listRowInsets(
        EdgeInsets(
          top: 0,
          leading: DashTheme.Spacing.listInset,
          bottom: 0,
          trailing: DashTheme.Spacing.listInset
        )
      )
      .environment(\.defaultMinListRowHeight, 1)
      .dashTextStyle(.bodyMedium)
      .buttonStyle(DashListButtonStyle())
      .tint(DashTheme.strong)
      .headerProminence(.increased)
      .scrollContentBackground(.hidden)
      .background(DashTheme.canvas)
      .foregroundStyle(DashTheme.text)
  }
}
