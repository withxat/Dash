import SwiftUI

@main
struct DashApp: App {
  @State private var model = AppModel()
  @State private var showSplash = true

  init() {
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
        RootWithSplash(model: model, showSplash: $showSplash)
          .tint(DashTheme.brand)
      }
    }
  }
}

/// Bridges the static system launch screen into the first interactive frame:
/// same `LaunchBackground` + centered `LaunchLogo`, held until bootstrap
/// finishes (and a short minimum), then faded away.
private struct RootWithSplash: View {
  var model: AppModel
  @Binding var showSplash: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private static let minimumDuration: Duration = .milliseconds(800)
  private static let fadeDuration: TimeInterval = 0.35

  var body: some View {
    ZStack {
      AppRootView()
        .environment(model)
        .environment(\.dashSplashLifted, !showSplash)

      if showSplash {
        LaunchSplashView()
          .transition(.opacity)
          .zIndex(1)
      }
    }
    .task {
      async let bootstrap: Void = model.bootstrap()
      try? await Task.sleep(for: Self.minimumDuration)
      await bootstrap

      if reduceMotion {
        showSplash = false
      } else {
        withAnimation(.easeOut(duration: Self.fadeDuration)) {
          showSplash = false
        }
      }
    }
  }
}

/// Matches `UILaunchScreen` composition so the handoff from the system splash
/// does not flash a different layout.
private struct LaunchSplashView: View {
  var body: some View {
    ZStack {
      Color("LaunchBackground")
        .ignoresSafeArea()
      Image("LaunchLogo")
        .resizable()
        .scaledToFit()
        .frame(width: 88, height: 88)
        .clipShape(RoundedRectangle(cornerRadius: 88 * 0.2237, style: .continuous))
        .accessibilityHidden(true)
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
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
