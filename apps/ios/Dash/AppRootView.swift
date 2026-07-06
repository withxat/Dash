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
          VStack(spacing: 12) {
            ZStack {
              RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous)
                .fill(DashTheme.accent)
              Image(systemName: "cloud.fill")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(DashTheme.inverse)
            }
            .frame(width: 64, height: 64)
            Text("Dash")
              .font(.chill(38, heavy: true))
              .foregroundStyle(DashTheme.strong)
            Text(
              "Zones, DNS, cache, security and analytics, your Cloudflare account in your pocket."
            )
            .font(.system(size: 14))
            .foregroundStyle(DashTheme.subtle)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
          }

          if let error = model.errorMessage {
            Text(error)
              .font(.system(size: 13))
              .foregroundStyle(DashTheme.danger)
              .multilineTextAlignment(.center)
          }

          Button {
            model.signIn()
          } label: {
            HStack(spacing: 8) {
              if model.isAuthenticating { ProgressView().tint(DashTheme.inverse) }
              Text("Connect Cloudflare").font(.system(size: 14, weight: .medium))
            }
            .foregroundStyle(DashTheme.inverse)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(DashTheme.brand)
            .clipShape(RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous))
          }
          .buttonStyle(DashOpacityButtonStyle())
          .disabled(model.isAuthenticating || !model.configuration.isConfigured)
          .opacity(model.isAuthenticating || !model.configuration.isConfigured ? 0.5 : 1)

          if !model.configuration.isConfigured {
            DashCard {
              VStack(alignment: .leading, spacing: 8) {
                Text("Almost ready").font(.system(size: 14, weight: .semibold))
                Text(
                  "Add Config/Secrets.xcconfig with your OAuth client values, then rebuild Dash."
                )
                .font(.system(size: 13))
                .foregroundStyle(DashTheme.subtle)
                .fixedSize(horizontal: false, vertical: true)
              }
            }
          }

          DashCard {
            VStack(alignment: .leading, spacing: 4) {
              Text("Secure OAuth with PKCE")
                .font(.system(size: 12))
                .foregroundStyle(DashTheme.subtle)
              Text("Your credentials never pass through the callback relay.")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(DashTheme.text)
                .fixedSize(horizontal: false, vertical: true)
            }
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

private struct MainTabView: View {
  @State private var selection: AppTab = .home
  var body: some View {
    TabView(selection: $selection) {
      NavigationStack { HomeView() }
        .tabItem { Image(systemName: "house.fill").accessibilityLabel("Home") }
        .tag(AppTab.home)
      NavigationStack { ItemsView() }
        .tabItem { Image(systemName: "square.grid.2x2.fill").accessibilityLabel("Items") }
        .tag(AppTab.items)
      NavigationStack { WatchtowerView() }
        .tabItem {
          Image(systemName: "shield.lefthalf.filled").accessibilityLabel("Watchtower")
        }
        .tag(AppTab.watchtower)
    }
    .toolbarBackground(DashTheme.elevated, for: .tabBar)
    .toolbarBackground(.visible, for: .tabBar)
  }
}

struct AccountToolbar: ToolbarContent {
  @Environment(AppModel.self) private var model
  @State private var showsProfile = false

  var body: some ToolbarContent {
    ToolbarItem(placement: .topBarTrailing) {
      Button {
        showsProfile = true
      } label: {
        ZStack {
          Circle().fill(DashTheme.accent)
          Text(model.user?.displayName.prefix(1).uppercased() ?? "D").font(.caption.bold())
            .foregroundStyle(DashTheme.inverse)
        }.frame(width: 32, height: 32)
      }.accessibilityLabel("Profile").sheet(isPresented: $showsProfile) {
        NavigationStack { ProfileView() }
      }
    }
  }
}

private struct ProfileView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    List {
      Section {
        LabeledContent("Name", value: model.user?.displayName ?? "—")
        LabeledContent("Email", value: model.user?.email ?? "—")
      }
      Section("Active account") {
        ForEach(model.accounts) { account in
          Button {
            model.selectAccount(account)
            dismiss()
          } label: {
            HStack {
              Text(account.name)
              Spacer()
              if account.id == model.activeAccountID { Image(systemName: "checkmark") }
            }
          }.foregroundStyle(.primary)
        }
      }
      Section {
        Button("Sign out", role: .destructive) {
          Task {
            await model.signOut()
            dismiss()
          }
        }
      }
    }
    .dashGroupedList()
    .navigationTitle("Profile").navigationBarTitleDisplayMode(.inline)
    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
  }
}

extension View {
  @ViewBuilder func destinationRouting() -> some View {
    navigationDestination(for: Destination.self) { destination in
      switch destination {
      case .feature(let feature): FeatureRouterView(feature: feature)
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
