import CloudflareAPI
import SwiftUI
import UIKit

struct AppRootView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// Lags `model.authState` so sign-in can play the login exit to completion
  /// (stage briefly `nil`) before the catalog entrance — a simultaneous
  /// crossfade hides the exit behind the catalog's opaque canvas.
  @State private var stage: AuthenticationState? = .loading

  var body: some View {
    ZStack {
      // Matches `UILaunchScreen` / the splash canvas: visible during bootstrap
      // and for the beat between the login exit and the catalog entrance.
      Color("LaunchBackground").ignoresSafeArea()

      switch stage {
      case .unauthenticated:
        // Animations ride the transitions themselves: removal transitions
        // reliably animate only when the animation is bound to them, not to
        // the surrounding transaction.
        LoginView()
          .zIndex(1)
          .transition(
            .asymmetric(
              insertion: .opacity.animation(.easeOut(duration: 0.35)),
              removal: .opacity.combined(with: .scale(scale: 0.97))
                .animation(.easeOut(duration: 0.25))
            ))
      case .authenticated:
        MainTabView()
          .transition(
            .asymmetric(
              insertion: .scale(scale: 1.04).combined(with: .opacity)
                .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.55)),
              removal: .opacity.animation(.easeOut(duration: 0.2))
            ))
      case .loading, nil:
        Color.clear
      }
    }
    .onAppear { stage = model.authState }
    .onChange(of: model.authState) { old, new in
      if reduceMotion {
        stage = new
        return
      }
      if old == .unauthenticated, new == .authenticated {
        Task { @MainActor in
          withAnimation(.easeOut(duration: 0.25)) { stage = nil }
          try? await Task.sleep(for: .milliseconds(240))
          withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.55)) { stage = .authenticated }
        }
      } else {
        withAnimation(.easeOut(duration: 0.3)) { stage = new }
      }
    }
  }
}

private struct LoginView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dashSplashLifted) private var splashLifted
  @Environment(\.dashLoginIconCloaked) private var iconCloaked
  @State private var showsPermissions = false
  @State private var revealed = false
  /// Under the splash the icon skips the stagger: the launch logo glides onto
  /// its spot and hands off in place. Later visits (sign-out) stagger it.
  @State private var iconJoinsReveal = false

  var body: some View {
    ZStack {
      LoginBackground()
      VStack(spacing: 32) {
        Spacer()
        VStack(spacing: 16) {
          appIconView
            .opacity(iconCloaked ? 0 : 1)
            .dashReveal(0, shown: iconJoinsReveal ? revealed : true)
            .anchorPreference(key: DashLoginIconAnchorKey.self, value: .bounds) { $0 }
          VStack(spacing: 6) {
            Text("Dash")
              .font(.dashTitle(40))
              .foregroundStyle(DashTheme.strong)
              .dashReveal(1, shown: revealed)
            Text("Cloudflare in your hand")
              .font(.system(size: 17))
              .foregroundStyle(DashTheme.subtle)
              .multilineTextAlignment(.center)
              .dashReveal(2, shown: revealed)
          }
        }
        Spacer()

        VStack(spacing: 16) {
          if let error = model.errorMessage {
            Text(error)
              .font(.system(size: 14))
              .foregroundStyle(DashTheme.danger)
              .multilineTextAlignment(.center)
          }

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

          Button {
            showsPermissions = true
          } label: {
            Text("Permissions")
              .dashTextStyle(.buttonMedium)
              .foregroundStyle(DashTheme.subtle)
              .frame(maxWidth: .infinity, minHeight: 44)
          }
          .buttonStyle(DashPressButtonStyle())
          .dashReveal(3, shown: revealed)

          DashPillButton(
            title: "Start your engine!",
            icon: SolarAsset.cloudflare,
            isLoading: model.isAuthenticating,
            action: { model.signIn() }
          )
          .disabled(!model.configuration.isConfigured)
          .opacity(model.configuration.isConfigured ? 1 : 0.5)
          .dashReveal(4, shown: revealed)

          legalCaption
            .dashReveal(5, shown: revealed)
        }
      }
      .frame(maxWidth: 448)
      .padding(.horizontal, 24)
      .padding(.bottom, 28)
      .frame(maxWidth: .infinity)
    }
    .dashTray(isPresented: $showsPermissions, title: "Permissions") {
      PermissionSelectionView()
    }
    .onAppear {
      iconJoinsReveal = splashLifted
      if splashLifted { revealed = true }
    }
    .onChange(of: splashLifted) { _, lifted in
      if lifted { revealed = true }
    }
  }

  /// Terms/privacy notice. The highlighted spans are styling only for now —
  /// they'll become links once the documents exist.
  private var legalCaption: some View {
    (Text("By using Dash, you agree to accept our\n")
      + Text("Terms of Use").foregroundStyle(DashTheme.text).fontWeight(.medium)
      + Text(" and ")
      + Text("Privacy Policy").foregroundStyle(DashTheme.text).fontWeight(.medium)
      + Text("."))
      .font(.system(size: 12))
      .lineSpacing(5)
      .foregroundStyle(DashTheme.subtle)
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity)
      .padding(.top, 20)
  }

  /// A raster copy of the app icon (`LoginAppIcon`). Never read the compiled
  /// `AppIcon` through `UIImage(named:)`: on iOS 26 it can resolve to an Icon
  /// Composer layer stack without a bitmap and crash with "Need an imageRef".
  private var appIconView: some View {
    Image("LoginAppIcon")
      .resizable()
      .scaledToFit()
      .frame(width: 88, height: 88)
      .clipShape(RoundedRectangle(cornerRadius: 88 * 0.2237, style: .continuous))
      .accessibilityHidden(true)
  }
}

