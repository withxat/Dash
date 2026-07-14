import AppIntents
import SwiftUI

@main
struct DashApp: App {
  @UIApplicationDelegateAdaptor(PushDelegate.self) private var pushDelegate
  @State private var model: AppModel

  init() {
    let model = AppModel()
    _model = State(initialValue: model)
    // In-app App Intents run in this process; hand them the app's own model
    // so they share its client and single-flight token refresh.
    AppDependencyManager.shared.add(dependency: model)

    let largeTitleAttributes: [NSAttributedString.Key: Any] = [
      .font: UIFont.dashTitle(size: AvatarHeaderMetrics.titleSize, weight: .bold),
      .foregroundColor: UIColor.label,
    ]
    let inlineTitleAttributes: [NSAttributedString.Key: Any] = [
      .font: UIFont.dashTitle(size: 17, weight: .semibold),
      .foregroundColor: UIColor.label,
    ]

    let scrollEdgeAppearance = UINavigationBarAppearance()
    scrollEdgeAppearance.configureWithTransparentBackground()
    scrollEdgeAppearance.largeTitleTextAttributes = largeTitleAttributes
    scrollEdgeAppearance.titleTextAttributes = inlineTitleAttributes
    scrollEdgeAppearance.shadowColor = .clear

    // Default background keeps the system blur material, so scrolled content
    // frosts through the inline-title bar instead of hitting a flat canvas.
    let standardAppearance = UINavigationBarAppearance()
    standardAppearance.configureWithDefaultBackground()
    standardAppearance.largeTitleTextAttributes = largeTitleAttributes
    standardAppearance.titleTextAttributes = inlineTitleAttributes
    standardAppearance.shadowColor = .clear

    UINavigationBar.appearance().scrollEdgeAppearance = scrollEdgeAppearance
    UINavigationBar.appearance().standardAppearance = standardAppearance
    UINavigationBar.appearance().compactAppearance = standardAppearance

    // Minimal back chevron — same leading slot as the tab-root profile avatar.
    let backImage = UIImage(named: SolarAsset.chevronLeft)?.withRenderingMode(.alwaysTemplate)
    UINavigationBar.appearance().backIndicatorImage = backImage
    UINavigationBar.appearance().backIndicatorTransitionMaskImage = backImage

    // Tab icons: near-black when selected (instead of the global brand tint),
    // quiet gray otherwise. SwiftUI ignores foregroundStyle on tab labels, so
    // this has to go through the UIKit appearance proxy.
    let tabAppearance = UITabBarAppearance()
    let inactive = UIColor(red: 0xBD / 255, green: 0xBF / 255, blue: 0xC1 / 255, alpha: 1)
    let active = UIColor { $0.userInterfaceStyle == .dark ? .white : .black }
    for item in [
      tabAppearance.stackedLayoutAppearance,
      tabAppearance.inlineLayoutAppearance,
      tabAppearance.compactInlineLayoutAppearance,
    ] {
      item.normal.iconColor = inactive
      item.selected.iconColor = active
    }
    UITabBar.appearance().standardAppearance = tabAppearance
    UITabBar.appearance().scrollEdgeAppearance = tabAppearance
    UITabBar.appearance().unselectedItemTintColor = inactive
  }

  var body: some Scene {
    WindowGroup {
      if ProcessInfo.processInfo.arguments.contains("-uiTestKeyboardForm") {
        KeyboardDismissalTestHost()
          .tint(DashTheme.brand)
      } else {
        RootWithSplash(model: model)
          .tint(DashTheme.brand)
          .onAppear { pushDelegate.inbox = model }
      }
    }
    .backgroundTask(.appRefresh(AppModel.backgroundRefreshID)) {
      await model.performBackgroundWatchtowerRefresh()
    }
  }
}

/// Bridges the static system launch screen into the first interactive frame:
/// same `LaunchBackground` + centered `LaunchLogo`, held until bootstrap
/// finishes (and a short minimum). Signed out, the canvas fades while the
/// logo glides onto the login screen's icon and hands off in place; signed
/// in, everything fades together.
private struct RootWithSplash: View {
  var model: AppModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var phase: Phase = .holding

  private enum Phase { case holding, revealing, done }

  private static let minimumDuration: Duration = .milliseconds(800)
  private static let revealDuration: TimeInterval = 0.6

  var body: some View {
    AppRootView()
      .environment(model)
      .onOpenURL { url in
        if let route = DashRoute.parse(url) { model.pendingRoute = route }
      }
      .environment(\.dashSplashLifted, phase != .holding)
      .environment(\.dashLoginIconCloaked, phase != .done)
      .overlayPreferenceValue(DashLoginIconAnchorKey.self) { anchor in
        if phase != .done {
          // Full-screen space: the system launch screen centers its image in
          // the whole screen, so the overlay must too or the logo jumps ~12pt
          // at handoff (the root view's frame is inset by asymmetric safe
          // areas).
          GeometryReader { proxy in
            splashOverlay(in: proxy, target: anchor.map { proxy[$0] })
          }
          .ignoresSafeArea()
          .allowsHitTesting(false)
          .accessibilityHidden(true)
        }
      }
      .task {
        async let bootstrap: Void = model.bootstrap()
        try? await Task.sleep(for: Self.minimumDuration)
        await bootstrap

        if reduceMotion {
          phase = .done
          return
        }
        withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: Self.revealDuration)) {
          phase = .revealing
        }
        try? await Task.sleep(for: .milliseconds(Int(Self.revealDuration * 1000) + 50))
        phase = .done
      }
  }

  /// Matches `UILaunchScreen` composition while holding. `target` is the
  /// login icon's frame when the login screen is mounted underneath.
  private func splashOverlay(in proxy: GeometryProxy, target: CGRect?) -> some View {
    let holding = phase == .holding
    return ZStack(alignment: .topLeading) {
      Color("LaunchBackground")
        .ignoresSafeArea()
        .opacity(holding ? 1 : 0)
      Image("LaunchLogo")
        .resizable()
        .scaledToFit()
        .frame(width: 88, height: 88)
        .clipShape(RoundedRectangle(cornerRadius: 88 * 0.2237, style: .continuous))
        .position(logoCenter(in: proxy, target: target))
        .opacity(holding || target != nil ? 1 : 0)
    }
  }

  private func logoCenter(in proxy: GeometryProxy, target: CGRect?) -> CGPoint {
    if phase != .holding, let target {
      return CGPoint(x: target.midX, y: target.midY)
    }
    return CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
  }
}

private struct KeyboardDismissalTestHost: View {
  @State private var text = ""
  @State private var presentsForm = true

  var body: some View {
    Color.clear
      .dashTray(isPresented: $presentsForm, title: "Keyboard test") {
        DashFormSheet(
          onSave: {},
          content: {
            VStack(spacing: 24) {
              DashFormField(label: "Name", text: $text)
              Text("Form background")
                .frame(maxWidth: .infinity, minHeight: 80)
            }
          }
        )
      }
  }
}
