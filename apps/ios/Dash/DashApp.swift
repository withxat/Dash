import SwiftUI

@main
struct DashApp: App {
  @State private var model = AppModel()

  init() {
    let appearance = UINavigationBarAppearance()
    appearance.configureWithDefaultBackground()
    appearance.backgroundColor = .clear
    appearance.shadowColor = .clear
    if let largeTitleFont = UIFont(name: "ChillRoundGothic_Bold", size: 34) {
      appearance.largeTitleTextAttributes = [.font: largeTitleFont]
    }
    UINavigationBar.appearance().standardAppearance = appearance
    UINavigationBar.appearance().scrollEdgeAppearance = appearance
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
