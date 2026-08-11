import SwiftUI

// MARK: - Page chrome hosting

enum DashPageChromeAssetRules {
  static func leadingAsset(
    for dismissal: DashNavigationDismissal,
    rightToLeft: Bool
  ) -> String {
    switch dismissal {
    case .back:
      rightToLeft ? SolarAsset.chevronRight : SolarAsset.chevronLeft
    case .closeToWorkspaceRoot:
      // Page chrome uses the finer 2pt mark; the heavier close glyph is tray-only.
      SolarAsset.editClose
    }
  }
}

private struct DashPageNavigationBar: View {
  let entry: DashNavigationEntry
  let chrome: DashPageChromePreference
  let allowsBusinessActions: Bool
  let dismiss: () -> Void
  @Environment(\.layoutDirection) private var layoutDirection

  var body: some View {
    ZStack {
      if let header = chrome.header {
        DashPageChromeTitleView(header: header)
      }

      HStack(spacing: DashPageChromeMetrics.actionSpacing) {
        leadingControl
        Spacer(minLength: 0)
        if !chrome.trailingActions.isEmpty {
          DashPageActionGroupView(
            actions: chrome.trailingActions,
            allowsInteraction: allowsBusinessActions)
        }
      }
    }
    .frame(height: DashPageChromeMetrics.controlSize)
    .padding(.horizontal, DashPageChromeMetrics.horizontalInset)
    .padding(.top, DashPageChromeMetrics.topInset)
    .frame(maxWidth: .infinity, alignment: .top)
  }

  @ViewBuilder private var leadingControl: some View {
    if !chrome.leadingActions.isEmpty {
      DashPageActionGroupView(
        actions: chrome.leadingActions,
        allowsInteraction: allowsBusinessActions)
    } else {
      switch entry.dismissal {
      case .back:
        DashToolbarIconButton(
          asset: DashPageChromeAssetRules.leadingAsset(
            for: .back,
            rightToLeft: layoutDirection == .rightToLeft),
          accessibilityLabel: DashL10n.string("Back"),
          action: dismiss
        )
        .accessibilityIdentifier("dash.navigation.back")
      case .closeToWorkspaceRoot:
        DashToolbarIconButton(
          asset: DashPageChromeAssetRules.leadingAsset(
            for: .closeToWorkspaceRoot,
            rightToLeft: layoutDirection == .rightToLeft),
          accessibilityLabel: DashL10n.string("Close"),
          action: dismiss
        )
        .accessibilityIdentifier("dash.navigation.close")
      }
    }
  }
}

private struct DashPageEscapeActionModifier: ViewModifier {
  let isEnabled: Bool
  let action: () -> Void

  @ViewBuilder
  func body(content: Content) -> some View {
    if isEnabled {
      content.accessibilityAction(.escape, action)
    } else {
      content
    }
  }
}

/// The visible leading replacement owns VoiceOver Escape too. Equality ignores
/// the closure deliberately: a page action's stable ID and enabled state define
/// its lifetime, while SwiftUI's state-backed action keeps reading live values.
private struct DashPageEscapeActionPreference: Equatable {
  let id: String
  let isEnabled: Bool
  let action: () -> Void

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id && lhs.isEnabled == rhs.isEnabled
  }
}

private struct DashPageEscapeActionPreferenceKey: PreferenceKey {
  static var defaultValue: DashPageEscapeActionPreference? { nil }

  static func reduce(
    value: inout DashPageEscapeActionPreference?,
    nextValue: () -> DashPageEscapeActionPreference?
  ) {
    if let next = nextValue() { value = next }
  }
}

/// Page-local custom chrome used by Dash's UIKit page container. It
/// deliberately lives in the same SwiftUI tree as the page so dynamic actions,
/// frost, and scroll probing retain their existing ownership.
struct DashRoutePageChromeHost<Content: View>: View {
  let entry: DashNavigationEntry?
  var allowsBodyInteraction = true
  @ViewBuilder var content: () -> Content
  @Environment(\.destinationNavigator) private var navigator
  @Environment(\.dashWorkspaceWashScroll) private var washScroll
  @State private var scroll = DashHeaderScrollState()
  @State private var pageChrome = DashPageChromePreference()
  @State private var preferredEscapeAction: DashPageEscapeActionPreference?

