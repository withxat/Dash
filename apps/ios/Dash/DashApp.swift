import SwiftUI

@main
struct DashApp: App {
  @State private var model = AppModel()

  init() {
    let appearance = UINavigationBarAppearance()
    appearance.configureWithDefaultBackground()
    appearance.backgroundColor = .clear
    appearance.shadowColor = .clear
    appearance.largeTitleTextAttributes = [
      .font: UIFont.dashRounded(size: 34, weight: .bold)
    ]
    UINavigationBar.appearance().standardAppearance = appearance
    UINavigationBar.appearance().scrollEdgeAppearance = appearance

    // Minimal back chevron — same leading slot as the tab-root profile avatar.
    let backImage = UIImage(named: SolarAsset.chevronLeft)?.withRenderingMode(.alwaysTemplate)
    UINavigationBar.appearance().backIndicatorImage = backImage
    UINavigationBar.appearance().backIndicatorTransitionMaskImage = backImage
  }

  var body: some Scene {
    WindowGroup {
      AppRootView()
        .environment(model)
        .tint(DashTheme.brand)
        .task { await model.bootstrap() }
    }
  }
}
