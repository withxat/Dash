import SwiftUI

@main
struct DashApp: App {
  @State private var model = AppModel()

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
        AppRootView()
          .environment(model)
          .tint(DashTheme.brand)
          .task { await model.bootstrap() }
      }
    }
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