// MARK: - Login background

/// Sign-in backdrop: a slowly drifting warm mesh gradient (iOS 18+) under a
/// static Metal film grain (`LoginGrain.metal`). iOS 17 and Reduce Motion get
/// a still gradient with the same grain.
private struct LoginBackground: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Group {
      if #available(iOS 18.0, *) {
        LoginMeshGradient(animated: !reduceMotion, dark: colorScheme == .dark)
      } else {
        LoginStaticGradient(dark: colorScheme == .dark)
      }
    }
    .colorEffect(ShaderLibrary.loginGrain(.float(0.12)))
    .ignoresSafeArea()
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

@available(iOS 18.0, *)
private struct LoginMeshGradient: View {
  let animated: Bool
  let dark: Bool

  var body: some View {
    if animated {
      TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
        mesh(at: context.date.timeIntervalSinceReferenceDate)
      }
    } else {
      mesh(at: 0)
    }
  }

  private func mesh(at t: TimeInterval) -> MeshGradient {
    MeshGradient(
      width: 3, height: 3,
      points: Self.points(at: t),
      colors: dark ? DashTheme.LoginBackdrop.meshDark : DashTheme.LoginBackdrop.meshLight
    )
  }

  /// Edge points keep their pinned axis so the mesh always covers the canvas;
  /// the free axes and the center drift on slow, unsynchronized waves.
  private static func points(at t: TimeInterval) -> [SIMD2<Float>] {
    func wave(_ speed: Double, _ phase: Double, _ amplitude: Double) -> Float {
      Float(0.5 + amplitude * sin(t * speed + phase))
    }
    return [
      [0, 0], [wave(0.60, 0.0, 0.24), 0], [1, 0],
      [0, wave(0.50, 1.3, 0.22)],
      [wave(0.70, 2.1, 0.28), wave(0.40, 4.2, 0.26)],
      [1, wave(0.45, 5.1, 0.22)],
      [0, 1], [wave(0.55, 3.4, 0.24), 1], [1, 1],
    ]
  }

}

/// iOS 17 fallback: the same warm palette as a still diagonal wash.
private struct LoginStaticGradient: View {
  let dark: Bool

  var body: some View {
    LinearGradient(
      colors: dark ? DashTheme.LoginBackdrop.stillDark : DashTheme.LoginBackdrop.stillLight,
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }
}

private struct PermissionSelectionView: View {
  @Environment(AppModel.self) private var model
  private var categories: [(key: String, values: [OAuthScopeDefinition])] {
    OAuthScopeCatalog.categories
      .map { ($0.key, $0.value.sorted { $0.name < $1.name }) }
      .sorted { ($0.1.first?.categoryTitle ?? $0.0) < ($1.1.first?.categoryTitle ?? $1.0) }
  }

