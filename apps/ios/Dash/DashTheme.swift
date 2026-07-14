import SwiftUI
import UIKit

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
    static let listInset: CGFloat = 0
  }

  /// Strong ease-out motion tokens — built-in easings feel soft, and frequent
  /// state flips stay the shortest.
  enum Motion {
    static let quick = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.12)
    static let reduced = Animation.easeOut(duration: 0.12)
    /// Deliberate hero morph for matchedGeometryEffect tray transitions — springy
    /// and slower than the micro-interaction tokens so the shape change reads.
    static var morph: Animation {
      UIAccessibility.isReduceMotionEnabled
        ? reduced : Animation.spring(response: 0.32, dampingFraction: 0.85)
    }
    /// Tray present/dismiss — the card slide and dim fade. Slower and eased in and
    /// out so the sheet arrives and leaves gently rather than snapping.
    static var sheet: Animation {
      UIAccessibility.isReduceMotionEnabled
        ? reduced : Animation.timingCurve(0.42, 0, 0.58, 1, duration: 0.34)
    }
    /// Tray reveal — half-height slide, fade, and blur share one strongly
    /// decelerating curve so the short travel still reads as a full open.
    static var trayOpen: Animation {
      UIAccessibility.isReduceMotionEnabled
        ? reduced : Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.4)
    }
    /// The way out mirrors the reveal but accelerates: a decelerating exit
    /// spends its tail at near-zero opacity, where the card fill blends away
    /// before the text does and the content seems to linger. Accelerating,
    /// everything reaches zero together and the close reads as one motion.
    static var trayClose: Animation {
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
    static let headerBorder = adaptive(light: 0xF9F7FA, dark: 0x262626)
    static let shortcutItem = adaptive(light: 0xF5F5F5, dark: 0x262626)
    static let scrimOpacity: CGFloat = 0.35
    /// Gap between a floating tray and the screen edges.
    static let floatingMargin: CGFloat = 12
    /// Native-sheet-like top corners while an expandable tray is expanded.
    static let expandedTopRadius: CGFloat = 12
    /// Gap kept below the top safe area while expanded.
    static let expandedTopGap: CGFloat = 10
    /// Share of the screen an expandable tray keeps when collapsed to its
    /// floating detent.
    static let floatingDetentFraction: CGFloat = 0.62
  }

  static let canvas = adaptive(light: 0xFFFFFF, dark: 0x1A1A1A)
  static let elevated = adaptive(light: 0xFAFAFA, dark: 0x1F1F1F)
  static let recessed = adaptive(light: 0xF5F5F5, dark: 0x262626)
  static let base = adaptive(light: 0xFFFFFF, dark: 0x2B2B2B)
  static let fill = adaptive(light: 0xE5E5E5, dark: 0x404040)

  static let text = adaptive(light: 0x212126, dark: 0xF5F5F5)
  static let strong = adaptive(light: 0x171717, dark: 0xFAFAFA)
  static let subtle = adaptive(light: 0x717171, dark: 0xA3A3A3)
  /// Quiet icon actions (e.g. list-header edit); a tier fainter than `subtle`.
  static let faint = Color(hex: 0xB3B3B3)
  /// Leading icons on neutral tray menu rows; danger rows keep `danger`.
  static let iconMuted = Color(hex: 0x8E908F)
  static let placeholder = adaptive(light: 0xA3A3A3, dark: 0x717171)
  static let inverse = adaptive(light: 0xFFFFFF, dark: 0x171717)

  static let accent = Color(hex: 0xF6821F)
  static let brand = adaptive(light: 0x1460E6, dark: 0x1256D6)
  static let line = adaptive(light: 0xE5E5E5, dark: 0x525252)
  static let hairline = adaptive(light: 0xEEEEEE, dark: 0x404040)
  /// Row separators on `recessed` panels — a step darker than `hairline`,
  /// which disappears on gray.
  static let panelLine = adaptive(light: 0xE8E8EA, dark: 0x3A3A3C)
  static let danger = adaptive(light: 0xEF4444, dark: 0xDC2626)
  static let dangerTint = adaptive(light: 0xFEE2E2, dark: 0x450A0A)
  static let success = adaptive(light: 0x10B981, dark: 0x34D399)
  static let successTint = adaptive(light: 0xD1FAE5, dark: 0x064E3B)
  static let warning = adaptive(light: 0xEAB308, dark: 0xFACC15)
  static let warningTint = adaptive(light: 0xFEF9C3, dark: 0x713F12)
  static let info = adaptive(light: 0x3B82F6, dark: 0x60A5FA)
  static let infoTint = adaptive(light: 0xDBEAFE, dark: 0x1E3A8A)

  private static func adaptive(light: UInt32, dark: UInt32) -> Color {
    Color(
      uiColor: UIColor { traits in
        UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
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
  case bodyMedium
  case bodySemibold
  case bodyBold
  case button
  case buttonMedium
  case buttonBold
  case supporting
  case supportingMedium
  case supportingSemibold
  case footnoteSemibold
  case captionSemibold
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
    case .bodyMedium: (16, .medium, .default, .body)
    case .bodySemibold: (16, .semibold, .default, .body)
    case .bodyBold: (16, .bold, .default, .body)
    case .button: (17, .semibold, .default, .body)
    case .buttonMedium: (17, .medium, .default, .body)
    case .buttonBold: (17, .bold, .default, .body)
    case .supporting: (15, .regular, .default, .subheadline)
    case .supportingMedium: (14, .medium, .default, .subheadline)
    case .supportingSemibold: (15, .semibold, .default, .subheadline)
    case .footnoteSemibold: (13, .semibold, .default, .footnote)
    case .captionSemibold: (12, .semibold, .default, .caption)
    case .code: (13, .regular, .monospaced, .footnote)
    }
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

/// Home/Items-style list card without a section title.
struct DashListCard<Content: View>: View {
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 0) { content() }
      .padding(.horizontal, 16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        DashTheme.recessed,
        in: RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous))
  }
}

