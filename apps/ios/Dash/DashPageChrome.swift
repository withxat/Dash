import CloudflareAPI
import GradientAvatars
import SwiftUI
import UIKit

// MARK: - Detail header

/// The identity glyph a detail screen shows ahead of its inline title.
/// `Hashable` because the shared header keys the glyph's morph on it: the icon
/// and the title change as two independent parts, not one block.
enum DetailIcon: Hashable {
  case feature(FeatureID)
  case avatar(String)
  case solar(String)
}

struct DetailIconView: View {
  let icon: DetailIcon
  var tint: Color = DashTheme.brand

  var body: some View {
    switch icon {
    case .feature(let feature):
      CatalogFeatureIcon(feature: feature, size: .compact)
    case .avatar(let seed):
      GradientAvatar(seed: seed, size: 24, pattern: .dither, contentScale: 1.5)
    case .solar(let asset):
      SolarIcon(asset: asset, size: 20, color: tint)
    }
  }
}

struct DashPageHeaderDescriptor: Equatable {
  let icon: DetailIcon
  let title: String
  let tint: Color
}

struct DashPageActionDescriptor: Identifiable {
  enum Label: Equatable {
    case icon(
      asset: String,
      accessibilityLabel: String,
      variant: DashToolbarIconButton.Variant
    )
    case text(title: String)
  }

  let id: String
  let label: Label
  let isEnabled: Bool
  let disabledOpacity: Double?
  let accessibilityIdentifier: String?
  let action: () -> Void

  static func icon(
    id: String,
    asset: String,
    accessibilityLabel: String,
    variant: DashToolbarIconButton.Variant = .standard,
    isEnabled: Bool = true,
    disabledOpacity: Double? = nil,
    accessibilityIdentifier: String? = nil,
    action: @escaping () -> Void
  ) -> Self {
    Self(
      id: id,
      label: .icon(
        asset: asset,
        accessibilityLabel: accessibilityLabel,
        variant: variant),
      isEnabled: isEnabled,
      disabledOpacity: disabledOpacity,
      accessibilityIdentifier: accessibilityIdentifier,
      action: action)
  }

  static func text(
    id: String,
    title: String,
    isEnabled: Bool = true,
    disabledOpacity: Double? = nil,
    accessibilityIdentifier: String? = nil,
    action: @escaping () -> Void
  ) -> Self {
    Self(
      id: id,
      label: .text(title: title),
      isEnabled: isEnabled,
      disabledOpacity: disabledOpacity,
      accessibilityIdentifier: accessibilityIdentifier,
      action: action)
  }
}

/// Equality ignores action closures: chrome identity is id / label / enabled
/// state, matching `DashPageEscapeActionPreference`.
extension DashPageActionDescriptor: Equatable {
  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id
      && lhs.label == rhs.label
      && lhs.isEnabled == rhs.isEnabled
      && lhs.disabledOpacity == rhs.disabledOpacity
      && lhs.accessibilityIdentifier == rhs.accessibilityIdentifier
  }
}

struct DashPageChromePreference: Equatable {
  var header: DashPageHeaderDescriptor? = nil
  var leadingActions: [DashPageActionDescriptor] = []
  var trailingActions: [DashPageActionDescriptor] = []
}

struct DashPageChromePreferenceKey: PreferenceKey {
  static var defaultValue: DashPageChromePreference { DashPageChromePreference() }

  static func reduce(
    value: inout DashPageChromePreference,
    nextValue: () -> DashPageChromePreference
  ) {
    let next = nextValue()
    if let header = next.header { value.header = header }
    value.leadingActions = merge(value.leadingActions, with: next.leadingActions)
    value.trailingActions = merge(value.trailingActions, with: next.trailingActions)
  }

  private static func merge(
    _ current: [DashPageActionDescriptor],
    with next: [DashPageActionDescriptor]
  ) -> [DashPageActionDescriptor] {
    var merged = current
    for action in next {
      if let index = merged.firstIndex(where: { $0.id == action.id }) {
        merged[index] = action
      } else {
        merged.append(action)
      }
    }
    return merged
  }
}

/// Who paints a page's header slots.
enum DashPageChromeHosting: Hashable {
  /// The page draws its own bar — previews and UI-test harnesses that host a
  /// stack outside `MainTabView`.
  case page
  /// The page only publishes; the ONE workspace header draws the slots.
  case workspace
}

/// The one channel page chrome travels out of a page on.
///
/// SwiftUI preferences do not cross a `UIHostingController`, and every route is
/// its own hosting controller, so the shared header cannot read a page's
/// `detailHeader` / `dashPageActions` the way a page-local bar could. Each page
/// publishes its resolved descriptor here under its entry id instead.
///
/// Like `DashHeaderScrollState` and `DashWorkspaceWashScroll`, this store has
/// exactly ONE reader — `DashWorkspaceHeaderBar`. Nothing in `MainTabView`'s
/// body may read it: a trailing-action change (an R2 selection, a Save becoming
/// enabled) would otherwise refresh every cached page host mid-transition.
@MainActor
@Observable
final class DashPageChromeStore {
  private(set) var pages: [DashNavigationEntry.ID: DashPageChromePreference] = [:]

