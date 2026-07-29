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
    .frame(maxWidth: .infinity, minHeight: 96)
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
  var onNavigate: (() -> Void)?
  @ViewBuilder let label: () -> Label

  var body: some View {
    DestinationLink(destination: value, onNavigate: onNavigate, label: label)
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
  ForEach(items) { item in
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
              .dashFailureRemovalTransition()
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
    DashTwoToneListGroup(title: title) {
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
/// where the placeholder was.
private struct DashInfoRowPlaceholders: View {
  let rows: Int

  var body: some View {
    VStack(spacing: 0) {
      ForEach(0..<max(rows, 1), id: \.self) { index in
        HStack(spacing: 12) {
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(DashTheme.fill.opacity(0.55))
            .frame(width: 64, height: 12)
          Spacer(minLength: 0)
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(DashTheme.fill.opacity(0.4))
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
  let retry: (() -> Void)?

  var body: some View {
    VStack(spacing: DashTheme.Spacing.compact) {
      SolarIcon(asset: SolarAsset.Content.danger, size: 22, color: DashTheme.subtle)
        .dashContentReveal()
      Text(DashL10n.ui(message))
        .dashTextStyle(.footnote)
        .foregroundStyle(DashTheme.subtle)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .dashContentReveal()
      if let retry {
        Button(DashL10n.string("Try again"), action: retry)
          .dashTextStyle(.supportingSemibold)
          .foregroundStyle(DashTheme.brand)
          .buttonStyle(DashPressButtonStyle())
          .dashCompactHitTarget()
          .dashContentReveal(1)
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
  // Cloudflare Tunnel
  case healthy
  case degraded
  case down
  case inactive
  case protected

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
    case .current, .success, .verified, .ready, .registered, .healthy, .protected:
      .quiet
    case .route, .readOnly, .locked, .unread, .failed, .inProgress, .canceled, .skipped,
      .unknown, .unverified, .misconfigured, .unlocked, .managed, .disabled,
      .registrationPending, .expired, .suspended, .redemptionPeriod, .pendingDelete, .degraded,
      .down, .inactive:
      .capsule
    }
  }

  var tone: Tone {
    switch self {
    case .current, .success, .verified, .ready, .registered, .healthy, .protected:
      .success
    case .readOnly, .locked, .unverified, .unlocked, .degraded:
      .warning
    case .failed, .canceled, .misconfigured, .expired, .suspended, .redemptionPeriod,
      .pendingDelete, .down:
      .danger
    case .route, .unread, .inProgress, .skipped, .unknown, .managed, .disabled,
      .registrationPending, .inactive:
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
    case .locked: DashL10n.string("Locked")
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

  static func accessibilityText(for token: StatusToken) -> String {
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

/// How tall a cold-failure layer grows over the skeleton it covers.
enum DashColdFailureExtent {
  /// Grow to the enclosing scroll viewport. A list skeleton is four rows tall,
  /// so without this the copy lands in the top third with dead canvas below it.
  case scrollViewport
  /// Take the skeleton's own height — for placeholders that already paint a
  /// screenful (Watchtower's saved chart layout).
  case skeleton
}

extension View {
  /// Fails *over* this skeleton instead of replacing it.
  ///
  /// A cold failure used to swap the placeholder for a centered empty state: the
  /// structure the user was already reading vanished and one icon owned the
  /// screen. Here the skeleton holds its ground, a canvas wash climbs out of the
  /// bottom edge — solid under the copy, gone by the top, so the fade band *is*
  /// the placeholder dissolving — and the copy reveals headline-first over it.
  ///
  /// The skeleton is frozen chrome from here on: hit testing and VoiceOver both
  /// belong to the copy, so nothing announces “Loading” after a failure.
  func dashColdFailure(
    title: String = "Couldn’t load",
    message: String,
    actionTitle: String,
    extent: DashColdFailureExtent = .skeleton,
    action: @escaping () -> Void
  ) -> some View {
    modifier(
      DashColdFailureModifier(
        title: title,
        message: message,
        actionTitle: actionTitle,
        extent: extent,
        action: action))
  }
}

private struct DashColdFailureModifier: ViewModifier {
  let title: String
  let message: String
  let actionTitle: String
  let extent: DashColdFailureExtent
  let action: () -> Void

  func body(content: Content) -> some View {
    ZStack(alignment: .bottom) {
      DashColdFailureExtentFloor(extent: extent)

      // Top-pinned: the skeleton must stay exactly where the loading phase left
      // it, whatever height the layer grows to — the point of the treatment is
      // that nothing moves when the failure arrives.
      VStack(spacing: 0) {
        content
        Spacer(minLength: 0)
      }
      .allowsHitTesting(false)
      .accessibilityHidden(true)

      DashColdFailureCopy(
        title: title,
        message: message,
        actionTitle: actionTitle,
        action: action)
    }
  }
}

/// Height *floor* for the layer, never a cap: a `ZStack` takes its tallest
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

/// The canvas wash a cold failure lands on: solid behind the copy, then a
/// fill → clear ramp climbing `fadeDepth` above it, so the placeholder dissolves
/// upward instead of ending on a line.
///
/// The ramp is measured in points from the copy's top edge, not as a fraction of
/// the layer: the copy grows with Dynamic Type and the skeleton under it can be
/// four list rows or a screenful of chart cards, so a fractional band would
/// either starve the copy of contrast or wipe out the whole placeholder.
enum DashColdFailureWashRamp {
  /// How far above the copy the wash keeps dissolving the placeholder.
  static let fadeDepth: CGFloat = 240

  /// Fill (at the copy's edge) → clear (`fadeDepth` above it). Eased, not
  /// linear — a straight ramp reads as a visible diagonal seam over rows.
  static let stops: [(location: CGFloat, opacity: Double)] = [
    (0, 1),
    (0.15, 0.94),
    (0.32, 0.78),
    (0.5, 0.52),
    (0.68, 0.26),
    (0.85, 0.08),
    (1, 0),
  ]

  static var fade: LinearGradient {
    LinearGradient(
      stops: stops.map {
        Gradient.Stop(color: DashTheme.canvas.opacity($0.opacity), location: $0.location)
      },
      startPoint: .bottom,
      endPoint: .top)
  }
}

private struct DashColdFailureWash: View {
  var body: some View {
    VStack(spacing: 0) {
      DashColdFailureWashRamp.fade
        .frame(height: DashColdFailureWashRamp.fadeDepth)
      DashTheme.canvas
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

private struct DashColdFailureCopy: View {
  let title: String
  let message: String
  let actionTitle: String
  let action: () -> Void

  var body: some View {
    // Headline first, then supporting copy and action at 40ms intervals.
    // The mark shares the headline's first beat; removal belongs to the
    // container's independent 200ms fade and never reverses this reveal.
    VStack(spacing: DashTheme.Spacing.comfortable) {
      SolarIcon(asset: SolarAsset.Content.danger, size: 34, color: DashTheme.strong)
        .frame(width: 72, height: 72)
        .background(DashTheme.recessed, in: Circle())
        .dashContentReveal()
      Text(DashL10n.ui(title))
        .dashTextStyle(.emptyTitle)
        .foregroundStyle(DashTheme.strong)
        .multilineTextAlignment(.center)
        .dashContentReveal()
      Text(DashL10n.ui(message))
        .dashTextStyle(.supporting)
        .foregroundStyle(DashTheme.subtle)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .dashContentReveal(1)
      DashSecondaryPillButton(title: actionTitle, action: action)
        .padding(.top, 6)
        .dashContentReveal(2)
    }
    .frame(maxWidth: 440)
    .padding(DashTheme.Spacing.panel)
    .frame(maxWidth: .infinity)
    // Hoisted above its host so the ramp overhangs the copy's top edge; the
    // solid half stays exactly behind the copy at any type size.
    .background(alignment: .bottom) {
      DashColdFailureWash()
        .padding(.top, -DashColdFailureWashRamp.fadeDepth)
    }
  }
}

/// Cold-load failure for a feature list: `DashListSkeleton` stays on screen and
/// the failure lands on a wash over it (`dashColdFailure`).
struct ErrorStateView: View {
  let message: String
  let retry: () -> Void
  @Environment(AppModel.self) private var model
  @Environment(\.featureRequiredScopes) private var featureRequiredScopes

  private var presentation: DashFailurePresentation {
    DashFailurePresentation.from(message: message)
  }

  var body: some View {
    DashListSkeleton()
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