struct DashListCardRows<Item: Identifiable, Row: View>: View {
  let items: [Item]
  @ViewBuilder let row: (Item) -> Row

  var body: some View {
    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
      row(item)
      if index < items.count - 1 {
        DashListGroupDivider()
      }
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
    .overlay {
      RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous)
        .stroke(DashTheme.brand.opacity(0.45), lineWidth: 1.5)
        .opacity(focusBinding.wrappedValue ? 1 : 0)
    }
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
    .padding(.top, 12)
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
    self.init(search: search, prompt: prompt, chrome: { EmptyView() }, content: content)
  }
}

/// Shared feature list: optional search, loading/error slots, grouped list chrome.
struct DashFeatureList<Header: View, Content: View>: View {
  var search: Binding<String>?
  var prompt: String = ""
  var isLoading: Bool = false
  var error: String?
  var retry: () -> Void
  @ViewBuilder var header: () -> Header
  @ViewBuilder var content: () -> Content

  init(
    search: Binding<String>? = nil,
    prompt: String = "",
    isLoading: Bool = false,
    error: String? = nil,
    retry: @escaping () -> Void = {},
    @ViewBuilder header: @escaping () -> Header,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.search = search
    self.prompt = prompt
    self.isLoading = isLoading
    self.error = error
    self.retry = retry
    self.header = header
    self.content = content
  }

  var body: some View {
    DashFeatureScreen(search: search, prompt: prompt, chrome: header) {
      ScrollView {
        LazyVStack(spacing: DashTheme.Spacing.section) {
          if isLoading {
            LoadingStateView()
              .frame(
                maxWidth: .infinity,
                minHeight: DashTheme.Layout.emptyStateMinHeight
              )
          } else if let error {
            ErrorStateView(message: error, retry: retry)
          } else {
            content()
              .dashContentReveal()
          }
        }
        .padding(.horizontal, DashTheme.Spacing.screen)
        .padding(.bottom, 100)
      }
      .scrollDismissesKeyboard(.interactively)
    }
  }
}

