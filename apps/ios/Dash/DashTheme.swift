import SwiftUI
import UIKit

@MainActor
enum DashScreenMetrics {
  /// Matches the display's physical corner radius when available.
  static var displayCornerRadius: CGFloat {
    guard
      let screen = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene })
        .first?.screen
    else { return 47.33 }

    if let radius = screen.value(forKey: "_displayCornerRadius") as? CGFloat, radius > 10 {
      return radius
    }

    let height = max(screen.nativeBounds.width, screen.nativeBounds.height)
    switch height {
    case 2868, 2796, 2622, 2556: return 55.75
    case 2532, 2460, 2778: return 47.33
    default:
      if height >= 2700 { return 55.75 }
      if height >= 2500 { return 47.33 }
      return 39
    }
  }

  /// Gives list states enough height to read as screen content instead of a stray list cell.
  static var emptyStateHeight: CGFloat {
    guard
      let screen = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene })
        .first?.screen
    else { return 520 }
    return max(420, min(screen.bounds.height - 280, 680))
  }
}

enum DashTheme {
  enum Radius {
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let button: CGFloat = 18
    static let card: CGFloat = 20
    static let sheet: CGFloat = 36
  }

  static var buttonShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
  }

  enum Spacing {
    static let screen: CGFloat = 16
    static let section: CGFloat = 20
    static let card: CGFloat = 16
    static let listRow: CGFloat = 6
    static let listInset: CGFloat = 0
  }

  enum Sheet {
    static let horizontalInset: CGFloat = 12
    static let bottomInset: CGFloat = 0
    static let content: CGFloat = 24
    static let headerTop: CGFloat = 28
    static let headerBottom: CGFloat = 14
    static let bodyVertical: CGFloat = 16
    static let outerBottom: CGFloat = 20
    static let bodyBottom: CGFloat = 32
    static let grabBarWidth: CGFloat = 36
    static let grabBarHeight: CGFloat = 5
    static let grabBarTop: CGFloat = 10
    static let grabBarBottom: CGFloat = 8
    static let closeIcon = Color(hex: 0x9B9A9D)
    static let headerBorder = Color(hex: 0xF9F7FA)
    static let shortcutItem = Color(hex: 0xF9F9FB)
    static let scrimOpacity: CGFloat = 0.35
  }

  static let canvas = adaptive(light: 0xFFFFFF, dark: 0x1A1A1A)
  static let elevated = adaptive(light: 0xFAFAFA, dark: 0x1F1F1F)
  static let recessed = adaptive(light: 0xF5F5F5, dark: 0x262626)
  static let base = adaptive(light: 0xFFFFFF, dark: 0x2B2B2B)
  static let tint = adaptive(light: 0xF7F7F7, dark: 0x404040)
  static let control = adaptive(light: 0xFFFFFF, dark: 0x212126)
  static let fill = adaptive(light: 0xE5E5E5, dark: 0x404040)

  static let text = adaptive(light: 0x212126, dark: 0xF5F5F5)
  static let strong = adaptive(light: 0x171717, dark: 0xFAFAFA)
  static let subtle = adaptive(light: 0x717171, dark: 0xA3A3A3)
  static let placeholder = adaptive(light: 0xA3A3A3, dark: 0x717171)
  static let inverse = adaptive(light: 0xFFFFFF, dark: 0x171717)

  static let accent = Color(hex: 0xF6821F)
  static let brand = adaptive(light: 0x1460E6, dark: 0x1256D6)
  static let line = adaptive(light: 0xE5E5E5, dark: 0x525252)
  static let hairline = adaptive(light: 0xEEEEEE, dark: 0x404040)
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
  static func dashRounded(size: CGFloat, weight: UIFont.Weight) -> UIFont {
    let system = UIFont.systemFont(ofSize: size, weight: weight)
    guard let descriptor = system.fontDescriptor.withDesign(.rounded) else { return system }
    return UIFont(descriptor: descriptor, size: size)
  }
}

extension Color {
  fileprivate init(hex: UInt32) {
    self.init(uiColor: UIColor(hex: hex))
  }
}

