import CloudflareAPI
import SwiftUI
import UIKit

private struct FeatureTransitionNamespaceKey: EnvironmentKey {
  static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
  var featureTransitionNamespace: Namespace.ID? {
    get { self[FeatureTransitionNamespaceKey.self] }
    set { self[FeatureTransitionNamespaceKey.self] = newValue }
  }
}

enum DashTheme {
  enum Layout {
    /// Reading width for regular-width feature screens. The parent container still
    /// wins when Split View or Stage Manager gives the app less room.
    static let contentMaxWidth: CGFloat = 760
    static let trayMaxWidth: CGFloat = 640
    static let emptyStateMinHeight: CGFloat = 420
    static let minimumHitTarget: CGFloat = 44
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
    /// Inner horizontal padding of a single item card (tiles, vivid hero cards).
    static let itemCardInset: CGFloat = 14
    /// Extra scroll padding above the floating tab bar / home indicator.
    static let scrollBottomInset: CGFloat = 72
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
        ? reduced : Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.36)
    }
    /// Deliberate hero morph for matchedGeometryEffect tray transitions — springy
    /// and slower than the micro-interaction tokens so the shape change reads.
    @MainActor static var morph: Animation {
      UIAccessibility.isReduceMotionEnabled
        ? reduced : Animation.spring(response: 0.32, dampingFraction: 0.85)
    }
    /// A small threshold-crossing pop for pull affordances — enough overshoot to
    /// snap without wobbling.
    @MainActor static var pop: Animation {
      UIAccessibility.isReduceMotionEnabled
        ? reduced : Animation.spring(response: 0.3, dampingFraction: 0.6)
    }
    /// Tray present/dismiss — the card slide and dim fade. Slower and eased in and
    /// out so the sheet arrives and leaves gently rather than snapping.
    @MainActor static var sheet: Animation {
      UIAccessibility.isReduceMotionEnabled
        ? reduced : Animation.timingCurve(0.42, 0, 0.58, 1, duration: 0.34)
    }
    /// Tray reveal — half-height slide, fade, and blur share one strongly
    /// decelerating curve so the short travel still reads as a full open.
    @MainActor static var trayOpen: Animation {
      UIAccessibility.isReduceMotionEnabled
        ? reduced : Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.4)
    }
    /// The way out mirrors the reveal but accelerates: a decelerating exit
    /// spends its tail at near-zero opacity, where the card fill blends away
    /// before the text does and the content seems to linger. Accelerating,
    /// everything reaches zero together and the close reads as one motion.
    @MainActor static var trayClose: Animation {
      UIAccessibility.isReduceMotionEnabled
        ? reduced : Animation.timingCurve(0.64, 0, 0.78, 0, duration: 0.3)
    }
  }

  enum Sheet {
    static let content: CGFloat = 28
    static let headerTop: CGFloat = 28
    static let headerBottom: CGFloat = 14
    static let bodyVertical: CGFloat = 16
    static let bodyBottom: CGFloat = 32
    static let grabBarWidth: CGFloat = 36
    static let grabBarHeight: CGFloat = 5
    static let grabBarTop: CGFloat = 10
    static let grabBarBottom: CGFloat = 8
    static let closeIcon = Color(hex: 0x9B9A9D)
    static let headerBorder = adaptive(light: 0xF6F8FA, dark: 0x262626)
    static let shortcutItem = adaptive(light: 0xF6F8FA, dark: 0x262626)
    static let scrimOpacity: CGFloat = 0.35
    /// Gap between a floating tray and the screen edges.
    static let floatingMargin: CGFloat = 12
    /// Lets floating trays sit slightly inside the home-indicator safe area.
    static let floatingBottomTuck: CGFloat = 6
    /// Native-sheet-like top corners while an expandable tray is expanded.
    static let expandedTopRadius: CGFloat = 12
    /// Gap kept below the top safe area while expanded.
    static let expandedTopGap: CGFloat = 10
    /// Share of the screen an expandable tray keeps when collapsed to its
    /// floating detent.
    static let floatingDetentFraction: CGFloat = 0.62
  }

  // Cool neutral surfaces: controls and grouped elements share one light fill,
  // while the white canvas keeps their boundaries visible without warm tinting.
  static let canvas = adaptive(light: 0xFFFFFF, dark: 0x1A1A1A)
  static let elevated = adaptive(light: 0xF6F8FA, dark: 0x1F1F1F)
  static let recessed = adaptive(light: 0xF6F8FA, dark: 0x262626)
  static let base = adaptive(light: 0xF6F8FA, dark: 0x2B2B2B)
  static let fill = adaptive(light: 0xD0D7DE, dark: 0x404040)

  static let text = adaptive(light: 0x212126, dark: 0xF5F5F5)
  static let strong = adaptive(light: 0x171717, dark: 0xFAFAFA)
  /// Supporting copy on canvas — tuned for ≥4.5:1 on `canvas` in both modes.
  static let subtle = adaptive(
    light: 0x5C5C5C, dark: 0xA3A3A3, highLight: 0x404040, highDark: 0xD4D4D4)
  /// List-row descriptions: quieter than `subtle` so titles carry the row.
  /// Sits below AA in light mode (~2.7:1 on canvas) — deliberate, decorative
  /// tier; Increased Contrast promotes it back to the `subtle` stops.
  static let rowSubtitle = adaptive(
    light: 0x9B9B9B, dark: 0x9B9B9B, highLight: 0x404040, highDark: 0xD4D4D4)
  /// Quiet icon actions (e.g. list-header edit); a tier fainter than `subtle`.
  static let faint = adaptive(
    light: 0x8A8A8A, dark: 0x8A8A8A, highLight: 0x6B6B6B, highDark: 0xB3B3B3)
  /// Leading icons on neutral tray menu rows; danger rows keep `danger`.
  static let iconMuted = adaptive(
    light: 0x6F7170, dark: 0x9A9C9B, highLight: 0x525252, highDark: 0xC4C4C4)
  static let placeholder = adaptive(
    light: 0x6B6B6B, dark: 0xA3A3A3, highLight: 0x525252, highDark: 0xD4D4D4)
  static let inverse = adaptive(light: 0xFFFFFF, dark: 0x171717)

  static let accent = Color(hex: 0xF6821F)
  /// Reserved for focus rings, primary CTAs, and rare accents — not catalog decoration.
  static let brand = adaptive(
    light: 0x1460E6, dark: 0x5B9BFF, highLight: 0x0B4FCF, highDark: 0x93C5FD)
  static let line = adaptive(light: 0xD0D7DE, dark: 0x525252)
  static let hairline = adaptive(light: 0xEAEEF2, dark: 0x404040)
  /// Row separators on `recessed` panels — a step darker than `hairline`,
  /// which disappears on gray.
  static let panelLine = adaptive(light: 0xD8DEE4, dark: 0x3A3A3C)
  /// Status foregrounds — readable as small text on canvas and on matching tints.
  static let danger = adaptive(
    light: 0xDC2626, dark: 0xF87171, highLight: 0xB91C1C, highDark: 0xFCA5A5)
  static let dangerTint = adaptive(light: 0xFEE2E2, dark: 0x450A0A)
  static let success = adaptive(
    light: 0x047857, dark: 0x6EE7B7, highLight: 0x065F46, highDark: 0xA7F3D0)
  static let successTint = adaptive(light: 0xD1FAE5, dark: 0x064E3B)
  static let warning = adaptive(
    light: 0xA16207, dark: 0xFDE68A, highLight: 0x854D0E, highDark: 0xFEF08A)
  static let warningTint = adaptive(light: 0xFEF9C3, dark: 0x713F12)
  static let info = adaptive(
    light: 0x1D4ED8, dark: 0x93C5FD, highLight: 0x1E40AF, highDark: 0xBFDBFE)
  static let infoTint = adaptive(light: 0xDBEAFE, dark: 0x1E3A8A)

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
  enum LoginBackdrop {
    static let meshLight: [Color] = [
      Color(hex: 0xFFFFFF), Color(hex: 0xFFE4C7), Color(hex: 0xFFF7EF),
      Color(hex: 0xFFEBD6), Color(hex: 0xFFF5EB), Color(hex: 0xFFDFBE),
      Color(hex: 0xFFF7EF), Color(hex: 0xFFEEDD), Color(hex: 0xFFFFFF),
    ]
    static let meshDark: [Color] = [
      Color(hex: 0x1A1A1A), Color(hex: 0x33220F), Color(hex: 0x1F1B16),
      Color(hex: 0x2A1D10), Color(hex: 0x221A11), Color(hex: 0x3A2410),
      Color(hex: 0x1F1B16), Color(hex: 0x2A1D10), Color(hex: 0x1A1A1A),
    ]
    static let stillLight: [Color] = [
      Color(hex: 0xFFE4C7), Color(hex: 0xFFFFFF), Color(hex: 0xFFEEDD),
    ]
    static let stillDark: [Color] = [
      Color(hex: 0x33220F), Color(hex: 0x1A1A1A), Color(hex: 0x2A1D10),
    ]
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
  fileprivate init(hex: UInt32) {
    self.init(uiColor: UIColor(hex: hex))
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
  /// One color family per catalog section so a group reads as a set.
  static func tone(forCategory category: String) -> FeatureVisualTone {
    switch category {
    case "Domains & DNS": .success
    case "Compute": .brand
    case "Storage & Data": .accent
    default: .soft
    }
  }

  static func tone(for feature: FeatureID) -> FeatureVisualTone {
    tone(forCategory: feature.category)
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

private struct DashContentColumnModifier: ViewModifier {
  let regularMaxWidth: CGFloat
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  func body(content: Content) -> some View {
    content
      .frame(
        maxWidth: horizontalSizeClass == .regular ? regularMaxWidth : .infinity,
        alignment: .top
      )
      .frame(maxWidth: .infinity, alignment: .top)
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

  func dashContentColumn(
    maxWidth: CGFloat = DashTheme.Layout.contentMaxWidth
  ) -> some View {
    modifier(DashContentColumnModifier(regularMaxWidth: maxWidth))
  }

  func dashCompactHitTarget() -> some View {
    frame(
      minWidth: DashTheme.Layout.minimumHitTarget,
      minHeight: DashTheme.Layout.minimumHitTarget
    )
    .contentShape(Rectangle())
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
        in: RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous))
  }
}

/// Icon-over-title navigation tile for tool grids, carrying DashCard chrome.
struct DashToolTile: View {
  let title: String
  let icon: String

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      SolarIcon(asset: icon, size: 22, color: DashTheme.brand)
      Text(title)
        .dashTextStyle(.supportingSemibold)
        .foregroundStyle(DashTheme.text)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(DashTheme.Spacing.card)
    .frame(minHeight: 96)
    .background(
      DashTheme.recessed,
      in: RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous))
  }
}

