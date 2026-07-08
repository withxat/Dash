import SwiftUI

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

private enum AppTab: Hashable { case home, items, watchtower, search }

private struct FeatureNavigationStack<Root: View>: View {
  @ViewBuilder let root: () -> Root

  var body: some View {
    NavigationStack {
      root()
        .destinationRouting()
    }
  }
}

private struct MainTabView: View {
  @State private var selection: AppTab = .home
  @State private var showsProfile = false
  @State private var showsEditShortcuts = false
  @State private var nestedTrayPresented = false
  @State private var tabBarExitHold = false
  @State private var tabBarHoldTask: Task<Void, Never>?

  private var hidesTabBar: Bool {
    showsProfile || showsEditShortcuts || nestedTrayPresented || tabBarExitHold
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
          FeatureNavigationStack { HomeView() }
        } label: {
          tabLabel("Home", asset: selection == .home ? "SolarTabHomeFill" : "SolarTabHomeLine")
        }
        Tab(value: AppTab.items) {
          FeatureNavigationStack { ItemsView() }
        } label: {
          tabLabel("Items", asset: selection == .items ? "SolarTabItemsFill" : "SolarTabItemsLine")
        }
        Tab(value: AppTab.watchtower) {
          FeatureNavigationStack { WatchtowerView() }
        } label: {
          tabLabel(
            "Watchtower",
            asset: selection == .watchtower ? "SolarTabWatchtowerFill" : "SolarTabWatchtowerLine")
        }
        Tab(value: AppTab.search, role: .search) {
          FeatureNavigationStack { SearchView() }
        } label: {
          tabLabel("Search", asset: SolarAsset.search)
        }
      }
      .modifier(TabBarChrome(hidden: hidesTabBar))
    } else {
      TabView(selection: $selection) {
        FeatureNavigationStack { HomeView() }
          .tabItem {
            tabLabel("Home", asset: selection == .home ? "SolarTabHomeFill" : "SolarTabHomeLine")
          }
          .tag(AppTab.home)
        FeatureNavigationStack { ItemsView() }
          .tabItem {
            tabLabel(
              "Items", asset: selection == .items ? "SolarTabItemsFill" : "SolarTabItemsLine")
          }
          .tag(AppTab.items)
        FeatureNavigationStack { WatchtowerView() }
          .tabItem {
            tabLabel(
              "Watchtower",
              asset: selection == .watchtower ? "SolarTabWatchtowerFill" : "SolarTabWatchtowerLine")
          }
          .tag(AppTab.watchtower)
        FeatureNavigationStack { SearchView() }
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

  func body(content: Content) -> some View {
    content
      .toolbar(hidden ? .hidden : .visible, for: .tabBar)
      .toolbarBackground(DashTheme.elevated, for: .tabBar)
      .toolbarBackground(hidden ? .hidden : .visible, for: .tabBar)
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
          message: "You'll need to reconnect your Cloudflare account to use Dash again.",
          confirmTitle: "Sign out"
        ) {
          await model.signOut()
        }
      ])
    }
  }
}

extension View {
  @ViewBuilder func destinationRouting() -> some View {
    navigationDestination(for: Destination.self) { destination in
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
        case .worker(let name): WorkerDetailView(name: name)
        case .r2Bucket(let name): R2BucketView(bucket: name)
        case .kvNamespace(let id): KVNamespaceView(namespaceID: id)
        case .d1Database(let id, let name): D1ConsoleView(databaseID: id, name: name)
        }
      }
      .toolbar(.hidden, for: .tabBar)
    }
  }
}