extension Font {
  static func dashTitle(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
    .system(size: size, weight: weight, design: .rounded)
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
      .background(DashTheme.base)
      .clipShape(RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous)
          .stroke(DashTheme.line, lineWidth: 0.5)
      }
      .dashCardShadow()
  }
}

struct DashListGroupLink<Label: View>: View {
  let value: Destination
  var heroOrigin: FeatureHeroOrigin?
  var onNavigate: (() -> Void)?
  @ViewBuilder let label: () -> Label
  @Environment(FeatureTransitionCoordinator.self) private var transitionCoordinator
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    switch value {
    case .feature(let feature):
      Button {
        guard let heroOrigin else { return }
        transitionCoordinator.present(feature, from: heroOrigin, reduceMotion: reduceMotion)
        onNavigate?()
      } label: {
        label()
          .environment(\.featureHeroOrigin, heroOrigin)
          .featureCardSource(feature)
      }
      .buttonStyle(DashPressButtonStyle())
    default:
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

/// Routes `Destination` values; feature opens via overlay instead of push.
struct DashDestinationLink<Label: View>: View {
  let destination: Destination
  var heroOrigin: FeatureHeroOrigin?
  @ViewBuilder let label: () -> Label
  @Environment(FeatureTransitionCoordinator.self) private var transitionCoordinator
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    switch destination {
    case .feature(let feature):
      Button {
        guard let heroOrigin else { return }
        transitionCoordinator.present(feature, from: heroOrigin, reduceMotion: reduceMotion)
      } label: {
        label()
          .environment(\.featureHeroOrigin, heroOrigin)
          .featureCardSource(feature)
      }
      .buttonStyle(DashPressButtonStyle())
    default:
      NavigationLink(value: destination) {
        label()
      }
      .listRowSeparator(.hidden)
      .listSectionSeparator(.hidden)
    }
  }
}

struct DashListGroupDivider: View {
  var body: some View {
    Divider().overlay(DashTheme.hairline)
  }
}

/// Home/Items-style list card without a section title.
struct DashListCard<Content: View>: View {
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 0) { content() }
      .padding(.horizontal, 16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(DashTheme.base)
      .clipShape(RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous)
          .stroke(DashTheme.line, lineWidth: 0.5)
      }
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
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(DashTheme.text)
        .focused(focusBinding)
        .submitLabel(.search)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
      if !text.isEmpty {
        Button {
          withAnimation(.easeOut(duration: 0.16)) { text = "" }
        } label: {
          SolarIcon(asset: SolarAsset.close, size: 18, color: DashTheme.subtle)
        }
        .buttonStyle(DashPressButtonStyle())
        .accessibilityLabel("Clear search")
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
      }
    }
    .padding(.horizontal, 16)
    .frame(minHeight: 52)
    .background(DashTheme.base)
    .clipShape(RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous)
        .stroke(
          focusBinding.wrappedValue ? DashTheme.brand.opacity(0.45) : DashTheme.line,
          lineWidth: focusBinding.wrappedValue ? 1.5 : 0.5
        )
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
              .frame(maxWidth: .infinity, minHeight: DashScreenMetrics.emptyStateHeight)
          } else if let error {
            ErrorStateView(message: error, retry: retry)
          } else {
            content()
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
  var action: (() -> Void)?
  private let content: Content

  init(
    title: String, actionTitle: String? = nil, action: (() -> Void)? = nil,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.actionTitle = actionTitle
    self.action = action
    self.content = content()
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Text(title)
          .font(.system(size: 16, weight: .medium))
          .foregroundStyle(DashTheme.subtle)
        Spacer(minLength: 0)
        if let actionTitle, let action {
          Button(actionTitle, action: action)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(DashTheme.brand)
            .buttonStyle(DashOpacityButtonStyle())
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)

      DashListCard { content }
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

private struct FeatureZoomNamespaceKey: EnvironmentKey {
  static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
  var featureZoomNamespace: Namespace.ID? {
    get { self[FeatureZoomNamespaceKey.self] }
    set { self[FeatureZoomNamespaceKey.self] = newValue }
  }

  /// Kept for call sites that already pass the shared namespace.
  var featureHeroNamespace: Namespace.ID? {
    get { featureZoomNamespace }
    set { featureZoomNamespace = newValue }
  }
}

// MARK: - Feature navigation transitions (overlay hero)

/// Distinguishes duplicate features across Home sections and Items categories.
enum FeatureHeroOrigin: Hashable {
  case shortcuts
  case frequent
  case recent
  case editShortcuts
  case itemsCategory(String)
  case itemsSearch
  case watchtower

  var stableID: String {
    switch self {
    case .shortcuts: "shortcuts"
    case .frequent: "frequent"
    case .recent: "recent"
    case .editShortcuts: "edit-shortcuts"
    case .itemsCategory(let name): "items-\(name)"
    case .itemsSearch: "items-search"
    case .watchtower: "watchtower"
    }
  }
}

struct SelectedFeature: Hashable {
  let origin: FeatureHeroOrigin
  let feature: FeatureID
}

private struct FeatureHeroOriginKey: EnvironmentKey {
  static let defaultValue: FeatureHeroOrigin? = nil
}

extension EnvironmentValues {
  var featureHeroOrigin: FeatureHeroOrigin? {
    get { self[FeatureHeroOriginKey.self] }
    set { self[FeatureHeroOriginKey.self] = newValue }
  }
}

enum FeatureHeroPart {
  case icon, title, card
}

enum FeatureHeroID {
  static func icon(origin: FeatureHeroOrigin, _ feature: FeatureID) -> String {
    "\(origin.stableID)-\(feature.id)-icon"
  }

  static func title(origin: FeatureHeroOrigin, _ feature: FeatureID) -> String {
    "\(origin.stableID)-\(feature.id)-title"
  }

  static func card(origin: FeatureHeroOrigin, _ feature: FeatureID) -> String {
    "\(origin.stableID)-\(feature.id)-card"
  }
}

enum FeatureHeroZIndex {
  static let listCard: Double = 100
  static let detailCard: Double = 200
  static let icon: Double = 300
  static let title: Double = 301
  static let detailShell: Double = 10
  static let heroShell: Double = 999
}

enum FeatureTransitionMotion {
  static let duration: TimeInterval = 0.38
  static var hero: Animation { .smooth(duration: duration, extraBounce: 0) }
}

@MainActor
@Observable
final class FeatureTransitionCoordinator {
  var selection: SelectedFeature?
  var presentedFeature: FeatureID?
  private(set) var isTransitioning = false
  @ObservationIgnored private var transitionTask: Task<Void, Never>?

  var isAnimatingHero: Bool { isTransitioning }

  func present(_ feature: FeatureID, from origin: FeatureHeroOrigin, reduceMotion: Bool = false) {
    transitionTask?.cancel()
    selection = SelectedFeature(origin: origin, feature: feature)
    guard !reduceMotion else {
      isTransitioning = false
      presentedFeature = feature
      return
    }
    isTransitioning = true
    withAnimation(FeatureTransitionMotion.hero) {
      presentedFeature = feature
    }
    finishTransition(after: FeatureTransitionMotion.duration)
  }

  func dismiss(reduceMotion: Bool = false) {
    transitionTask?.cancel()
    guard !reduceMotion else {
      isTransitioning = false
      presentedFeature = nil
      selection = nil
      return
    }
    isTransitioning = true
    withAnimation(FeatureTransitionMotion.hero) {
      presentedFeature = nil
    }
    transitionTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(Int(FeatureTransitionMotion.duration * 1000)))
      guard !Task.isCancelled else { return }
      isTransitioning = false
      clearSelectionIfNeeded()
    }
  }

  private func finishTransition(after duration: TimeInterval) {
    transitionTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(Int(duration * 1000)))
      guard !Task.isCancelled else { return }
      isTransitioning = false
    }
  }

  func clearSelectionIfNeeded() {
    guard presentedFeature == nil else { return }
    selection = nil
  }
}