/// Tool-tile grid that reflows with available width — two-up on iPhone (kept
/// down to 320pt Display Zoom windows), four or five inside the regular-width
/// content column.
struct DashTileGrid<Content: View>: View {
  @ViewBuilder let content: () -> Content

  var body: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 136), spacing: 12)], spacing: 12) {
      content()
    }
  }
}

struct DashListGroupLink<Label: View>: View {
  let value: Destination
  var onNavigate: (() -> Void)?
  @ViewBuilder let label: () -> Label

  var body: some View {
    NavigationLink(value: value) {
      label()
    }
    .buttonStyle(DashPressButtonStyle())
    .simultaneousGesture(
      TapGesture().onEnded {
        onNavigate?()
      })
  }
}

/// List row navigation link. Row chrome modifiers must live on the link, not the label.
struct DashListNavigationLink<Value: Hashable, Label: View>: View {
  let value: Value
  @ViewBuilder let label: () -> Label

  var body: some View {
    NavigationLink(value: value) {
      label()
    }
    .listRowSeparator(.hidden)
    .listSectionSeparator(.hidden)
  }
}

/// Routes `Destination` values through the tab navigation stack.
struct DashDestinationLink<Label: View>: View {
  let destination: Destination
  @ViewBuilder let label: () -> Label

