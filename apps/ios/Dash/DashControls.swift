import CloudflareAPI
import GradientAvatars
import SwiftDitherKit
import SwiftUI
import UIKit

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

struct DashSectionHeader: View {
  let title: String
  /// Optional content glyph seated before the title.
  var icon: String?
  /// Optional metadata capsule seated after the title, vertically centred on
  /// it — a section's freshness, never a status. Pre-localized like `title`.
  var badge: String?
  /// What VoiceOver reads for `badge`, which is usually a bare fragment
  /// ("3 minutes ago") that means nothing without its subject.
  var badgeAccessibilityLabel: String?
  /// Optional trailing control — `DashListGroupHeader`'s icon action at the
  /// section ramp, so an editable section reads the same at both scales.
  var actionIcon: String?
  var actionLabel: String?
  var action: (() -> Void)?

  init(
    _ title: String,
    icon: String? = nil,
    badge: String? = nil,
    badgeAccessibilityLabel: String? = nil,
    actionIcon: String? = nil,
    actionLabel: String? = nil,
    action: (() -> Void)? = nil
  ) {
    self.title = title
    self.icon = icon
    self.badge = badge
    self.badgeAccessibilityLabel = badgeAccessibilityLabel
    self.actionIcon = actionIcon
    self.actionLabel = actionLabel
    self.action = action
  }

  var body: some View {
    HStack(spacing: 8) {
      if let icon {
        SolarIcon(asset: icon, size: 20, color: DashTheme.strong)
      }
      Text(title)
        .dashTextStyle(.sectionTitle)
        .foregroundStyle(DashTheme.strong)
        .textCase(nil)
        .layoutPriority(1)
      if let badge {
        DashMetaBadge(badge)
          .accessibilityLabel(badgeAccessibilityLabel ?? badge)
      }
      Spacer(minLength: 0)
      if let action, let actionIcon {
        Button(action: action) {
          SolarIcon(asset: actionIcon, size: 16, color: DashTheme.brand)
        }
        .buttonStyle(DashPressButtonStyle())
        .accessibilityLabel(actionLabel ?? DashL10n.ui("Edit"))
        .dashHeaderActionHitTarget()
      }
    }
    // Padding rides the row, not the title, so a decorated header keeps the
    // plain header's vertical rhythm.
    .padding(.top, 12)
    .padding(.bottom, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct DashToolbarActionIcon: View {
  let asset: String
  var color: Color = DashTheme.strong

  var body: some View {
    // Keep the glyph square so Liquid Glass morphs to a circle, not a capsule.
    // 24pt matches the system back chevron, which renders its 24×24 Solar
    // asset at natural size.
    SolarIcon(asset: asset, size: 24, color: color)
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

/// Navigation-bar icon action. Forces a circle on iOS 26 Liquid Glass
/// (system default is a capsule whenever the label isn't treated as square).
struct DashToolbarIconButton: View {
  enum Variant: Equatable {
    case standard
    case confirmation
  }

  let asset: String
  var accessibilityLabel: String
  var variant: Variant = .standard
  let action: () -> Void

  private var confirmationGlyph: some View {
    DashToolbarActionIcon(asset: asset, color: .white)
  }

  @ViewBuilder
  private var label: some View {
    switch variant {
    case .confirmation:
      confirmationGlyph
        .frame(
          width: AvatarHeaderMetrics.barSize,
          height: AvatarHeaderMetrics.barSize
        )
        .background(DashTheme.brand, in: Circle())
        .contentShape(Circle())
    case .standard:
      if #available(iOS 26.0, *) {
        // Do NOT use `.buttonStyle(.glass)` here. After
        // `sharedBackgroundVisibility(.hidden)`, that style paints a circle a
        // few points smaller than the system back control, and the nav-bar
        // item-height clamp shrinks it further. An explicit 44pt `glassEffect`
        // matches the leading back button / floated profile avatar.
        DashToolbarActionIcon(asset: asset)
          .frame(
            width: AvatarHeaderMetrics.barSize,
            height: AvatarHeaderMetrics.barSize
          )
          .contentShape(Circle())
          .glassEffect(.regular.interactive(), in: .circle)
      } else {
        DashToolbarActionIcon(asset: asset)
          .dashCompactHitTarget()
      }
    }
  }

  var body: some View {
    Group {
      if #available(iOS 26.0, *), variant == .confirmation {
        // In a toolbar, borderedProminent is the system's tinted Liquid Glass
        // confirmation treatment. Let it own sizing, contrast, and interaction
        // while retaining Dash's Solar glyph.
        Button(action: action) {
          confirmationGlyph
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
        .tint(DashTheme.brand)
      } else {
        Button(action: action) {
          label
        }
        .buttonStyle(DashPressButtonStyle())
      }
    }
    .accessibilityLabel(DashL10n.ui(accessibilityLabel))
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
