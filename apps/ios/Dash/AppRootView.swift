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
      VStack(spacing: 24) {
        Spacer()
        ZStack {
          RoundedRectangle(cornerRadius: 28, style: .continuous).fill(DashTheme.accent.gradient)
          Image(systemName: "cloud.fill").font(.system(size: 44, weight: .bold)).foregroundStyle(
            .white)
        }.frame(width: 96, height: 96).shadow(
          color: DashTheme.accent.opacity(0.28), radius: 24, y: 12)
        VStack(spacing: 8) {
          Text("Dash").font(.chill(42, heavy: true))
          Text("Cloudflare in your pocket").font(.subheadline).foregroundStyle(DashTheme.subtle)
        }
        Spacer()
        VStack(spacing: 12) {
          if let error = model.errorMessage {
            Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
          }
          Button {
            model.signIn()
          } label: {
            HStack {
              if model.isAuthenticating { ProgressView().tint(.white) }
              Text("Continue with Cloudflare").fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 14)
          }
          .buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle(radius: 14))
          .disabled(model.isAuthenticating || !model.configuration.isConfigured)
          if !model.configuration.isConfigured {
            Text("OAuth is not configured. Add Config/Secrets.xcconfig and rebuild.").font(.caption)
              .foregroundStyle(DashTheme.subtle).multilineTextAlignment(.center)
          }
          Text(
            "Dash uses Cloudflare OAuth with PKCE. Your credentials never pass through the relay."
          )
          .font(.caption2).foregroundStyle(DashTheme.subtle).multilineTextAlignment(.center)
        }.padding(.bottom, 24)
      }.padding(.horizontal, 28)
    }
  }
}

private enum AppTab: Hashable { case home, items, watchtower }

private struct MainTabView: View {
  @State private var selection: AppTab = .home
  var body: some View {
    TabView(selection: $selection) {
      NavigationStack { HomeView() }
        .tabItem { Label("Home", systemImage: "house.fill") }
        .tag(AppTab.home)
      NavigationStack { ItemsView() }
        .tabItem { Label("Items", systemImage: "square.grid.2x2.fill") }
        .tag(AppTab.items)
      NavigationStack { WatchtowerView() }
        .tabItem { Label("Watchtower", systemImage: "shield.lefthalf.filled") }
        .tag(AppTab.watchtower)
    }
    .toolbarBackground(.ultraThinMaterial, for: .tabBar)
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
          Circle().fill(DashTheme.brand.opacity(0.14))
          Text(model.user?.displayName.prefix(1).uppercased() ?? "D").font(.caption.bold())
            .foregroundStyle(DashTheme.brand)
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