  var body: some View {
    NavigationLink(value: destination) {
      label()
    }
    .listRowSeparator(.hidden)
    .listSectionSeparator(.hidden)
  }
}

struct DashListGroupDivider: View {
  var body: some View {
    Divider().overlay(DashTheme.panelLine)
  }
}

/// Home/Resources-style list group without a section title. Bare rows on the
/// canvas — no fill, no separators; the row's own padding carries the rhythm.
struct DashListCard<Content: View>: View {
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 0) { content() }
      .padding(.horizontal, DashTheme.Spacing.rowInset)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct DashListCardRows<Item: Identifiable, Row: View>: View {
  let items: [Item]
  @ViewBuilder let row: (Item) -> Row

  var body: some View {
    ForEach(Array(items.enumerated()), id: \.element.id) { _, item in
      row(item)
    }
  }
}

struct DashInlineSearch: View {
  let prompt: String
  @Binding var text: String
  private var reportsFocus: FocusState<Bool>.Binding?
  @FocusState private var internalFocused: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(
    prompt: String,
    text: Binding<String>,
    reportsFocus: FocusState<Bool>.Binding? = nil
  ) {
    self.prompt = prompt
    self._text = text
    self.reportsFocus = reportsFocus
  }

  private var focusBinding: FocusState<Bool>.Binding {
    reportsFocus ?? $internalFocused
  }

