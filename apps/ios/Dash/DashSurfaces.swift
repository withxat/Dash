import CloudflareAPI
import SwiftDitherKit
import SwiftUI

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
  /// shifts hue: a bevel ring (lit top edge, weighted bottom) and a whisper of
  /// face sheen. Nothing is cast onto the canvas — the drop shadows were
  /// removed on purpose; restrained skeuomorphism lights the surface itself
  /// and stops at its edge. Action pills take no emboss at all.
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

  /// Bevel / sheen only — no press-sink duplicate. Use when the view already
  /// owns its hit target (`DashPressButtonStyle`, hold gesture) or carries a
  /// `matchedGeometryEffect` that must stay single-instance. Action pills
  /// deliberately take NO emboss at all (`DashActionButton` is flat).
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
    // No drop shadows — the emboss stays restrained: light on the face (sheen)
    // and on the edge (bevel), nothing cast onto the canvas. Pressing still
    // reads through the 1pt sink shift and the face dim (see `body`).
  }
}

/// Static enamel chrome (sheen + bevel) without duplicating content.
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
    // No drop shadows — same restraint as the pressed container above.
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
  /// `summaryValue`'s raw magnitude, for `.numericText(value:)` direction when
  /// a screen-level range control swaps the figure in place (Web Analytics'
  /// 7d / 30d). Cards on tabless screens leave it nil — their figure only
  /// changes outside an animated transaction, where no transition fires.
  var summaryNumericValue: Double? = nil
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
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous)
  }

  private var showsMetricHeader: Bool {
    summaryValue != nil || trend != nil
  }

  /// Same rolling digits as every other primary metric — the range tabs swap
  /// the figure inside a fixed frame, so it rolls rather than cross-fades.
  private var summaryValueTransition: ContentTransition {
    guard !reduceMotion else { return .opacity }
    guard let summaryNumericValue else { return .numericText() }
    return .numericText(value: summaryNumericValue)
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
              .contentTransition(summaryValueTransition)
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
      .environment(\.dashTwoToneListRows, true)
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
///
/// Everything in the inner card is a list at the `twoToneListRow` seat — one
/// row or many. `\.dashTwoToneListRows` publishes that so `DashListRow` /
/// `FeatureRow` / `DashInfoRow` share one height without a per-call-site flag.
struct DashTwoToneListGroup<Content: View>: View {
  let title: String
  var actionTitle: String?
  var actionIcon: String?
  var action: (() -> Void)?
  /// Kept as a builder (not an eagerly stored `Content`) so the two-tone list
  /// environment is in force when child `@Environment` values resolve —
  /// capturing `content()` in `init` made About's CF status row miss the
  /// flag and fall through to the 72pt catalog seat.
  @ViewBuilder var content: () -> Content

  init(
    title: String, actionTitle: String? = nil, actionIcon: String? = nil,
    action: (() -> Void)? = nil,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.title = title
    self.actionTitle = actionTitle
    self.actionIcon = actionIcon
    self.action = action
    self.content = content
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

      VStack(alignment: .leading, spacing: 0) {
        content()
      }
      .environment(\.dashTwoToneListRows, true)
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

/// True inside a two-tone eyebrow card (`DashTwoToneListGroup` /
/// `dashTwoToneCardRows`). Rows there use `twoToneListRow` (60); service
/// catalogs outside the band keep 72.
private struct DashTwoToneListRowsKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  var dashTwoToneListRows: Bool {
    get { self[DashTwoToneListRowsKey.self] }
    set { self[DashTwoToneListRowsKey.self] = newValue }
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
            covers: CGFloat(max(placeholderRows, 1)) * DashTheme.Layout.twoToneListRow,
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
    // Same `twoToneListRow` seat as Home Shortcuts / Recently used /
    // `DashInfoRowPlaceholders`.
    .frame(minHeight: DashTheme.Layout.twoToneListRow)
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
        .dashItemStagger(visible: revealed, index: 0)
      Text(DashL10n.ui(message))
        .dashTextStyle(.footnote)
        .foregroundStyle(DashTheme.subtle)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .dashItemStagger(visible: revealed, index: 1)
      if let retry {
        Button(DashL10n.ui(actionTitle), action: retry)
          .dashTextStyle(.supportingSemibold)
          .foregroundStyle(DashTheme.brand)
          .buttonStyle(DashPressButtonStyle())
          .dashCompactHitTarget()
          .dashItemStagger(visible: revealed, index: 2)
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

/// Guidance over an already-loaded, temporarily unavailable section. Unlike a
/// failure veil, this keeps the shared bottom-dense material wash and uses a
/// neutral content glyph: the rows are real, but the product is explaining
/// when they become available rather than reporting a request error.
private struct DashSectionNoticeVeil: View {
  let icon: String
  let message: String

  @State private var revealed = false

  var body: some View {
    ZStack {
      // The modifier mounts this veil as an overlay on the rows, so the wash
      // receives their current proposed size immediately. Keep it visible on
      // the first frame; only the compact guidance copy staggers into place.
      DashTranslucentNoticeWash(revealed: true)

      VStack(spacing: DashTheme.Spacing.compact) {
        SolarIcon(asset: icon, size: 22, color: DashTheme.subtle)
          .dashItemStagger(visible: revealed, index: 0)
        Text(DashL10n.ui(message))
          .dashTextStyle(.footnote)
          .foregroundStyle(DashTheme.subtle)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .dashItemStagger(visible: revealed, index: 1)
      }
      .padding(DashTheme.Spacing.card)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(DashL10n.ui(message))
    .onAppear {
      // Commit the hidden lifted item poses before starting their shared
      // entrance; the wash itself is already covering the live rows.
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

  /// Local guidance over a preserved, multi-row section. It shares the cold
  /// empty/error wash and item cadence without inheriting full-screen sizing
  /// or failure semantics. While present, the underlying rows keep their
  /// layout but surrender hit testing and VoiceOver to the notice.
  func dashSectionNotice(_ message: String?, icon: String) -> some View {
    modifier(
      DashSectionNoticeModifier(message: message, icon: icon))
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

private struct DashSectionNoticeModifier: ViewModifier {
  let message: String?
  let icon: String

  func body(content: Content) -> some View {
    content
      .environment(\.dashSkeletonPulseActive, message == nil)
      .allowsHitTesting(message == nil)
      .accessibilityHidden(message != nil)
      .overlay {
        if let message {
          DashSectionNoticeVeil(
            icon: icon,
            message: message
          )
          .dashFailureRemovalTransition()
        }
      }
      .clipped()
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
    // The shared classification intentionally folds skipped into cancelled
    // for charts and color. Preserve the more specific badge wording.
    guard !isSkipped, PagesDeploymentStatusClassification.normalized(pagesStatus) != "skipped"
    else {
      self = .skipped
      return
    }
    switch PagesDeploymentStatusClassification.classify(pagesStatus) {
    case .success:
      self = .success
    case .failure:
      self = .failed
    case .cancelled:
      self = .canceled
    case .active, .idle:
      self = .inProgress
    case .unknown:
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
