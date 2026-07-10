import CloudflareAPI
import SwiftUI
import UIKit

struct AppRootView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    switch model.authState {
    case .loading:
      ZStack {
        DashTheme.canvas.ignoresSafeArea()
        ProgressView().tint(DashTheme.brand)
      }
    case .unauthenticated:
      LoginView()
    case .authenticated:
      MainTabView()
    }
  }
}

private struct LoginView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    ZStack {
      DashTheme.canvas.ignoresSafeArea()
      ScrollView {
        VStack(spacing: 32) {
          Spacer(minLength: 80)
          VStack(spacing: 16) {
            ZStack {
              Circle().fill(DashTheme.accent)
              SolarIcon(asset: SolarAsset.cloud, size: 32, color: DashTheme.inverse)
            }
            .frame(width: 72, height: 72)
            Text("Dash")
              .font(.dashTitle(40))
              .foregroundStyle(DashTheme.strong)
            Text(
              "Zones, DNS, cache, security and analytics — your Cloudflare account in your pocket."
            )
            .font(.system(size: 15))
            .foregroundStyle(DashTheme.subtle)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
          }

          if let error = model.errorMessage {
            Text(error)
              .font(.system(size: 14))
              .foregroundStyle(DashTheme.danger)
              .multilineTextAlignment(.center)
          }

          DashPillButton(
            title: "Connect Cloudflare",
            isLoading: model.isAuthenticating,
            action: { model.signIn() }
          )
          .disabled(!model.configuration.isConfigured)
          .opacity(model.configuration.isConfigured ? 1 : 0.5)

          PermissionSelectionView()

          if !model.configuration.isConfigured {
            DashCard {
              VStack(alignment: .leading, spacing: 8) {
                Text("Almost ready")
                  .font(.system(size: 16, weight: .semibold))
                Text(
                  "Add Config/Secrets.xcconfig with your OAuth client values, then rebuild Dash."
                )
                .font(.system(size: 14))
                .foregroundStyle(DashTheme.subtle)
                .fixedSize(horizontal: false, vertical: true)
              }
            }
          }

          DashCard {
            Text("Secure OAuth with PKCE. Your credentials never pass through the callback relay.")
              .font(.system(size: 13))
              .foregroundStyle(DashTheme.subtle)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 24)
        }
        .frame(maxWidth: 448)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
      }
    }
  }
}

private struct PermissionSelectionView: View {
  @Environment(AppModel.self) private var model
  @State private var expanded = false

  private var categories: [(key: String, values: [OAuthScopeDefinition])] {
    OAuthScopeCatalog.categories
      .map { ($0.key, $0.value.sorted { $0.name < $1.name }) }
      .sorted { ($0.1.first?.categoryTitle ?? $0.0) < ($1.1.first?.categoryTitle ?? $1.0) }
  }

  var body: some View {
    DashCard {
      DisclosureGroup(isExpanded: $expanded) {
        VStack(spacing: 14) {
          Toggle(isOn: allBinding) {
            permissionLabel(
              "All OAuth-enabled permissions",
              detail:
                "\(model.selectedScopes.count) of \(CloudflareScopes.published.count) selected"
            )
          }
          .tint(DashTheme.brand)

          ForEach(categories, id: \.key) { category in
            DisclosureGroup {
              VStack(spacing: 10) {
                ForEach(category.values) { scope in
                  Toggle(isOn: scopeBinding(scope.id)) {
                    permissionLabel(
                      scope.name,
                      detail: scope.id,
                      risk: scope.risk,
                      unavailable: CloudflareScopes.unsupportedByOAuthClient.contains(scope.id)
                    )
                  }
                  .tint(DashTheme.brand)
                  .disabled(
                    CloudflareScopes.required.contains(scope.id)
                      || CloudflareScopes.unsupportedByOAuthClient.contains(scope.id)
                  )
                }
              }
              .padding(.top, 8)
            } label: {
              Toggle(isOn: categoryBinding(category.values)) {
                Text(category.values.first?.categoryTitle ?? category.key)
                  .font(.subheadline.weight(.medium))
                  .foregroundStyle(DashTheme.text)
              }
              .tint(DashTheme.brand)
            }
          }
        }
        .padding(.top, 14)
      } label: {
        VStack(alignment: .leading, spacing: 4) {
          Text("Permissions")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(DashTheme.strong)
          Text("All published capabilities are selected by default. Expand to customize.")
            .font(.caption)
            .foregroundStyle(DashTheme.subtle)
        }
      }
    }
  }