  var body: some View {
    HStack(spacing: 10) {
      SolarIcon(
        asset: SolarAsset.search,
        size: 18,
        color: focusBinding.wrappedValue ? DashTheme.brand : DashTheme.placeholder
      )
      TextField(prompt, text: $text)
        .dashTextStyle(.bodyMedium)
        .foregroundStyle(DashTheme.text)
        .focused(focusBinding)
        .submitLabel(.search)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
      if !text.isEmpty {
        Button {
          withAnimation(reduceMotion ? DashTheme.Motion.reduced : DashTheme.Motion.quick) {
            text = ""
          }
        } label: {
          SolarIcon(asset: SolarAsset.close, size: 18, color: DashTheme.subtle)
            .dashCompactHitTarget()
        }
        .buttonStyle(DashPressButtonStyle())
        .accessibilityLabel("Clear search")
        .transition(
          reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9))
        )
      }
    }
    .padding(.horizontal, 16)
    .frame(minHeight: 52)
    .background(
      DashTheme.recessed,
      in: RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous)
    )
    // No focus ring: the caret and the brand-tinted search icon already say
    // "focused", and panels never carry strokes in this design language.
  }
}

/// Feature drill-down shell: optional search and fixed chrome above scrollable content.
struct DashFeatureScreen<Chrome: View, Content: View>: View {
  var search: Binding<String>?
  var prompt: String = ""
  @ViewBuilder var chrome: () -> Chrome
  @ViewBuilder var content: () -> Content

  init(
    search: Binding<String>? = nil,
    prompt: String = "",
    @ViewBuilder chrome: @escaping () -> Chrome,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.search = search
    self.prompt = prompt
    self.chrome = chrome
    self.content = content
  }

  var body: some View {
    VStack(spacing: 0) {
      if let search {
        DashInlineSearch(prompt: prompt, text: search)
          .padding(.horizontal, DashTheme.Spacing.screen)
          .padding(.bottom, 12)
      }
      chrome()
        .padding(.horizontal, DashTheme.Spacing.screen)
      content()
    }
    .dashContentColumn()
    .background(DashTheme.canvas)
  }
}

extension DashFeatureScreen where Chrome == EmptyView {
  init(
    search: Binding<String>? = nil,
    prompt: String = "",
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.init(
      search: search,
      prompt: prompt,
      chrome: { EmptyView() },
      content: content
    )
  }
}

/// What a feature list should render for a given load/error/content state.
/// Cache-first: when rows already exist, refresh keeps content visible and only
/// surfaces an inline banner — never flips back to a full-screen loading slot.
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

/// Shared feature list: optional search, loading/error slots, grouped list chrome.
struct DashFeatureList<Header: View, Content: View>: View {
  var search: Binding<String>?
  var prompt: String = ""
  var isLoading: Bool = false
  var error: String?
  var hasContent: Bool = false
  var retry: () -> Void
  @ViewBuilder var header: () -> Header
  @ViewBuilder var content: () -> Content
  @Environment(AppModel.self) private var model
  @Environment(\.featureRequiredScopes) private var featureRequiredScopes

  init(
    search: Binding<String>? = nil,
    prompt: String = "",
    isLoading: Bool = false,
    error: String? = nil,
    hasContent: Bool = false,
    retry: @escaping () -> Void = {},
    @ViewBuilder header: @escaping () -> Header,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.search = search
    self.prompt = prompt
    self.isLoading = isLoading
    self.error = error
    self.hasContent = hasContent
    self.retry = retry
    self.header = header
    self.content = content
  }