  var body: some View {
    Group {
      content()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(allowsBodyInteraction)
        .accessibilityHidden(!allowsBodyInteraction)
    }
    // Frost sits on the content, under the inset chrome — same z-order as under
    // UINavigationBar. The inset expands safeAreaInsets.top so content and
    // landing anchors share the physical screen's safe coordinate space.
    .overlayPreferenceValue(DashHeaderScrimHandledKey.self) { handled in
      if !handled {
        DashHeaderScrim(scroll: scroll)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
          .allowsHitTesting(false)
      }
    }
    .backgroundPreferenceValue(DashHeaderScrimHandledKey.self) { handled in
      if !handled {
        DashHeaderScrollProbe(scroll: scroll, wash: washScroll)
        DashScreenClipLift()
      }
    }
    .onPreferenceChange(DashPageChromePreferenceKey.self) { [$pageChrome] chrome in
      $pageChrome.wrappedValue = chrome
    }
    // The slots leave the page here — and deliberately NOT with `initial:
    // true`. The first body evaluation runs before the page's preferences have
    // propagated, so an initial publish speaks with the DEFAULT-EMPTY voice:
    // it blanks the shared title slot on the very frame the push lands, the
    // header's holdover never sees a "has not spoken" window, and every title
    // change degrades from a content morph into remove → gap → insert. The
    // store only ever hears chrome the page actually resolved; until then the
    // header holds the previous page's title.
    .onChange(of: pageChrome) { _, chrome in
      publishChrome(chrome)
    }
    .safeAreaInset(edge: .top, spacing: 0) {
      routeChromeInset
    }
    .preference(key: DashHeaderScrimHandledKey.self, value: true)
    .onPreferenceChange(DashPageEscapeActionPreferenceKey.self) { action in
      preferredEscapeAction = action
    }
    .modifier(
      DashPageEscapeActionModifier(
        isEnabled: entry != nil,
        action: {
          guard let entry else { return }
          if let preferredEscapeAction {
            guard preferredEscapeAction.isEnabled, allowsBodyInteraction else { return }
            preferredEscapeAction.action()
          } else {
            navigator?.dismiss(entryID: entry.id)
          }
        }))
  }

  /// Fixed-height top chrome so roots and destinations share one safe-area
  /// reservation. The reservation is the invariant and never moves; only the
  /// painting does. Under `.workspace` hosting the slot stays clear on every
  /// page, because the ONE header above the pager draws it.
  ///
  /// The constant height is also what keeps this host acyclic. The chrome
  /// preference is read OUT of the content and this inset is fed BACK IN as a
  /// top safe area — a closed loop by construction. It stays shut only because
  /// the inset's height is a compile-time constant: measure it from the bar's
  /// own content and a taller title would grow the inset, which re-lays-out
  /// the content that published the title. `check-ios-ui-architecture` asserts
  /// the constant for exactly this reason.
  @ViewBuilder private var routeChromeInset: some View {
    Group {
      if let entry, chromeHosting == .page {
        DashPageNavigationBar(
          entry: entry,
          chrome: pageChrome,
          allowsBusinessActions: allowsBodyInteraction,
          dismiss: { navigator?.dismiss(entryID: entry.id) }
        )
      } else {
        Color.clear
      }
    }
    .frame(height: DashPageChromeMetrics.reservedHeight)
    .frame(maxWidth: .infinity, alignment: .top)
  }

  /// A stored `let` on the navigator, so reading it registers no observation.
  private var chromeHosting: DashPageChromeHosting {
    navigator?.chromeHosting ?? .page
  }

  /// Published, never withdrawn on disappear: the page container detaches a
  /// covered page's view, and a page that came back would have no second
  /// `initial` change to republish from — it would return under a titleless
  /// bar. `DestinationNavigator` prunes the store when the entry itself goes.
  private func publishChrome(_ chrome: DashPageChromePreference) {
    guard chromeHosting == .workspace, let entry else { return }
    navigator?.pageChrome.publish(chrome, for: entry.id)
  }
}

