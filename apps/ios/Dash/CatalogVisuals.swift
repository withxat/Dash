import SwiftUI
import UIKit

enum FeatureResourceCardKind: Hashable, Sendable {
  case workers
  case pages

  var feature: FeatureID {
    switch self {
    case .workers: .workers
    case .pages: .pages
    }
  }
}

/// Render-ready identity shared by the Workers / Pages catalogs, their detail
/// landing seats, and the page compositor's semantic flight. Raw timestamps
/// and status values stay in the value so a return flight can resolve the
/// current locale instead of baking one language into the route entry.
struct FeatureResourceCardContent: Hashable, Sendable {
  enum Metadata: Hashable, Sendable {
    case worker(modifiedOn: String?, createdOn: String?)
    case pages(subdomain: String?, deploymentStatus: String?)
  }

  let kind: FeatureResourceCardKind
  let resourceID: String
  /// Stable API / destination key. Pages keeps its immutable list id in
  /// `resourceID`, while routing and cache lookup use the project name here.
  let routeKey: String
  let title: String
  let metadata: Metadata

  var feature: FeatureID { kind.feature }

  @MainActor
  var subtitle: String? {
    switch metadata {
    case .worker(let modifiedOn, let createdOn):
      if let modifiedOn {
        return Self.timestampText(modifiedOn, prefix: "Updated")
      }
      if let createdOn {
        return Self.timestampText(createdOn, prefix: "Created")
      }
      return nil
    case .pages(let subdomain, _):
      return subdomain
    }
  }

  @MainActor
  var statusToken: StatusToken? {
    guard case .pages(_, let deploymentStatus) = metadata,
      let deploymentStatus, !deploymentStatus.isEmpty
    else { return nil }
    return StatusToken(pagesStatus: deploymentStatus)
  }

  @MainActor
  var accessibilitySummary: String {
    // Lead with the resource itself so a long catalog stays fast to scan in
    // VoiceOver; the repeated feature name remains the second field.
    var parts = [title, feature.title]
    if let subtitle { parts.append(subtitle) }
    if let statusToken {
      parts.append(StatusBadge.accessibilityText(for: statusToken))
    }
    return parts.joined(separator: ", ")
  }

  @MainActor
  private static func timestampText(_ value: String, prefix: String) -> String {
    let displayed: String
    if let date = DashDateFormatting.date(fromISO8601: value) {
      displayed = DashDateFormatting.abbreviatedRelativeTime(
        date,
        relativeTo: .now,
        locale: DashL10n.activeLocale)
    } else {
      displayed = value
    }
    switch prefix {
    case "Updated": return DashL10n.string("Updated \(displayed)")
    case "Created": return DashL10n.string("Created \(displayed)")
    default: return displayed
    }
  }
}

enum FeatureResourceCardLandingRules {
  /// A reversible push keeps the exact tapped snapshot until its flight has
  /// settled. Steady-state detail and return poses prefer the newest cache
  /// snapshot, with the captured card as the no-network fallback.
  static func content(
    transitionActive: Bool,
    captured: FeatureResourceCardContent?,
    latest: FeatureResourceCardContent?,
    fallback: FeatureResourceCardContent
  ) -> FeatureResourceCardContent {
    if transitionActive, let captured { return captured }
    return latest ?? captured ?? fallback
  }
}

/// Surface and ink stops for the full-width resource cards. Workers keeps one
/// deep stop from the brand-blue family so its white copy stays crisp through
/// the grain and enamel sheen in every appearance. Pages retains the adaptive
/// muted catalog color and flips its ink with the interface style.
enum FeatureResourceCardPalette {
  /// Same hue family as `DashTheme.brand`, lowered enough to leave rendering
  /// headroom for the card's brightest grain + top sheen over white copy.
  static let workersFillHex: UInt32 = 0x0041D2

  static func fill(for kind: FeatureResourceCardKind) -> Color {
    switch kind {
    case .workers:
      Color(hex: workersFillHex)
    case .pages:
      FeatureVisualIdentity.catalogColor(for: kind.feature)
    }
  }

  static func foregroundHex(
    for kind: FeatureResourceCardKind,
    interfaceStyle: UIUserInterfaceStyle,
    accessibilityContrast: UIAccessibilityContrast
  ) -> UInt32 {
    let dark = interfaceStyle == .dark
    switch kind {
    case .workers:
      return 0xFFFFFF
    case .pages:
      return dark ? 0x0A0A0A : 0xFFFFFF
    }
  }

  static func foreground(for kind: FeatureResourceCardKind) -> Color {
    Color(
      uiColor: UIColor { traits in
        Self.uiColor(
          hex: foregroundHex(
            for: kind,
            interfaceStyle: traits.userInterfaceStyle,
            accessibilityContrast: traits.accessibilityContrast))
      })
  }

