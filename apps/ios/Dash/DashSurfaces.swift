import CloudflareAPI
import GradientAvatars
import SwiftDitherKit
import SwiftUI
import UIKit

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
  /// `.shadow` stacks or solid gray strokes on elevated surfaces.
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

/// A flat 1pt ring that defines an elevated surface's edge — `DashTheme.separator`
/// (pure black/white at token opacity), never a tinted solid. Drop shadows were
/// removed project-wide, so `.border` and `.raised` render identically.
private struct DashShadowModifier<S: InsettableShape>: ViewModifier {
  let style: DashTheme.Shadow
  let shape: S

  func body(content: Content) -> some View {
    content.overlay {
      shape.strokeBorder(DashTheme.separator, lineWidth: 1)
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
///
/// This is one half of a deliberate split, so a titled block of section content
/// has exactly one right answer: **a chart or a metric is a glass card with its
/// own `footnoteSemibold` heading inside; read-only label/value fields are a
/// `DashInfoGroup`** on the two-tone band. Do not move chart cards onto the
/// band — Watchtower's reorderable metric cards could not follow, and the
/// analytics screens would end up split across two frames.
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

extension View {
  /// One invariant for the prominent value above every chart. The primary
  /// figure keeps its Dynamic Type size; a neighboring trend label yields
  /// horizontal space first instead of shrinking this value per card.
  func dashChartPrimaryMetricValue() -> some View {
    dashTextStyle(.emptyTitle)
      .monospacedDigit()
      .foregroundStyle(DashTheme.strong)
      .lineLimit(1)
      .allowsTightening(true)
      .layoutPriority(1)
  }
}

/// A chart in its collapsed state: a title band over a sparkline flush to the
/// card's bottom edge, on the same embossed enamel as `DashGlassCard`. Sized so
/// two of them share one row (Watchtower's collapsed metric cards are the same
/// shape).
///
/// It composes its own panel rather than nesting in `DashGlassCard` because the
/// plot has to reach that bottom edge, which a uniformly padded card cannot
/// allow. The plot is summary-only — no axes, legend, tooltip, or scrubbing —
/// so the totals belong to the metric panel above it and the interactive chart
/// belongs to the pushed detail behind `detail`.
struct DashCollapsedChartCard: View {
  /// Catalog key, localized here.
  let title: String
  /// When set, the card matches Watchtower's collapsed metric chrome — two
  /// reserved title lines over the total and trend — instead of a title-only
  /// strip above the sparkline.
  var summaryValue: String? = nil
  /// Catalog key naming the window the total covers ("Last 24 hours").
  ///
  /// For a card that stands alone: a total needs its window stated, and a lone
  /// card has no totals panel or screen-level range control above it to say so.
  /// Paired half-width cards must leave it nil — one card carrying a caption
  /// beside one that does not would break their shared height.
  var caption: String? = nil
  var trend: DashChartTrend? = nil
  let data: [DitherDatum]
  let series: [DitherSeries]
  /// From `CollapsedDitherTrendSeries`, so an all-zero series keeps its short
  /// band instead of expanding to the full plot height.
  var valueCeiling: Double?
  /// Already-localized sentence describing the series; the card is one
  /// accessibility element reading title then this.
  let accessibilitySummary: String
  var detail: DashChartDetail?
  var detailAccessibilityIdentifier: String?
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous)
  }

  private var showsMetricHeader: Bool {
    summaryValue != nil || trend != nil
  }

  /// The caption is deliberately absent: `accessibilitySummary` already names
  /// the window in a sentence, and reading both makes VoiceOver state the range
  /// twice in a row.
  private var combinedAccessibilityLabel: String {
    let change =
      trend?.formattedPercentage.map {
        " \(DashL10n.ui("Change")): \($0)."
      } ?? ""
    if let summaryValue {
      return "\(DashL10n.ui(title)), \(summaryValue).\(change) \(accessibilitySummary)"
    }
    return "\(DashL10n.ui(title)).\(change) \(accessibilitySummary)"
  }

  var body: some View {
    Group {
      if let detail {
        DashNavigationSource(destination: .chartDetail(detail)) { navigate in
          Button(action: navigate) {
            cardContent
          }
          .buttonStyle(DashSurfaceButtonStyle())
          .accessibilityHint("Shows chart details")
          .accessibilityIdentifier(
            detailAccessibilityIdentifier ?? "collapsed-chart-detail")
        }
      } else {
        cardContent
      }
    }
  }

  private var cardContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      sparkline
        .frame(maxWidth: .infinity)
        .frame(height: DashTheme.DitherChart.collapsedHeight(dynamicTypeSize: dynamicTypeSize))
        // Only the bottom corners take the panel radius, so the plot does not
        // square off the embossed fill.
        .clipShape(
          UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: DashTheme.Radius.card,
            bottomTrailingRadius: DashTheme.Radius.card,
            topTrailingRadius: 0,
            style: .continuous)
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
    // A resolved `String`, not an interpolated literal: the literal overload is
    // `LocalizedStringKey`, and both halves are already localized.
    .accessibilityLabel(combinedAccessibilityLabel)
    .background(DashTheme.homeCardSurface, in: shape)
    .dashEmbossChrome(shape: shape)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: showsMetricHeader ? 4 : 0) {
      Text(DashL10n.ui(title))
        .dashTextStyle(.footnoteSemibold)
        .foregroundStyle(DashTheme.subtle)
        // Watchtower reserves two lines so paired cards share one height when
        // a title wraps; the title-only Worker pose kept one line before the
        // metric header landed here — same rule once a total is present.
        .lineLimit(showsMetricHeader ? 2 : 1, reservesSpace: true)
        .minimumScaleFactor(showsMetricHeader ? 0.85 : 0.7)
      if showsMetricHeader {
        HStack(alignment: .center, spacing: 6) {
          if let summaryValue {
            Text(verbatim: summaryValue)
              .dashChartPrimaryMetricValue()
          }
          DashCollapsedChartTrendLabel(trend: trend)
          Spacer(minLength: 4)
        }
      }
      if let caption {
        Text(DashL10n.ui(caption))
          .dashTextStyle(.caption)
          .foregroundStyle(DashTheme.subtle)
          .lineLimit(1)
      }
    }
    .padding(.horizontal, DashTheme.Spacing.card)
    .padding(.top, DashTheme.Spacing.card)
    .padding(.bottom, 8)
  }

  private var sparkline: some View {
    DashAreaChart(
      data: data,
      series: series,
      options: DashTheme.DitherChart.sparklineOptions(
        accessibility: DitherAccessibility(
          title: DashL10n.ui(title),
          summary: accessibilitySummary),
        valueCeiling: valueCeiling),
      highlighted: false,
      selection: nil)
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

/// Names the category selected from a chart legend and provides the one escape
/// hatch back to the complete data set. The legend chip itself shows selection
/// visually; this strip states the filtering effect in words.
struct DashChartFilterStrip: View {
  let label: String
  let countText: String
  let color: DitherColor
  let clearAccessibilityLabel: String
  let clearAccessibilityIdentifier: String
  let clear: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(Color(red: color.red, green: color.green, blue: color.blue))
        .frame(width: 8, height: 8)
      Text(verbatim: label)
        .dashTextStyle(.captionSemibold)
        .foregroundStyle(DashTheme.strong)
      Text(verbatim: countText)
        .dashTextStyle(.caption)
        .monospacedDigit()
        .foregroundStyle(DashTheme.subtle)
      Spacer(minLength: 8)
      Button(DashL10n.string("Show all"), action: clear)
        .dashTextStyle(.captionSemibold)
        .foregroundStyle(DashTheme.brand)
        .buttonStyle(DashPressButtonStyle())
        .frame(minHeight: DashTheme.Layout.minimumHitTarget)
        .dashHeaderActionHitTarget()
        .accessibilityLabel(clearAccessibilityLabel)
        .accessibilityIdentifier(clearAccessibilityIdentifier)
    }
    .lineLimit(1)
    .frame(minHeight: DashTheme.Layout.minimumHitTarget)
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
    .frame(maxWidth: .infinity, minHeight: 96, maxHeight: .infinity)
    .background(
      DashTheme.homeCardSurface,
      in: RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous)
    )
    .dashEmbossed()
  }
}

/// Opens a destination on the enclosing tab's navigation stack.
struct DashListGroupLink<Label: View>: View {
  let value: Destination
  var hero: DashNavigationHero? = nil
  var onNavigate: (() -> Void)?
  @ViewBuilder let label: () -> Label

  var body: some View {
    DestinationLink(destination: value, hero: hero, onNavigate: onNavigate, label: label)
  }
}

