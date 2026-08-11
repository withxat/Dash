import SwiftUI

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
        .frame(minHeight: DashTheme.Layout.twoToneListRow)
      }
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Loading")
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
    .padding(.vertical, DashTheme.Spacing.listRow)
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

/// Heading bar over a row of metric tiles inside a glass card — Worker detail
/// and zone HTTP traffic totals, and the same tile/bar vocabulary their
/// cold-failure fallbacks use.
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