/// Collapsed header title: compact icon before text.
private struct FeatureInlineNavigationTitle: View {
  let feature: FeatureID
  let title: String

  var body: some View {
    HStack(spacing: 6) {
      CatalogFeatureIcon(feature: feature, size: .compact)
        .featureHeroDestination(feature, part: .icon)
      Text(title)
        .font(.headline)
        .foregroundStyle(DashTheme.strong)
        .lineLimit(1)
        .featureHeroDestination(feature, part: .title)
    }
  }
}

/// Custom in-tree navigation bar; hero targets live here instead of UIKit toolbar.
struct FeatureHeroNavigationBar: View {
  let feature: FeatureID
  let title: String
  let onDismiss: () -> Void

  var body: some View {
    ZStack {
      HStack {
        Button(action: onDismiss) {
          SolarIcon(asset: SolarAsset.chevronLeft, size: 18, color: DashTheme.strong)
            .frame(width: AvatarHeaderMetrics.barSize, height: AvatarHeaderMetrics.barSize)
            .background(DashTheme.base, in: Circle())
            .overlay { Circle().stroke(DashTheme.line, lineWidth: 0.5) }
        }
        .buttonStyle(DashPressButtonStyle())
        .accessibilityLabel("Back")

        Spacer(minLength: 0)
      }

      FeatureInlineNavigationTitle(feature: feature, title: title)
    }
    .padding(.horizontal, DashTheme.Spacing.screen)
    .frame(height: AvatarHeaderMetrics.barSize)
    .background(DashTheme.canvas)
  }
}