  private var allBinding: Binding<Bool> {
    Binding(
      get: { Set(CloudflareScopes.published).isSubset(of: model.selectedScopes) },
      set: { enabled in
        model.selectedScopes =
          enabled ? Set(CloudflareScopes.published) : Set(CloudflareScopes.required)
      }
    )
  }

  private func categoryBinding(_ scopes: [OAuthScopeDefinition]) -> Binding<Bool> {
    let requestable = Set(scopes.map(\.id)).intersection(CloudflareScopes.requestable)
    return Binding(
      get: { requestable.isSubset(of: model.selectedScopes) },
      set: { model.setScopeCategory(scopes, enabled: $0) }
    )
  }

  private func scopeBinding(_ scope: String) -> Binding<Bool> {
    Binding(
      get: { model.selectedScopes.contains(scope) },
      set: { enabled in
        if enabled, CloudflareScopes.requestable.contains(scope) {
          model.selectedScopes.insert(scope)
        } else if !CloudflareScopes.required.contains(scope) {
          model.selectedScopes.remove(scope)
        }
      }
    )
  }

  private func permissionLabel(
    _ title: String,
    detail: String,
    risk: OAuthScopeRisk = .read,
    unavailable: Bool = false
  ) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 6) {
        Text(title)
          .font(.caption.weight(.medium))
          .foregroundStyle(DashTheme.text)
        if risk == .elevated {
          Text("Elevated")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(DashTheme.warning)
        }
        if unavailable {
          Text("OAuth unavailable")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(DashTheme.danger)
        }
      }
      Text(detail)
        .font(.caption2)
        .foregroundStyle(DashTheme.subtle)
    }
  }
}

private enum AppTab: Hashable { case home, items, watchtower, search }

private struct FeatureNavigationStack<Root: View>: View {
  @Binding var path: NavigationPath
  @ViewBuilder let root: () -> Root

  var body: some View {
    NavigationStack(path: $path) {
      root()
        .destinationRouting()
    }
  }
}

/// Search-role tab. The searchable host stays mounted while UIKit animates the
/// whole tab bar off-screen, preserving the bottom morph across push and pop.
private struct SearchNavigationStack: View {
  @Binding var search: String
  @Binding var path: NavigationPath

  var body: some View {
    NavigationStack(path: $path) {
      SearchView(search: $search)
        .destinationRouting()
    }
    // Plain `.searchable` only — no `isPresented` / toolbar placement overrides.
    .searchable(text: $search, prompt: "Features, zones…")
  }
}

private struct MainTabView: View {
  @State private var selection: AppTab = .home
  @State private var homePath = NavigationPath()
  @State private var itemsPath = NavigationPath()
  @State private var watchtowerPath = NavigationPath()
  @State private var search = ""
  @State private var searchPath = NavigationPath()
  @State private var showsProfile = false
  @State private var showsEditShortcuts = false
  @State private var nestedTrayPresented = false
  @State private var tabBarExitHold = false
  @State private var tabBarHoldTask: Task<Void, Never>?

  private var hidesTabBar: Bool {
    showsProfile || showsEditShortcuts || nestedTrayPresented || tabBarExitHold
      || activeNavigationDepth > 0
  }

  private var activeNavigationDepth: Int {
    switch selection {
    case .home: homePath.count
    case .items: itemsPath.count
    case .watchtower: watchtowerPath.count
    case .search: searchPath.count
    }
  }