extension DashFeatureList where Header == EmptyView {
  init(
    search: Binding<String>? = nil,
    prompt: String = "",
    isLoading: Bool = false,
    error: String? = nil,
    retry: @escaping () -> Void = {},
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.init(
      search: search,
      prompt: prompt,
      isLoading: isLoading,
      error: error,
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
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Text(title)
          .dashTextStyle(.bodyMedium)
          .foregroundStyle(DashTheme.subtle)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      // The action rides an overlay so its 44pt hit target never stretches
      // the header: with or without an action, headers stay the same height.
      .overlay(alignment: .trailing) {
        if let action {
          Group {
            if let actionIcon {
              Button(action: action) {
                SolarIcon(asset: actionIcon, size: 20, color: DashTheme.faint)
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
          .padding(.trailing, 16)
        }
      }

      // The signature two-tone group: a white, hairlined card seated in an
      // elevated frame. Deliberately exempt from the strokeless panel language;
      // inlined rather than reusing DashListCard so the panels can evolve
      // without dragging this along.
      VStack(alignment: .leading, spacing: 0) { content }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DashTheme.base)
        .clipShape(RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous)
            .stroke(DashTheme.line, lineWidth: 0.5)
        }
        .padding(.horizontal, -0.5)
        .padding(.bottom, -0.5)
    }
    .background(DashTheme.elevated)
    .clipShape(RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous)
        .stroke(DashTheme.line, lineWidth: 0.5)
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

  private var tone: Color {
    switch feature {
    case .zones, .registrar, .tunnels, .loadBalancerPools: DashTheme.success
    case .workers, .turnstile, .accessApps, .emailAddresses, .account: DashTheme.brand
    case .analytics, .images, .stream, .secrets: DashTheme.warning
    default: DashTheme.accent
    }
  }

  private var assetName: String {
    style == .duotone ? feature.solarAssetName : feature.solarOutlineAssetName
  }

  private var glyphSize: CGFloat {
    switch size {
    case .list: 24
    case .shortcut: 20
    case .compact: 18
    case .hero: 36
    }
  }

  private var tileSize: CGFloat {
    switch size {
    case .list: 44
    case .shortcut: 34
    case .compact: 28
    case .hero: 56
    }
  }

  var body: some View {
    Image(assetName)
      .resizable()
      .renderingMode(.template)
      .scaledToFit()
      .foregroundStyle(tone)
      .frame(width: glyphSize, height: glyphSize)
      .frame(width: tileSize, height: tileSize)
      .background(tone.opacity(0.15))
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

/// Collapsed header title: compact icon before text.
private struct FeatureInlineNavigationTitle: View {
  let feature: FeatureID
  let title: String

  var body: some View {
    HStack(spacing: 6) {
      CatalogFeatureIcon(feature: feature, size: .compact)
      Text(title)
        .font(.headline)
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
  }
}

struct StatusBadge: View {
  let text: String

  private var colors: (foreground: Color, background: Color) {
    let value = text.lowercased()
    if ["active", "ok", "healthy", "success"].contains(value) {
      return (DashTheme.success, DashTheme.successTint)
    }
    if ["warning", "pending", "degraded"].contains(value) {
      return (DashTheme.warning, DashTheme.warningTint)
    }
    if ["error", "failed", "critical", "inactive"].contains(value) {
      return (DashTheme.danger, DashTheme.dangerTint)
    }
    return (DashTheme.brand, DashTheme.infoTint)
  }

  var body: some View {
    Text(text.capitalized)
      .dashTextStyle(.captionSemibold)
      .foregroundStyle(colors.foreground)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(colors.background, in: Capsule())
  }
}

struct LoadingStateView: View {
  var body: some View {
    DashLoadingRing(color: DashTheme.brand)
      .frame(maxWidth: .infinity, minHeight: DashTheme.Layout.emptyStateMinHeight)
      .listRowInsets(EdgeInsets())
      .listRowSeparator(.hidden)
      .listSectionSeparator(.hidden)
      .listRowBackground(Color.clear)
  }
}

struct ErrorStateView: View {
  let message: String
  let retry: () -> Void
  var body: some View {
    DashEmptyState(
      icon: SolarAsset.danger,
      title: "Couldn’t load",
      message: message,
      actionTitle: "Try again",
      action: retry)
  }
}

struct DashPressButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
      .opacity(configuration.isPressed ? 0.82 : 1)
      .animation(
        reduceMotion ? DashTheme.Motion.reduced : DashTheme.Motion.quick,
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

struct DashListRow: View {
  let title: String
  var subtitle: String?
  var icon: String?
  var iconColor: Color = DashTheme.brand
  var trailing: String?
  var showsChevron = true

  var body: some View {
    HStack(spacing: 12) {
      if let icon {
        SolarIcon(asset: icon, size: 22, color: iconColor)
          .frame(width: 40, height: 40)
          .background(iconColor.opacity(0.15), in: Circle())
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.body)
          .foregroundStyle(DashTheme.text)
          .lineLimit(1)
        if let subtitle {
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(DashTheme.subtle)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 8)
      if let trailing {
        Text(trailing)
          .font(.caption)
          .foregroundStyle(DashTheme.subtle)
      }
      if showsChevron {
        SolarIcon(asset: SolarAsset.chevronRight, size: 16, color: DashTheme.placeholder)
      }
    }
    .padding(.vertical, 12)
    .contentShape(Rectangle())
  }
}

struct DashValueRow: View {
  let title: String
  let value: String
  var subtitle: String?

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 16) {
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
      Spacer(minLength: 12)
      Text(value)
        .dashTextStyle(.supportingMedium)
        .foregroundStyle(DashTheme.subtle)
        .multilineTextAlignment(.trailing)
        .lineLimit(2)
    }
    .padding(.vertical, 14)
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

  var body: some View {
    Button {
      isOn.toggle()
    } label: {
      DashControlSurface(title: title) {
        Toggle("", isOn: $isOn)
          .labelsHidden()
          .tint(DashTheme.brand)
          .allowsHitTesting(false)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(DashPressButtonStyle())
    .disabled(!isEnabled)
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
  let onSelect: (String) -> Void

  var body: some View {
    DashControlSurface(title: title) {
      Menu {
        Picker(title, selection: Binding(get: { value }, set: onSelect)) {
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
    .dashControlCaption(caption)
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
          if index < rows.count - 1 { DashListGroupDivider() }
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
    .padding(.bottom, 12)
  }
}

private struct DashGroupedListModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
      .listStyle(.insetGrouped)
      .contentMargins(.horizontal, DashTheme.Spacing.screen, for: .scrollContent)
      .contentMargins(.top, 0, for: .scrollContent)
      .contentMargins(.bottom, 72, for: .scrollContent)
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