  /// The watermark uses the opposite ink from the copy. If it crosses a glyph
  /// edge, it therefore moves the local fill away from the foreground instead
  /// of silently reducing small-text contrast.
  static func textureHex(
    for kind: FeatureResourceCardKind,
    interfaceStyle: UIUserInterfaceStyle,
    accessibilityContrast: UIAccessibilityContrast
  ) -> UInt32 {
    foregroundHex(
      for: kind,
      interfaceStyle: interfaceStyle,
      accessibilityContrast: accessibilityContrast) == 0xFFFFFF
      ? 0x0A0A0A : 0xFFFFFF
  }

  static func texture(for kind: FeatureResourceCardKind) -> Color {
    Color(
      uiColor: UIColor { traits in
        Self.uiColor(
          hex: textureHex(
            for: kind,
            interfaceStyle: traits.userInterfaceStyle,
            accessibilityContrast: traits.accessibilityContrast))
      })
  }

  private static func uiColor(hex: UInt32) -> UIColor {
    UIColor(
      red: CGFloat((hex >> 16) & 0xFF) / 255,
      green: CGFloat((hex >> 8) & 0xFF) / 255,
      blue: CGFloat(hex & 0xFF) / 255,
      alpha: 1)
  }
}

/// Full-width, low-profile enamel card for account resources whose visual
/// identity belongs to a catalog feature rather than a user-customizable
/// domain color. It deliberately parallels `DomainCardFace` without inheriting
/// domain-only avatar, pin, plan, or color-persistence semantics.
struct FeatureResourceCardFace: View {
  static let minimumHeight: CGFloat = 92
  static let accessibilityMinimumHeight: CGFloat = 116

  let content: FeatureResourceCardContent
  var fillsContainer = false

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  private let cornerRadius: CGFloat = DashTheme.Radius.button
  private var foreground: Color {
    FeatureResourceCardPalette.foreground(for: content.kind)
  }
  private var minimumHeight: CGFloat {
    dynamicTypeSize.isAccessibilitySize
      ? Self.accessibilityMinimumHeight : Self.minimumHeight
  }

  var body: some View {
    cardContent
      .padding(.horizontal, DashTheme.Spacing.card)
      .padding(.vertical, 12)
      .frame(
        maxWidth: .infinity,
        minHeight: fillsContainer ? nil : minimumHeight,
        maxHeight: fillsContainer ? .infinity : nil,
        alignment: .topLeading
      )
      .background {
        DashGrainSurface(
          color: FeatureResourceCardPalette.fill(for: content.kind),
          cornerRadius: cornerRadius,
          intensity: 0.055
        )
        .overlay(alignment: .topTrailing) {
          SolarIcon(
            asset: content.feature.solarFillAssetName,
            size: 88,
            color: FeatureResourceCardPalette.texture(for: content.kind)
          )
          .opacity(0.1)
          .offset(x: 18, y: -20)
          .accessibilityHidden(true)
          .allowsHitTesting(false)
        }
        .clipShape(
          RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
      }
      .dashEmbossed(.pigmented, cornerRadius: cornerRadius)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(content.accessibilitySummary)
  }

  private var cardContent: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: DashTheme.Spacing.compact) {
        SolarIcon(
          asset: content.feature.solarFillAssetName,
          size: 22,
          color: foreground
        )
        .accessibilityHidden(true)
        Spacer(minLength: 0)
        if !dynamicTypeSize.isAccessibilitySize, let status = content.statusToken {
          statusLabel(status)
        }
      }

      VStack(alignment: .leading, spacing: 2) {
        Text(content.title)
          .dashTextStyle(.bodySemibold)
          .foregroundStyle(foreground)
          .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
          .minimumScaleFactor(0.85)
        if let subtitle = content.subtitle {
          Text(subtitle)
            .dashTextStyle(content.kind == .pages ? .code : .footnote)
            .foregroundStyle(foreground)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if dynamicTypeSize.isAccessibilitySize, let status = content.statusToken {
        statusLabel(status)
      }
    }
    .frame(
      maxWidth: .infinity,
      maxHeight: fillsContainer ? .infinity : nil,
      alignment: .topLeading)
  }

  private func statusLabel(_ token: StatusToken) -> some View {
    HStack(spacing: 4) {
      Image(systemName: statusSymbol(for: token))
        .font(.system(size: 12, weight: .semibold))
      Text(token.label)
        .dashTextStyle(.captionSemibold)
        .lineLimit(1)
    }
    .foregroundStyle(foreground)
    .fixedSize(horizontal: true, vertical: false)
    .accessibilityHidden(true)
  }

  private func statusSymbol(for token: StatusToken) -> String {
    switch token {
    case .success: "checkmark.circle.fill"
    case .failed: "exclamationmark.circle.fill"
    case .inProgress: "clock.fill"
    case .canceled, .skipped: "xmark.circle.fill"
    case .unknown: "questionmark.circle.fill"
    default: "circle.fill"
    }
  }
}

enum FeatureVisualIdentity {
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