  var body: some View {
    tabContainer
      .onPreferenceChange(TrayPresentedPreferenceKey.self) { nestedTrayPresented = $0 }
      .onChange(of: showsProfile) { _, presented in
        if presented {
          cancelTabBarHold()
        } else {
          scheduleTabBarRestore()
        }
      }
      .onChange(of: showsEditShortcuts) { _, presented in
        if presented {
          cancelTabBarHold()
        } else {
          scheduleTabBarRestore()
        }
      }
      .onChange(of: nestedTrayPresented) { _, presented in
        if presented {
          cancelTabBarHold()
        } else {
          scheduleTabBarRestore()
        }
      }
      .environment(\.showsProfile, $showsProfile)
      .environment(\.showsEditShortcuts, $showsEditShortcuts)
      .dashTray(isPresented: $showsProfile, title: "Profile") {
        ProfileTrayContent()
      }
      .dashTray(isPresented: $showsEditShortcuts, title: "Edit shortcuts", sizing: .large) {
        EditShortcutsView()
      }
  }

  // Tab(role: .search) detaches the search button beside the tab bar on
  // iOS 26; on 18–25 it renders as a regular trailing tab.
  @ViewBuilder
  private var tabContainer: some View {
    if #available(iOS 18.0, *) {
      TabView(selection: $selection) {
        Tab(value: AppTab.home) {
          FeatureNavigationStack(path: $homePath) { HomeView() }
        } label: {
          tabLabel("Home", asset: selection == .home ? "SolarTabHomeFill" : "SolarTabHomeLine")
        }
        Tab(value: AppTab.items) {
          FeatureNavigationStack(path: $itemsPath) { ItemsView() }
        } label: {
          tabLabel("Items", asset: selection == .items ? "SolarTabItemsFill" : "SolarTabItemsLine")
        }
        Tab(value: AppTab.watchtower) {
          FeatureNavigationStack(path: $watchtowerPath) { WatchtowerView() }
        } label: {
          tabLabel(
            "Watchtower",
            asset: selection == .watchtower ? "SolarTabWatchtowerFill" : "SolarTabWatchtowerLine")
        }
        Tab(value: AppTab.search, role: .search) {
          SearchNavigationStack(search: $search, path: $searchPath)
        } label: {
          tabLabel("Search", asset: SolarAsset.search)
        }
      }
      .modifier(TabBarChrome(hidden: hidesTabBar))
    } else {
      TabView(selection: $selection) {
        FeatureNavigationStack(path: $homePath) { HomeView() }
          .tabItem {
            tabLabel("Home", asset: selection == .home ? "SolarTabHomeFill" : "SolarTabHomeLine")
          }
          .tag(AppTab.home)
        FeatureNavigationStack(path: $itemsPath) { ItemsView() }
          .tabItem {
            tabLabel(
              "Items", asset: selection == .items ? "SolarTabItemsFill" : "SolarTabItemsLine")
          }
          .tag(AppTab.items)
        FeatureNavigationStack(path: $watchtowerPath) { WatchtowerView() }
          .tabItem {
            tabLabel(
              "Watchtower",
              asset: selection == .watchtower ? "SolarTabWatchtowerFill" : "SolarTabWatchtowerLine")
          }
          .tag(AppTab.watchtower)
        SearchNavigationStack(search: $search, path: $searchPath)
          .tabItem {
            tabLabel("Search", asset: SolarAsset.search)
          }
          .tag(AppTab.search)
      }
      .modifier(TabBarChrome(hidden: hidesTabBar))
    }
  }

  private func tabLabel(_ title: String, asset: String) -> some View {
    Image(asset)
      .renderingMode(.template)
      .accessibilityLabel(title)
  }

  private func cancelTabBarHold() {
    tabBarHoldTask?.cancel()
    tabBarHoldTask = nil
    tabBarExitHold = false
  }

  private func scheduleTabBarRestore() {
    tabBarHoldTask?.cancel()
    guard !showsProfile, !showsEditShortcuts, !nestedTrayPresented else { return }
    tabBarExitHold = true
    tabBarHoldTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(400))
      guard !Task.isCancelled else { return }
      tabBarExitHold = false
      tabBarHoldTask = nil
    }
  }
}