  var body: some View {
    DashFeatureScreen(
      search: search,
      prompt: prompt,
      chrome: header
    ) {
      ScrollView {
        LazyVStack(spacing: DashTheme.Spacing.section) {
          switch DashListPhase.resolve(isLoading: isLoading, error: error, hasContent: hasContent) {
          case .loading:
            DashListSkeleton()
          case .fullScreenError(let message):
            ErrorStateView(message: message, retry: retry)
          case .content(let banner, let refreshing):
            if refreshing {
              HStack(spacing: 10) {
                DashLoadingRing(color: DashTheme.brand, size: 16, lineWidth: 2.5)
                Text("Updating…")
                  .dashTextStyle(.footnote)
                  .foregroundStyle(DashTheme.subtle)
                Spacer(minLength: 0)
              }
              .accessibilityElement(children: .combine)
              .accessibilityLabel("Updating")
            }
            if let banner {
              failureBanner(banner)
            }
            content()
              .dashContentReveal()
          }
        }
        .padding(.horizontal, DashTheme.Spacing.screen)
        // This gap belongs to the scroll content. Putting it on
        // DashFeatureScreen turns it into fixed header chrome.
        .padding(.top, DashTheme.Spacing.section)
        .padding(.bottom, DashTheme.Spacing.scrollBottomInset)
      }
      .scrollDismissesKeyboard(.interactively)
    }
  }

  @ViewBuilder
  private func failureBanner(_ message: String) -> some View {
    let presentation = DashFailurePresentation.from(message: message)
    VStack(alignment: .leading, spacing: 10) {
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
    search: Binding<String>? = nil,
    prompt: String = "",
    isLoading: Bool = false,
    error: String? = nil,
    hasContent: Bool = false,
    retry: @escaping () -> Void = {},
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.init(
      search: search,
      prompt: prompt,
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
      HStack(spacing: 12) {
        Text(title)
          .dashTextStyle(.supportingMedium)
          .foregroundStyle(DashTheme.subtle)
        Spacer(minLength: 0)
        if let action {
          Group {
            if let actionIcon {
              Button(action: action) {
                SolarIcon(asset: actionIcon, size: 16, color: DashTheme.faint)
                  .dashCompactHitTarget()
              }
              .buttonStyle(DashPressButtonStyle())
              .accessibilityLabel(actionTitle ?? "Edit")
            } else if let actionTitle {
              Button(actionTitle, action: action)
                .dashTextStyle(.supportingMedium)
                .foregroundStyle(DashTheme.brand)
                .dashCompactHitTarget()
                .buttonStyle(DashPressButtonStyle())
            }
          }
        }
      }
      .padding(.horizontal, 4)

      // Bare rows on the canvas — no fill, no separators. Rows inset to match
      // the title above them, so the group reads as one column.
      VStack(alignment: .leading, spacing: 0) { content }
        .padding(.horizontal, DashTheme.Spacing.rowInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

struct CatalogFeatureIcon: View {
  enum Style {
    case duotone
    case outline
  }

  enum Size {
    case list
    case shortcut
    case compact
    case hero
  }

  let feature: FeatureID
  var style: Style = .duotone
  var size: Size = .list
  /// When true, uses vivid tone (pinned/hero). Catalog lists stay muted.
  var emphasized: Bool = false
  /// Sitting on a card already filled with the feature's tone: the glyph flips
  /// to the on-card color and drops its tile, which would otherwise tint-on-tint.
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
    // Duotone assets are two layers — a low-alpha backdrop under the glyph.
    // `.renderingMode(.template)` flattens both to the tint, so on a colored
    // card the backdrop resurfaces as a ghost tile. Outline has one layer.
    style == .duotone && !onColor ? feature.solarAssetName : feature.solarOutlineAssetName
  }

  private var scaleClamp: CGFloat {
    min(max(listGlyphScale, 1), 1.3)
  }

  private var glyphSize: CGFloat {
    let base: CGFloat =
      switch size {
      case .list: 24
      case .shortcut: 20
      case .compact: 18
      case .hero: 36
      }
    return size == .list || size == .shortcut ? base * scaleClamp : base
  }

  private var tileSize: CGFloat {
    let base: CGFloat =
      switch size {
      case .list: 44
      case .shortcut: 34
      case .compact: 28
      case .hero: 56
      }
    return size == .list || size == .shortcut
      ? base * min(max(listTileScale, 1), 1.3) : base
  }

  var body: some View {
    Image(assetName)
      .resizable()
      .renderingMode(.template)
      .scaledToFit()
      .foregroundStyle(tone)
      .frame(width: glyphSize, height: glyphSize)
      .frame(width: tileSize, height: tileSize, alignment: onColor ? .leading : .center)
      .background(onColor ? Color.clear : tone.opacity(emphasized || size == .hero ? 0.16 : 0.1))
      .clipShape(
        RoundedRectangle(
          cornerRadius: size == .compact || size == .shortcut
            ? DashTheme.Radius.small : DashTheme.Radius.medium,
          style: .continuous
        )
      )
      .accessibilityHidden(true)
  }
}

// MARK: - Feature navigation

private struct FeatureTransitionSourceModifier: ViewModifier {
  let feature: FeatureID
  let background: Color
  let cornerRadius: CGFloat
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.featureTransitionNamespace) private var featureTransitionNamespace

  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(iOS 18.0, *), !reduceMotion, let featureTransitionNamespace {
      content.matchedTransitionSource(id: feature, in: featureTransitionNamespace) { source in
        source
          .background(background)
          .clipShape(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          )
      }
    } else {
      content
    }
  }
}

private struct FeatureTransitionDestinationModifier: ViewModifier {
  let feature: FeatureID
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.featureTransitionNamespace) private var featureTransitionNamespace

  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(iOS 18.0, *), !reduceMotion, let featureTransitionNamespace {
      content.navigationTransition(.zoom(sourceID: feature, in: featureTransitionNamespace))
    } else {
      content
    }
  }
}