  func publish(_ chrome: DashPageChromePreference, for id: DashNavigationEntry.ID) {
    guard pages[id] != chrome else { return }
    pages[id] = chrome
  }

  func prune(keeping ids: Set<DashNavigationEntry.ID>) {
    guard !pages.isEmpty else { return }
    pages = pages.filter { ids.contains($0.key) }
  }

  func chrome(for id: DashNavigationEntry.ID?) -> DashPageChromePreference? {
    guard let id else { return nil }
    return pages[id]
  }
}

struct DashPageActionControl: View {
  let descriptor: DashPageActionDescriptor
  var allowsInteraction = true

  @ViewBuilder private var control: some View {
    switch descriptor.label {
    case .icon(let asset, let accessibilityLabel, let variant):
      DashToolbarIconButton(
        asset: asset,
        accessibilityLabel: accessibilityLabel,
        variant: variant,
        action: descriptor.action)
    case .text(let title):
      DashToolbarTextButton(title: title, action: descriptor.action)
    }
  }

  var body: some View {
    if let identifier = descriptor.accessibilityIdentifier {
      control
        .disabled(!descriptor.isEnabled || !allowsInteraction)
        .opacity(resolvedOpacity)
        .accessibilityIdentifier(identifier)
    } else {
      control
        .disabled(!descriptor.isEnabled || !allowsInteraction)
        .opacity(resolvedOpacity)
    }
  }

  private var resolvedOpacity: Double {
    descriptor.isEnabled ? 1 : (descriptor.disabledOpacity ?? 1)
  }
}

struct DashPageActionGroupView: View {
  let actions: [DashPageActionDescriptor]
  var allowsInteraction = true

  var body: some View {
    DashToolbarActionGroup {
      ForEach(actions) { action in
        DashPageActionControl(
          descriptor: action,
          allowsInteraction: allowsInteraction)
      }
    }
  }
}

enum DashPageChromeMetrics {
  static let controlSize = AvatarHeaderMetrics.barSize
  static let topInset = AvatarHeaderMetrics.chromeInset
  /// Same gutter as catalog / feature scrolls (`DashTheme.Spacing.screen`) so
  /// the floated Back / avatar / inbox line up with the content column — not
  /// the tighter top chrome inset, which only owns the status-bar gap.
  static let horizontalInset = DashTheme.Spacing.screen
  static let reservedHeight = controlSize + topInset
  static let actionSpacing: CGFloat = 8
  static let maximumPrincipalWidth: CGFloat = 160
}

/// The opaque destination plate covers the workspace wash under pushed pages.
///
/// Flow and card root pushes still snap the plate to full opacity before the
/// first attached frame — otherwise the wash flashes in the gap between the
/// two pages. The Settings train is the exception: it mounts the plate at
/// zero and lets the route animator fade it in, so the glow dissolves on the
/// same timeline instead of cutting out under a vertical handoff. Dismiss
/// always starts covered so the animator can dissolve the plate away.
enum DashDestinationCanvasRules {
  struct Preparation: Equatable {
    let isHidden: Bool
    let alpha: CGFloat
  }

  static func preparation(
    sourceShowsDestinationCanvas: Bool,
    targetShowsDestinationCanvas: Bool,
    fadesCoverWithTransition: Bool = false
  ) -> Preparation {
    let shows = sourceShowsDestinationCanvas || targetShowsDestinationCanvas
    guard shows else {
      return Preparation(isHidden: true, alpha: 0)
    }
    // A workspace present from root starts uncovered; every other case that
    // needs the plate is already covered (or must be, before the first frame).
    let startsCovered =
      sourceShowsDestinationCanvas || !fadesCoverWithTransition
    return Preparation(isHidden: false, alpha: startsCovered ? 1 : 0)
  }
}

/// The centred identity of a page bar — glyph plus inline title. Shared so the
/// page-local fallback bar and the workspace header cannot drift apart in
/// glyph size, spacing, truncation, or the identifier UI tests query.
///
/// The title deliberately does NOT animate its own change. It briefly did — a
/// keyed glyph morph beside a `contentTransition` text dissolve — and the
/// animated blur ran per-frame main-thread work in the same window where the
/// page compositor's display link is already re-laying-out a live hero, which
/// dropped frames. A title change now lands whole; the header's seats keep
/// their animations, which are render-server work, not per-frame CPU.
struct DashPageChromeTitleView: View {
  let header: DashPageHeaderDescriptor

  var body: some View {
    HStack(spacing: 6) {
      DetailIconView(icon: header.icon, tint: header.tint)
        .layoutPriority(1)
      Text(header.title)
        .dashTextStyle(.sectionTitle)
        .foregroundStyle(DashTheme.strong)
        .lineLimit(1)
        .truncationMode(.tail)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("dash.navigation.title")
    }
    .frame(maxWidth: DashPageChromeMetrics.maximumPrincipalWidth)
  }
}