private struct TabBarChrome: ViewModifier {
  let hidden: Bool

  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(iOS 18.0, *) {
      content
        .background {
          TabBarVisibilityResolver(hidden: hidden)
            .frame(width: 0, height: 0)
        }
        .toolbarBackground(DashTheme.elevated, for: .tabBar)
    } else {
      content
        .toolbar(hidden ? .hidden : .visible, for: .tabBar)
        .toolbarBackground(DashTheme.elevated, for: .tabBar)
        .toolbarBackground(hidden ? .hidden : .visible, for: .tabBar)
    }
  }
}

enum TabBarVisibilityTransition: Equatable {
  case initial
  case navigation

  var animated: Bool { self == .navigation }
}

struct TabBarVisibilityChange: Equatable {
  let hidden: Bool
  let animated: Bool
}

func tabBarVisibilityChange(
  currentlyHidden: Bool,
  targetHidden: Bool,
  transition: TabBarVisibilityTransition
) -> TabBarVisibilityChange? {
  guard currentlyHidden != targetHidden else { return nil }
  return TabBarVisibilityChange(hidden: targetHidden, animated: transition.animated)
}

@MainActor
private protocol TabBarVisibilityControlling: AnyObject {
  var isTabBarHidden: Bool { get }
  func setTabBarHidden(_ hidden: Bool, animated: Bool)
}

@available(iOS 18.0, *)
extension UITabBarController: TabBarVisibilityControlling {}

@MainActor
private func applyTabBarVisibility(
  _ hidden: Bool,
  to controller: any TabBarVisibilityControlling,
  animated: Bool
) {
  guard
    let change = tabBarVisibilityChange(
      currentlyHidden: controller.isTabBarHidden,
      targetHidden: hidden,
      transition: animated ? .navigation : .initial
    )
  else { return }
  controller.setTabBarHidden(change.hidden, animated: change.animated)
}

@available(iOS 18.0, *)
private struct TabBarVisibilityResolver: UIViewControllerRepresentable {
  let hidden: Bool

  func makeUIViewController(context: Context) -> TabBarVisibilityResolverViewController {
    let controller = TabBarVisibilityResolverViewController()
    controller.targetHidden = hidden
    return controller
  }

  func updateUIViewController(
    _ uiViewController: TabBarVisibilityResolverViewController,
    context: Context
  ) {
    uiViewController.setTargetHidden(hidden)
  }
}

@available(iOS 18.0, *)
private final class TabBarVisibilityResolverViewController: UIViewController {
  var targetHidden = false
  private var resolutionAttempts = 0
  private var manuallyAppliedHidden: Bool?

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    apply(animated: false)
  }

  func setTargetHidden(_ hidden: Bool) {
    targetHidden = hidden
    guard isViewLoaded, view.window != nil else { return }
    apply(animated: true)
  }

  private func apply(animated: Bool) {
    let resolvedTabBarController =
      tabBarController
      ?? findTabBarController(in: viewIfLoaded?.window?.rootViewController)
    guard let resolvedTabBarController else {
      guard resolutionAttempts < 3 else { return }
      resolutionAttempts += 1
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.apply(animated: self.viewIfLoaded?.window != nil)
      }
      return
    }
    resolutionAttempts = 0
    if #available(iOS 26.0, *) {
      applyTabBarChromeVisibility(
        targetHidden, to: resolvedTabBarController, animated: animated)
    } else {
      applyTabBarVisibility(targetHidden, to: resolvedTabBarController, animated: animated)
    }
  }

  private func findTabBarController(in controller: UIViewController?) -> UITabBarController? {
    guard let controller else { return nil }
    if let tabBarController = controller as? UITabBarController {
      return tabBarController
    }
    for child in controller.children {
      if let match = findTabBarController(in: child) {
        return match
      }
    }
    return findTabBarController(in: controller.presentedViewController)
  }

  private func applyTabBarChromeVisibility(
    _ hidden: Bool,
    to controller: UITabBarController,
    animated: Bool
  ) {
    if controller.isTabBarHidden {
      controller.setTabBarHidden(false, animated: false)
    }
    guard manuallyAppliedHidden != hidden else { return }
    manuallyAppliedHidden = hidden

    let tabBar = controller.tabBar
    // On iOS 26 the hosted search field is a sibling of UITabBar. Their
    // common wrapper is two levels above the public tabBar view.
    let animatedView = tabBar.superview?.superview ?? tabBar
    if !hidden {
      animatedView.accessibilityElementsHidden = false
    }
    let changes = {
      animatedView.transform =
        hidden
        ? CGAffineTransform(translationX: 0, y: self.hiddenTabBarOffset(animatedView))
        : .identity
    }
    let completion: (Bool) -> Void = { finished in
      if finished, hidden {
        animatedView.accessibilityElementsHidden = true
      }
    }

    if animated {
      UIView.animate(
        withDuration: 0.35,
        delay: 0,
        options: [.beginFromCurrentState, .curveEaseInOut, .allowUserInteraction],
        animations: changes,
        completion: completion
      )
    } else {
      changes()
      completion(true)
    }
  }

  private func hiddenTabBarOffset(_ view: UIView) -> CGFloat {
    guard let window = view.window else {
      return view.bounds.height + 32
    }
    let frameInWindow = view.convert(view.bounds, to: window)
    return window.bounds.maxY - frameInWindow.minY + 16
  }

}

