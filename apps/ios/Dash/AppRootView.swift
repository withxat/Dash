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

private enum AppTab: Hashable { case home, items, watchtower }

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
  @Namespace private var featureHero
  @State private var featureTransitionCoordinator = FeatureTransitionCoordinator()
  @State private var selection: AppTab = .home
  @State private var showsProfile = false
  @State private var showsEditShortcuts = false
  @State private var nestedTrayPresented = false
  @State private var tabBarExitHold = false
  @State private var tabBarHoldTask: Task<Void, Never>?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var reduceMotionTransition: AnyTransition {
    reduceMotion ? .identity : .opacity
  }

  private var hidesTabBar: Bool {
    featureTransitionCoordinator.presentedFeature != nil
      || showsProfile || showsEditShortcuts || nestedTrayPresented || tabBarExitHold
  }

  var body: some View {
    ZStack {
      TabView(selection: $selection) {
        FeatureNavigationStack { HomeView() }
          .tabItem {
            Image(selection == .home ? "SolarTabHomeFill" : "SolarTabHomeLine")
              .renderingMode(.template)
              .accessibilityLabel("Home")
          }
          .tag(AppTab.home)
        FeatureNavigationStack { ItemsView() }
          .tabItem {
            Image(selection == .items ? "SolarTabItemsFill" : "SolarTabItemsLine")
              .renderingMode(.template)
              .accessibilityLabel("Items")
          }
          .tag(AppTab.items)
        FeatureNavigationStack { WatchtowerView() }
          .tabItem {
            Image(
              selection == .watchtower ? "SolarTabWatchtowerFill" : "SolarTabWatchtowerLine"
            )
            .renderingMode(.template)
            .accessibilityLabel("Watchtower")
          }
          .tag(AppTab.watchtower)
      }
      .zIndex(0)
      .opacity(featureTransitionCoordinator.presentedFeature == nil ? 1 : 0.94)

      if let feature = featureTransitionCoordinator.presentedFeature {
        FeatureDetailOverlay(feature: feature) {
          featureTransitionCoordinator.dismiss(reduceMotion: reduceMotion)
        }
        .zIndex(
          featureTransitionCoordinator.isAnimatingHero
            ? FeatureHeroZIndex.heroShell
            : FeatureHeroZIndex.detailShell
        )
        .transition(reduceMotionTransition)
      }
    }
    .environment(\.featureZoomNamespace, featureHero)
    .environment(featureTransitionCoordinator)
    .toolbar(hidesTabBar ? .hidden : .visible, for: .tabBar)
    .toolbarBackground(DashTheme.elevated, for: .tabBar)
    .toolbarBackground(hidesTabBar ? .hidden : .visible, for: .tabBar)
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

struct AccountToolbar: ToolbarContent {
  @Environment(AppModel.self) private var model
  @Environment(\.showsProfile) private var showsProfile

  var body: some ToolbarContent {
    leadingAvatarItem
  }

  @ToolbarContentBuilder
  private var leadingAvatarItem: some ToolbarContent {
    if #available(iOS 26.0, *) {
      ToolbarItem(placement: .topBarLeading) { profileButton }
        .sharedBackgroundVisibility(.hidden)
    } else {
      ToolbarItem(placement: .topBarLeading) { profileButton }
    }
  }

  private var profileButton: some View {
    Button {
      showsProfile.wrappedValue = true
    } label: {
      HeaderProfileAvatar(email: model.user?.email ?? "")
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Open profile")
  }
}

struct ProfileTrayContent: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dashTrayDismiss) private var dismiss

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

      VStack(spacing: 12) {
        DashActionRow(
          title: "Sign out",
          icon: SolarAsset.danger,
          role: .destructive
        ) {
          Task {
            await model.signOut()
            dismiss()
          }
        }
      }
    }
    .padding(.horizontal, DashTheme.Sheet.content)
    .padding(.bottom, DashTheme.Sheet.bodyBottom)
  }
}

extension View {
  @ViewBuilder func destinationRouting() -> some View {
    navigationDestination(for: Destination.self) { destination in
      switch destination {
      case .feature:
        EmptyView()
      case .zone(let id): ZoneDetailView(zoneID: id)
      case .dns(let id): DNSRecordsView(zoneID: id)
      case .cache(let id): CachePurgeView(zoneID: id)
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
  }
}