private struct DashPageActionsModifier: ViewModifier {
  let leading: [DashPageActionDescriptor]
  let trailing: [DashPageActionDescriptor]

  func body(content: Content) -> some View {
    content
      // Mutate only the action slots. Replacing the whole preference here
      // would erase an inner `detailHeader` descriptor on the same page.
      .transformPreference(DashPageChromePreferenceKey.self) { preference in
        preference.leadingActions = leading
        preference.trailingActions = trailing
      }
      .preference(
        key: DashPageEscapeActionPreferenceKey.self,
        value: leading.first.map {
          DashPageEscapeActionPreference(
            id: $0.id,
            isEnabled: $0.isEnabled,
            action: $0.action)
        }
      )
      // Keep the same page-owned descriptor usable in isolated previews and
      // system-presented leaf contexts. Production routes consume the
      // preference above in Dash's custom chrome.
      .toolbar {
        if !leading.isEmpty {
          ToolbarItem(placement: .topBarLeading) {
            DashPageActionGroupView(actions: leading)
          }
          .dashSeparateToolbarBackground()
        }
        if !trailing.isEmpty {
          ToolbarItem(placement: .topBarTrailing) {
            DashPageActionGroupView(actions: trailing)
          }
          .dashSeparateToolbarBackground()
        }
      }
  }
}

extension View {
  /// Page-bar identity for a pushed detail screen: the feature glyph or avatar
  /// ahead of the title. Dash's custom chrome consumes the descriptor; the
  /// native modifiers underneath keep isolated previews usable.
  ///
  /// Tint resolution: explicit `tint` → feature hero → brand.
  func detailHeader(icon: DetailIcon, title: String, tint: Color? = nil) -> some View {
    modifier(DetailHeaderModifier(icon: icon, title: title, tint: tint))
  }

  /// Page-owned navigation actions. The descriptor form is intentionally
  /// finite: it can render in both the native bridge and Dash's custom chrome
  /// without moving arbitrary SwiftUI view identity across hosting trees.
  func dashPageActions(
    leading: [DashPageActionDescriptor] = [],
    trailing: [DashPageActionDescriptor] = []
  ) -> some View {
    modifier(DashPageActionsModifier(leading: leading, trailing: trailing))
  }
}

private struct DetailHeaderModifier: ViewModifier {
  /// Leaves a stable trailing region for the widest shared toolbar group
  /// (two 44pt actions plus their gap) on a compact portrait iPhone. The
  /// toolbar can still propose less space when a text action or large Dynamic
  /// Type needs it.
  private static let maximumPrincipalWidth: CGFloat = 160

  let icon: DetailIcon
  let title: String
  var tint: Color?
  @Environment(\.featureIdentity) private var featureIdentity

  private var resolvedTint: Color {
    if let tint { return tint }
    if let feature = featureIdentity {
      return FeatureVisualIdentity.heroColor(for: feature)
    }
    return DashTheme.brand
  }

  private var displayedTitle: String { DashL10n.ui(title) }

  func body(content: Content) -> some View {
    content
      // Preserve page actions regardless of modifier order.
      .transformPreference(DashPageChromePreferenceKey.self) { preference in
        preference.header = DashPageHeaderDescriptor(
          icon: icon,
          title: displayedTitle,
          tint: resolvedTint)
      }
      .navigationTitle(displayedTitle)
      .toolbar {
        ToolbarItem(placement: .principal) {
          HStack(spacing: 6) {
            DetailIconView(icon: icon, tint: resolvedTint)
              .layoutPriority(1)
            Text(displayedTitle)
              .dashTextStyle(.sectionTitle)
              .foregroundStyle(DashTheme.strong)
              .lineLimit(1)
              .truncationMode(.tail)
          }
          .frame(maxWidth: Self.maximumPrincipalWidth)
        }
        // Root principals are a clear 1×1 prop (no glass). A real title + icon
        // principal gets iOS 26's shared Liquid Glass plate — a gray capsule
        // over the canvas — unless the shared background is hidden.
        .dashSeparateToolbarBackground()
      }
  }
}
