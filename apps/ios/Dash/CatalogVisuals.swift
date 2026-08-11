import SwiftUI

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