extension View {
  func dashFeatureTransitionSource(
    _ feature: FeatureID,
    background: Color,
    cornerRadius: CGFloat
  ) -> some View {
    modifier(
      FeatureTransitionSourceModifier(
        feature: feature,
        background: background,
        cornerRadius: cornerRadius
      )
    )
  }

  fileprivate func dashFeatureTransitionDestination(_ feature: FeatureID) -> some View {
    modifier(FeatureTransitionDestinationModifier(feature: feature))
  }
}

/// Collapsed header title: compact icon before text.
private struct FeatureInlineNavigationTitle: View {
  let feature: FeatureID
  let title: String

  var body: some View {
    HStack(spacing: 6) {
      CatalogFeatureIcon(feature: feature, size: .compact)
      Text(title)
        .dashTextStyle(.sectionTitle)
        .foregroundStyle(DashTheme.strong)
        .lineLimit(1)
    }
  }
}

/// Feature drill-down shell with a custom principal title above scrollable content.
struct FeatureDetailChrome<Content: View>: View {
  let feature: FeatureID
  @ViewBuilder var content: () -> Content

  var body: some View {
    content()
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .background(DashTheme.canvas)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .principal) {
          FeatureInlineNavigationTitle(feature: feature, title: feature.title)
        }
      }
      .dashFeatureTransitionDestination(feature)
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
          Text(text.capitalized)
            .dashTextStyle(.captionSemibold)
            .foregroundStyle(colors.foreground)
            .lineLimit(1)
        }
      case .capsule:
        Text(text.capitalized)
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

  static func accessibilityText(for text: String) -> String {
    "Status, \(text)"
  }
}

/// Sparse delight for rare, high-value moments — not for list filters or typing.
@MainActor
enum DashDelight {
  static func celebrateSuccess() {
    UINotificationFeedbackGenerator().notificationOccurred(.success)
  }

  static func warnImpact() {
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
  }

  static func recoverFromIssue() {
    UINotificationFeedbackGenerator().notificationOccurred(.success)
  }
}

struct LoadingStateView: View {
  var body: some View {
    DashListSkeleton()
  }
}

/// Placeholder rows that match `DashListRow` / recessed card geometry so first
/// paint keeps catalog structure instead of a blank 420pt spinner.
struct DashListSkeleton: View {
  var rows: Int = 4