  var body: some View {
    VStack(spacing: 14) {
      Text("All published capabilities are selected by default.")
        .dashTextStyle(.supporting)
        .foregroundStyle(DashTheme.subtle)
        .frame(maxWidth: .infinity, alignment: .leading)

      permissionRow(
        "All OAuth-enabled permissions",
        detail: "\(model.selectedScopes.count) of \(CloudflareScopes.published.count) selected",
        isOn: allBinding
      )

      ForEach(categories, id: \.key) { category in
        permissionRow(
          category.values.first?.categoryTitle ?? category.key,
          detail: categoryDetail(category.values),
          isOn: categoryBinding(category.values),
          disabled:
            Set(category.values.map(\.id)).intersection(CloudflareScopes.requestable).isEmpty
        )
      }
    }
    .padding(.horizontal, DashTheme.Sheet.content)
  }

  /// A whole-row toggle target: the bare switch ignores taps on its empty track
  /// on this iOS, and a full row is the friendlier target anyway. The switch is
  /// display-only; the row button flips the binding.
  private func permissionRow(
    _ title: String,
    detail: String,
    isOn: Binding<Bool>,
    disabled: Bool = false
  ) -> some View {
    Button {
      isOn.wrappedValue.toggle()
    } label: {
      HStack(spacing: 12) {
        permissionLabel(title, detail: detail)
        Spacer(minLength: 12)
        Toggle("", isOn: isOn)
          .labelsHidden()
          .tint(DashTheme.brand)
          .allowsHitTesting(false)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(DashPressButtonStyle())
    .disabled(disabled)
    .accessibilityElement(children: .combine)
  }

  private func categoryDetail(_ scopes: [OAuthScopeDefinition]) -> String {
    let count = scopes.count
    return count == 1 ? "1 permission" : "\(count) permissions"
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

  private func permissionLabel(_ title: String, detail: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.subheadline.weight(.medium))
        .foregroundStyle(DashTheme.text)
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

  private func pushOnActiveTab(_ destination: Destination) {
    switch selection {
    case .home: homePath.append(destination)
    case .items: itemsPath.append(destination)
    case .watchtower: watchtowerPath.append(destination)
    case .search: searchPath.append(destination)
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
        ProfileTrayContent {
          showsProfile = false
          pushOnActiveTab(.profile)
        }
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
          tabLabel(
            "Home", asset: selection == .home ? "SolarTabHomeFill" : "SolarTabHomeLine",
            active: selection == .home)
        }
        Tab(value: AppTab.items) {
          FeatureNavigationStack(path: $itemsPath) { ItemsView() }
        } label: {
          tabLabel(
            "Items", asset: selection == .items ? "SolarTabItemsFill" : "SolarTabItemsLine",
            active: selection == .items)
        }
        Tab(value: AppTab.watchtower) {
          FeatureNavigationStack(path: $watchtowerPath) { WatchtowerView() }
        } label: {
          tabLabel(
            "Watchtower",
            asset: selection == .watchtower ? "SolarTabWatchtowerFill" : "SolarTabWatchtowerLine",
            active: selection == .watchtower)
        }
        Tab(value: AppTab.search, role: .search) {
          SearchNavigationStack(search: $search, path: $searchPath)
        } label: {
          tabLabel(
            "Search", asset: selection == .search ? "SolarTabSearchFill" : "SolarTabSearchLine",
            active: selection == .search)
        }
      }
      .modifier(TabBarChrome(hidden: hidesTabBar))
    } else {
      TabView(selection: $selection) {
        FeatureNavigationStack(path: $homePath) { HomeView() }
          .tabItem {
            tabLabel(
              "Home", asset: selection == .home ? "SolarTabHomeFill" : "SolarTabHomeLine",
              active: selection == .home)
          }
          .tag(AppTab.home)
        FeatureNavigationStack(path: $itemsPath) { ItemsView() }
          .tabItem {
            tabLabel(
              "Items", asset: selection == .items ? "SolarTabItemsFill" : "SolarTabItemsLine",
              active: selection == .items)
          }
          .tag(AppTab.items)
        FeatureNavigationStack(path: $watchtowerPath) { WatchtowerView() }
          .tabItem {
            tabLabel(
              "Watchtower",
              asset: selection == .watchtower ? "SolarTabWatchtowerFill" : "SolarTabWatchtowerLine",
              active: selection == .watchtower)
          }
          .tag(AppTab.watchtower)
        SearchNavigationStack(search: $search, path: $searchPath)
          .tabItem {
            tabLabel(
              "Search", asset: selection == .search ? "SolarTabSearchFill" : "SolarTabSearchLine",
              active: selection == .search)
          }
          .tag(AppTab.search)
      }
      .modifier(TabBarChrome(hidden: hidesTabBar))
    }
  }

  /// Active tabs render as templates so the UIKit appearance proxy's selected
  /// icon color applies; inactive tabs render original with the quiet gray
  /// baked into the Line SVGs, because the iOS 26 tab bar ignores both
  /// `normal.iconColor` and `unselectedItemTintColor`.
  private func tabLabel(_ title: String, asset: String, active: Bool) -> some View {
    Image(asset)
      .renderingMode(active ? .template : .original)
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
  @Environment(\.dashTrayDismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// Dismisses the tray and pushes the Profile page onto the active tab.
  let openProfile: () -> Void
  @State private var showsAccounts = false

  private var morphAnimation: Animation {
    reduceMotion ? DashTheme.Motion.reduced : DashTheme.Motion.morph
  }

  var body: some View {
    ZStack {
      if showsAccounts {
        accountList
          .transition(reduceMotion ? .opacity : .dashMorph)
      } else {
        menu
          .transition(reduceMotion ? .opacity : .dashMorph)
      }
    }
  }

  private var menu: some View {
    VStack(spacing: 20) {
      HStack(spacing: 16) {
        UserAvatar(email: model.user?.email ?? "", size: 56)
        VStack(alignment: .leading, spacing: 4) {
          Text(model.profileTitle)
            .font(.system(size: 18, weight: .semibold))
          if let email = model.user?.email, email != model.profileTitle {
            Text(email)
              .font(.system(size: 14))
              .foregroundStyle(DashTheme.subtle)
          }
          if let account = model.activeAccount, account.name != model.profileTitle {
            Text(account.name)
              .font(.system(size: 13))
              .foregroundStyle(DashTheme.placeholder)
          }
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, DashTheme.Sheet.content)

      VStack(spacing: 10) {
        menuRow(title: "Profile", icon: SolarAsset.userCircle, action: openProfile)
        if model.accounts.count > 1 {
          menuRow(title: "Switch account", icon: SolarAsset.users) {
            withAnimation(morphAnimation) { showsAccounts = true }
          }
        }

        DashConfirmableActions(
          actions: [
            DashDangerAction(
              title: "Sign out",
              icon: SolarAsset.danger,
              message: "You'll need to reconnect your Cloudflare account to use Dash again."
            ) {
              await model.signOut()
            }
          ], horizontalInset: 0)
      }
      .padding(.horizontal, DashTheme.Sheet.content)
    }
  }

  private var accountList: some View {
    VStack(spacing: 16) {
      VStack(spacing: 10) {
        ForEach(model.accounts) { account in
          Button {
            model.selectAccount(account)
            dismiss()
          } label: {
            HStack(spacing: 12) {
              Text(account.name)
                .dashTextStyle(.bodyMedium)
                .foregroundStyle(DashTheme.text)
                .lineLimit(1)
              Spacer(minLength: 0)
              SolarIcon(
                asset: account.id == model.activeAccountID
                  ? SolarAsset.checkCircle : SolarAsset.circle,
                size: 22,
                color: account.id == model.activeAccountID
                  ? DashTheme.brand : DashTheme.placeholder)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DashTheme.Sheet.shortcutItem, in: DashTheme.buttonShape)
          }
          .buttonStyle(DashPressButtonStyle())
          .accessibilityAddTraits(account.id == model.activeAccountID ? .isSelected : [])
        }
      }

      Button {
        withAnimation(morphAnimation) { showsAccounts = false }
      } label: {
        Text("Back")
          .dashTextStyle(.buttonMedium)
          .foregroundStyle(DashTheme.subtle)
          .frame(maxWidth: .infinity, minHeight: 44)
      }
      .buttonStyle(DashPressButtonStyle())
    }
    .padding(.horizontal, DashTheme.Sheet.content)
  }

  private func menuRow(title: String, icon: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 12) {
        SolarIcon(asset: icon, size: 22, color: DashTheme.iconMuted)
        Text(title)
          .dashTextStyle(.bodyMedium)
          .foregroundStyle(DashTheme.text)
          .lineLimit(1)
        Spacer(minLength: 0)
        SolarIcon(asset: SolarAsset.chevronRight, size: 16, color: DashTheme.placeholder)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(DashTheme.Sheet.shortcutItem, in: DashTheme.buttonShape)
    }
    .buttonStyle(DashPressButtonStyle())
  }
}

/// The standalone Profile page, pushed from the avatar tray's Profile row:
/// identity, user id and registration date, and the active account's details.
/// Switching accounts and signing out stay on the tray menu.
struct ProfileView: View {
  @Environment(AppModel.self) private var model
  @State private var showsRename = false
  @State private var renameText = ""
  @State private var renaming = false
  @State private var renameError: String?

  var body: some View {
    ScrollView {
      LazyVStack(spacing: DashTheme.Spacing.section) {
        VStack(spacing: 12) {
          UserAvatar(email: model.user?.email ?? "", size: 80)
          VStack(spacing: 2) {
            Text(model.profileTitle)
              .dashTextStyle(.sheetTitle)
              .foregroundStyle(DashTheme.strong)
            if let email = model.user?.email, email != model.profileTitle {
              Text(email)
                .dashTextStyle(.supporting)
                .foregroundStyle(DashTheme.subtle)
            }
          }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)

        DashCard {
          VStack(alignment: .leading, spacing: 0) {
            profileField(label: "User ID", value: model.user?.id ?? "—", mono: true)
            DashListGroupDivider()
            profileField(label: "Registered", value: formattedDate(model.user?.createdOn) ?? "—")
          }
        }

        if let account = model.activeAccount {
          VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
              Text("Active account")
                .dashTextStyle(.footnoteSemibold)
                .foregroundStyle(DashTheme.subtle)
              Spacer(minLength: 0)
              Button {
                renameError = nil
                renameText = account.name
                showsRename = true
              } label: {
                SolarIcon(asset: SolarAsset.pen, size: 18, color: DashTheme.faint)
                  .dashCompactHitTarget()
              }
              .buttonStyle(DashPressButtonStyle())
              .accessibilityLabel("Rename account")
            }
            DashCard {
              VStack(alignment: .leading, spacing: 0) {
                profileField(label: "Name", value: account.name)
                DashListGroupDivider()
                profileField(label: "Account ID", value: account.id, mono: true)
                if let created = formattedDate(account.createdOn) {
                  DashListGroupDivider()
                  profileField(label: "Created", value: created)
                }
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }

      }
      .dashContentColumn()
      .padding(.horizontal, DashTheme.Spacing.screen)
      .padding(.vertical, DashTheme.Spacing.section)
    }
    .background(DashTheme.canvas)
    .navigationTitle("Profile")
    .navigationBarTitleDisplayMode(.inline)
    .dashTray(isPresented: $showsRename, title: "Rename account") {
      DashFormSheet(
        isSaving: renaming,
        canSave: !renameText.trimmingCharacters(in: .whitespaces).isEmpty,
        onSave: { Task { await renameAccount() } }
      ) {
        VStack(spacing: 14) {
          if let renameError {
            DashNotice(kind: .error, message: renameError)
          }
          DashFormField(label: "Name", text: $renameText)
        }
      }
    }
  }

  private func renameAccount() async {
    renaming = true
    renameError = nil
    do {
      try await model.renameActiveAccount(
        to: renameText.trimmingCharacters(in: .whitespaces))
      showsRename = false
    } catch {
      renameError = error.dashActionableMessage
    }
    renaming = false
  }

  private func profileField(label: String, value: String, mono: Bool = false) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label)
        .dashTextStyle(.footnoteSemibold)
        .foregroundStyle(DashTheme.subtle)
      Text(value)
        .font(mono ? .system(size: 14, design: .monospaced) : .system(size: 15))
        .foregroundStyle(DashTheme.text)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// Cloudflare timestamps arrive as ISO 8601, with or without fractional
  /// seconds; render them as a plain date.
  private func formattedDate(_ iso: String?) -> String? {
    guard let iso else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plain = ISO8601DateFormatter()
    guard let date = fractional.date(from: iso) ?? plain.date(from: iso) else { return iso }
    return date.formatted(date: .abbreviated, time: .omitted)
  }
}

private struct DestinationRoutedContent: View {
  let destination: Destination

  var body: some View {
    Group {
      switch destination {
      case .profile: ProfileView()
      case .accountDNSSettings: AccountDNSSettingsView()
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
      case .accessAppPolicies(let appID, let appName):
        AccessAppPoliciesView(appID: appID, appName: appName)
      case .worker(let name): WorkerDetailView(name: name)
      case .r2Bucket(let name): R2BucketView(bucket: name)
      case .kvNamespace(let id): KVNamespaceView(namespaceID: id)
      case .d1Database(let id, let name): D1ConsoleView(databaseID: id, name: name)
      case .d1Table(let databaseID, let databaseName, let table):
        D1TableView(databaseID: databaseID, databaseName: databaseName, table: table)
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