/// Feature drill-down shell: custom header above scrollable content.
struct FeatureDetailChrome<Content: View>: View {
  let feature: FeatureID
  let onDismiss: () -> Void
  @ViewBuilder var content: () -> Content

  var body: some View {
    VStack(spacing: 0) {
      FeatureHeroNavigationBar(feature: feature, title: feature.title, onDismiss: onDismiss)
      content()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(DashTheme.canvas)
    .safeAreaPadding(.top)
    .toolbar(.hidden, for: .navigationBar)
  }
}

/// Full-screen overlay detail; shares namespace with the list card for hero transitions.
struct FeatureDetailOverlay: View {
  let feature: FeatureID
  let onDismiss: () -> Void

  @Environment(\.showsEditShortcuts) private var showsEditShortcuts
  @Environment(FeatureTransitionCoordinator.self) private var transitionCoordinator
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    NavigationStack {
      FeatureDetailChrome(feature: feature, onDismiss: onDismiss) {
        FeatureRouterContent(feature: feature)
      }
      .destinationRouting()
    }
    .featureCardDestination(feature)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(DashTheme.canvas)
    .clipShape(
      RoundedRectangle(
        cornerRadius: transitionCoordinator.presentedFeature == nil
          ? DashTheme.Radius.card : 0,
        style: .continuous
      )
    )
    .ignoresSafeArea()
    .onAppear {
      showsEditShortcuts.wrappedValue = false
    }
    .onDisappear {
      transitionCoordinator.clearSelectionIfNeeded()
    }
  }
}

extension View {
  func featureCardSource(_ feature: FeatureID) -> some View {
    modifier(FeatureCardSourceModifier(feature: feature))
  }

  func featureCardDestination(_ feature: FeatureID) -> some View {
    modifier(FeatureCardDestinationModifier(feature: feature))
  }

  func featureHeroDestination(_ feature: FeatureID, part: FeatureHeroPart) -> some View {
    modifier(FeatureHeroDestinationModifier(feature: feature, part: part))
  }

  func featureHeroSource(_ feature: FeatureID, part: FeatureHeroPart) -> some View {
    modifier(FeatureHeroSourceModifier(feature: feature, part: part))
  }
}

private struct FeatureCardSourceModifier: ViewModifier {
  @Environment(\.featureZoomNamespace) private var namespace
  @Environment(\.featureHeroOrigin) private var rowOrigin
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(FeatureTransitionCoordinator.self) private var transitionCoordinator
  let feature: FeatureID

  func body(content: Content) -> some View {
    if isActiveSource,
      let rowOrigin,
      let namespace,
      !reduceMotion
    {
      content
        .matchedGeometryEffect(
          id: FeatureHeroID.card(origin: rowOrigin, feature),
          in: namespace,
          properties: .frame,
          anchor: .center,
          isSource: true
        )
        .zIndex(
          transitionCoordinator.isAnimatingHero ? FeatureHeroZIndex.listCard : 0
        )
    } else {
      content
    }
  }

  private var isActiveSource: Bool {
    guard transitionCoordinator.isAnimatingHero else { return false }
    guard let rowOrigin,
      let selection = transitionCoordinator.selection
    else { return false }
    return selection.origin == rowOrigin && selection.feature == feature
  }
}