struct ProfileTrayContent: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    VStack(spacing: 20) {
      HStack(spacing: 16) {
        UserAvatar(email: model.user?.email ?? "", size: 56)
        VStack(alignment: .leading, spacing: 4) {
          Text(model.user?.displayName ?? "—")
            .font(.system(size: 18, weight: .semibold))
          Text(model.user?.email ?? "—")
            .font(.system(size: 14))
            .foregroundStyle(DashTheme.subtle)
          if let account = model.activeAccount {
            Text(account.name)
              .font(.system(size: 13))
              .foregroundStyle(DashTheme.placeholder)
          }
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, DashTheme.Sheet.content)

      DashConfirmableActions(actions: [
        DashDangerAction(
          title: "Sign out",
          icon: SolarAsset.danger,
          message: "You'll need to reconnect your Cloudflare account to use Dash again."
        ) {
          await model.signOut()
        }
      ])
    }
  }
}

private struct DestinationRoutedContent: View {
  let destination: Destination

  var body: some View {
    Group {
      switch destination {
      case .feature(let feature):
        FeatureDetailChrome(feature: feature) {
          FeatureRouterContent(feature: feature)
        }
      case .zone(let id): ZoneDetailView(zoneID: id)
      case .dns(let id): DNSRecordsView(zoneID: id)
      case .cache(let id): CachePurgeView(zoneID: id)
      case .zoneAnalytics(let id): ZoneAnalyticsView(zoneID: id)
      case .zoneSettings(let id): ZoneSettingsView(zoneID: id)
      case .zoneTool(let zoneID, let title, let path):
        GenericResourcesView(
          title: title, path: path.replacingOccurrences(of: "{zone}", with: zoneID))
      case .zonePicker(let feature): FeatureZonePickerView(feature: feature)
      case .zoneFeatureHub(let feature, let zoneID, let zoneName):
        ZoneFeatureHubView(feature: feature, zoneID: zoneID, zoneName: zoneName)
      case .botManagement(let zoneID, let zoneName):
        BotManagementView(zoneID: zoneID, zoneName: zoneName)
      case .cachePerformance(let zoneID, let zoneName):
        CachePerformanceView(zoneID: zoneID, zoneName: zoneName)
      case .rulesetList(let basePath, let title):
        RulesetListView(basePath: basePath, title: title)
      case .ruleset(let basePath, let rulesetID, let name):
        RulesetDetailView(basePath: basePath, rulesetID: rulesetID, name: name)
      case .worker(let name): WorkerDetailView(name: name)
      case .r2Bucket(let name): R2BucketView(bucket: name)
      case .kvNamespace(let id): KVNamespaceView(namespaceID: id)
      case .d1Database(let id, let name): D1ConsoleView(databaseID: id, name: name)
      }
    }
  }
}

extension View {
  func destinationRouting() -> some View {
    navigationDestination(for: Destination.self) { destination in
      DestinationRoutedContent(destination: destination)
    }
  }
}
