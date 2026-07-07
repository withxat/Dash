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