private struct FeatureCardDestinationModifier: ViewModifier {
  @Environment(\.featureZoomNamespace) private var namespace
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(FeatureTransitionCoordinator.self) private var transitionCoordinator
  let feature: FeatureID

  func body(content: Content) -> some View {
    if transitionCoordinator.isAnimatingHero,
      let selection = transitionCoordinator.selection,
      selection.feature == feature,
      let namespace,
      !reduceMotion
    {
      content
        .matchedGeometryEffect(
          id: FeatureHeroID.card(origin: selection.origin, feature),
          in: namespace,
          properties: .frame,
          anchor: .center,
          isSource: false
        )
        .zIndex(FeatureHeroZIndex.detailCard)
    } else {
      content
    }
  }
}

private struct FeatureHeroDestinationModifier: ViewModifier {
  @Environment(\.featureZoomNamespace) private var namespace
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(FeatureTransitionCoordinator.self) private var transitionCoordinator
  let feature: FeatureID
  let part: FeatureHeroPart

  func body(content: Content) -> some View {
    if part == .card {
      content
    } else if transitionCoordinator.isAnimatingHero,
      let selection = transitionCoordinator.selection,
      selection.feature == feature,
      let namespace,
      !reduceMotion
    {
      content
        .matchedGeometryEffect(
          id: heroID(origin: selection.origin),
          in: namespace,
          properties: .frame,
          anchor: .center,
          isSource: false
        )
        .zIndex(
          transitionCoordinator.isAnimatingHero ? zIndexForPart : 0
        )
    } else {
      content
    }
  }

  private var zIndexForPart: Double {
    switch part {
    case .icon: FeatureHeroZIndex.icon
    case .title: FeatureHeroZIndex.title
    case .card: FeatureHeroZIndex.detailCard
    }
  }

  private func heroID(origin: FeatureHeroOrigin) -> String {
    switch part {
    case .icon: FeatureHeroID.icon(origin: origin, feature)
    case .title: FeatureHeroID.title(origin: origin, feature)
    case .card: FeatureHeroID.card(origin: origin, feature)
    }
  }
}

private struct FeatureHeroSourceModifier: ViewModifier {
  @Environment(\.featureZoomNamespace) private var namespace
  @Environment(\.featureHeroOrigin) private var rowOrigin
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(FeatureTransitionCoordinator.self) private var transitionCoordinator
  let feature: FeatureID
  let part: FeatureHeroPart

  func body(content: Content) -> some View {
    if isActiveSource,
      let rowOrigin,
      let namespace,
      !reduceMotion
    {
      content
        .matchedGeometryEffect(
          id: heroID(origin: rowOrigin),
          in: namespace,
          properties: .frame,
          anchor: .center,
          isSource: true
        )
        .zIndex(
          transitionCoordinator.isAnimatingHero ? zIndexForPart : 0
        )
    } else {
      content
    }
  }

  private var isActiveSource: Bool {
    guard transitionCoordinator.isAnimatingHero else { return false }
    guard let rowOrigin,
      let selection = transitionCoordinator.selection
    else { return false }
    return selection.origin == rowOrigin && selection.feature == feature
  }

  private var zIndexForPart: Double {
    switch part {
    case .icon: FeatureHeroZIndex.icon
    case .title: FeatureHeroZIndex.title
    case .card: FeatureHeroZIndex.listCard
    }
  }

  private func heroID(origin: FeatureHeroOrigin) -> String {
    switch part {
    case .icon: FeatureHeroID.icon(origin: origin, feature)
    case .title: FeatureHeroID.title(origin: origin, feature)
    case .card: FeatureHeroID.card(origin: origin, feature)
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
      .font(.system(size: 12, weight: .semibold))
      .foregroundStyle(colors.foreground)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(colors.background, in: Capsule())
  }
}

struct LoadingStateView: View {
  var body: some View {
    ProgressView()
      .tint(DashTheme.brand)
      .frame(maxWidth: .infinity, minHeight: DashScreenMetrics.emptyStateHeight)
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

struct DashOpacityButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
  }
}

struct DashPressButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
      .opacity(configuration.isPressed ? 0.82 : 1)
      .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
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
        .font(.dashTitle(24))
        .foregroundStyle(DashTheme.strong)
        .multilineTextAlignment(.center)
      Text(message)
        .font(.system(size: 15))
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
    .frame(maxWidth: .infinity, minHeight: DashScreenMetrics.emptyStateHeight)
    .listRowInsets(EdgeInsets())
    .listRowSeparator(.hidden)
    .listSectionSeparator(.hidden)
    .listRowBackground(Color.clear)
  }
}