struct DashListGroupDivider: View {
  /// A filled rule, not `Divider()`: the system divider paints its own line
  /// under the overlay, so a translucent token stacked on top read darker than
  /// the same token anywhere else. Same 1pt edge `DashTextTabs` draws.
  var body: some View {
    Rectangle()
      .fill(DashTheme.panelLine)
      .frame(height: 1)
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
  ForEach(items) { item in
    if inset {
      row(item)
        .dashListCardInset()
    } else {
      row(item)
    }
  }
}

/// `DashTwoToneListGroup` (Home's Shortcuts / Recently used, and every
/// `DashInfoGroup`) split into lazily emitted pieces: a header band and rows
/// that each paint their own slice of the plate.
///
/// The component itself owns an eager stack, which is right for the handful of
/// fields an info group holds. A chart's exact-value table is the same frame
/// over a few hundred rows — worker analytics alone is 288 five-minute buckets
/// — so it emits header and rows straight into `DashFeatureList`'s `LazyVStack`
/// instead, and only onscreen rows are built. Pair the two: the header rounds
/// the top of the plate and the last row rounds the bottom.
@MainActor
@ViewBuilder
func dashTwoToneGroupHeader(title: String) -> some View {
  DashListGroupHeader(title: DashL10n.ui(title))
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(DashTheme.listGroupHeaderSurface)
    .clipShape(
      .rect(
        topLeadingRadius: DashTheme.Radius.card,
        topTrailingRadius: DashTheme.Radius.card,
        style: .continuous))
}

/// Rows for `dashTwoToneGroupHeader`. Insets and radii mirror
/// `DashTwoToneListGroup` exactly — 14pt of row padding over the 2pt plate
/// margin lands rows on the header title's 16, and the inner card's radius is
/// one step per point of inset so the two shapes stay concentric.
@MainActor
@ViewBuilder
func dashTwoToneCardRows<Item: Identifiable, Row: View>(
  items: [Item],
  @ViewBuilder row: @escaping (Item) -> Row
) -> some View {
  let lastIndex = items.count - 1
  ForEach(Array(items.enumerated()), id: \.element.id) { entry in
    let isFirst = entry.offset == 0
    let isLast = entry.offset == lastIndex
    row(entry.element)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 14)
      .background(DashTheme.homeCardSurface)
      .clipShape(
        .rect(
          topLeadingRadius: isFirst ? DashTheme.Radius.card - 2 : 0,
          bottomLeadingRadius: isLast ? DashTheme.Radius.card - 2 : 0,
          bottomTrailingRadius: isLast ? DashTheme.Radius.card - 2 : 0,
          topTrailingRadius: isFirst ? DashTheme.Radius.card - 2 : 0,
          style: .continuous)
      )
      .padding(.horizontal, 2)
      .padding(.bottom, isLast ? 2 : 0)
      .background(DashTheme.listGroupHeaderSurface)
      .clipShape(
        .rect(
          bottomLeadingRadius: isLast ? DashTheme.Radius.card : 0,
          bottomTrailingRadius: isLast ? DashTheme.Radius.card : 0,
          style: .continuous))
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
    // `DashPageChromeHost` keeps fixed chrome (text tabs) above the header
    // frost — same stacking as the nav title — and sizes the scroll slot to
    // the remaining height so the list scrolls instead of clipping.
    DashPageChromeHost(chrome: chrome) {
      content()
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
/// - **Cold** (`loading`): no cached primary payload → one feature body in
///   `DashBodyMode.placeholder` (same structure as live; redacted / geometric
///   stand-ins). Never paint an empty shell with “Updating…”.
/// - **Warm** (`content` + `refreshing`): body stays in `.live` with the inline
///   “Updating…” strip (and optional error banner). Refresh never remounts
///   placeholder mode.
/// - **Empty settled** (`empty`): zero items after a successful load → the same
///   placeholder body stays mounted and empty copy lands on the cold wash
///   (same mount as failure — never swap in a bare `DashEmptyState` that tears
///   the bars down). Nested empties inside an already-loaded detail stay in
///   live content.
/// - **Handoff**: the first cold → live transition animates with
///   `DashBodyTransition` — surplus placeholder slots recede (scale 0.97 +
///   blur + fade), extra live slots insert; index-aligned slots replace in
///   place. Navigation push and warm refresh must not add a second reveal.
/// - **Section cold** (not this enum): secondary fetches inside an already-loaded
///   detail (build log, traffic chart, preview) may use a local ring + short copy.
///
/// Cache-first: when `hasContent` is true, refresh never returns to Cold.
enum DashListPhase: Equatable {
  case loading
  case fullScreenError(String)
  case empty
  case content(banner: String?, refreshing: Bool)

  static func resolve(isLoading: Bool, error: String?, hasContent: Bool) -> DashListPhase {
    if hasContent {
      return .content(banner: error, refreshing: isLoading)
    }
    if isLoading { return .loading }
    if let error { return .fullScreenError(error) }
    // Settled with nothing to show. Call sites that always paint chrome
    // (chart detail snapshots, settings screens with alerts/nameservers,
    // dual-fetch pages where one half can be empty) must pass
    // `hasContent: true` / `hasPresentedContent` after settle — the default
    // `false` leaves the skeleton up forever, with or without `empty:`.
    return .empty
  }

  /// Placeholder body for cold / empty / failure; live body once `hasContent`.
  var bodyMode: DashBodyMode {
    switch self {
    case .loading, .fullScreenError, .empty: return .placeholder
    case .content: return .live
    }
  }
}

/// Paint mode for a feature body's single structure tree.
enum DashBodyMode: Equatable, Sendable {
  /// Cold / empty / failure — same layout as live, non-interactive stand-ins.
  case placeholder
  /// Settled primary payload — real values and controls.
  case live

  var isPlaceholder: Bool { self == .placeholder }
}

/// Soft blur stand-in for body-slot removal (same device as tray `.dashMorph`).
private struct DashBodyBlurModifier: ViewModifier, Animatable {
  var radius: CGFloat

  nonisolated var animatableData: CGFloat {
    get { radius }
    set { radius = newValue }
  }

  func body(content: Content) -> some View {
    content.blur(radius: radius)
  }
}

/// Slot insert/remove transitions for placeholder ↔ live count deltas.
enum DashBodyTransition {
  /// Surplus placeholders recede in place (scale to 0.97 + blur + fade); new
  /// live slots fade in. No slide — that fought the navigation push and read
  /// as an upward exit. Isolation-free so `dashModeListRows` can apply it from
  /// a `@ViewBuilder` free function.
  nonisolated static func content(_ reduceMotion: Bool) -> AnyTransition {
    if reduceMotion { return .opacity }
    let dissolve = AnyTransition.opacity.combined(
      with: .modifier(
        active: DashBodyBlurModifier(radius: 3),
        identity: DashBodyBlurModifier(radius: 0)))
    return .asymmetric(
      insertion: .opacity,
      removal: dissolve.combined(with: .scale(scale: 0.97))
    )
  }

  /// Animation applied when `DashBodyMode` flips cold → live once. Slower than
  /// `Motion.morph` so the scale/blur/fade on surplus slots can read.
  @MainActor
  static var handoff: Animation {
    UIAccessibility.isReduceMotionEnabled
      ? DashTheme.Motion.reduced
      : Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.48)
  }
}

/// Reserved placeholder counts for fuller cold paint (over-reserve; extras exit).
enum DashBodyPlaceholderDepth {
  static let listRows = 4
  static let domainCards = 6
  static let infoRows = 4
}

/// Settled-empty copy for a `DashFeatureList` — lands on the same placeholder
/// body + wash as a cold failure, with the call site's mark and an optional CTA.
struct DashFeatureEmpty {
  var icon: String
  var title: String
  var message: String
  var actionTitle: String? = nil
  var action: (() -> Void)? = nil
}

/// Shared feature list: loading/error/empty slots, grouped list chrome.
///
/// One `@ViewBuilder` body receives `DashBodyMode` so cold and live share
/// structure. Settled empty and cold failure keep that same body in
/// `.placeholder` under the wash. The first flip to `.live` uses
/// `DashBodyTransition.handoff`; warm refresh stays on `.live`.
struct DashFeatureList<Header: View, Content: View>: View {
  var isLoading: Bool = false
  var error: String?
  /// Whether the content phase may paint. Defaults to `false` for cold lists;
  /// snapshot screens and details whose body mounts chrome independent of the
  /// primary rows must set this once settled (`true` or `hasPresentedContent`),
  /// never derive it only from a subset of optional rows.
  var hasContent: Bool = false
  /// Primary-list empty (zero items after a successful load). Detail screens
  /// that never settle empty may omit it; the empty phase then shows the
  /// placeholder body alone until a call site supplies copy — and forever if
  /// `hasContent` was left false by mistake.
  var empty: DashFeatureEmpty? = nil
  var retry: () -> Void
  @ViewBuilder var header: () -> Header
  @ViewBuilder var content: (DashBodyMode) -> Content
  @Environment(AppModel.self) private var model
  @Environment(\.featureRequiredScopes) private var featureRequiredScopes
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(
    isLoading: Bool = false,
    error: String? = nil,
    hasContent: Bool = false,
    empty: DashFeatureEmpty? = nil,
    retry: @escaping () -> Void = {},
    @ViewBuilder header: @escaping () -> Header,
    @ViewBuilder content: @escaping (DashBodyMode) -> Content
  ) {
    self.isLoading = isLoading
    self.error = error
    self.hasContent = hasContent
    self.empty = empty
    self.retry = retry
    self.header = header
    self.content = content
  }

  private var phase: DashListPhase {
    DashListPhase.resolve(isLoading: isLoading, error: error, hasContent: hasContent)
  }

  private var bodyMode: DashBodyMode { phase.bodyMode }

  var body: some View {
    DashFeatureScreen(chrome: header) {
      ScrollView {
        // Spacing must stay 0: `dashListCardRows` flattens its ForEach into this
        // stack so rows stay lazy. Section spacing here would gap every row
        // (Workers/Pages looked sparse vs Resources' DashListGroup VStack(0)).
        // Pad chrome blocks (Updating… / error banner) explicitly instead.
        LazyVStack(spacing: 0) {
          if case .content(let banner, let refreshing) = phase {
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
          }

          // One body identity across loading → failure/empty → live. Mode flips
          // drive slot replace / recede / append; the wash only veils
          // placeholder. Warm refresh never remounts `.placeholder`.
          content(bodyMode)
            .dashColdOverlay(copy: coldOverlayCopy, extent: .scrollViewport)
            .dashFailureRemovalTransition()
        }
        .animation(
          reduceMotion ? DashTheme.Motion.reduced : DashBodyTransition.handoff,
          value: bodyMode
        )
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

  private var coldOverlayCopy: DashColdOverlayCopy? {
    switch phase {
    case .loading:
      return nil
    case .fullScreenError:
      guard let message = coldFailureMessage else { return nil }
      return DashColdOverlayCopy(
        icon: SolarAsset.Content.danger,
        title: "Couldn’t load",
        message: message,
        actionTitle: coldFailureActionTitle,
        action: coldFailureAction
      )
    case .empty:
      guard let empty else { return nil }
      return DashColdOverlayCopy(
        icon: empty.icon,
        title: empty.title,
        message: empty.message,
        actionTitle: empty.actionTitle,
        action: empty.action
      )
    case .content:
      return nil
    }
  }

  private var coldFailurePresentation: DashFailurePresentation? {
    error.map(DashFailurePresentation.from(message:))
  }

  private var coldFailureActionTitle: String {
    coldFailurePresentation?.action.title ?? "Try again"
  }

  private var coldFailureMessage: String? {
    guard let presentation = coldFailurePresentation else { return nil }
    if presentation.action == .grantAccess, !model.isDemoSession {
      return [
        presentation.message,
        DashL10n.string(
          "Dash requests all permissions used by its current features in one authorization."
        ),
      ].joined(separator: " ")
    }
    return presentation.message
  }

  private func coldFailureAction() {
    switch coldFailurePresentation?.action {
    case .signInAgain:
      Task { await model.signOut() }
    case .grantAccess:
      model.requestAccess(
        to: featureRequiredScopes.isEmpty
          ? DashAuthorizationScopes.initialReadOnly : featureRequiredScopes)
    case .tryAgain, .none:
      retry()
    }
  }

  @ViewBuilder
  private func failureBanner(_ message: String) -> some View {
    let presentation = DashFailurePresentation.from(message: message)
    VStack(alignment: .leading, spacing: DashTheme.Spacing.compact) {
      DashNotice(kind: .error, message: presentation.message)
      if presentation.action == .grantAccess {
        DashAuthorizationDisclosure()
      }
      DashSecondaryPillButton(title: presentation.action.title) {
        switch presentation.action {
        case .signInAgain:
          Task { await model.signOut() }
        case .grantAccess:
          model.requestAccess(
            to: featureRequiredScopes.isEmpty
              ? DashAuthorizationScopes.initialReadOnly : featureRequiredScopes)
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
    empty: DashFeatureEmpty? = nil,
    retry: @escaping () -> Void = {},
    @ViewBuilder content: @escaping (DashBodyMode) -> Content
  ) {
    self.init(
      isLoading: isLoading,
      error: error,
      hasContent: hasContent,
      empty: empty,
      retry: retry,
      header: { EmptyView() },
      content: content
    )
  }
}

/// Redact + pulse + freeze interaction while a shared body is in placeholder mode.
extension View {
  @ViewBuilder
  func dashBodyPlaceholder(_ active: Bool) -> some View {
    if active {
      self
        .redacted(reason: .placeholder)
        .dashSkeletonPulse()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    } else {
      self
    }
  }

  nonisolated func dashBodySlot(reduceMotion: Bool) -> some View {
    transition(DashBodyTransition.content(reduceMotion))
  }
}

/// Index-stable catalog rows: placeholder count → live count with receding
/// surplus slots (scale + blur + fade) and in-place replace for overlap.
@MainActor
@ViewBuilder
func dashModeListRows<Item: Identifiable, Row: View>(
  mode: DashBodyMode,
  items: [Item],
  placeholderRows: Int = DashBodyPlaceholderDepth.listRows,
  reduceMotion: Bool,
  inset: Bool = true,
  @ViewBuilder row: @escaping (Item) -> Row
) -> some View {
  let count = mode.isPlaceholder ? max(placeholderRows, 1) : items.count
  ForEach(0..<count, id: \.self) { index in
    Group {
      if mode.isPlaceholder {
        DashListRowPlaceholder()
      } else {
        row(items[index])
      }
    }
    .modifier(DashListCardInsetModifier(enabled: inset))
    .dashBodySlot(reduceMotion: reduceMotion)
  }
}

private struct DashListCardInsetModifier: ViewModifier {
  var enabled: Bool

  func body(content: Content) -> some View {
    if enabled {
      content.dashListCardInset()
    } else {
      content
    }
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

/// Two-tone group (the short-lived `WatchtowerListGroup` framing): the title
/// rides an elevated plate, and the rows sit in their own rounded card inset
/// 2pt inside it.
///
/// Nothing is stroked. That 2pt of plate showing along the card's sides and
/// bottom *is* the border — the same band colour that runs behind the header,
/// so the frame closes on all four sides instead of being a ring painted over
/// the group. Fill does the work a `strokeBorder` used to: light gets a tint
/// band around a white card, dark a lighter band around the tint card.
///
/// Home's Shortcuts and Recently used cards and every pushed screen's info
/// group (`DashInfoGroup`); plain `DashListGroup` stays bandless.
struct DashTwoToneListGroup<Content: View>: View {
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
        // 14 + the 2pt inset below = rows land on the header title's 16.
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DashTheme.homeCardSurface)
        // Concentric with the plate: one radius step per point of inset.
        .clipShape(
          RoundedRectangle(cornerRadius: DashTheme.Radius.card - 2, style: .continuous)
        )
        .padding(.horizontal, 2)
        .padding(.bottom, 2)
    }
    .background(DashTheme.listGroupHeaderSurface)
    .clipShape(RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous))
  }
}

// MARK: - Info groups

/// Load state of one *section* inside an already-loaded detail screen — the
/// “section cold” slot the list contract leaves open (`DashListPhase` still owns
/// the screen's primary payload, and there is still no fifth full-screen
/// spinner).
///
/// A section that fetches on its own has four outcomes, not two, and the two
/// that used to be conflated are the ones that bite: a lookup that comes back
/// *empty* is a settled answer the call site may legitimately hide, while a
/// lookup that *failed* must stay on screen and say so. Deciding that with a
/// bare optional is what let the zone registration card fail silently.
enum DashSectionPhase: Equatable {
  case loading
  case content
  case failed(String)

  var failureMessage: String? {
    if case .failed(let message) = self { return message }
    return nil
  }
}

/// A titled group of read-only information rows, in the same two-tone frame as
/// Home's Shortcuts and Recently used: title on the header band, rows in the
/// card below it.
///
/// This is the shared home for the label/value blocks that pushed screens used
/// to hand-roll — a `DashCard` with a `footnoteSemibold` heading *inside* it,
/// one per screen, each with slightly different insets and no relationship to
/// the group headers around it.
///
/// It also owns the section's load states, because reserving the space is the
/// whole point: `.loading` paints placeholder rows the arriving data lands on
/// instead of shoving the rest of the screen down when it appears, and
/// `.failed` veils the message over those same placeholders rather than
/// swapping them out (see `DashSectionFailureVeil`).
///
/// Rows go in an eager stack like `DashListGroup`'s — info groups are bounded
/// (a handful of fields, two name servers). Never put an unbounded `ForEach`
/// in one.
struct DashInfoGroup<Content: View>: View {
  let title: String
  var phase: DashSectionPhase = .content
  /// How many placeholder rows the cold and failed states paint. Set it to the
  /// number of fields the section usually settles on, so the swap is a
  /// cross-dissolve in place rather than a reflow.
  var placeholderRows: Int = 3
  var retry: (() -> Void)?
  /// Optional trailing header control — same chrome as Home Shortcuts' Edit
  /// (`DashListGroupHeader` icon action on the two-tone band).
  var actionTitle: String? = nil
  var actionIcon: String? = nil
  var action: (() -> Void)? = nil
  @ViewBuilder var content: () -> Content

  private var showsContent: Bool {
    if case .content = phase { return true }
    return false
  }

  private var failureMessage: String? {
    if case .failed(let message) = phase { return message }
    return nil
  }

  var body: some View {
    DashTwoToneListGroup(
      title: title,
      actionTitle: actionTitle,
      actionIcon: actionIcon,
      action: action
    ) {
      ZStack {
        Group {
          if showsContent {
            // `content()` may be a multi-row ViewBuilder product; keep it in
            // one stack so the ZStack treats the rows as a single layer.
            VStack(alignment: .leading, spacing: 0) {
              content()
            }
            .transition(.opacity)
          } else {
            DashInfoRowPlaceholders(rows: placeholderRows)
              // Failure freezes the breath under the veil (same contract as
              // `dashColdOverlay`).
              .environment(\.dashSkeletonPulseActive, failureMessage == nil)
              .allowsHitTesting(false)
              .accessibilityHidden(failureMessage != nil)
              .transition(.opacity)
          }
        }
        .animation(DashTheme.Motion.content, value: showsContent)

        if let failureMessage {
          // The placeholders are frozen chrome from here on — hit testing and
          // VoiceOver both belong to the message, so nothing announces
          // “Loading” after a failure. The ZStack takes whichever layer is
          // taller, so a long message grows the section instead of clipping.
          DashSectionFailureVeil(
            message: failureMessage,
            covers: CGFloat(max(placeholderRows, 1)) * DashTheme.Layout.minimumHitTarget,
            retry: retry
          )
          .dashFailureRemovalTransition()
        }
      }
    }
  }
}

/// One label/value pair inside a `DashInfoGroup`. Label leading, value trailing
/// — the phone-native spec-sheet row; at accessibility sizes (and for
/// label-less rows such as name servers) the pair goes leading-aligned so
/// neither side truncates.
///
/// The trailing slot also takes an `accessory`, so a field whose value is a
/// badge or a link stays one of these rows instead of forking into a bespoke
/// `HStack` — a status shown as text beside a status shown as a capsule is how
/// two renderings of the same token start to disagree.
///
/// Labels are Dash's own copy and localize here, matching `DashDetailTray`'s
/// field rows. Values are Cloudflare's data — hostnames, registrars, dates
/// already formatted by the call site — and stay verbatim.
struct DashInfoRow<Accessory: View>: View {
  let label: String?
  let value: String?
  var mono = false
  @ViewBuilder let accessory: () -> Accessory
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  init(
    _ label: String? = nil,
    value: String? = nil,
    mono: Bool = false,
    @ViewBuilder accessory: @escaping () -> Accessory
  ) {
    self.label = label
    self.value = value
    self.mono = mono
    self.accessory = accessory
  }

  private var isAccessibilitySize: Bool { dynamicTypeSize.isAccessibilitySize }

  var body: some View {
    Group {
      if let label, !isAccessibilitySize {
        // Centered rather than baseline-aligned: the trailing slot may hold a
        // badge, and a capsule has no text baseline to hang off.
        HStack(spacing: 12) {
          labelText(label)
          Spacer(minLength: 0)
          trailing(.trailing)
        }
      } else {
        VStack(alignment: .leading, spacing: 4) {
          if let label { labelText(label) }
          trailing(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    // Row height floor shared with `DashListRow` (and with
    // `DashInfoRowPlaceholders`), so an info group keeps the same rhythm as the
    // Home cards it borrows its frame from.
    .frame(minHeight: DashTheme.Layout.minimumHitTarget)
    .accessibilityElement(children: .combine)
  }

  private func labelText(_ label: String) -> some View {
    Text(DashL10n.ui(label))
      .dashTextStyle(.supporting)
      .foregroundStyle(DashTheme.subtle)
      .lineLimit(isAccessibilitySize ? nil : 1)
      .layoutPriority(0)
  }

  private func trailing(_ alignment: TextAlignment) -> some View {
    HStack(spacing: 8) {
      if let value {
        Text(value)
          .dashTextStyle(mono ? .code : .supporting)
          .foregroundStyle(DashTheme.text)
          .multilineTextAlignment(alignment)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
      accessory()
    }
    .layoutPriority(1)
  }
}

extension DashInfoRow where Accessory == EmptyView {
  init(_ label: String? = nil, value: String, mono: Bool = false) {
    self.init(label, value: value, mono: mono, accessory: { EmptyView() })
  }
}

/// The shape an info group's data will take, painted while it loads. Bar
/// heights and the row floor match `DashInfoRow` so the arriving values land
/// where the placeholder was. Also the stock placeholder for any self-fetching
/// section that veils failures with `dashSectionFailure` and has no
/// content-shaped skeleton of its own.
struct DashInfoRowPlaceholders: View {
  let rows: Int

  var body: some View {
    VStack(spacing: 0) {
      ForEach(0..<max(rows, 1), id: \.self) { index in
        HStack(spacing: 12) {
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .dashSkeletonFill(DashSkeletonStyle.strong)
            .frame(width: 64, height: 12)
          Spacer(minLength: 0)
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .dashSkeletonFill(DashSkeletonStyle.soft)
            .frame(width: index.isMultiple(of: 2) ? 132 : 100, height: 12)
        }
        .frame(minHeight: DashTheme.Layout.minimumHitTarget)
      }
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Loading")
  }
}

/// Section-scale counterpart to `dashColdFailure`: the placeholder rows keep
/// their ground and the message lands on a veil over them.
///
/// The veil is the card's own fill at 80%, so it dissolves into the surface it
/// covers and the placeholder still reads faintly through — the section shows
/// the shape a successful retry will fill, and the failure costs the screen no
/// layout shift. The copy is compact on purpose: `DashColdFailureCopy`'s 72pt
/// mark and title are sized for a screenful of skeleton and would tower over a
/// four-row group.
private struct DashSectionFailureVeil: View {
  let message: String
  /// Height of the placeholder block this veil has to cover. `.background` is
  /// layout-neutral, so overhanging the fill by that much in both directions
  /// veils the whole section whichever of the two ends up taller — the copy
  /// never has to stretch to fill it. The enclosing card clips the overhang, so
  /// it can never reach the header band.
  let covers: CGFloat
  /// Catalog key (or an already-resolved presentation title) for the action —
  /// `DashFailurePresentation` failures recover with Grant access / Sign in
  /// again, not only Try again.
  var actionTitle: String = "Try again"
  let retry: (() -> Void)?

  @State private var revealed = false

  var body: some View {
    VStack(spacing: DashTheme.Spacing.compact) {
      SolarIcon(asset: SolarAsset.Content.danger, size: 22, color: DashTheme.subtle)
        .dashReveal(2, shown: revealed)
      Text(DashL10n.ui(message))
        .dashTextStyle(.footnote)
        .foregroundStyle(DashTheme.subtle)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .dashReveal(1, shown: revealed)
      if let retry {
        Button(DashL10n.ui(actionTitle), action: retry)
          .dashTextStyle(.supportingSemibold)
          .foregroundStyle(DashTheme.brand)
          .buttonStyle(DashPressButtonStyle())
          .dashCompactHitTarget()
          .dashReveal(0, shown: revealed)
      }
    }
    .padding(.vertical, DashTheme.Spacing.card)
    .frame(maxWidth: .infinity)
    .background {
      DashTheme.homeCardSurface
        .opacity(0.8)
        .padding(.vertical, -covers)
    }
    .accessibilityElement(children: .contain)
    .onAppear {
      DispatchQueue.main.async { revealed = true }
    }
  }
}

extension View {
  /// Section-scale failure for sections that are not `DashInfoGroup`s — chart
  /// cards, log cards, deployment rows. Apply it to the section's own
  /// *placeholder* (the shape its loading state paints) and the failure lands
  /// on the card-fill veil over it, exactly as `DashInfoGroup.phase == .failed`
  /// does for info rows: no swap, no layout shift, the section keeps showing
  /// the shape a successful retry will fill.
  ///
  /// The placeholder becomes frozen chrome while the message is up — hit
  /// testing and VoiceOver both belong to the veil, so nothing announces
  /// "Loading" after a failure. Apply the modifier *inside* the section's
  /// card, to its content: the veil overhangs the placeholder's box so
  /// whichever layer is taller stays covered, and the modifier clips its own
  /// overhang so a bare call site can't leak fill over its neighbors.
  ///
  /// `actionTitle` defaults to Try again; a `DashFailurePresentation` failure
  /// passes its own action title (Grant access, Sign in again) with the matching
  /// closure.
  func dashSectionFailure(
    _ message: String?,
    actionTitle: String = "Try again",
    retry: (() -> Void)? = nil
  ) -> some View {
    modifier(
      DashSectionFailureModifier(
        message: message, actionTitle: actionTitle, retry: retry))
  }
}

private struct DashSectionFailureModifier: ViewModifier {
  let message: String?
  let actionTitle: String
  let retry: (() -> Void)?
  /// Measured height of the placeholder, feeding the veil's overhang the same
  /// way `DashInfoGroup` derives `covers` from its row count.
  @State private var placeholderHeight: CGFloat = 0

  func body(content: Content) -> some View {
    ZStack {
      content
        .environment(\.dashSkeletonPulseActive, message == nil)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
          placeholderHeight = height
        }
        .allowsHitTesting(message == nil)
        .accessibilityHidden(message != nil)

      if let message {
        // The ZStack takes whichever layer is taller, so a long message grows
        // the section instead of clipping.
        DashSectionFailureVeil(
          message: message,
          covers: placeholderHeight,
          actionTitle: actionTitle,
          retry: retry
        )
        .dashFailureRemovalTransition()
      }
    }
    // Inside `DashInfoGroup` the enclosing card trims the veil's overhang;
    // here the modifier trims it itself.
    .clipped()
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

/// What a status badge *means*, decided at the call site — never sniffed back
/// out of its wording.
///
/// `StatusBadge` used to take a `String` and derive both its shape and its
/// colour by lowercasing it and matching an English word list, then render a
/// separately-localized label. One string served two masters: the style path
/// needed an English source token, the label path needed a catalog key, and
/// the two drifted apart whenever a transform landed between them
/// (`"Read-only".capitalized == "Read-Only"`, which is not a key — the badge
/// stayed English in every non-en locale) or whenever a caller localized
/// early. It also meant a status Cloudflare spells differently than the word
/// list ("failure" vs "failed") silently fell through to the informational
/// tone, so a failed Pages build wore an info capsule next to a red row icon.
///
/// A token fixes both ends: `presentation` and `tone` come from an exhaustive
/// switch, so a new status cannot compile without naming its shape and colour,
/// and `label` carries its own catalog key with nothing in between.
enum StatusToken: String, CaseIterable, Sendable {
  /// The Worker deployment currently taking 100% of traffic. Deliberately not
  /// "Active": Dash already spends that word on zone and R2-domain health, and
  /// one English word can only carry one translation (the catalog key *is* the
  /// source string) — reusing it left the Chinese badge reading 正常, "healthy",
  /// on a list where the question is *which one is live*.
  case current
  /// A Workers route binding.
  case route
  /// Present, but Dash lacks the write scopes to change it.
  case readOnly
  /// Not reachable in this session at all (demo workspace).
  case locked
  /// A Cloudflare delivery this iPhone has not shown yet.
  case unread
  /// Pages: build finished cleanly.
  case success
  /// Pages: build finished with an error.
  case failed
  /// Pages: build is still running (Cloudflare spells the running stage
  /// "active", which is why the raw token could never be trusted for style).
  case inProgress
  /// Pages: build was stopped before it finished.
  case canceled
  /// Pages: Cloudflare skipped the build.
  case skipped
  /// Pages: Cloudflare reported a stage Dash does not model.
  case unknown
  // Email Routing
  case verified
  case unverified
  case ready
  case misconfigured
  case unlocked
  case managed
  case disabled
  // Registrar
  case registered
  case registrationPending
  case expired
  case suspended
  case redemptionPeriod
  case pendingDelete
  // Cloudflare Tunnel. `degraded` is shared with status-page components —
  // one English word, one translation.
  case healthy
  case degraded
  case down
  case inactive
  case protected
  // Cloudflare status page (cloudflarestatus.com). Page indicator…
  case operational
  case minorOutage
  case majorOutage
  case criticalOutage
  // …component-only states…
  case partialOutage
  case underMaintenance
  // …and the incident lifecycle.
  case investigating
  case identified
  case monitoring
  case resolved

  enum Presentation: Equatable {
    /// Quiet trailing label or check — never a colored capsule.
    case quiet
    /// Capsule reserved for warnings, critical states, and access limits.
    case capsule
  }

  enum Tone: Equatable {
    case success
    case warning
    case danger
    case info
  }

  var presentation: Presentation {
    switch self {
    case .current, .success, .verified, .ready, .registered, .healthy, .protected,
      .operational, .resolved:
      .quiet
    case .route, .readOnly, .locked, .unread, .failed, .inProgress, .canceled, .skipped,
      .unknown, .unverified, .misconfigured, .unlocked, .managed, .disabled,
      .registrationPending, .expired, .suspended, .redemptionPeriod, .pendingDelete, .degraded,
      .down, .inactive, .minorOutage, .majorOutage, .criticalOutage, .partialOutage,
      .underMaintenance, .investigating, .identified, .monitoring:
      .capsule
    }
  }

  var tone: Tone {
    switch self {
    case .current, .success, .verified, .ready, .registered, .healthy, .protected,
      .operational, .resolved:
      .success
    case .readOnly, .locked, .unverified, .unlocked, .degraded, .minorOutage, .partialOutage,
      .investigating, .identified:
      .warning
    case .failed, .canceled, .misconfigured, .expired, .suspended, .redemptionPeriod,
      .pendingDelete, .down, .majorOutage, .criticalOutage:
      .danger
    case .route, .unread, .inProgress, .skipped, .unknown, .managed, .disabled,
      .registrationPending, .inactive, .underMaintenance, .monitoring:
      .info
    }
  }

  /// The badge's own catalog key. Pages outcomes deliberately reuse the words
  /// the build-outcomes legend already ships (`PagesDeploymentChartModel.label`)
  /// so the badge and the chart on the same screen never disagree.
  var label: String {
    switch self {
    case .current: DashL10n.string("Current")
    case .route: DashL10n.string("Route")
    case .readOnly: DashL10n.string("Read-only")
    case .locked: DashL10n.string("Needs authorization")
    case .unread: DashL10n.string("Unread")
    case .success: DashL10n.string("Success")
    case .failed: DashL10n.string("Failed")
    case .inProgress: DashL10n.string("In progress")
    case .canceled: DashL10n.string("Canceled")
    case .skipped: DashL10n.string("Skipped")
    case .unknown: DashL10n.string("Unknown")
    case .verified: DashL10n.string("Verified")
    case .unverified: DashL10n.string("Unverified")
    case .ready: DashL10n.string("Ready")
    case .misconfigured: DashL10n.string("Misconfigured")
    case .unlocked: DashL10n.string("Unlocked")
    case .managed: DashL10n.string("Managed")
    case .disabled: DashL10n.string("Disabled")
    case .registered: DashL10n.string("Registered")
    case .registrationPending: DashL10n.string("Pending")
    case .expired: DashL10n.string("Expired")
    case .suspended: DashL10n.string("Suspended")
    case .redemptionPeriod: DashL10n.string("Redemption")
    case .pendingDelete: DashL10n.string("Pending delete")
    case .healthy: DashL10n.string("Healthy")
    case .degraded: DashL10n.string("Degraded")
    case .down: DashL10n.string("Down")
    case .inactive: DashL10n.string("Inactive")
    case .protected: DashL10n.string("Protected")
    case .operational: DashL10n.string("Operational")
    case .minorOutage: DashL10n.string("Minor outage")
    case .majorOutage: DashL10n.string("Major outage")
    case .criticalOutage: DashL10n.string("Critical outage")
    case .partialOutage: DashL10n.string("Partial outage")
    case .underMaintenance: DashL10n.string("Maintenance")
    case .investigating: DashL10n.string("Investigating")
    case .identified: DashL10n.string("Identified")
    case .monitoring: DashL10n.string("Monitoring")
    case .resolved: DashL10n.string("Resolved")
    }
  }

  /// Maps a Cloudflare Pages stage status onto a token. Kept beside the tone
  /// table so a status Cloudflare adds shows up here rather than defaulting to
  /// an informational capsule.
  init(pagesStatus: String?, isSkipped: Bool = false) {
    guard !isSkipped else {
      self = .skipped
      return
    }
    switch pagesStatus?.lowercased() {
    case "success":
      self = .success
    case "failure", "failed":
      self = .failed
    case "canceled", "cancelled":
      self = .canceled
    case "skipped":
      self = .skipped
    case "active", "idle", "building", "deploying", "queued", "initializing":
      self = .inProgress
    default:
      self = .unknown
    }
  }

  /// Maps Cloudflare Registrar's raw registration lifecycle onto a token.
  /// Unknown states stay unknown rather than inheriting a positive style.
  init(registrarStatus: String?) {
    let normalized =
      registrarStatus?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: " ", with: "_")
    switch normalized {
    case "active":
      self = .registered
    case "registration_pending":
      self = .registrationPending
    case "expired":
      self = .expired
    case "suspended":
      self = .suspended
    case "redemption_period":
      self = .redemptionPeriod
    case "pending_delete":
      self = .pendingDelete
    default:
      self = .unknown
    }
  }

  /// Maps Cloudflare Tunnel's raw health value onto a token. Anything new is
  /// informationally unknown, never optimistically healthy.
  init(tunnelStatus: String?) {
    switch tunnelStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "healthy":
      self = .healthy
    case "degraded":
      self = .degraded
    case "down":
      self = .down
    case "inactive":
      self = .inactive
    default:
      self = .unknown
    }
  }

  /// Status-page mappings switch over the package's typed enums with no
  /// `default:`, so a vocabulary addition in `CloudflareStatus` cannot compile
  /// without choosing a badge here.
  init(statusIndicator: CloudflareStatusSummary.Indicator) {
    switch statusIndicator {
    case .none: self = .operational
    case .minor: self = .minorOutage
    case .major: self = .majorOutage
    case .critical: self = .criticalOutage
    case .unknown: self = .unknown
    }
  }

  init(statusComponent: CloudflareStatusComponent.Status) {
    switch statusComponent {
    case .operational: self = .operational
    case .degradedPerformance: self = .degraded
    case .partialOutage: self = .partialOutage
    case .majorOutage: self = .majorOutage
    case .underMaintenance: self = .underMaintenance
    case .unknown: self = .unknown
    }
  }

  init(statusIncident: CloudflareStatusIncident.Status) {
    switch statusIncident {
    case .investigating: self = .investigating
    case .identified: self = .identified
    case .monitoring: self = .monitoring
    case .resolved, .postmortem: self = .resolved
    case .unknown: self = .unknown
    }
  }
}

/// A small neutral capsule for secondary metadata seated beside a title — a
/// license identifier, a section's freshness. Tone-free on purpose: anything
/// that reports *state* is a `StatusBadge`, whose shape and tone come from a
/// `StatusToken` rather than from its wording.
struct DashMetaBadge: View {
  let text: String

  init(_ text: String) {
    self.text = text
  }

  var body: some View {
    Text(text)
      .dashTextStyle(.captionSemibold)
      .foregroundStyle(DashTheme.subtle)
      .lineLimit(1)
      .minimumScaleFactor(0.85)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(DashTheme.metaBadgeSurface, in: Capsule())
  }
}

struct StatusBadge: View {
  let token: StatusToken

  init(_ token: StatusToken) {
    self.token = token
  }

  private var colors: (foreground: Color, background: Color) {
    switch token.tone {
    case .success: (DashTheme.success, DashTheme.successTint)
    case .warning: (DashTheme.warning, DashTheme.warningTint)
    case .danger: (DashTheme.danger, DashTheme.dangerTint)
    case .info: (DashTheme.brand, DashTheme.infoTint)
    }
  }

  var body: some View {
    Group {
      switch token.presentation {
      case .quiet:
        HStack(spacing: 4) {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(colors.foreground)
          Text(token.label)
            .dashTextStyle(.captionSemibold)
            .foregroundStyle(colors.foreground)
            .lineLimit(1)
        }
      case .capsule:
        Text(token.label)
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
    .accessibilityLabel(StatusBadge.accessibilityText(for: token))
  }

  /// Pure catalog string — safe off the main actor so free helpers (registrar
  /// row labels, tests) can call it without hopping through a View.
  nonisolated static func accessibilityText(for token: StatusToken) -> String {
    DashL10n.string("Status, \(token.label)")
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

  /// A drag lifted off. Stands in for the feedback UIKit plays with its own
  /// lift preview, which a `previewForLifting` of nil suppresses.
  static func dragLift() {
    guard DashInteractionPreferences.hapticsEnabled else { return }
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
  }

  /// A hold inside a chart or the globe engaged: that surface now owns the
  /// finger, and the page under it has stopped answering to it.
  static func gestureEngaged() {
    guard DashInteractionPreferences.hapticsEnabled else { return }
    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
  }

  /// Picker, tab, or segment selection changed.
  static func selectionChanged() {
    guard DashInteractionPreferences.hapticsEnabled else { return }
    UISelectionFeedbackGenerator().selectionChanged()
  }

}

// MARK: - Skeleton pulse

/// Cold-load placeholders breathe (opacity dips, then restores) until a
/// failure or settled-empty overlay freezes them. Flip this off under
/// `dashColdFailure` / section failure veils so the washed-out chrome stops
/// the moment copy lands.
private struct DashSkeletonPulseActiveKey: EnvironmentKey {
  static let defaultValue = true
}

extension EnvironmentValues {
  var dashSkeletonPulseActive: Bool {
    get { self[DashSkeletonPulseActiveKey.self] }
    set { self[DashSkeletonPulseActiveKey.self] = newValue }
  }
}

/// Opacity steps for cold-load bars / circles / capsules, plus the shared
/// breath timing. Every placeholder reads the same phase so the screen pulses
/// as one field, not a crowd of independent blinks.
enum DashSkeletonStyle {
  static let strong: Double = 0.42
  static let mid: Double = 0.34
  static let soft: Double = 0.28
  /// One full dip-and-restore cycle.
  static let period: TimeInterval = 1.35
  /// Multiplier at the trough — peak is `1`. Soft enough to read as light
  /// breathing, not a strobe.
  static let pulseFloor: Double = 0.58
}

/// Shared fill for every cold-load bar / circle / capsule.
struct DashSkeletonShape<S: Shape>: View {
  var shape: S
  var opacity: Double = DashSkeletonStyle.strong
  @Environment(\.dashSkeletonPulseActive) private var pulseActive
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var animating: Bool { pulseActive && !reduceMotion }

  var body: some View {
    TimelineView(
      .animation(minimumInterval: 1.0 / 30.0, paused: !animating)
    ) { context in
      shape.fill(
        DashTheme.fill.opacity(
          opacity * (animating ? dashSkeletonPulseFactor(at: context.date) : 1)))
    }
  }
}

extension Shape {
  func dashSkeletonFill(_ opacity: Double = DashSkeletonStyle.strong) -> some View {
    DashSkeletonShape(shape: self, opacity: opacity)
  }
}

/// Full-bleed plot / hero stand-in. Callers own the clip shape.
struct DashSkeletonBand: View {
  var opacity: Double = DashSkeletonStyle.soft
  @Environment(\.dashSkeletonPulseActive) private var pulseActive
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var animating: Bool { pulseActive && !reduceMotion }

  var body: some View {
    TimelineView(
      .animation(minimumInterval: 1.0 / 30.0, paused: !animating)
    ) { context in
      DashTheme.fill.opacity(
        opacity * (animating ? dashSkeletonPulseFactor(at: context.date) : 1))
    }
  }
}

/// The same breath for `.redacted` text stand-ins (and any non-shape chrome
/// that still needs to pulse with the bars).
struct DashSkeletonPulseModifier: ViewModifier {
  @Environment(\.dashSkeletonPulseActive) private var pulseActive
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var animating: Bool { pulseActive && !reduceMotion }

  func body(content: Content) -> some View {
    TimelineView(
      .animation(minimumInterval: 1.0 / 30.0, paused: !animating)
    ) { context in
      content.opacity(animating ? dashSkeletonPulseFactor(at: context.date) : 1)
    }
  }
}

extension View {
  func dashSkeletonPulse() -> some View {
    modifier(DashSkeletonPulseModifier())
  }
}

/// `1` at the peak, `pulseFloor` at the trough, cosine so the turnaround is soft.
private func dashSkeletonPulseFactor(at date: Date) -> Double {
  let phase =
    date.timeIntervalSinceReferenceDate
    .truncatingRemainder(dividingBy: DashSkeletonStyle.period)
    / DashSkeletonStyle.period
  let wave = 0.5 + 0.5 * cos(phase * 2 * Double.pi)
  return DashSkeletonStyle.pulseFloor
    + (1 - DashSkeletonStyle.pulseFloor) * wave
}

/// Placeholder rows that match `DashListRow` / recessed card geometry. Prefer
/// `dashModeListRows` inside a mode-aware `DashFeatureList` body so cold and
/// live share one card; this group remains for section-cold veils.
struct DashListSkeleton: View {
  var rows: Int = DashBodyPlaceholderDepth.listRows

  var body: some View {
    DashListGroup(title: " ") {
      DashListRowPlaceholders(rows: rows)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Loading")
  }
}

/// One catalog row stand-in for index-stable handoff — same 36pt tone plate +
/// title/subtitle column as `DashListRow` / `CatalogFeatureIcon.list` /
/// Resources and detail Actions rows.
struct DashListRowPlaceholder: View {
  var body: some View {
    HStack(spacing: 12) {
      Circle()
        .dashSkeletonFill(DashSkeletonStyle.strong)
        .frame(width: 36, height: 36)
      VStack(alignment: .leading, spacing: 2) {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .dashSkeletonFill(DashSkeletonStyle.strong)
          .frame(height: 14)
          .frame(maxWidth: 160)
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .dashSkeletonFill(DashSkeletonStyle.soft)
          .frame(height: 11)
          .frame(maxWidth: 220)
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 12)
    // Match subtitled `DashListRow` (Actions / catalog-like rows).
    .frame(
      maxWidth: .infinity, minHeight: DashTheme.Layout.subtitledListRow,
      alignment: .leading
    )
    .accessibilityHidden(true)
  }
}

/// The `DashListSkeleton` row shape without the group chrome: the placeholder
/// for a *section* of list rows — deployments, domains — that fetches on its
/// own and veils failures with `dashSectionFailure`.
struct DashListRowPlaceholders: View {
  var rows: Int = 3

  var body: some View {
    VStack(spacing: 0) {
      ForEach(0..<max(rows, 1), id: \.self) { _ in
        DashListRowPlaceholder()
      }
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Loading")
  }
}

/// Heading bar over a row of metric tiles inside a glass card — the Worker
/// totals panel and the same tile/bar vocabulary its cold-failure fallback uses.
struct DashMetricPanelPlaceholder: View {
  var tiles: Int = 3

  var body: some View {
    DashGlassCard {
      VStack(alignment: .leading, spacing: 10) {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .dashSkeletonFill(DashSkeletonStyle.strong)
          .frame(width: 96, height: 12)
        HStack(spacing: 12) {
          ForEach(0..<max(tiles, 1), id: \.self) { _ in
            VStack(alignment: .leading, spacing: 6) {
              RoundedRectangle(cornerRadius: 4, style: .continuous)
                .dashSkeletonFill(DashSkeletonStyle.soft)
                .frame(width: 56, height: 10)
              RoundedRectangle(cornerRadius: 4, style: .continuous)
                .dashSkeletonFill(DashSkeletonStyle.strong)
                .frame(width: 64, height: 16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Loading")
  }
}

/// Compact glass metric tile — Zone analytics grid cells.
struct DashMetricTilePlaceholder: View {
  var body: some View {
    DashGlassCard {
      VStack(alignment: .leading, spacing: 4) {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .dashSkeletonFill(DashSkeletonStyle.soft)
          .frame(width: 72, height: 12)
        Text(verbatim: "888,888")
          .dashTextStyle(.sectionTitle)
          .monospacedDigit()
          .lineLimit(1)
          .redacted(reason: .placeholder)
          .dashSkeletonPulse()
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityHidden(true)
  }
}

/// Collapsed chart card: title (optionally over a total) and a plot flush to
/// the bottom edge — same enamel and heights as `DashCollapsedChartCard` /
/// Watchtower's collapsed metric skeleton.
struct DashCollapsedChartPlaceholder: View {
  var title: String?
  /// Matches `DashCollapsedChartCard` when it carries a total + trend.
  var showsMetricHeader = false
  /// Same catalog key the live card takes, so the window line is already in
  /// place when the total lands over it.
  var caption: String?
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  private var panelShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: showsMetricHeader ? 4 : 0) {
        Group {
          if let title {
            Text(DashL10n.ui(title))
              .dashTextStyle(.footnoteSemibold)
              .foregroundStyle(DashTheme.subtle)
              .lineLimit(showsMetricHeader ? 2 : 1, reservesSpace: true)
          } else {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
              .dashSkeletonFill(DashSkeletonStyle.strong)
              .frame(width: 72, height: 12)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.vertical, 2)
          }
        }
        if showsMetricHeader {
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .dashSkeletonFill(DashSkeletonStyle.strong)
            .frame(width: 64, height: 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let caption {
          Text(DashL10n.ui(caption))
            .dashTextStyle(.caption)
            .foregroundStyle(DashTheme.subtle)
            .lineLimit(1)
        }
      }
      .padding(.horizontal, DashTheme.Spacing.card)
      .padding(.top, DashTheme.Spacing.card)
      .padding(.bottom, 8)

      DashSkeletonBand()
        .frame(maxWidth: .infinity)
        .frame(height: DashTheme.DitherChart.collapsedHeight(dynamicTypeSize: dynamicTypeSize))
        .clipShape(
          UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: DashTheme.Radius.card,
            bottomTrailingRadius: DashTheme.Radius.card,
            topTrailingRadius: 0,
            style: .continuous))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      DashTheme.homeCardSurface.clipShape(panelShape)
    }
    .dashEmbossChrome(shape: panelShape)
    .accessibilityHidden(true)
  }
}

/// Full chart / donut panel: title band over a plot at `DitherChart.height`.
struct DashChartPanelPlaceholder: View {
  var showsLegend = false
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    DashGlassCard {
      VStack(alignment: .leading, spacing: 12) {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .dashSkeletonFill(DashSkeletonStyle.strong)
          .frame(width: 112, height: 12)
        DashSkeletonBand()
          .frame(maxWidth: .infinity)
          .frame(
            height: DashTheme.DitherChart.height(
              dynamicTypeSize: dynamicTypeSize,
              showsLegend: showsLegend)
          )
          .clipShape(
            RoundedRectangle(cornerRadius: DashTheme.Radius.button, style: .continuous))
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Loading")
  }
}

/// Aspect-ratio hero face — Zone detail's domain card slot before the zone
/// payload arrives.
struct DashHeroCardPlaceholder: View {
  var aspectRatio: CGFloat = 5.0 / 3.0

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: DashTheme.Radius.button, style: .continuous)
  }

  var body: some View {
    DashSkeletonBand(opacity: DashSkeletonStyle.mid)
      .aspectRatio(aspectRatio, contentMode: .fit)
      .frame(maxWidth: .infinity)
      .clipShape(shape)
      .dashEmbossChrome(shape: shape)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Loading")
  }
}

/// Recessed control-card shape matching `DashToggleRow` (title bar + switch
/// capsule) so a settings toggle does not pop in later.
struct DashToggleRowPlaceholder: View {
  var body: some View {
    HStack(spacing: 16) {
      RoundedRectangle(cornerRadius: 4, style: .continuous)
        .dashSkeletonFill(DashSkeletonStyle.strong)
        .frame(width: 120, height: 14)
      Spacer(minLength: 12)
      Capsule(style: .continuous)
        .dashSkeletonFill(DashSkeletonStyle.mid)
        .frame(width: 51, height: 31)
    }
    .frame(minHeight: 31)
    .padding(.horizontal, 16)
    .padding(.vertical, DashTheme.Spacing.comfortable)
    .frame(maxWidth: .infinity)
    .background(
      DashTheme.recessed,
      in: RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous)
    )
    .accessibilityHidden(true)
  }
}

/// How tall a cold-failure layer grows over the skeleton it covers.
enum DashColdFailureExtent {
  /// Grow to the enclosing scroll viewport. A list skeleton is four rows tall,
  /// so without this the copy lands in the top third with dead canvas below it.
  case scrollViewport
  /// Take the skeleton's own height — for placeholders that already paint a
  /// screenful (Watchtower's saved chart layout).
  case skeleton
}

/// Copy that lands on the cold skeleton wash — failure or settled empty.
struct DashColdOverlayCopy: Equatable {
  var icon: String
  var title: String
  var message: String
  var actionTitle: String? = nil
  /// Compared by title only; the closure itself is not part of equality.
  var action: (() -> Void)? = nil

  static func == (lhs: DashColdOverlayCopy, rhs: DashColdOverlayCopy) -> Bool {
    lhs.icon == rhs.icon
      && lhs.title == rhs.title
      && lhs.message == rhs.message
      && lhs.actionTitle == rhs.actionTitle
      && (lhs.action != nil) == (rhs.action != nil)
  }
}

extension View {
  /// Lands copy *over* this skeleton instead of replacing it — cold failure and
  /// settled empty share the mount so loading → overlay never remounts the bars.
  ///
  /// When `copy` is `nil`, the skeleton keeps breathing (cold load). When copy
  /// arrives, the same skeleton stays mounted under a viewport-tall veil — the
  /// pulse freezes, a top-clear canvas wash settles over it, and the copy is
  /// centred in that veil (not pinned under the bars). Hit testing and
  /// VoiceOver both belong to the copy once it is up.
  func dashColdOverlay(
    copy: DashColdOverlayCopy?,
    extent: DashColdFailureExtent = .skeleton
  ) -> some View {
    modifier(DashColdOverlayModifier(copy: copy, extent: extent))
  }

  /// Fails *over* this skeleton instead of replacing it.
  ///
  /// Thin wrapper over `dashColdOverlay` that keeps the danger mark and a
  /// required action (Try again / Grant access / Sign in again).
  func dashColdFailure(
    title: String = "Couldn’t load",
    message: String?,
    actionTitle: String,
    extent: DashColdFailureExtent = .skeleton,
    action: @escaping () -> Void
  ) -> some View {
    dashColdOverlay(
      copy: message.map {
        DashColdOverlayCopy(
          icon: SolarAsset.Content.danger,
          title: title,
          message: $0,
          actionTitle: actionTitle,
          action: action)
      },
      extent: extent)
  }
}

private struct DashColdOverlayModifier: ViewModifier {
  let copy: DashColdOverlayCopy?
  let extent: DashColdFailureExtent

  func body(content: Content) -> some View {
    ZStack {
      // Top-pinned: the skeleton must stay exactly where the loading phase left
      // it — the veil grows over it; the bars themselves never jump.
      VStack(spacing: 0) {
        content
          .environment(\.dashSkeletonPulseActive, copy == nil)
        Spacer(minLength: 0)
      }
      .allowsHitTesting(copy == nil)
      .accessibilityHidden(copy != nil)

      if let copy {
        // Floor + centred copy: one viewport-tall (or skeleton-tall) layer so
        // the tip is not appended under the bars and never forces a scroll.
        ZStack {
          DashColdFailureExtentFloor(extent: extent)
          DashColdOverlayCopyView(copy: copy)
        }
        .transition(.opacity)
      }
    }
    .animation(DashTheme.Motion.content, value: copy != nil)
  }
}

/// Height *floor* for the veil, never a cap: a `ZStack` takes its tallest
/// child, so the copy can still grow the layer past the viewport at
/// accessibility type sizes instead of being clipped out of reach.
private struct DashColdFailureExtentFloor: View {
  let extent: DashColdFailureExtent

  var body: some View {
    switch extent {
    case .skeleton:
      EmptyView()
    case .scrollViewport:
      // `DashFeatureList` pads its scroll content; subtracting that lands the
      // layer on the visible height exactly, so a failure never turns the
      // screen into a scroll (pull-to-refresh still overscrolls).
      Color.clear
        .containerRelativeFrame(.vertical) { height, _ in
          max(
            DashTheme.Layout.emptyStateMinHeight,
            height - DashTheme.Spacing.section - DashTheme.Spacing.scrollBottomInset)
        }
    }
  }
}

/// The translucent canvas wash a cold failure / empty tip lands on: clear at
/// the top so the frozen skeleton still peeks through, densest from mid to
/// bottom so the centred copy sits on readable canvas.
enum DashColdFailureWashRamp {
  /// Full-bleed stops, `location` 0 = top of the veil, 1 = bottom.
  /// Peak opacity is translucent on purpose so bars still read through.
  static let stops: [(location: CGFloat, opacity: Double)] = [
    (0, 0),
    (0.18, 0.05),
    (0.36, 0.22),
    (0.5, 0.55),
    (0.62, 0.78),
    (0.78, 0.88),
    (1, 0.88),
  ]

  static var fade: LinearGradient {
    LinearGradient(
      stops: stops.map {
        Gradient.Stop(color: DashTheme.canvas.opacity($0.opacity), location: $0.location)
      },
      startPoint: .top,
      endPoint: .bottom)
  }
}

private struct DashColdFailureWash: View {
  var body: some View {
    DashColdFailureWashRamp.fade
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}

private struct DashColdOverlayCopyView: View {
  let copy: DashColdOverlayCopy
  /// Drives the bottom → top stagger; flipped on appear so the reveal always
  /// plays when copy lands on an already-mounted skeleton.
  @State private var revealed = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var hasAction: Bool { copy.actionTitle != nil && copy.action != nil }

  var body: some View {
    // Fill the veil, centre the tip. Wash is full-bleed behind so the top stays
    // open over the skeleton and the mid/bottom carries the copy.
    ZStack {
      DashColdFailureWash()
        .opacity(revealed || reduceMotion ? 1 : 0)
        .animation(
          reduceMotion ? nil : DashTheme.Motion.content,
          value: revealed)

      VStack(spacing: DashTheme.Spacing.comfortable) {
        SolarIcon(asset: copy.icon, size: 34, color: DashTheme.strong)
          .frame(width: 72, height: 72)
          .background(DashTheme.recessed, in: Circle())
          .dashReveal(hasAction ? 3 : 2, shown: revealed)
        Text(DashL10n.ui(copy.title))
          .dashTextStyle(.emptyTitle)
          .foregroundStyle(DashTheme.strong)
          .multilineTextAlignment(.center)
          .dashReveal(hasAction ? 2 : 1, shown: revealed)
        Text(DashL10n.ui(copy.message))
          .dashTextStyle(.supporting)
          .foregroundStyle(DashTheme.subtle)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .dashReveal(hasAction ? 1 : 0, shown: revealed)
        if let actionTitle = copy.actionTitle, let action = copy.action {
          DashSecondaryPillButton(title: actionTitle, action: action)
            .padding(.top, 6)
            .dashReveal(0, shown: revealed)
        }
      }
      .frame(maxWidth: 440)
      .padding(DashTheme.Spacing.panel)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear {
      // Next run-loop beat so the hidden pose (offset + blur) commits before
      // `shown` flips — otherwise the stagger lands already at rest.
      DispatchQueue.main.async { revealed = true }
    }
  }
}

/// Cold-load failure for a feature list: the same placeholder body the loading
/// phase painted stays on screen and the failure lands on a wash over it
/// (`dashColdFailure`). Prefer keeping that body mounted in the caller
/// (see `DashFeatureList`) so loading → error never remounts the bars; this
/// type remains for one-off call sites that already own a discrete failure view.
struct ErrorStateView<Skeleton: View>: View {
  let message: String
  let retry: () -> Void
  @ViewBuilder var skeleton: () -> Skeleton
  @Environment(AppModel.self) private var model
  @Environment(\.featureRequiredScopes) private var featureRequiredScopes

  private var presentation: DashFailurePresentation {
    DashFailurePresentation.from(message: message)
  }

  var body: some View {
    skeleton()
      .dashColdFailure(
        message:
          presentation.action == .grantAccess && !model.isDemoSession
          ? [
            presentation.message,
            DashL10n.string(
              "Dash requests all permissions used by its current features in one authorization."
            ),
          ].joined(separator: " ")
          : presentation.message,
        actionTitle: presentation.action.title,
        extent: .scrollViewport,
        action: recover)
  }

  private func recover() {
    switch presentation.action {
    case .signInAgain:
      Task { await model.signOut() }
    case .grantAccess:
      model.requestAccess(
        to: featureRequiredScopes.isEmpty
          ? DashAuthorizationScopes.initialReadOnly : featureRequiredScopes)
    case .tryAgain:
      retry()
    }
  }
}

/// Explains the real OAuth boundary before any access-recovery control opens
/// Cloudflare. Dash currently upgrades real accounts to the complete reviewed
/// scope set, even when the missing permission belongs to one feature.
struct DashAuthorizationDisclosure: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    if !model.isDemoSession {
      Text(
        DashL10n.string(
          "Dash requests all permissions used by its current features in one authorization."
        )
      )
      .dashTextStyle(.caption)
      .foregroundStyle(DashTheme.subtle)
      .fixedSize(horizontal: false, vertical: true)
    }
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