  var body: some View {
    DashListGroup(title: " ") {
      ForEach(0..<rows, id: \.self) { index in
        HStack(spacing: 12) {
          RoundedRectangle(cornerRadius: DashTheme.Radius.medium, style: .continuous)
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
      icon: SolarAsset.danger,
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

struct DashPressButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
      .animation(
        reduceMotion ? nil : DashTheme.Motion.press,
        value: configuration.isPressed
      )
  }
}

struct DashEmptyState: View {
  let icon: String
  let title: String
  let message: String
  var actionTitle: String?
  var action: (() -> Void)?

  var body: some View {
    VStack(spacing: 14) {
      SolarIcon(asset: icon, size: 34, color: DashTheme.strong)
        .frame(width: 72, height: 72)
        .background(DashTheme.recessed, in: Circle())
      Text(title)
        .dashTextStyle(.emptyTitle)
        .foregroundStyle(DashTheme.strong)
        .multilineTextAlignment(.center)
      Text(message)
        .dashTextStyle(.supporting)
        .foregroundStyle(DashTheme.subtle)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      if let actionTitle, let action {
        DashSecondaryPillButton(title: actionTitle, action: action)
          .padding(.top, 6)
      }
    }
    .frame(maxWidth: 440)
    .padding(28)
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
  var iconColor: Color = DashTheme.brand
  var trailing: String?
  var showsChevron = true
  @ViewBuilder var accessory: () -> Accessory
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @ScaledMetric(relativeTo: .body) private var iconScale: CGFloat = 1

  init(
    title: String,
    subtitle: String? = nil,
    icon: String? = nil,
    iconColor: Color = DashTheme.brand,
    trailing: String? = nil,
    showsChevron: Bool = true,
    @ViewBuilder accessory: @escaping () -> Accessory
  ) {
    self.title = title
    self.subtitle = subtitle
    self.icon = icon
    self.iconColor = iconColor
    self.trailing = trailing
    self.showsChevron = showsChevron
    self.accessory = accessory
  }

  private var isAccessibilitySize: Bool { dynamicTypeSize.isAccessibilitySize }
  private var iconPointSize: CGFloat { 22 * min(max(iconScale, 1), 1.3) }
  private var iconFrame: CGFloat { 40 * min(max(iconScale, 1), 1.3) }

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
              SolarIcon(asset: SolarAsset.chevronRight, size: 16, color: DashTheme.placeholder)
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
            SolarIcon(asset: SolarAsset.chevronRight, size: 16, color: DashTheme.placeholder)
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
    if let icon {
      SolarIcon(asset: icon, size: iconPointSize, color: iconColor)
        .frame(width: iconFrame, height: iconFrame)
        .background(iconColor.opacity(0.15), in: Circle())
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
    iconColor: Color = DashTheme.brand,
    trailing: String? = nil,
    showsChevron: Bool = true
  ) {
    self.init(
      title: title,
      subtitle: subtitle,
      icon: icon,
      iconColor: iconColor,
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
            .foregroundStyle(DashTheme.subtle)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      } else {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
          titleBlock
          Spacer(minLength: 12)
          Text(value)
            .dashTextStyle(.supportingMedium)
            .foregroundStyle(DashTheme.subtle)
            .multilineTextAlignment(.trailing)
            .lineLimit(2)
        }
      }
    }
    .padding(.vertical, 14)
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
      Text(title)
        .dashTextStyle(.bodySemibold)
        .foregroundStyle(DashTheme.strong)
        .multilineTextAlignment(.leading)
      Spacer(minLength: 12)
      trailing()
    }
    // UISwitch stands 31pt; every card matches it so toggle, menu, and value
    // rows share one height.
    .frame(minHeight: 31)
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
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
        Text(caption)
          .dashTextStyle(.supporting)
          .foregroundStyle(DashTheme.subtle)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 16)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A switch in a control card. The whole card is the toggle target — the bare
/// switch ignores taps on its empty track on this iOS, and a full card is the
/// friendlier target anyway — so the switch is display-only and the card button
/// flips the binding.
struct DashToggleRow: View {
  let title: String
  var subtitle: String?
  @Binding var isOn: Bool
  var isEnabled = true
  var isLoading = false

  var body: some View {
    Button {
      isOn.toggle()
    } label: {
      DashControlSurface(title: title) {
        if isLoading {
          DashLoadingRing(color: DashTheme.brand)
            .frame(width: 31, height: 31)
        } else {
          Toggle("", isOn: $isOn)
            .labelsHidden()
            .tint(DashTheme.brand)
            .allowsHitTesting(false)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(DashPressButtonStyle())
    .disabled(!isEnabled || isLoading)
    .opacity(isEnabled ? 1 : 0.55)
    .accessibilityElement(children: .combine)
    .dashControlCaption(subtitle)
  }
}

/// An enum setting in a control card: the current value and a disclosure sit
/// where the switch would, and only that trailing part triggers the menu — the
/// card itself stays put.
struct DashMenuRow: View {
  let title: String
  let value: String
  var caption: String?
  let options: [String]
  var isEnabled = true
  var isLoading = false
  let onSelect: (String) -> Void
  /// Local mirror of `value` so the picker gets a native binding. Building a
  /// `Binding(get:set:)` from `onSelect` needs a Sendable conversion that
  /// warns, and isolating the setter crashes the Xcode 26.4.1 frontend.
  @State private var selection = ""

  var body: some View {
    DashControlSurface(title: title) {
      if isLoading {
        DashLoadingRing(color: DashTheme.brand)
          .frame(width: 31, height: 31)
      } else {
        Menu {
          Picker(title, selection: $selection) {
            ForEach(options, id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ")) }
          }
        } label: {
          HStack(spacing: 6) {
            Text(value.replacingOccurrences(of: "_", with: " "))
              .dashTextStyle(.bodyMedium)
              .foregroundStyle(DashTheme.subtle)
              .lineLimit(1)
            SolarIcon(asset: SolarAsset.chevronRight, size: 12, color: DashTheme.placeholder)
              .rotationEffect(.degrees(90))
          }
          .frame(minHeight: 31)
          .contentShape(Rectangle())
        }
        .buttonStyle(DashPressButtonStyle())
      }
    }
    .disabled(!isEnabled || isLoading)
    .opacity(isEnabled ? 1 : 0.55)
    .dashControlCaption(caption)
    .onAppear { selection = value }
    .onChange(of: value) { _, newValue in selection = newValue }
    .onChange(of: selection) { _, chosen in
      guard chosen != value else { return }
      onSelect(chosen)
      // Snap back to the source of truth: a successful save re-syncs through
      // `value`, and a failed one leaves the same option pickable again.
      selection = value
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
      DashListCard {
        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
          DashValueRow(title: row.0, value: row.1)
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
  enum Kind { case success, error, warning }

  let kind: Kind
  let message: String

  private var colors: (foreground: Color, background: Color, icon: String) {
    switch kind {
    case .success: (DashTheme.success, DashTheme.successTint, SolarAsset.checkCircle)
    case .error: (DashTheme.danger, DashTheme.dangerTint, SolarAsset.danger)
    case .warning: (DashTheme.warning, DashTheme.warningTint, SolarAsset.danger)
    }
  }

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      SolarIcon(asset: colors.icon, size: 20, color: colors.foreground)
      Text(message)
        .dashTextStyle(.supportingMedium)
        .foregroundStyle(colors.foreground)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(16)
    .background(colors.background)
    .clipShape(RoundedRectangle(cornerRadius: DashTheme.Radius.medium, style: .continuous))
    .accessibilityElement(children: .combine)
    .accessibilityLabel(DashNotice.accessibilityText(kind: kind, message: message))
  }

  static func accessibilityText(kind: Kind, message: String) -> String {
    switch kind {
    case .success: "Success: \(message)"
    case .error: "Error: \(message)"
    case .warning: "Warning: \(message)"
    }
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
/// loose for a compact pair, so paired actions share one item and sit edge to
/// edge while retaining their own circular glass.
struct DashToolbarActionGroup<Content: View>: View {
  @ViewBuilder let content: () -> Content

  var body: some View {
    HStack(spacing: 0) {
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
    if #available(iOS 26.0, *) {
      Button(action: action) {
        // Match the system back-button glass diameter (~44pt). `.glass` adds
        // ~7pt of chrome padding, so subtract it or the circle reads smaller.
        DashToolbarActionIcon(asset: asset)
          .frame(width: AvatarHeaderMetrics.barSize, height: AvatarHeaderMetrics.barSize)
          .padding(-7)
      }
      .buttonStyle(.glass)
      .buttonBorderShape(.circle)
      .accessibilityLabel(accessibilityLabel)
    } else {
      Button(action: action) {
        DashToolbarActionIcon(asset: asset)
          .dashCompactHitTarget()
      }
      .buttonStyle(DashPressButtonStyle())
      .accessibilityLabel(accessibilityLabel)
    }
  }
}

extension ToolbarContent {
  /// Lets each trailing icon keep its own circular glass instead of merging
  /// into one shared capsule when several actions sit side by side.
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
      HStack(spacing: 28) {
        ForEach(items.indices, id: \.self) { index in
          let item = items[index]
          Button {
            withAnimation(reduceMotion ? DashTheme.Motion.reduced : DashTheme.Motion.quick) {
              selection = item.value
            }
          } label: {
            Text(item.title)
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
      .padding(.bottom, 10)

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