extension View {
  func dashCardShadow() -> some View {
    shadow(color: .black.opacity(0.04), radius: 1, y: 1)
      .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
  }

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
          .font(.system(size: 16, weight: .medium))
          .foregroundStyle(DashTheme.text)
        if let subtitle {
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(DashTheme.subtle)
        }
      }
      Spacer(minLength: 12)
      Text(value)
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(DashTheme.subtle)
        .multilineTextAlignment(.trailing)
        .lineLimit(2)
    }
    .padding(.vertical, 14)
  }
}

struct DashToggleRow: View {
  let title: String
  var subtitle: String?
  @Binding var isOn: Bool
  var isEnabled = true

  var body: some View {
    Toggle(isOn: $isOn) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.system(size: 16, weight: .medium))
          .foregroundStyle(DashTheme.text)
        if let subtitle {
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(DashTheme.subtle)
        }
      }
    }
    .tint(DashTheme.brand)
    .padding(.vertical, 12)
    .disabled(!isEnabled)
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
          .font(.dashTitle(18, weight: .semibold))
          .foregroundStyle(DashTheme.strong)
        if let message {
          Text(message)
            .font(.caption)
            .foregroundStyle(DashTheme.subtle)
        }
      }

      TextEditor(text: $text)
        .font(.system(size: 13, design: .monospaced))
        .foregroundStyle(DashTheme.text)
        .scrollContentBackground(.hidden)
        .disabled(!isEditable)
        .frame(minHeight: minHeight)
        .padding(12)
        .background(DashTheme.recessed)
        .clipShape(RoundedRectangle(cornerRadius: DashTheme.Radius.medium, style: .continuous))
    }
    .padding(DashTheme.Spacing.card)
    .background(DashTheme.base)
    .clipShape(RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous)
        .stroke(DashTheme.line, lineWidth: 0.5)
    }
    .dashCardShadow()
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
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(colors.foreground)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(16)
    .background(colors.background)
    .clipShape(RoundedRectangle(cornerRadius: DashTheme.Radius.medium, style: .continuous))
  }
}

struct DashListButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .opacity(configuration.isPressed ? 0.58 : 1)
      .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
  }
}

struct DashSectionHeader: View {
  let title: String

  init(_ title: String) {
    self.title = title
  }

  var body: some View {
    Text(title)
      .font(.system(size: 18, weight: .semibold, design: .rounded))
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
    SolarIcon(asset: asset, size: 18, color: DashTheme.inverse)
      .frame(width: 36, height: 36)
      .background(DashTheme.strong, in: Circle())
      .accessibilityHidden(true)
  }
}

struct DashTextTabs<Selection: Hashable>: View {
  let items: [(title: String, value: Selection)]
  @Binding var selection: Selection

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 28) {
        ForEach(items.indices, id: \.self) { index in
          let item = items[index]
          Button {
            withAnimation(.easeOut(duration: 0.22)) {
              selection = item.value
            }
          } label: {
            Text(item.title)
              .font(.system(size: 18, weight: .semibold, design: .rounded))
              .foregroundStyle(selection == item.value ? DashTheme.strong : DashTheme.placeholder)
              .contentTransition(.interpolate)
          }
          .buttonStyle(DashPressButtonStyle())
          .accessibilityAddTraits(selection == item.value ? .isSelected : [])
        }
      }
      .padding(.vertical, 4)
    }
    .scrollClipDisabled()
    .frame(maxWidth: .infinity, alignment: .leading)
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
      .font(.system(size: 16, weight: .medium))
      .buttonStyle(DashListButtonStyle())
      .tint(DashTheme.strong)
      .headerProminence(.increased)
      .scrollContentBackground(.hidden)
      .background(DashTheme.canvas)
      .foregroundStyle(DashTheme.text)
  }
}
